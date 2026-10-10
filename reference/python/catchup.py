#!/usr/bin/env python3
"""
catchup.py — ingest scheduled runs that were researched while this Mac was offline.

Research is perishable, audio is not. A trending sound's window is 5-14 days, so
the research has to happen on schedule whether or not the Mac is awake; the clips
can be fetched whenever the machine next appears. A scheduled run that can't
reach this Mac drops its findings into `<root>/pending/<run-date>.json`, and this
picks them up in date order.

    python3 catchup.py [--root .] [--keep-runs N] [--list]

Success is judged from ingest's own machine-readable result, never by counting
files. An earlier version compared clips-on-disk before and after — but ingest
prunes in the same process, so a run that added two clips and evicted two older
ones netted zero, was declared a failure, stayed pending forever, and printed a
diagnostic blaming yt-dlp. That was the ordinary case once three runs existed.

Safe to run often: a no-op when nothing is pending, and it refuses to start when
another run holds the lock.
"""

import argparse
import json
import subprocess
import sys
from datetime import date, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import libstore
from libstore import LibraryError


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def pending_runs(root):
    """Un-ingested run files, oldest first — order matters for retention."""
    pdir = root / "pending"
    if not pdir.exists():
        return []
    runs = []
    for path in sorted(pdir.glob("*.json")):
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            log(f"  ! {path.name} is unreadable ({exc}); leaving it alone")
            libstore.record(root, "pending", False,
                            f"{path.name} could not be read and was skipped.", str(exc))
            continue
        if data:
            runs.append((path, data))
    return runs


def age_days(run_stamp):
    try:
        return (date.today() - datetime.strptime(str(run_stamp), "%Y-%m-%d").date()).days
    except (ValueError, TypeError):
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--keep-runs", type=int, default=None)
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    root = Path(args.root).expanduser().resolve()
    runs = pending_runs(root)

    if not runs:
        log("nothing pending")
        libstore.clear_kind(root, "pending")
        return 0

    if args.list:
        for path, data in runs:
            stamp = data.get("run", path.stem)
            age = age_days(stamp)
            n = len(data.get("candidates", []))
            log(f"{stamp}  {n} candidates" + (f"  ({age}d old)" if age and age > 0 else ""))
        return 0

    libstore.require_tools("yt-dlp", "ffmpeg")

    done_dir = root / "pending" / "ingested"
    done_dir.mkdir(parents=True, exist_ok=True)
    # Deliberately NOT overriding --result: ingest writes last_run.json, which
    # is what /api/health and the dashboard's "Last run" line read. An earlier
    # version pointed it at a scratch file and deleted it, so every run that
    # arrived through catch-up — which is the normal path, since the machine
    # doing the research usually cannot reach YouTube — left the dashboard with
    # no record of having run at all.
    result_path = root / "last_run.json"

    ok, stuck = 0, []
    for path, data in runs:
        stamp = data.get("run", path.stem)
        age = age_days(stamp)
        log(f"\n=== ingesting run {stamp}"
            + (f" ({age} days late)" if age and age > 0 else "") + " ===")

        if age is not None and age > 21:
            log("  note: over three weeks old. The 'rising' calls were true when "
                "researched, not necessarily now — treat it as archive.")

        cmd = [sys.executable, str(root / "ingest.py"), str(path),
               "--root", str(root)]
        if args.keep_runs is not None:
            cmd += ["--keep-runs", str(args.keep_runs)]
        res = subprocess.run(cmd, cwd=str(root))

        # ingest reports what it did. Exit 2 means "ran cleanly, added nothing
        # new" — every track was already known, which is a legitimate outcome
        # for a re-run and must still consume the pending file.
        if res.returncode in (0, 2):
            dest = done_dir / path.name
            if dest.exists():
                dest = done_dir / f"{path.stem}-{datetime.now():%H%M%S}.json"
            path.rename(dest)
            ok += 1
            try:
                summary = json.loads(result_path.read_text())
                log(f"  consumed: +{summary['added']} new, "
                    f"{summary['no_audio']} without audio")
            except (OSError, json.JSONDecodeError, KeyError):
                pass
        else:
            stuck.append(stamp)
            log(f"  ! run {stamp} failed (exit {res.returncode}). Leaving it "
                f"pending so it can be retried.")

    log(f"\ncaught up {ok} run(s), {len(stuck)} still pending")

    if stuck:
        libstore.record(root, "pending", False,
                        f"{len(stuck)} queued run(s) could not be ingested: "
                        + ", ".join(stuck),
                        "Usually a missing yt-dlp/ffmpeg on PATH, or no network. "
                        "They stay queued and will be retried.")
    else:
        libstore.clear_kind(root, "pending")

    # Anything starred while offline still needs its full track.
    try:
        queue = libstore.load_json(root / "promote_queue.json", {"ids": []})
    except LibraryError as exc:
        log(f"promote queue unreadable: {exc}")
        return 1 if stuck else 0

    if queue.get("ids"):
        log("working the promotion queue…")
        subprocess.run([sys.executable, str(root / "promote.py"),
                        "--root", str(root)], cwd=str(root))

    return 1 if stuck else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except LibraryError as exc:
        log(f"\nSTOPPED — {exc}")
        try:
            root = Path(sys.argv[sys.argv.index("--root") + 1]
                        if "--root" in sys.argv else ".")
            libstore.record(root, "pending", False,
                            "Catch-up could not run.", str(exc))
        except Exception:
            pass
        sys.exit(1)
