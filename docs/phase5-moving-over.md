# Phase 5: moving Jak's real library over

Do this only after Phase 4 passes on both systems. Nothing here is automatic; each step is a
decision. The order matters because the app's library lock is not compatible with the Python
lock: the old system must be off for good before the app is pointed at the real folder.

## 1. Back up the state files (not the audio)

In Terminal on the Mac:

```
cd ~/Movies/Soundbites/_library
mkdir -p ~/Desktop/soundbites-backup-$(date +%Y-%m-%d)
cp *.json *.bak ~/Desktop/soundbites-backup-$(date +%Y-%m-%d)/ 2>/dev/null
ls ~/Desktop/soundbites-backup-*
```

## 2. Switch the old system off for good

```
launchctl list | grep soundbites
```

If that prints anything, unload both agents and move their files out of LaunchAgents so they do
not come back at the next login:

```
launchctl unload ~/Library/LaunchAgents/com.jak.soundbites.plist
launchctl unload ~/Library/LaunchAgents/com.jak.soundbites.catchup.plist
mkdir -p ~/Movies/Soundbites/_legacy
mv ~/Library/LaunchAgents/com.jak.soundbites.plist ~/Library/LaunchAgents/com.jak.soundbites.catchup.plist ~/Movies/Soundbites/_legacy/
```

Confirm nothing is listening on port 8765 (the command prints nothing when the port is free):

```
lsof -nP -iTCP:8765 -sTCP:LISTEN
```

If something is listed, quit it (it is `python3 serve.py`), then run the check again.

## 3. Point the app at the real library

Open Soundbites, Settings, Change… and choose `~/Movies/Soundbites/_library`. The app opens the
existing library.json unchanged; it should show the same track count and the same favourites as
before. Play a clip, star something, confirm the full track arrives.

The first feed check will queue the runs the Python never ingested (everything since
29 August). Only the newest eight get clips; older ones are filed as metadata.

## 4. Tidy the old scripts (optional, never delete)

Offer: move the old scripts, index.html, library.js, the two plists already moved above, and the
installer/ folder into `~/Movies/Soundbites/_library/_legacy/`. The app ignores that folder.
Nothing is deleted; the library.json, favourites.json, profile.json, clips/ and full/ stay
exactly where they are.
