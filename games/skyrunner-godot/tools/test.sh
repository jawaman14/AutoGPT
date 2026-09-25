#!/usr/bin/env bash
# Run the headless test suite: ./tools/test.sh [filter]
# --import first so class_name scripts are registered; without it a headless
# --script run can stall on an unresolved class instead of failing.
# GDScript runtime errors don't abort the calling function (it carries on with
# null), so any "SCRIPT ERROR" in the output also fails the run.
set -uo pipefail
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
timeout 120 "$GODOT" --headless --import >/dev/null 2>&1
out=$(mktemp)
timeout "${TEST_TIMEOUT:-900}" "$GODOT" --headless --script res://tests/run_tests.gd -- "$@" >"$out" 2>&1
code=$?
grep -v -E "^\s*JSBSim Flight Dynamics|JSBSim-ML|JSBSim startup|^\s*$" "$out"
if grep -q "SCRIPT ERROR" "$out"; then
  echo "FAILED: script errors above"
  [[ $code -eq 0 ]] && code=100
fi
rm -f "$out"
exit $code
