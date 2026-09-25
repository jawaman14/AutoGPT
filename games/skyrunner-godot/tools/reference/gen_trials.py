"""Seeded tactical and feasibility trials from the Python sims, for exact-replay parity.

  python3 tools/reference/gen_trials.py   # writes tests/fixtures/trials_ref.json (JSBSim chats on stdout)
"""
import itertools
import json
import os
import sys
from dataclasses import asdict

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "..", "skyrunner"))
from skyrunner import jobs as J  # noqa: E402
from skyrunner.sim.feasibility import landing_trial, takeoff_trial  # noqa: E402
from skyrunner.sim.tactical import run_trial  # noqa: E402

TACTICAL = [("west", "standard", "high", 100), ("sea", "all_in", "evasive", 101), ("north", "tipped", "low", 102)]
FEAS = [("takeoff", "c172p", "QRY", "half"), ("landing", "c172p", "EGL", "light"), ("takeoff", "c310", "PNR", "max")]
out = {"tactical": [], "feasibility": []}
for z, l, t, seed in TACTICAL:
    J._ids = itertools.count(1)
    out["tactical"].append(asdict(run_trial(z, l, t, seed)))
for test, k, c, ld in FEAS:
    J._ids = itertools.count(1)
    out["feasibility"].append(asdict((takeoff_trial if test == "takeoff" else landing_trial)(k, c, ld)))
with open(os.path.join(os.path.dirname(__file__), "..", "..", "tests", "fixtures", "trials_ref.json"), "w") as f:
    json.dump(out, f, indent=1)
