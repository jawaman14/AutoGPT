#!/usr/bin/env bash
# Render the documentation screenshots into docs/img/ under a virtual X server
# (works on a GPU-less box: Mesa llvmpipe + Godot's GL compatibility renderer).
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
OUT=docs/img
mkdir -p "$OUT"
timeout 120 "$GODOT" --headless --import >/dev/null 2>&1 || true
run() { timeout 180 xvfb-run -a -s "-screen 0 1280x720x24" "$GODOT" --rendering-method gl_compatibility \
  --audio-driver Dummy --script "$@" 2>&1 | grep -E "saved|SCRIPT ERROR" || true; }
run res://tools/shots/pilot_shot.gd -- medium 14 "$PWD/$OUT/runway-medium.png" chase
run res://tools/shots/pilot_shot.gd -- high 17.7 "$PWD/$OUT/dusk-high.png" chase air
run res://tools/shots/pilot_shot.gd -- high 21 "$PWD/$OUT/night-runway.png" chase
run res://tools/shots/pilot_shot.gd -- low 11 "$PWD/$OUT/low-preset.png" chase air
run res://tools/shots/pilot_shot.gd -- high 10 "$PWD/$OUT/on-foot-hangar.png" chase foot
run res://tools/shots/pilot_shot.gd -- high 15 "$PWD/$OUT/villa-desk.png" chase villa
run res://tools/shots/pilot_shot.gd -- high 16 "$PWD/$OUT/hq-org.png" chase org
run res://tools/shots/pilot_shot.gd -- high 16 "$PWD/$OUT/hq-rival.png" chase rival
run res://tools/shots/pilot_shot.gd -- high 13 "$PWD/$OUT/map-classic.png" chase overview
run res://tools/shots/pilot_shot.gd -- high 13 "$PWD/$OUT/map-seed7.png" chase overview 7
run res://tools/shots/pilot_shot.gd -- high 15 "$PWD/$OUT/storm.png" chase air 0 storm 0.2
run res://tools/shots/pilot_shot.gd -- high 22 "$PWD/$OUT/full-moon.png" chase air 0 clear 1.0
for w in load jobs hangar boss chief desk copilot hud lobby; do
  run res://tools/shots/ui_shot.gd -- $w "$PWD/$OUT/ui-$w.png"
done
