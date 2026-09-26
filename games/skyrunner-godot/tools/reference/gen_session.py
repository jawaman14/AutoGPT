"""ARCHIVAL: the Python prototype is reference only. This script regenerates a frozen
parity fixture; nothing in the Godot game needs it to build, play or test.

Reference runs from the Python game for the port's Session/police/HQ parity tests.

  python3 tools/reference/gen_session.py > tests/fixtures/session_ref.json
"""
import itertools
import json
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "..", "skyrunner"))
from skyrunner import jobs as J  # noqa: E402
from skyrunner.bots.hq import LAW_POLICIES, RUNNER_POLICIES  # noqa: E402
from skyrunner.game import Session  # noqa: E402
from skyrunner.hq import Season, resolve_abstract  # noqa: E402
from skyrunner.roles import Mode  # noqa: E402

out = {}

J._ids = itertools.count(1)
s = Session(seed=3)
out["solo"] = {"squawk": s.squawk, "cove": list(s.maritime.cove), "cg": list(s.maritime.cg_station),
               "board": [[j.id, j.title, j.payout, round(j.weight_lb, 6)] for j in s.boards["HAR"]]}


def police_snap(p):
    return {
        "t": round(p.time, 6),
        "smugglers": [[a.id, a.x, a.y, a.z, a.heading, a.state, a.bales_left] for a in p.smugglers],
        "units": [[u.id, u.kind, u.x, u.y, u.z, u.heading, u.state, u.target_id] for u in p.police.units],
        "cases": {k: [c.suspicion, c.wanted, c.bust_meter] for k, c in p.police.cases.items()},
        "score": dict(p.police.score),
        "boats": [[b.id, b.kind, b.x, b.y, b.state] for b in p.maritime.boats],
        "tracks": {k: [t.x, t.y] for k, t in p.police.sensors.tracks.items()},
        "stock": dict(p.police.stock),
        "law_log": [m[1] for m in p.law_log[-6:]],
    }


J._ids = itertools.count(1)
p = Session(seed=3, mode=Mode.POLICE)
snaps = []
for i in range(1, 30 * 300 + 1):
    p.update(1 / 30)
    if i % (30 * 60) == 0:
        snaps.append(police_snap(p))
out["police"] = snaps

seasons = []
for ri, rname in enumerate(RUNNER_POLICIES):
    for li, lname in enumerate(LAW_POLICIES):
        ss = Season(random.Random(1000 + 10 * ri + li))
        bot = random.Random(7 + ri * 31 + li)
        mem = ({}, {})
        while True:
            RUNNER_POLICIES[rname](ss, bot, mem[0])
            LAW_POLICIES[lname](ss, bot, mem[1])
            plan = ss.start_operation()
            ss.finish_night(resolve_abstract(ss, plan, bot))
            if ss.phase == "over":
                break
            ss.next_night()
        seasons.append({"runner": rname, "law": lname, "winner": ss.winner, "reason": ss.reason,
                        "history": ss.history, "news": [ln for r in ss.reports for ln in r.lines],
                        "dirty": ss.org.dirty, "clean": ss.org.clean, "evidence": ss.law.evidence})
out["seasons"] = seasons
print(json.dumps(out))
