"""ARCHIVAL: the Python prototype is reference only. This script regenerates a frozen
parity fixture; nothing in the Godot game needs it to build, play or test.

Reference output from the Python bots for the port's planner/flight parity tests.

  python3 tools/reference/gen_bots.py  # writes tests/fixtures/bots_ref.json (JSBSim chats on stdout)
"""
import itertools
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "..", "skyrunner"))
from skyrunner import jobs as J  # noqa: E402
from skyrunner.bots.pilot import Leg, PilotBot, fly, plan_approach, plan_departure  # noqa: E402
from skyrunner.bots.route import plan_route  # noqa: E402
from skyrunner.game import Session  # noqa: E402
from skyrunner.world import AIRFIELD_BY_CODE, AIRFIELDS, World  # noqa: E402

w = World()
out = {"routes": [], "approaches": {}, "departures": {}}
for a, b in [("FRM", "QRY"), ("HAR", "ISL"), ("VAL", "EGL"), ("PNR", "COV")]:
    fa, fb = AIRFIELD_BY_CODE[a], AIRFIELD_BY_CODE[b]
    out["routes"].append({"from": a, "to": b, "pts": [list(p) for p in plan_route(w, (fa.x, fa.y), (fb.x, fb.y))]})
for af in AIRFIELDS:
    ap = plan_approach(w, af, 1.2, 120.0)
    out["approaches"][af.code] = [ap.hdg, list(ap.aim), ap.elev, ap.gamma, ap.clear_m]
    out["departures"][af.code] = list(plan_departure(w, af, 160))

J._ids = itertools.count(1)
s = Session(seed=5, location="HAR", features=set())
s.police.tick = lambda *a, **k: {}
val = AIRFIELD_BY_CODE["VAL"]
bot = PilotBot(s, [Leg("land", val.x, val.y, "VAL")])
trace = []


def frame(sess):
    n = round(sess.time * 30)
    if n % 300 == 0:
        st = sess.state
        trace.append([round(sess.time, 6), bot.phase, st.x, st.y, st.alt, st.heading, st.ias_kts])


outcome = fly(s, bot, 900, on_frame=frame)
out["flight"] = {"outcome": outcome, "time": s.time, "trace": trace, "touchdown_fpm": s.log.max_touchdown_fpm}
with open(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "..", "tests", "fixtures", "bots_ref.json"), "w") as f:
    json.dump(out, f, indent=1)
