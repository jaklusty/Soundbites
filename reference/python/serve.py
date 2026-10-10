#!/usr/bin/env python3
"""
serve.py — the soundbites library, served locally.

Static files plus a small write API, so starring a track in the dashboard
persists to favourites.json instead of dying with the browser tab. Standard
library only: no pip install, nothing to keep updated.

    python3 serve.py [--root .] [--port 8765] [--host 127.0.0.1]

Then open http://127.0.0.1:8765

SECURITY, plainly: this service is not a viewer. Starring a track spawns a
subprocess and makes outbound network requests. So:

  * It binds loopback only, unless you give it a token.
  * POSTs are rejected unless the Origin and Host match this server and the
    Content-Type is application/json. Without those checks any website you had
    open could star tracks and trigger downloads on your machine — a plain
    fetch() with text/plain is a CORS "simple request" and gets delivered.
  * To serve it on a LAN or a NAS you must pass --token; --host anything other
    than a loopback address is refused without one. Append ?k=<token> to the
    URL once and the page keeps using it.

Catch-up runs on start, which is the reliable "this Mac is awake" signal.
"""

import argparse
import hmac
import ipaddress
import json
import os
import secrets
import subprocess
import sys
import threading
from datetime import datetime, timezone
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, str(Path(__file__).resolve().parent))
import libstore
from libstore import LibraryError

MAX_BODY = 64 * 1024
_worker = None
_worker_lock = threading.Lock()


class Handler(SimpleHTTPRequestHandler):
    root = Path(".")
    token = ""
    origins = ()

    # ---------------------------------------------------------------- helpers

    def _send(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _authorised(self):
        """Token check, when one is configured. Constant-time."""
        if not self.token:
            return True
        supplied = ""
        auth = self.headers.get("X-Soundbites-Token")
        if auth:
            supplied = auth
        else:
            qs = parse_qs(urlparse(self.path).query)
            supplied = (qs.get("k") or [""])[0]
        # compare_digest raises TypeError on non-ASCII str, which was a
        # pre-auth crash; bytes always compare.
        return hmac.compare_digest(supplied.encode("utf-8", "replace"),
                                   self.token.encode("utf-8"))

    def _host_ok(self):
        """Blocks DNS rebinding: the Host header must be one we expect."""
        host = (self.headers.get("Host") or "").split(":")[0].strip("[]")
        if not host:
            return False
        if host in ("127.0.0.1", "localhost", "::1"):
            return True
        return bool(self.token)  # a LAN deployment authenticates instead

    def _origin_ok(self):
        """
        Same-origin only. A missing Origin is fine (curl, the page's own
        same-origin fetch in some browsers); a foreign one never is.
        """
        origin = self.headers.get("Origin")
        if not origin:
            return True
        return origin in self.origins

    def _body(self):
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip()
        if ctype != "application/json":
            return None
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return None
        if length <= 0 or length > MAX_BODY:
            return None
        try:
            return json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None

    ALLOWED_FILES = ("/", "/index.html", "/library.js", "/favicon.ico")
    ALLOWED_DIRS = ("/clips/", "/full/")

    def _path_allowed(self):
        """
        Whitelist. Directory listings were already off, but every name here is
        guessable — library.json, favourites.json, profile.json, the .lock
        files and the scripts themselves were all readable.
        """
        path = urlparse(self.path).path
        if path in self.ALLOWED_FILES:
            return True
        return any(path.startswith(d) for d in self.ALLOWED_DIRS)

    def _load(self, name, default):
        try:
            return libstore.load_json(self.root / name, default)
        except LibraryError:
            return None  # caller decides; never silently substitute a default

    # ---------------------------------------------------------------- routes

    def do_GET(self):
        if not self._authorised():
            return self._send({"ok": False, "error": "bad or missing token"}, 403)
        if urlparse(self.path).path.rstrip("/") == "/api/state":
            if not self._host_ok():
                return self._send({"ok": False, "error": "bad host"}, 403)
            favs = self._load("favourites.json", {"ids": []})
            queue = self._load("promote_queue.json", {"ids": []})
            profile = self._load("profile.json", {})
            if favs is None or queue is None:
                return self._send(
                    {"ok": False,
                     "error": "a library file is corrupt — see the terminal"}, 500)
            with _worker_lock:
                busy = _worker is not None and _worker.poll() is None
            return self._send({
                "ok": True,
                "favourites": favs.get("ids", []),
                "profile": profile or {},
                "promote_queue": queue.get("ids", []),
                "promoting": busy,
            })
        if urlparse(self.path).path.rstrip("/") == "/api/health":
            if not self._host_ok():
                return self._send({"ok": False, "error": "bad host"}, 403)
            return self._send(self._health())
        if not self._path_allowed():
            return self.send_error(404, "Not found")
        return super().do_GET()

    def _health(self):
        """
        What is wrong right now, in terms the dashboard can render. Every error
        in this system used to go to a log file nobody opens, so a jammed
        catch-up or a failed run was invisible.
        """
        health = self._load("health.json", {}) or {}
        events = [e for e in health.get("events", []) if not e.get("ok")]

        pending = []
        pdir = self.root / "pending"
        if pdir.is_dir():
            pending = sorted(f.name for f in pdir.glob("*.json"))

        library = self._load("library.json", {"tracks": []}) or {"tracks": []}
        favs = set((self._load("favourites.json", {"ids": []}) or {}).get("ids", []))
        reclaimable, reclaim_bytes = 0, 0
        for t in library.get("tracks", []):
            if t.get("full") and t.get("id") not in favs:
                reclaimable += 1
                reclaim_bytes += t.get("full_bytes", 0)

        last_run = self._load("last_run.json", None)

        return {
            "ok": True,
            "issues": events[-8:],
            "pending": pending,
            "last_run": last_run,
            "reclaimable": reclaimable,
            "reclaim_bytes": reclaim_bytes,
        }

    def do_HEAD(self):
        # SimpleHTTPRequestHandler supplies do_HEAD for free, and an earlier
        # version left it ungated: GET /library.json returned 403 while HEAD
        # returned 200 with Content-Length, letting anyone on the LAN enumerate
        # every file and its size without the token.
        if not (self._authorised() and self._host_ok()):
            return self._send({"ok": False, "error": "rejected"}, 403)
        if not self._path_allowed():
            return self.send_error(404, "Not found")
        return super().do_HEAD()

    def do_POST(self):
        if not (self._authorised() and self._host_ok() and self._origin_ok()):
            return self._send({"ok": False, "error": "rejected"}, 403)

        payload = self._body()
        if payload is None:
            return self._send(
                {"ok": False, "error": "expected application/json"}, 400)

        route = urlparse(self.path).path.rstrip("/")
        try:
            with libstore.locked(self.root, "library", timeout=10):
                if route == "/api/star":
                    return self._star(payload)
                if route == "/api/profile":
                    return self._profile(payload)
                if route == "/api/reclaim":
                    return self._reclaim()
        except LibraryError as exc:
            return self._send({"ok": False, "error": str(exc)}, 503)
        return self._send({"ok": False, "error": "no such route"}, 404)

    def _star(self, payload):
        track_id = str(payload.get("id") or "").strip()
        if not track_id or len(track_id) > 200:
            return self._send({"ok": False, "error": "bad id"}, 400)

        library = self._load("library.json", {"tracks": []})
        if library is None:
            return self._send({"ok": False, "error": "library.json is corrupt"}, 500)
        if not any(t.get("id") == track_id for t in library.get("tracks", [])):
            return self._send({"ok": False, "error": "no such track"}, 404)

        favs = self._load("favourites.json", {"ids": []})
        if favs is None:
            return self._send(
                {"ok": False, "error": "favourites.json is corrupt"}, 500)
        favs.setdefault("ids", [])

        ids = set(favs["ids"])
        on = bool(payload.get("on", True))
        ids.add(track_id) if on else ids.discard(track_id)

        favs["ids"] = sorted(ids)
        favs["updated"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
        starred_at = favs.setdefault("starred_at", {})
        if on:
            starred_at.setdefault(track_id, favs["updated"])
        else:
            starred_at.pop(track_id, None)

        libstore.write_json(self.root / "favourites.json", favs)

        queued = self._queue_promotion(track_id) if on else False
        return self._send({"ok": True, "favourites": favs["ids"],
                           "promotion_queued": queued})

    def _queue_promotion(self, track_id):
        library = self._load("library.json", {"tracks": []})
        if library is None:
            return False
        track = next((t for t in library.get("tracks", [])
                      if t.get("id") == track_id), None)
        if track and track.get("full"):
            return False

        path = self.root / "promote_queue.json"
        queue = self._load("promote_queue.json", {"ids": []})
        if queue is None:
            # The one place that used to substitute an empty default for a
            # corrupt file and then overwrite it, destroying the queue while
            # returning ok:true.
            return False
        queue.setdefault("ids", [])
        if track_id not in queue["ids"]:
            queue["ids"].append(track_id)
            libstore.write_json(path, queue)

        self._kick_worker()
        return True

    def _kick_worker(self):
        """At most one promote.py. Downloads must not block the request."""
        global _worker
        script = self.root / "promote.py"
        if not script.exists():
            return
        with _worker_lock:
            if _worker is not None and _worker.poll() is None:
                return  # it will pick up the queue entry we just wrote
            try:
                logfh = open(self.root / "promote.log", "ab")
            except OSError:
                return
            try:
                profile = self._load("profile.json", {}) or {}
                fmt = (profile.get("promote") or {}).get("format")
                cmd = [sys.executable, str(script), "--root", str(self.root)]
                if fmt:
                    cmd += ["--format", str(fmt)]
                _worker = subprocess.Popen(
                    cmd,
                    cwd=str(self.root), stdout=subprocess.DEVNULL,
                    stderr=logfh, start_new_session=True)
            except OSError:
                pass
            finally:
                logfh.close()  # Popen dup'd it; not closing leaked an fd per star

    def _reclaim(self):
        """Delete full tracks for anything unstarred. Never touches a favourite."""
        script = self.root / "promote.py"
        if not script.exists():
            return self._send({"ok": False, "error": "promote.py missing"}, 500)
        res = subprocess.run(
            [sys.executable, str(script), "--root", str(self.root), "--reclaim"],
            cwd=str(self.root), capture_output=True, text=True, timeout=120)
        return self._send({"ok": res.returncode == 0,
                           "detail": (res.stderr or "").strip()[-500:]})

    def _profile(self, payload):
        active = str(payload.get("active") or "").strip()
        profile = self._load("profile.json", {})
        if profile is None:
            return self._send({"ok": False, "error": "profile.json is corrupt"}, 500)
        if active and active in (profile.get("profiles") or {}):
            profile["active"] = active
            libstore.write_json(self.root / "profile.json", profile)
            return self._send({"ok": True, "active": active})
        return self._send({"ok": False, "error": "unknown profile"}, 400)

    # ---------------------------------------------------------------- misc

    def end_headers(self):
        if self.path.startswith(("/library.", "/api/")):
            self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        super().end_headers()

    def list_directory(self, path):
        # No directory listings: clips/, full/, pending/ and the logs are not
        # for browsing, and on a LAN they leak the whole library's shape.
        self.send_error(404, "Not found")
        return None

    def log_message(self, fmt, *args):
        if getattr(self, "verbose", False):
            super().log_message(fmt, *args)


def is_loopback(host):
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return host in ("localhost",)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--token", default=os.environ.get("SOUNDBITES_TOKEN", ""),
                    help="required to bind a non-loopback address")
    ap.add_argument("--no-catchup", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    root = Path(args.root).expanduser().resolve()
    if not root.exists():
        print(f"library root does not exist: {root}", file=sys.stderr)
        return 1

    if not is_loopback(args.host) and not args.token:
        print(
            f"Refusing to bind {args.host} without --token.\n"
            f"Starring a track runs a program and downloads files, so an\n"
            f"unauthenticated listener on a LAN lets anything on that network\n"
            f"do both. Generate one and pass it:\n\n"
            f"    python3 serve.py --host {args.host} --token {secrets.token_urlsafe(16)}\n\n"
            f"then open the page as  http://<host>:{args.port}/?k=<token>",
            file=sys.stderr)
        return 1

    Handler.root = root
    Handler.token = args.token
    Handler.verbose = args.verbose
    Handler.origins = tuple(
        f"http://{h}:{args.port}" for h in
        ({args.host, "127.0.0.1", "localhost", "[::1]"} if is_loopback(args.host)
         else {args.host}))

    # Bind BEFORE spawning anything. Starting catch-up first meant a second,
    # accidental `python3 serve.py` left a detached ingest running after the
    # bind failed — two of them racing on the same library.
    try:
        server = ThreadingHTTPServer((args.host, args.port),
                                     partial(Handler, directory=str(root)))
    except OSError as exc:
        if exc.errno in (48, 98):  # EADDRINUSE on macOS / Linux
            print(f"Something is already serving port {args.port} — it is "
                  f"probably this, already running.\nOpen "
                  f"http://127.0.0.1:{args.port} instead.", file=sys.stderr)
            return 0
        raise

    if not args.no_catchup and (root / "catchup.py").exists():
        try:
            with open(root / "catchup.log", "ab") as logfh:
                subprocess.Popen(
                    [sys.executable, str(root / "catchup.py"),
                     "--root", str(root)],
                    cwd=str(root), stdout=subprocess.DEVNULL, stderr=logfh,
                    start_new_session=True)
        except OSError:
            pass

    scheme = f"http://{args.host}:{args.port}"
    print(f"soundbites library → {scheme}"
          + (f"/?k={args.token}" if args.token else "")
          + f"  (root: {root})")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
