#!/usr/bin/env bash
# Compile every script headless and print parse errors with file:line.
cd "$(dirname "$0")/.."
timeout 120 "${GODOT:-godot}" --headless --import 2>&1 | grep -E "SCRIPT ERROR|at: .*res://|ERROR: Failed to load" | grep -v "^\s*$" | head -${1:-40}
