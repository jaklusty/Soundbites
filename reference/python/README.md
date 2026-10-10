# Soundbites library

A local trending-audio dashboard and soundbite store, built to move onto a NAS later without changing shape.

## Install

Unzip so the contents land at `~/Movies/Soundbites/_library/`. `~/Movies` matters — it's never iCloud-synced, so Resolve can't find media offline mid-edit.

```bash
mkdir -p ~/Movies/Soundbites
unzip soundbites-library.zip -d ~/Movies/Soundbites/
brew install yt-dlp ffmpeg whisper-cpp
```

Start the server:

```bash
cd ~/Movies/Soundbites/_library
python3 serve.py
```

Open <http://127.0.0.1:8765>. It'll be empty until the first trending run.

To have it start at login, replace every `USERNAME` in **both** plists with your short username (`whoami`), then:

```bash
cp com.jak.soundbites.plist com.jak.soundbites.catchup.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.jak.soundbites.plist
launchctl load ~/Library/LaunchAgents/com.jak.soundbites.catchup.plist
```

Two agents, not one: launchd won't start a second instance of a label that's already running, so a file-watch on the long-lived server would never fire. The second agent is short-lived and exists to notice new queued runs.

## What each file does

| File | Role |
|---|---|
| `index.html` | The dashboard. Sections, search, profile switcher, playback, starring. |
| `serve.py` | Static server + write API on `:8765`. Runs catch-up on start. Stdlib only. |
| `libstore.py` | Shared safety layer: corruption handling, backups, durable writes, locking. |
| `ingest.py` | Called after research: downloads hooks, transcodes, merges, prunes. |
| `promote.py` | Pulls the **full track** for anything you star. |
| `catchup.py` | Ingests runs researched while this Mac was offline. |
| `library.json` | Source of truth. Every track ever surfaced, with per-run history. |
| `library.js` | Same data as a `<script>` so the page also opens straight off disk. |
| `favourites.json` | Starred track IDs. Written by the API. |
| `promote_queue.json` | Stars waiting for their full track. |
| `profile.json` | Your niches. Drives relevance filtering. Hand-edit this. |
| `clips/` | 30s audition MP3s, ~0.5 MB each. |
| `full/<id>/` | Full tracks for favourites, plus the original download. |
| `pending/` | Runs researched in the cloud, waiting for this Mac. |
| `health.json` | What has gone wrong lately. The dashboard reads this. |
| `last_run.json` | Machine-readable summary of the most recent ingest. |
| `*.bak` | Previous good copy of each state file, rewritten on every save. |

## Two tiers of audio, on purpose

**Audition clips** (30s, mono, 128k, ~0.5 MB) answer *does this fit my footage?* Every candidate in every run gets one.

**Full tracks** are pulled automatically the moment you star something, because that's the point at which you need to find the bar that lands on your cut. They go in `full/<id>/` as 48kHz 16-bit stereo WAV — drag straight into Resolve and trim to the section you want.

Real sizes, since they matter:

| Format | Per minute | 3-minute track |
|---|---|---|
| 48k 16-bit WAV (default) | 11.5 MB | ~35 MB |
| 48k 24-bit WAV | 17.3 MB | ~52 MB |
| 320k MP3 | 2.4 MB | ~7 MB |

WAV is the default because Resolve conforms it without re-sampling. But 35 MB each adds up — around 2 GB a year at five favourites a month. If that's the wrong trade for you, `python3 promote.py --format mp3` costs a fifth of the space and is transparent for a music bed. `promote.py` warns you once total full-track storage passes 2 GB.

## Storage overall

Metadata is free, audio isn't. So:

- A **clip** is kept only if the track is starred, or was seen in the last 2 runs. Everything else keeps its full metadata row and stays searchable; only the MP3 goes, and `source_url` means it can be re-pulled.
- A **full track** is only ever pulled for something you starred. Unstar what you're done with, then hit **Free that space** in the dashboard — or run `python3 promote.py --reclaim`. It deletes full tracks for unstarred entries only, and never touches a favourite or an audition clip. The dashboard shows how much is reclaimable.

Steady state for the audition tier is roughly **10–15 MB**, indefinitely. The full tier is whatever your favourites add up to, shown in the dashboard footer.

## Missed runs

Trend research is time-sensitive; the audio isn't. So a scheduled run that can't reach this Mac still does the research and drops it into `pending/` as a small JSON file. `catchup.py` then ingests every pending run in date order and works the promotion queue. It runs when `serve.py` starts, and the second launchd agent watches `pending/` so a run arriving while you're logged in is picked up within moments. Simply waking the laptop does not trigger it — nothing restarts on wake — so the file-watch is what covers the in-between case.

```bash
python3 catchup.py --list    # what's waiting
python3 catchup.py           # ingest it all now
```

A run more than three weeks old gets flagged: its "rising" calls were true when researched, not necessarily now.

## Moving to a NAS

Nothing here is machine-specific except the paths in the plist.

1. `rsync -a ~/Movies/Soundbites/ nas:/volume1/media/Soundbites/`
2. Run it there with a token (command below) — Synology Web Station, or a Python container.
3. Every device on the LAN gets the same library and the same favourites.

`serve.py` refuses to bind a non-loopback address without `--token`, and rejects cross-origin POSTs. That is deliberate: starring a track runs a program and downloads a file, so an open listener on a LAN lets anything on that network do both. For the NAS:

```bash
python3 serve.py --root /volume1/media/Soundbites/_library \
  --host 0.0.0.0 --token "$(python3 -c 'import secrets;print(secrets.token_urlsafe(16))')"
```

Then open it as `http://<nas>:8765/?k=<token>` — the page carries the token from there.

**One honest limit on the NAS plan.** Serving the library from a NAS to several devices is fine. Having several *machines* write to one `library.json` over an SMB or AFP mount is not: the file locking this uses (`flock`) is advisory and may not carry across a network share, so two machines running an ingest at once could lose each other's work. Run the scheduled ingest on exactly one machine, and let the others be readers.

## Manual use

```bash
# see what a run would change without touching anything
python3 ingest.py candidates.json --root . --dry-run

# ingest, keeping a deeper cache
python3 ingest.py candidates.json --root . --keep-runs 4
```

The candidate schema is documented at the top of `ingest.py`.

## When something goes wrong

The dashboard has a **Needs attention** strip at the top. It is the only thing you have to read — every failure in the system writes there, so a jammed queue or a failed download shows up in the page you already have open rather than in a log file.

`library.json`, `favourites.json` and `profile.json` each keep a `.bak` of the last good copy, rewritten on every successful save. If the live file is ever damaged, it is **left exactly where it is** — never renamed or overwritten — and the library is restored from the backup, with a note in the status strip saying so. If there is no usable backup, everything stops rather than quietly starting a fresh, empty library.

Logs, if you want them: `serve.log`, `catchup.log`, `promote.log`, `ingest.log`.

## What is deliberately not automatic

- Nothing deletes a full track without you asking (unstar, then reclaim).
- Nothing retries a failed download on its own — re-run the same `candidates.json`.
- Queued runs are only marked done when an ingest actually succeeds; a failed one stays queued and says so.
