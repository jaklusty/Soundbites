#!/usr/bin/env bash
# Prepares the two library copies used by test/parity.test.ts (Phase 1 checks b and c).
#   scripts/prepare-parity.sh <reference-folder-with-python-and-json> <target-folder>
# Creates <target>/py (with the Python scripts), <target>/ts, dummy clip files of the recorded
# sizes for every track (the audio itself is not needed), and three synthetic test tracks in
# <target>/audio. Then run:
#   SOUNDBITES_PARITY=<target> npx vitest run test/parity.test.ts
set -euo pipefail
REF="$1"; OUT="$2"
rm -rf "$OUT"; mkdir -p "$OUT/audio"
for d in py ts; do
  mkdir -p "$OUT/$d/clips" "$OUT/$d/full" "$OUT/$d/pending"
  for f in library.json favourites.json profile.json promote_queue.json health.json last_run.json; do
    [ -f "$REF/$f" ] && cp "$REF/$f" "$OUT/$d/"
  done
done
cp "$REF"/{ingest.py,libstore.py,hook.py,promote.py,catchup.py} "$OUT/py/"
python3 - "$OUT" <<'PY'
import json, os, sys
out=sys.argv[1]
lib=json.load(open(f'{out}/py/library.json'))
for d in ('py','ts'):
    for t in lib['tracks']:
        if t.get('clip_present') and t.get('clip'):
            with open(f"{out}/{d}/{t['clip']}",'wb') as f: f.write(b'\0'*max(1,t.get('clip_bytes',1000)))
        if t.get('full'):
            p=f"{out}/{d}/{t['full']}"; os.makedirs(os.path.dirname(p),exist_ok=True)
            with open(p,'wb') as f: f.write(b'\0'*1000)
print('dummy audio written for', sum(1 for t in lib['tracks'] if t.get('clip_present')), 'clips')
PY
for i in 1 2 3; do
  ffmpeg -y -loglevel error -f lavfi -i "sine=frequency=$((220*i)):duration=95" -ac 2 -ar 44100 -c:a libmp3lame -b:a 128k "$OUT/audio/local$i.mp3"
done
echo "prepared $OUT"
