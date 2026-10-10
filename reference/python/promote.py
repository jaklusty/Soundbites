#!/usr/bin/env python3
"""
promote.py — pull the FULL track for a favourite, so sections can be chosen
against real footage rather than a 30-second audition clip.

The audition clip answers "does this fit?". Once the answer is yes, you need
the whole thing in Resolve to find the bar that lands on your cut. This does
that, and only for tracks that were actually starred.

Usage:
    python3 promote.py            # work the queue serve.py writes on each star
    python3 promote.py <id> ...   # promote specific track ids now
    python3 promote.py --all-favourites
    python3 promote.py --format wav16 | wav24 | mp3
    python3 promote.py --reclaim   # free space held by unstarred tracks

Output per promoted track, in <root>/full/<id>/:
    <id>.wav        48kHz 16-bit stereo by default (Resolve-native)
    <id>.source.*   whatever yt-dlp delivered, kept so nothing needs re-fetching

Format note, with real numbers:

    48kHz 16-bit stereo WAV   11.5 MB/min   ~35 MB for a 3-minute track  (default)
    48kHz 24-bit stereo WAV   17.3 MB/min   ~52 MB
    320k MP3                   2.4 MB/min   ~7 MB

WAV is the default because it is what Resolve conforms without re-sampling, and
because a track you starred is one you intend to cut with. `--format mp3` costs
a fifth of the space if you would rather trade the last few percent of fidelity
on a music bed.

Concurrency: downloads run with NO lock held, and library.json is re-read under
lock afterwards so only this script's own fields are written. Holding the
library across a 20-minute download used to destroy a whole research run.
"""

import argparse
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import libstore
from libstore import LibraryError

FORMATS = {
    "wav24": ["-c:a", "pcm_s24le", "-ar", "48000", "-ac", "2"],
    "wav16": ["-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2"],
    "mp3":   ["-c:a", "libmp3lame", "-b:a", "320k", "-ar", "48000", "-ac", "2"],
}
EXT = {"wav24": "wav", "wav16": "wav", "mp3": "mp3"}
FETCH_TIMEOUT = 600


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def run_cmd(cmd, timeout):
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        log(f"  · timed out after {timeout}s")
        return subprocess.CompletedProcess(cmd, 124, "", "timed out")
    except OSError as exc:
        return subprocess.CompletedProcess(cmd, 127, "", str(exc))


def fetch_full(url, workdir):
    """Whole track, best available audio. Two attempts, then give up."""
    safe = libstore.safe_media_url(url)
    if not safe:
        log(f"  ! refusing non-http(s) source_url {url!r}")
        return None
    out = workdir / "full.%(ext)s"
    base = ["yt-dlp", "-f", "bestaudio", "--no-playlist", "--sleep-requests", "2",
            "-o", str(out)]
    # "--" ends option parsing; yt-dlp uses optparse and ships --exec.
    for i, cmd in enumerate((base + ["--", safe],
                             base + ["--cookies-from-browser", "safari", "--", safe]), 1):
        res = run_cmd(cmd, FETCH_TIMEOUT)
        got = sorted(workdir.glob("full.*"))
        if res.returncode == 0 and got:
            return got[0]
        tail = (res.stderr or "").strip().splitlines()[-1:] or ["no output"]
        log(f"  · attempt {i} failed: {tail[0][:160]}")
    return None


def promote(track, root, fmt):
    tid = track["id"]
    dest_dir = root / "full" / tid
    dest = dest_dir / f"{tid}.{EXT[fmt]}"

    if dest.exists() and dest.stat().st_size > 0:
        return "already", dest

    url = track.get("source_url")
    if not libstore.safe_media_url(url):
        return "no-source", None

    dest_dir.mkdir(parents=True, exist_ok=True)
    workdir = root / ".work-full" / tid
    shutil.rmtree(workdir, ignore_errors=True)
    workdir.mkdir(parents=True)

    try:
        src = fetch_full(url, workdir)
        if not src:
            return "download-failed", None

        # Keep the original: re-transcoding is free, re-downloading may not be
        # possible in six weeks.
        shutil.copy2(src, dest_dir / f"{tid}.source{src.suffix}")

        res = run_cmd(["ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
                       *FORMATS[fmt], "-map_metadata", "-1", str(dest)],
                      FETCH_TIMEOUT)
        if res.returncode != 0 or not dest.exists() or dest.stat().st_size == 0:
            log(f"  ! transcode failed: {(res.stderr or '')[:200]}")
            dest.unlink(missing_ok=True)
            return "transcode-failed", None
        return "ok", dest
    finally:
        shutil.rmtree(workdir, ignore_errors=True)



def reclaim(root):
    """
    Delete full tracks for anything no longer starred.

    Full tracks are the only part of this library that grows without bound, and
    the star button was the user's only verb — the README's remedy was "delete
    the folder yourself", which is not a remedy for someone who does not open a
    terminal. This is the same operation, callable from the dashboard.

    Only ever removes <root>/full/<id>/ for ids the library knows and the user
    has unstarred. Never touches clips, never touches a starred track.
    """
    with libstore.locked(root, "library"):
        library = libstore.load_json(root / "library.json", {"tracks": []},
                                     allow_restore=True)
        favourites = set(libstore.load_json(
            root / "favourites.json", {}, allow_restore=True).get("ids", []))

        freed, removed = 0, []
        for track in library.get("tracks", []):
            tid = track.get("id")
            if not tid or tid in favourites or not track.get("full"):
                continue
            folder = root / "full" / tid
            if folder.is_dir():
                for f in folder.rglob("*"):
                    if f.is_file():
                        freed += f.stat().st_size
                shutil.rmtree(folder, ignore_errors=True)
            removed.append(track.get("title", tid))
            for key in ("full", "full_format", "full_bytes", "promoted_at"):
                track.pop(key, None)

        if removed:
            libstore.write_json(root / "library.json", library)
            profile = libstore.load_json(root / "profile.json", {})
            libstore.write_text_atomic(root / "library.js", "window.SOUNDBITES = " +
                json.dumps({"library": library, "favourites": sorted(favourites),
                            "profile": profile,
                            "generated": datetime.now(timezone.utc)
                            .isoformat(timespec="seconds")}, ensure_ascii=False) + ";\n")

    log(f"reclaimed {len(removed)} full track(s), {libstore.human(freed)}")
    for name in removed:
        log(f"  removed: {name}")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ids", nargs="*")
    ap.add_argument("--root", default=".")
    ap.add_argument("--format", choices=sorted(FORMATS), default=None,
                    help="default comes from profile.json promote.format")
    ap.add_argument("--all-favourites", action="store_true")
    ap.add_argument("--reclaim", action="store_true",
                    help="delete full tracks for anything no longer starred")
    args = ap.parse_args()

    root = Path(args.root).expanduser().resolve()

    if args.reclaim:
        return reclaim(root)

    profile = libstore.load_json(root / "profile.json", {}, allow_restore=True)
    fmt = args.format or (profile.get("promote") or {}).get("format", "wav16")
    if fmt not in FORMATS:
        log(f"unknown format {fmt!r} in profile.json; using wav16")
        fmt = "wav16"

    with libstore.locked(root, "library"):
        library = libstore.load_json(root / "library.json", {"tracks": []})
        favourites = set(libstore.load_json(
            root / "favourites.json", {}).get("ids", []))
        queue = libstore.load_json(
            root / "promote_queue.json", {"ids": []}).get("ids", [])

    if args.ids:
        wanted = list(dict.fromkeys(args.ids))
    elif args.all_favourites:
        wanted = sorted(favourites)
    else:
        wanted = list(dict.fromkeys(queue))

    if not wanted:
        log("nothing queued")
        return 0

    libstore.require_tools("yt-dlp", "ffmpeg")

    by_id = {t.get("id"): t for t in library.get("tracks", [])}
    results = {}
    done, failed = [], []

    # Downloads: no lock held.
    for tid in wanted:
        track = by_id.get(tid)
        if not track:
            log(f"→ {tid}: not in library")
            failed.append((tid, "unknown"))
            results[tid] = ("unknown", None)
            continue

        label = f"{track.get('title', tid)} — {track.get('artist', '')}".strip(" —")
        log(f"→ {label}")
        status, path = promote(track, root, fmt)
        results[tid] = (status, path)

        if status in ("ok", "already"):
            done.append(label)
            log(f"  {'already had it' if status == 'already' else 'got it'}: "
                f"{path.stat().st_size / 1e6:.1f}MB")
        else:
            failed.append((label, status))
            log(f"  ! {status}")

    # Short critical section: re-read, write only our own fields, and re-read
    # the queue so a star that arrived mid-download is not silently dropped.
    with libstore.locked(root, "library"):
        library = libstore.load_json(root / "library.json", {"tracks": []})
        favourites = set(libstore.load_json(
            root / "favourites.json", {}).get("ids", []))
        by_id = {t.get("id"): t for t in library.get("tracks", [])}

        for tid, (status, path) in results.items():
            track = by_id.get(tid)
            if track is None:
                continue
            if status in ("ok", "already"):
                track["full"] = str(path.relative_to(root))
                track["full_format"] = fmt
                track["full_bytes"] = path.stat().st_size
                track["promoted_at"] = datetime.now(
                    timezone.utc).isoformat(timespec="seconds")
                track.pop("full_error", None)
            else:
                track["full_error"] = status

        current_queue = libstore.load_json(
            root / "promote_queue.json", {"ids": []}).get("ids", [])
        remaining = [i for i in current_queue if i not in results]
        libstore.write_json(root / "promote_queue.json", {"ids": remaining})
        libstore.write_json(root / "library.json", library)

        profile = libstore.load_json(root / "profile.json", {})
        libstore.write_text_atomic(root / "library.js", "window.SOUNDBITES = " +
            json.dumps({"library": library, "favourites": sorted(favourites),
                        "profile": profile,
                        "generated": datetime.now(timezone.utc)
                        .isoformat(timespec="seconds")},
                       ensure_ascii=False) + ";\n")

        total = sum(t.get("full_bytes", 0) for t in library.get("tracks", []))
        count = sum(1 for t in library.get("tracks", []) if t.get("full"))

    log(f"\npromoted {len(done)}, failed {len(failed)}")
    for name, why in failed:
        log(f"  {why}: {name}")
    log(f"full tracks on disk: {count} ({total / 1e6:.0f}MB)")

    if failed:
        libstore.record(root, "promote", False,
                        f"{len(failed)} full track(s) could not be downloaded.",
                        "; ".join(f"{n}: {w}" for n, w in failed)[:400])
    else:
        libstore.clear_kind(root, "promote")
    if remaining:
        log(f"still queued: {len(remaining)} (starred during this run)")
    if total > 2e9:
        log("  ! full tracks now exceed 2GB. Unstar what you are done with, or "
            "use --format mp3 (a fifth of the size) for future pulls.")

    return 0 if done else 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except LibraryError as exc:
        log(f"\nSTOPPED — {exc}")
        sys.exit(1)
