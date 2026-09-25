#!/usr/bin/env bash
# Record a split-screen demo from the Godot build and encode it as MP4.
#   tools/record_demo.sh out.mp4 <zone> <law> <tactic> <seed> [graphics] [max_s] [hour] [speedup]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$1; shift
SPEED=${9:-2}
GODOT=${GODOT:-godot}
TMP=$(mktemp -d)
timeout 120 "$GODOT" --headless --import >/dev/null 2>&1 || true
xvfb-run -a -s "-screen 0 1280x720x24" "$GODOT" --rendering-method gl_compatibility --audio-driver Dummy \
  --resolution 1280x720 --write-movie "$TMP/demo.avi" --fixed-fps 30 --script res://tools/demo.gd -- "${@:1:7}" 2>&1 \
  | grep -E "outcome|SCRIPT ERROR" || true
ffmpeg -loglevel error -y -i "$TMP/demo.avi" -vf "setpts=PTS/$SPEED" -r 30 -c:v libx264 -pix_fmt yuv420p -crf 26 "$OUT"
rm -rf "$TMP"
echo "wrote $OUT"
