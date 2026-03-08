#!/usr/bin/env python3
"""
Gitea webhook receiver + mkdocs builder.
- Listens on :9000
- Validates HMAC-SHA256 signature
- git clone/pull + mkdocs build into shared volume
- Initial build on startup
"""
import hashlib
import hmac
import http.server
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import threading

SECRET = os.environ.get("MKDOCS_WEBHOOK_SECRET", "")
REPO_URL = os.environ.get("MKDOCS_REPO_URL", "")
BRANCH = os.environ.get("MKDOCS_REPO_BRANCH", "main")
GITEA_USER = os.environ.get("GITEA_ADMIN_USER", "")
GITEA_PASS = os.environ.get("GITEA_ADMIN_PASSWORD", "")
REPO_DIR = "/workspace/repo"
SITE_DIR = "/workspace/site"
BUILD_LOCK = threading.Lock()
GIT_RETRIES = 5
GIT_RETRY_DELAY = 2


def git_url_with_auth(url: str) -> str:
    """Inject credentials into git URL for private repos."""
    if GITEA_USER and GITEA_PASS and "://" in url:
        proto, rest = url.split("://", 1)
        return f"{proto}://{GITEA_USER}:{GITEA_PASS}@{rest}"
    return url


def verify_signature(payload: bytes, signature: str) -> bool:
    if not SECRET:
        return True
    expected = hmac.new(SECRET.encode(), payload, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature)


def run_git(args, cwd=None):
    """Run git with retries for transient Gitea/network startup issues."""
    last_error = None
    for attempt in range(1, GIT_RETRIES + 1):
        try:
            return subprocess.run(
                args,
                cwd=cwd,
                check=True,
                capture_output=True,
                text=True,
            )
        except subprocess.CalledProcessError as exc:
            last_error = exc
            if attempt == GIT_RETRIES:
                raise
            print(
                f"[builder] git command failed (attempt {attempt}/{GIT_RETRIES}), retrying...",
                flush=True,
            )
            if getattr(exc, "stderr", ""):
                print(f"[builder] stderr: {exc.stderr}", file=sys.stderr, flush=True)
            time.sleep(GIT_RETRY_DELAY)

    raise last_error  # pragma: no cover


def rebuild() -> None:
    """Clone/pull and build. Thread-safe."""
    if not BUILD_LOCK.acquire(blocking=False):
        print("[builder] Build already in progress, skipping", flush=True)
        return

    tmp_site = None
    try:
        auth_url = git_url_with_auth(REPO_URL)
        if os.path.exists(os.path.join(REPO_DIR, ".git")):
            print(f"[builder] Pulling {BRANCH}...", flush=True)
            run_git(["git", "-C", REPO_DIR, "remote", "set-url", "origin", auth_url])
            run_git(["git", "-C", REPO_DIR, "fetch", "origin"])
            run_git(["git", "-C", REPO_DIR, "reset", "--hard", f"origin/{BRANCH}"])
        else:
            print(f"[builder] Cloning {BRANCH}...", flush=True)
            if os.path.exists(REPO_DIR):
                shutil.rmtree(REPO_DIR)
            os.makedirs(os.path.dirname(REPO_DIR), exist_ok=True)
            run_git(["git", "clone", "-b", BRANCH, "--single-branch", auth_url, REPO_DIR])

        # Build into a temporary directory outside the mounted site volume.
        # The site volume itself is a Docker mountpoint and cannot be renamed.
        tmp_site = tempfile.mkdtemp(prefix="mkdocs-site-")
        subprocess.run(
            ["python3", "-m", "mkdocs", "build", "--strict", "--site-dir", tmp_site],
            cwd=REPO_DIR,
            check=True,
        )

        os.makedirs(SITE_DIR, exist_ok=True)

        # Replace mounted volume contents in place.
        for entry in os.listdir(SITE_DIR):
            target = os.path.join(SITE_DIR, entry)
            if os.path.isdir(target) and not os.path.islink(target):
                shutil.rmtree(target)
            else:
                os.unlink(target)

        for entry in os.listdir(tmp_site):
            src = os.path.join(tmp_site, entry)
            dst = os.path.join(SITE_DIR, entry)
            if os.path.isdir(src) and not os.path.islink(src):
                shutil.copytree(src, dst, copy_function=shutil.copy2)
            else:
                shutil.copy2(src, dst, follow_symlinks=False)

        print(f"[builder] Build complete -> {SITE_DIR}", flush=True)
    except subprocess.CalledProcessError as e:
        print(f"[builder] Build FAILED: {e}", file=sys.stderr, flush=True)
        if hasattr(e, "stderr") and e.stderr:
            print(f"[builder] stderr: {e.stderr}", file=sys.stderr, flush=True)
    except Exception as e:
        print(f"[builder] Build FAILED: {e}", file=sys.stderr, flush=True)
    finally:
        if tmp_site and os.path.exists(tmp_site):
            shutil.rmtree(tmp_site, ignore_errors=True)
        BUILD_LOCK.release()


class WebhookHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/webhook":
            self.send_response(404)
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", 0))
        payload = self.rfile.read(length)
        signature = self.headers.get("X-Gitea-Signature", "")

        if not verify_signature(payload, signature):
            print("[webhook] Invalid signature", flush=True)
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b"Invalid signature")
            return

        try:
            data = json.loads(payload)
            ref = data.get("ref", "")
            if ref and ref != f"refs/heads/{BRANCH}":
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"Skipped: wrong branch")
                return
        except (json.JSONDecodeError, KeyError):
            pass

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"Build triggered")
        threading.Thread(target=rebuild, daemon=True).start()

    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, fmt, *args):
        print(f"[webhook] {args[0]}", flush=True)


if __name__ == "__main__":
    print("[builder] Initial build on startup...", flush=True)
    rebuild()

    server = http.server.HTTPServer(("0.0.0.0", 9000), WebhookHandler)
    print("[webhook] Listening on :9000", flush=True)
    server.serve_forever()
