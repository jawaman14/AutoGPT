#!/usr/bin/env bash
# Download the pinned Godot build (headless-capable editor binary) to ./.tools/
set -euo pipefail
VER=4.4.1-stable
cd "$(dirname "$0")/.."
mkdir -p .tools
BIN=.tools/Godot_v${VER}_linux.x86_64
if [[ ! -x $BIN ]]; then
  curl -sSL -o .tools/godot.zip "https://github.com/godotengine/godot/releases/download/${VER}/Godot_v${VER}_linux.x86_64.zip"
  (cd .tools && unzip -oq godot.zip && rm godot.zip)
  chmod +x "$BIN"
fi
echo "$PWD/$BIN"
