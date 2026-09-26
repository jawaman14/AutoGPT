"""ARCHIVAL: the Python prototype is reference only. This script regenerates a frozen
parity fixture; nothing in the Godot game needs it to build, play or test.

Reference output from the Python season simulator for the port's strategic parity tests.

  python3 tools/reference/gen_strategic.py > tests/fixtures/strategic_ref.json
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "..", "skyrunner"))
from skyrunner.hq import Calibration  # noqa: E402
from skyrunner.sim.strategic import action_values, dominance, equilibrium, matrix, play_season, run_matrix, summary  # noqa: E402
from skyrunner.sim.tactical import calibrate  # noqa: E402

cal = Calibration(**json.load(open(os.path.join(os.path.dirname(__file__), "..", "..", "..", "skyrunner", "sim-results", "calibration.json"))))
out = {"cal": cal.__dict__, "seasons": []}
for args in [("smart", "adaptive", 17, None, None, ()), ("cautious", "investigator", 1017, None, cal, ()),
             ("random", "random", 2017, None, cal, ("recruit",)), ("greedy", "random", 3017, None, None, ("comeback",)),
             ("random", "balanced", 4017, {"nights": 8}, cal, ("bribe", "wiretap"))]:
    r = play_season(*args)
    out["seasons"].append({"args": [args[0], args[1], args[2], args[3], args[4] is not None, list(args[5])], "result": r})

res = run_matrix(n=3, cal=cal, workers=1)
R, L, m = matrix(res)
p, q, v = equilibrium(m)
out["matrix"] = {"runners": R, "laws": L, "m": m.tolist(), "p": p.tolist(), "q": q.tolist(), "v": v,
                 "dominance": dominance(m, R, L), "summary": summary(res),
                 "action_values": {s: {k: list(x) for k, x in action_values(res, s).items()} for s in ("runner", "law")},
                 "results": [{k: r[k] for k in ("runner", "law", "seed", "winner", "reason", "nights", "halftime", "margin")} for r in res]}
tac = json.load(open(os.path.join(os.path.dirname(__file__), "..", "..", "..", "skyrunner", "sim-results", "tactical.json")))
out["calibrate_tactical"] = calibrate(tac).__dict__
json.dump(out, sys.stdout)
