#!/usr/bin/env python3
"""
ingest.py — merge a run of trending-sound candidates into the local library.

Called by the `trending-sounds` skill after research. Takes a candidates JSON
file, pulls a 30s hook for each, transcodes to a small audition MP3, merges into
library.json (keeping per-track history), applies retention, and writes
library.js for the dashboard.

Usage:
    python3 ingest.py candidates.json [--root .] [--keep-runs N] [--dry-run]
                                      [--result result.json]

`--keep-runs` defaults to profile.json's `retention.keep_runs`, then 2.

Candidate schema (list, or {"run": "YYYY-MM-DD", "candidates": [...]}):
    {
      "title": "...",            REQUIRED
      "artist": "...",           REQUIRED
      "source_url": "https://…", REQUIRED unless "local" is given. Must be
                                 http(s) and something yt-dlp can fetch — in
                                 practice a YouTube upload. A TikTok/Reels
                                 *sound page* is not fetchable. Anything else
                                 is rejected and the row is filed audio-less.
      "search": "artist title",  optional alternative to source_url. Resolved
                                 to a real YouTube URL by yt-dlp on whichever
                                 machine runs the ingest, then validated like
                                 any other URL. Use this when the machine doing
                                 the RESEARCH cannot reach YouTube but the
                                 machine doing the DOWNLOAD can — which is the
                                 normal split here.
      "local": "/path/file.mp3", optional, used instead of downloading
      "hook_start": "0:20",      OPTIONAL and now rarely needed — the hook is
                                 detected automatically from YouTube's
                                 most-replayed heatmap, falling back to chorus
                                 detection then loudest window. Set it only to
                                 override, e.g. when a roundup names the exact
                                 section people cut to.
      "platform": "tiktok"|"reels"|"both",
      "direction": "rising"|"peaking"|"fading",   -- decides dashboard section
      "uses": 420000, "bpm": 128, "energy": "low"|"medium"|"high",
      "mood": ["driving"], "suits": "...", "profiles": ["moto"],
      "licence": "platform"|"clearable", "notes": "...",
      "pin": true                optional. Evergreen pool member: never pruned,
                                 regardless of how old the run is.
    }

Runtime: 12-15 candidates takes 8-25 minutes. A killed run is safe to re-run —
clips already on disk are skipped and nothing is pruned until the end.

Writes a machine-readable summary to `--result` (default `last_run.json`).
Callers must judge success from THAT plus the exit code, never by counting
files: pruning runs in the same process, so a perfectly good run can add two
clips and evict two others for a net change of zero.

Exit codes: 0 ok, 1 error (nothing changed), 2 ran but added nothing.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import libstore
import hook as hookdet
from libstore import LibraryError, human

CLIP_SECONDS = 30
CLIP_BITRATE = "128k"
CLIP_CHANNELS = 1
DOWNLOAD_TIMEOUT = 180


def log(msg):
    print(msg, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- utilities

def slugify(artist, title):
    """
    Stable track id: an ASCII slug for humans, plus a hash for identity.

    Two failure modes to avoid at once. Hashing the RAW strings meant
    "Sabrina Carpenter" and "sabrina carpenter" minted different ids with
    identical readable slugs — and an LLM re-derives artist names from fresh
    research twice a week, so that drift is the expected case; it split the
    use-count history and killed the trajectory arrows. But hashing the
    ASCII-FOLDED strings collapsed every CJK, Cyrillic or emoji title to the
    same empty value, merging unrelated tracks.

    So: fold to ASCII for the readable part only, and hash a case-folded,
    punctuation-stripped form that PRESERVES non-ASCII characters. The NUL
    separator keeps ("a-b","c") and ("a","b-c") apart.
    """
    def readable_part(s):
        """ASCII slug for humans. Lossy on purpose — CJK becomes empty here."""
        s = unicodedata.normalize("NFKD", str(s or "")).encode("ascii", "ignore").decode()
        return re.sub(r"[\s_-]+", "-", re.sub(r"[^\w\s-]", "", s.lower())).strip("-")

    def identity(s):
        """
        What the hash is taken over. Case-folded and stripped of punctuation so
        "Sabrina Carpenter" and "sabrina carpenter" converge — but NOT stripped
        to ASCII, or every CJK title would hash identically and two different
        tracks by one artist would collapse onto a single row.
        """
        raw = unicodedata.normalize("NFKC", str(s or "")).casefold()
        cleaned = re.sub(r"\s+", " ", re.sub(r"[^\w\s]", "", raw, flags=re.UNICODE)).strip()
        # An emoji-only title cleans to nothing (\w excludes emoji), which would
        # make every such title hash the same. Fall back to the raw form.
        return cleaned or raw.strip()

    readable = "-".join(p for p in (readable_part(artist), readable_part(title)) if p)[:50]
    digest = hashlib.sha1(
        f"{identity(artist)}\x00{identity(title)}".encode("utf-8")).hexdigest()[:8]
    return f"{readable}-{digest}" if readable else f"track-{digest}"


def parse_ts(value):
    if value is None:
        return 20
    if isinstance(value, (int, float)):
        return max(0, int(value))
    try:
        nums = [float(p) for p in str(value).strip().split(":")]
    except ValueError:
        log(f"  · unparseable hook_start {value!r}; using 0:20")
        return 20
    seconds = 0.0
    for n in nums:
        seconds = seconds * 60 + n
    return max(0, int(seconds))


def run_cmd(cmd, timeout=DOWNLOAD_TIMEOUT):
    """Never let one hung subprocess discard a whole run's work."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        log(f"  · timed out after {timeout}s")
        return subprocess.CompletedProcess(cmd, 124, "", "timed out")
    except OSError as exc:
        return subprocess.CompletedProcess(cmd, 127, "", str(exc))


# ---------------------------------------------------------------- fetching

YT_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")


def resolve_search(query):
    """
    Turn "artist title" into a real YouTube watch URL using yt-dlp's own search.

    This exists because research and download often happen on different
    machines: a cloud session can read the trend charts but may not reach
    YouTube, while the Mac can reach YouTube but is not where the research
    runs. Carrying a search string instead of a URL lets each do its half.

    The query is sanitised and the result is validated as an 11-character video
    id before being turned into a URL, so nothing user- or web-derived reaches
    argv as an option.
    """
    q = re.sub(r"[\x00-\x1f]", " ", str(query or "")).strip()[:200]
    if not q:
        return None
    res = run_cmd(["yt-dlp", "--skip-download", "--no-warnings", "--no-playlist",
                   "--retries", "3", "--socket-timeout", "20",
                   "--print", "%(id)s", "--", f"ytsearch1:{q}"], timeout=120)
    vid = (res.stdout or "").strip().splitlines()
    vid = vid[0].strip() if vid else ""
    if res.returncode != 0 or not YT_ID.match(vid):
        tail = (res.stderr or "").strip().splitlines()[-1:] or ["no result"]
        log(f"  · search {q!r} found nothing: {tail[0][:140]}")
        return None
    url = f"https://www.youtube.com/watch?v={vid}"
    log(f"  · resolved to {url}")
    return url


def fetch_source(cand, workdir):
    local = cand.get("local")
    if local:
        p = Path(local).expanduser()
        if p.exists():
            return p
        log(f"  ! local file missing: {p}")
        return None

    raw = cand.get("source_url")
    if not raw and cand.get("search"):
        raw = resolve_search(cand["search"])
        if raw:
            cand["source_url"] = raw          # persist it so re-runs skip the search
    if not raw:
        log("  · no source_url or search — filing metadata only")
        return None

    url = libstore.safe_media_url(raw)
    if not url:
        log(f"  ! refusing non-http(s) source_url {raw!r} — filing metadata only")
        return None

    out = workdir / "src.%(ext)s"
    # --write-info-json brings YouTube's most-replayed heatmap down in the same
    # call, so finding the hook costs no extra network round trip.
    base = ["yt-dlp", "-f", "bestaudio", "--no-playlist", "--sleep-requests", "2",
            "--retries", "3", "--socket-timeout", "20",
            "--write-info-json", "-o", str(out)]
    # "--" ends option parsing: without it a URL beginning with "-" is read as
    # an option, and yt-dlp ships --exec.
    attempts = [base + ["--", url],
                base + ["--cookies-from-browser", "safari", "--", url]]

    for i, cmd in enumerate(attempts, 1):
        res = run_cmd(cmd)
        got = sorted(f for f in workdir.glob("src.*") if f.suffix != ".json")
        if res.returncode == 0 and got:
            return got[0]
        tail = (res.stderr or "").strip().splitlines()[-1:] or ["no output"]
        log(f"  · download attempt {i} failed: {tail[0][:160]}")
        if "Full Disk Access" in tail[0] or "could not copy" in tail[0].lower():
            log("  · (that's macOS Full Disk Access for the terminal, not the "
                "platform blocking you)")

    log("  ! both attempts failed — login-walled, rate-limited, or a stale "
        "yt-dlp. Try: brew upgrade yt-dlp")
    return None


def load_info(workdir):
    """yt-dlp's metadata sidecar, when there is one."""
    for f in workdir.glob("*.info.json"):
        try:
            return json.loads(f.read_text())
        except (OSError, json.JSONDecodeError):
            return {}
    return {}


def find_hook(src, workdir, cand):
    """Where the recognisable 30 seconds starts. Returns (seconds, method, detail)."""
    explicit = parse_ts(cand["hook_start"]) if cand.get("hook_start") is not None else None
    info = load_info(workdir)
    at, method, detail = hookdet.detect(src, info=info, explicit=explicit)
    log(f"  · hook at {hookdet.fmt(at)} ({method}: {detail})")
    return at, method, detail


def make_clip(src, dest, hook_start):
    dest.parent.mkdir(parents=True, exist_ok=True)
    res = run_cmd(["ffmpeg", "-y", "-loglevel", "error",
                   "-ss", str(hook_start), "-i", str(src), "-t", str(CLIP_SECONDS),
                   "-ac", str(CLIP_CHANNELS), "-ar", "44100",
                   "-b:a", CLIP_BITRATE, "-map_metadata", "-1", str(dest)],
                  timeout=120)
    if res.returncode != 0 or not dest.exists() or dest.stat().st_size == 0:
        log(f"  ! transcode failed: {(res.stderr or '').strip()[:200]}")
        dest.unlink(missing_ok=True)
        return False
    return True


# ---------------------------------------------------------------- merging

TRACK_FIELDS = ("title artist platform direction uses bpm energy mood suits "
                "profiles licence notes source_url").split()


def merge(library, cand, track_id, run_stamp, clip_rel, clip_bytes, hookinfo=None):
    rec = next((t for t in library["tracks"] if t.get("id") == track_id), None)
    if rec is None:
        rec = {"id": track_id, "first_seen": run_stamp, "runs": [],
               "clip": None, "clip_present": False}
        library["tracks"].append(rec)

    for field in TRACK_FIELDS:
        if cand.get(field) not in (None, "", []):
            rec[field] = cand[field]

    rec.setdefault("mood", [])
    rec.setdefault("profiles", [])
    rec.setdefault("licence", "platform")
    rec["last_seen"] = run_stamp
    if run_stamp not in rec["runs"]:
        rec["runs"] = sorted(set(rec["runs"] + [run_stamp]))[-24:]

    if cand.get("uses") is not None:
        hist = rec.setdefault("uses_history", {})
        hist[run_stamp] = cand["uses"]
        for stale in sorted(hist)[:-24]:
            hist.pop(stale)

    if clip_rel:
        rec["clip"] = clip_rel
        rec["clip_present"] = True
        rec["clip_bytes"] = clip_bytes
    if hookinfo:
        rec["hook_at"] = round(hookinfo[0], 1)
        rec["hook_method"] = hookinfo[1]
        rec["hook_detail"] = hookinfo[2]
    # Pool tracks are pinned: evergreen material that must survive retention
    # the way a favourite does, without pretending the user starred it.
    if cand.get("pin"):
        rec["pinned"] = True
    return rec


# ---------------------------------------------------------------- retention

def prune(library, root, favourites, keep_runs, current_run):
    """
    Keep a clip if the track is pinned, is a favourite, was seen in one of the
    last `keep_runs` dated runs, or was seen in the run just ingested.

    Pinned tracks are the evergreen pool — material chosen for the niche rather
    than for this week's chart. They are what makes the library a browsable
    catalogue instead of a rolling two-week window.

    That last clause is why catching up a weeks-old run no longer downloads
    clips and deletes them in the same process.
    """
    dated = sorted({r for t in library["tracks"] for r in t.get("runs", [])
                    if libstore.valid_run_stamp(r)})
    recent = set(dated[-keep_runs:]) if keep_runs > 0 else set()
    if current_run:
        recent.add(current_run)

    known_ids = {t.get("id") for t in library["tracks"]}
    freed = kept = 0

    for track in library["tracks"]:
        if not track.get("clip_present") or not track.get("clip"):
            continue
        if (track.get("pinned") or track.get("id") in favourites
                or set(track.get("runs", [])) & recent):
            kept += 1
            continue
        clip_path = root / track["clip"]
        if clip_path.exists():
            freed += clip_path.stat().st_size
            clip_path.unlink()
        track["clip_present"] = False
        track.pop("clip_bytes", None)

    # Only ever sweep <known-id>.mp3. Anything else in clips/ is the user's.
    referenced = {(root / t["clip"]).name for t in library["tracks"]
                  if t.get("clip_present") and t.get("clip")}
    clips_dir = root / "clips"
    if clips_dir.exists():
        for stray in clips_dir.iterdir():
            if (stray.is_file() and stray.suffix == ".mp3"
                    and stray.stem in known_ids and stray.name not in referenced):
                freed += stray.stat().st_size
                stray.unlink()

    return kept, freed


# ---------------------------------------------------------------- outputs

def save(root, library, favourites, profile):
    library["updated"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    libstore.write_json(root / "library.json", library)
    payload = {"library": library, "favourites": sorted(favourites),
               "profile": profile,
               "generated": library["updated"]}
    libstore.write_text_atomic(
        root / "library.js",
        "window.SOUNDBITES = " + json.dumps(payload, ensure_ascii=False) + ";\n")


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("candidates")
    ap.add_argument("--root", default=".")
    ap.add_argument("--keep-runs", type=int, default=None)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--result", default="last_run.json")
    args = ap.parse_args()

    root = Path(args.root).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    (root / "clips").mkdir(exist_ok=True)

    # The candidates file is written by an agent; malformed output is routine.
    # It is INPUT, so a parse failure must not touch the library or the file.
    try:
        raw = json.loads(Path(args.candidates).read_text())
    except (OSError, json.JSONDecodeError) as exc:
        log(f"cannot read {args.candidates}: {exc}\n"
            f"The file has been left exactly as it is — fix it and re-run.")
        return 1

    if isinstance(raw, dict):
        run_stamp = raw.get("run") or datetime.now().strftime("%Y-%m-%d")
        candidates = raw.get("candidates", [])
    else:
        run_stamp = datetime.now().strftime("%Y-%m-%d")
        candidates = raw

    if not libstore.valid_run_stamp(run_stamp):
        log(f"run stamp {run_stamp!r} is not YYYY-MM-DD; retention sorts by date.")
        return 1
    if not candidates:
        log("no candidates in file")
        return 1

    profile = libstore.load_json(root / "profile.json", {}, allow_restore=True)
    keep_runs = args.keep_runs
    if keep_runs is None:
        keep_runs = int((profile.get("retention") or {}).get("keep_runs", 2))

    if args.dry_run:
        # Read-only: never restores, never writes, never backs up.
        library = libstore.load_json(root / "library.json", {"version": 1, "tracks": []})
        known = {t.get("id") for t in library.get("tracks", [])}
        ids = [slugify(c.get("artist", ""), c.get("title", "")) for c in candidates]
        new = sum(1 for i in ids if i not in known)
        dupes = len(ids) - len(set(ids))
        log(f"dry run ({run_stamp}): {len(candidates)} candidates, {new} new, "
            f"{len(candidates) - new} already known, keep-runs {keep_runs}"
            + (f", {dupes} DUPLICATE ids" if dupes else ""))
        return 0

    # One run at a time, for the WHOLE run including downloads. Two ingests
    # racing used to delete each other's work directory and blame yt-dlp.
    try:
        run_guard = libstore.locked(root, "run", timeout=5)
        run_guard.__enter__()
    except LibraryError as exc:
        log(f"STOPPED — {exc}")
        libstore.record(root, "ingest", False, "A run was skipped: another was in progress.")
        return 1

    try:
        libstore.require_tools("ffmpeg")
        if any(not c.get("local") for c in candidates):
            libstore.require_tools("yt-dlp")

        workroot = root / f".work-{os.getpid()}"
        shutil.rmtree(workroot, ignore_errors=True)
        workroot.mkdir(parents=True)

        added, updated, failed, rejected = [], [], [], []
        downloaded, seen_ids = {}, {}

        for cand in candidates:
            title = (cand.get("title") or "").strip()
            artist = (cand.get("artist") or "").strip()
            if not title:
                rejected.append("(candidate with no title)")
                continue

            track_id = slugify(artist, title)
            label = f"{title} — {artist}" if artist else title

            if track_id in seen_ids:
                log(f"! duplicate of {seen_ids[track_id]} within this run: {label} "
                    f"— skipping so it cannot silently overwrite it")
                rejected.append(f"{label} (duplicate of {seen_ids[track_id]})")
                continue
            seen_ids[track_id] = label

            log(f"→ {label}")
            clip_rel = f"clips/{track_id}.mp3"
            clip_path = root / clip_rel
            got = clip_path.exists() and clip_path.stat().st_size > 0
            hookinfo = None

            if not got:
                workdir = workroot / track_id
                workdir.mkdir(parents=True, exist_ok=True)
                try:
                    src = fetch_source(cand, workdir)
                    if src:
                        hookinfo = find_hook(src, workdir, cand)
                        got = make_clip(src, clip_path, hookinfo[0])
                finally:
                    shutil.rmtree(workdir, ignore_errors=True)

            size = clip_path.stat().st_size if got else 0
            downloaded[track_id] = (cand, clip_rel if got else None, label, got,
                                    size, hookinfo)

        # RETRY PASS. A long run makes dozens of rapid DNS lookups, and on a
        # laptop the resolver can give out partway through — the first 51-track
        # run lost its last 24 to "Failed to resolve www.youtube.com", which
        # looked like rate limiting but was local. A pause and one more attempt
        # recovers those without re-doing the successes.
        retry = [tid for tid, (_, _, _, ok, _, _) in downloaded.items() if not ok
                 and (downloaded[tid][0].get("search") or downloaded[tid][0].get("source_url"))]
        if retry:
            log(f"\n--- retrying {len(retry)} that failed, after a pause ---")
            time.sleep(20)
            for track_id in retry:
                cand, _, label, _, _, _ = downloaded[track_id]
                log(f"↻ {label}")
                clip_rel = f"clips/{track_id}.mp3"
                clip_path = root / clip_rel
                workdir = workroot / f"retry-{track_id}"
                workdir.mkdir(parents=True, exist_ok=True)
                hookinfo = None
                got = False
                try:
                    src = fetch_source(cand, workdir)
                    if src:
                        hookinfo = find_hook(src, workdir, cand)
                        got = make_clip(src, clip_path, hookinfo[0])
                finally:
                    shutil.rmtree(workdir, ignore_errors=True)
                if got:
                    downloaded[track_id] = (cand, clip_rel, label, True,
                                            clip_path.stat().st_size, hookinfo)
                    log("  recovered")
                time.sleep(1)

        shutil.rmtree(workroot, ignore_errors=True)

        with libstore.locked(root, "library"):
            library = libstore.load_json(root / "library.json",
                                         {"version": 1, "tracks": []},
                                         allow_restore=True)
            library.setdefault("version", 1)
            library.setdefault("tracks", [])
            favourites = set(libstore.load_json(
                root / "favourites.json", {}, allow_restore=True).get("ids", []))

            for track_id, (cand, clip_rel, label, got, size, hookinfo) in downloaded.items():
                known = any(t.get("id") == track_id for t in library["tracks"])
                merge(library, cand, track_id, run_stamp, clip_rel, size, hookinfo)
                (failed if not got else (updated if known else added)).append(label)

            # Monotonic: catching up an older run must not drag the dashboard's
            # "Fresh" section back to a stale date.
            library["last_run"] = libstore.newer_stamp(
                library.get("last_run"), run_stamp)

            save(root, library, favourites, profile)   # save BEFORE pruning
            kept, freed = prune(library, root, favourites, keep_runs, run_stamp)
            save(root, library, favourites, profile)

            total = sum(t.get("clip_bytes", 0) for t in library["tracks"]
                        if t.get("clip_present"))
            tracked, nfav = len(library["tracks"]), len(favourites)
    finally:
        run_guard.__exit__(None, None, None)

    result = {
        "run": run_stamp, "ok": True,
        "added": len(added), "updated": len(updated),
        "no_audio": len(failed), "rejected": len(rejected),
        "clips_kept": kept, "bytes_freed": freed, "tracked": tracked,
        "finished": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    libstore.write_text_atomic(root / args.result, json.dumps(result, indent=2))

    log("")
    log(f"run {run_stamp}: {len(added)} new, {len(updated)} updated, "
        f"{len(failed)} without audio, {len(rejected)} rejected")
    for name in failed:
        log(f"  no audio: {name}")
    for name in rejected:
        log(f"  rejected: {name}")
    log(f"clips on disk: {kept} ({human(total)}), freed {human(freed)} this run")
    log(f"library: {tracked} tracks tracked, {nfav} favourites")

    if failed and not (added or updated):
        libstore.record(root, "ingest", False,
                        f"Run {run_stamp} downloaded nothing — {len(failed)} tracks "
                        f"had no audio.", "Usually a stale yt-dlp or no network.")
    elif failed:
        libstore.record(root, "ingest", False,
                        f"Run {run_stamp}: {len(failed)} of "
                        f"{len(added) + len(updated) + len(failed)} tracks had no audio.")
    else:
        libstore.clear_kind(root, "ingest")

    return 0 if (added or updated) else 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except LibraryError as exc:
        log(f"\nSTOPPED — {exc}")
        try:
            libstore.record(Path(sys.argv[sys.argv.index("--root") + 1]
                                 if "--root" in sys.argv else ".",),
                            "ingest", False, "A run stopped without changing anything.",
                            str(exc))
        except Exception:
            pass
        sys.exit(1)
