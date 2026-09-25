#!/usr/bin/env bash
# Build the JSBSim GDExtension into bin/. Needs cmake >= 3.22 and a C++17 compiler.
# Pass JSBSIM_SRC / GODOTCPP_SRC to reuse local checkouts instead of downloading.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD=${BUILD_DIR:-.build/native}
cmake -S native -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
  ${JSBSIM_SRC:+-DSKYRUNNER_JSBSIM_SRC=$JSBSIM_SRC} ${GODOTCPP_SRC:+-DSKYRUNNER_GODOTCPP_SRC=$GODOTCPP_SRC}
cmake --build "$BUILD" --target skyrunner_native -j"$(nproc)"
ls -la bin/
