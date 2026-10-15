#!/usr/bin/env bash
# Headless smoke run of the real UI on Linux: opens a demo library (a copy of the reference
# library's state with placeholder clips), waits for the window, screenshots it, and checks the
# process is still alive. Used by CI and for design previews.
set -euo pipefail
ROOT=$(pwd)
DEMO=$(mktemp -d)
mkdir -p "$DEMO/clips" "$DEMO/full"
cp reference/state/*.json "$DEMO/" 2>/dev/null || cp test/fixtures/demo-library/*.json "$DEMO/"
python3 - "$DEMO" <<'PY'
import json, os, sys, subprocess
D=sys.argv[1]
lib=json.load(open(f'{D}/library.json'))
first=True
for t in lib['tracks']:
    if t.get('clip_present') and t.get('clip'):
        p=f"{D}/{t['clip']}"
        if first:
            subprocess.run(['ffmpeg','-y','-loglevel','error','-f','lavfi','-i','sine=frequency=330:duration=30','-ac','1','-ar','44100','-b:a','128k',p],check=True); first=False
        else:
            open(p,'wb').write(b'\0'*max(1,t.get('clip_bytes',1000)))
    if t.get('full'):
        p=f"{D}/{t['full']}"; os.makedirs(os.path.dirname(p),exist_ok=True); open(p,'wb').write(b'\0'*1000)
PY
BIN=$(ls build/linux/x64/release/bundle/soundbites)
mkdir -p dist/screenshots
export SOUNDBITES_DEMO_LIBRARY="$DEMO"
xvfb-run -a -s "-screen 0 1440x900x24" bash -c '
  "'"$BIN"'" & PID=$!
  sleep 8
  import -window root dist/screenshots/library.png
  kill -0 $PID && echo "app still running" || { echo "app exited early"; exit 1; }
  kill $PID
'
ls -la dist/screenshots
