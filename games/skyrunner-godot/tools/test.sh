#!/usr/bin/env bash
# Run the headless test suite: ./tools/test.sh [filter]
# --import first so class_name scripts are registered; without it a headless
# --script run can stall on an unresolved class instead of failing.
set -uo pipefail
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
timeout 120 "$GODOT" --headless --import >/dev/null 2>&1
timeout "${TEST_TIMEOUT:-900}" "$GODOT" --headless --script res://tests/run_tests.gd -- "$@" 2>&1 \
  | grep -v -E "^\s*JSBSim Flight Dynamics|JSBSim-ML|JSBSim startup|^\s*$"
exit "${PIPESTATUS[0]}"
