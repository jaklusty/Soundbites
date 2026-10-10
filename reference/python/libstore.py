#!/usr/bin/env python3
"""
libstore.py — shared storage primitives for the Soundbites library.

Everything that touches library.json, favourites.json or promote_queue.json goes
through here.

Four rules, each of which existed as a real data-loss bug before this module:

1. A corrupt JSON file is an ERROR and STAYS WHERE IT IS. An earlier version
   renamed it aside, which turned "corrupt file" into "missing file" — and
   missing is a legitimate empty start, so the *next* scheduled run quietly
   built a fresh library and reported success. Detection that leads to silent
   amnesia is worse than no detection. Now: leave the file alone, restore from
   the backup if there is a good one, and otherwise refuse to run.

2. Every successful save writes a `.bak` first. A module whose entire purpose is
   preventing data loss had no backup of the source of truth.

3. Writes are atomic AND durable — fsync the file and its parent directory, not
   just tmp+rename. Without that, a lid-close can leave the zero-length file
   that rule 1 then has to deal with.

4. Concurrent writers take a lock. Two locks, deliberately:
     run.lock      held for a WHOLE ingest or catch-up, so two runs can't
                   interleave. Downloads happen inside it; that is the point.
     library.lock  short, around read-modify-write of library.json only.
   They are not collapsed into one because starring a track takes the library
   lock from the web server, and a single lock would make the dashboard hang
   for the 25 minutes an ingest takes.

Failures are also RECORDED (see `record`), because a non-programmer never reads
a log file. The dashboard surfaces what this writes.
"""

import errno
import fcntl
import json
import os
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

MAX_EVENTS = 40


class LibraryError(Exception):
    """Raised when continuing would risk the user's data."""


# ---------------------------------------------------------------- reading

def load_json(path, default, allow_restore=False):
    """
    Missing file -> `default`. Corrupt file -> raise, leaving it untouched.

    With allow_restore=True and a readable `<name>.bak`, restores from the
    backup and returns it rather than failing the run. That path always records
    a health event, so it can never be silent.
    """
    p = Path(path)
    if not p.exists():
        return default

    try:
        text = p.read_text()
    except OSError as exc:
        raise LibraryError(f"cannot read {p}: {exc}") from exc

    if text.strip():
        try:
            return json.loads(text)
        except json.JSONDecodeError as exc:
            problem = f"{p.name} is corrupt ({exc})"
    else:
        problem = f"{p.name} is empty (an interrupted write)"

    bak = p.with_name(p.name + ".bak")
    if allow_restore and bak.exists():
        try:
            data = json.loads(bak.read_text())
        except (OSError, json.JSONDecodeError):
            data = None
        if data is not None:
            record(p.parent, "restore", False,
                   f"{p.name} was damaged; restored from {bak.name}",
                   "The damaged file is still on disk under its own name. "
                   "Anything added since the last successful save is lost.")
            write_json(p, data, backup=False)
            return data

    raise LibraryError(
        f"{problem}.\n"
        f"It has NOT been moved, renamed or overwritten — it is still at {p}.\n"
        + (f"There is no usable backup at {bak.name}.\n" if not bak.exists()
           else f"The backup at {bak.name} is also unreadable.\n")
        + "Nothing will run against this library until it is repaired, because "
          "treating it as empty would quietly discard the history."
    )


# ---------------------------------------------------------------- writing

def write_text_atomic(path, text):
    """Write, fsync, rename, fsync the directory. Survives a power cut."""
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(f".{p.name}.tmp")

    with open(tmp, "w") as fh:
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())

    os.replace(tmp, p)

    try:
        dir_fd = os.open(str(p.parent), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(dir_fd)
    except OSError:
        pass  # some network shares don't allow it
    finally:
        os.close(dir_fd)


def write_json(path, data, backup=True):
    """
    Write, keeping the previous good copy as `<name>.bak`.

    The backup is taken from what is currently on disk, so it is always a
    state that was valid at some point — never a half-built one.
    """
    p = Path(path)
    if backup and p.exists():
        try:
            current = p.read_text()
            json.loads(current)          # only back up something that parses
            write_text_atomic(p.with_name(p.name + ".bak"), current)
        except (OSError, json.JSONDecodeError):
            pass                          # don't let a bad current file poison the bak
    write_text_atomic(p, json.dumps(data, indent=2, ensure_ascii=False))


# ---------------------------------------------------------------- health

def record(root, kind, ok, message, detail=""):
    """
    Append an event to health.json. The dashboard reads this and shows a banner,
    which is the only way the user finds out something went wrong — nobody opens
    serve.log.

    Best-effort by design: a failure to record must never break the caller.
    """
    try:
        p = Path(root) / "health.json"
        try:
            data = json.loads(p.read_text()) if p.exists() else {}
        except (OSError, json.JSONDecodeError):
            data = {}
        events = data.get("events", [])
        events.append({
            "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "kind": kind,
            "ok": bool(ok),
            "message": message,
            "detail": detail,
        })
        data["events"] = events[-MAX_EVENTS:]
        data["updated"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
        write_text_atomic(p, json.dumps(data, indent=2, ensure_ascii=False))
    except Exception:
        pass


def clear_kind(root, kind):
    """Drop earlier events of one kind — used when that thing next succeeds."""
    try:
        p = Path(root) / "health.json"
        if not p.exists():
            return
        data = json.loads(p.read_text())
        data["events"] = [e for e in data.get("events", []) if e.get("kind") != kind]
        write_text_atomic(p, json.dumps(data, indent=2, ensure_ascii=False))
    except Exception:
        pass


# ---------------------------------------------------------------- locking

@contextmanager
def locked(root, name, timeout=30.0, blocking=True):
    """Exclusive lock on <root>/<name>.lock. See the module docstring."""
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    lock_path = root / f"{name}.lock"

    fh = open(lock_path, "a+")
    deadline = time.monotonic() + timeout
    try:
        while True:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError as exc:
                if exc.errno not in (errno.EACCES, errno.EAGAIN):
                    raise
                if not blocking or time.monotonic() >= deadline:
                    raise LibraryError(
                        f"another Soundbites process is holding {name}.lock — a "
                        f"run or download is already in progress. Wait for it "
                        f"rather than forcing it."
                    ) from exc
                time.sleep(0.25)
        yield
    finally:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
        finally:
            fh.close()


# ---------------------------------------------------------------- misc

def valid_run_stamp(value):
    """Run stamps sort chronologically only if they really are dates."""
    try:
        datetime.strptime(str(value), "%Y-%m-%d")
        return True
    except (ValueError, TypeError):
        return False


def newer_stamp(a, b):
    """Later of two YYYY-MM-DD stamps; used to keep last_run monotonic."""
    if not valid_run_stamp(a):
        return b
    if not valid_run_stamp(b):
        return a
    return a if a >= b else b


def safe_media_url(url):
    """
    A URL is only safe to hand to yt-dlp if it is http(s). `source_url` comes
    from an LLM reading arbitrary web pages, and yt-dlp uses optparse — so a
    value starting with '-' is parsed as an option, and yt-dlp ships --exec.
    Callers must ALSO pass '--' before the URL; this is the belt to that brace.
    """
    s = str(url or "").strip()
    if not s or s.startswith("-"):
        return None
    low = s.lower()
    return s if (low.startswith("http://") or low.startswith("https://")) else None


def require_tools(*names):
    """A missing yt-dlp or ffmpeg is a configuration error, not a per-track one."""
    import shutil
    missing = [n for n in names if shutil.which(n) is None]
    if missing:
        raise LibraryError(
            "required tool(s) not found on PATH: " + ", ".join(missing) +
            f"\nPATH={os.environ.get('PATH', '')}\n"
            "If this ran from launchd, the plist needs a PATH containing "
            "/opt/homebrew/bin. Otherwise: brew install " + " ".join(missing)
        )


def human(nbytes):
    n = float(nbytes)
    for unit in ("B", "KB", "MB", "GB"):
        if abs(n) < 1024 or unit == "GB":
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024.0
