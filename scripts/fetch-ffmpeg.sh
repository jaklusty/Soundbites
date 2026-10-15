#!/usr/bin/env bash
# Downloads the bundled ffmpeg from a release made by .github/workflows/ffmpeg.yml into
# vendor/ffmpeg/<mac|win>/ and verifies it against the release's SHA256SUMS.
#   scripts/fetch-ffmpeg.sh mac|win <release-tag>
set -euo pipefail
PLATFORM="$1"; TAG="$2"
case "$PLATFORM" in mac) ASSET=ffmpeg-mac-universal.zip;; win) ASSET=ffmpeg-win-x64.zip;; *) echo "usage: fetch-ffmpeg.sh mac|win <tag>"; exit 2;; esac
OUT="vendor/ffmpeg/$PLATFORM"; TMP="vendor/ffmpeg/$PLATFORM-download"
rm -rf "$OUT" "$TMP"; mkdir -p "$OUT" "$TMP"
gh release download "$TAG" --repo jaklusty/soundbites --pattern "$ASSET" --pattern SHA256SUMS --dir "$TMP"
EXPECTED=$(grep " $ASSET\$" "$TMP/SHA256SUMS" | awk '{print $1}')
if command -v sha256sum >/dev/null; then ACTUAL=$(sha256sum "$TMP/$ASSET" | awk '{print $1}'); else ACTUAL=$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}'); fi
[ "$EXPECTED" = "$ACTUAL" ] || { echo "checksum mismatch for $ASSET"; exit 1; }
if [ "$PLATFORM" = win ]; then tar -xf "$TMP/$ASSET" -C "$OUT"; else unzip -o -q "$TMP/$ASSET" -d "$OUT"; fi
rm -rf "$TMP"
ls -la "$OUT"
echo "ffmpeg $TAG verified and placed in $OUT"
