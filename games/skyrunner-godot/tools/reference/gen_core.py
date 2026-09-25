"""Reference values from the Python game for the Godot port's parity tests.

  python3 tools/reference/gen_core.py > tests/fixtures/core_ref.json

Needs the Python game next door (../skyrunner) and its requirements.
"""
import itertools
import json
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "..", "skyrunner"))
from skyrunner import jobs as J  # noqa: E402
from skyrunner.aircraft import ROSTER  # noqa: E402
from skyrunner.fdm import FlightModel  # noqa: E402
from skyrunner.jsbsim_patch import build_patched_root, read_mass_data  # noqa: E402
from skyrunner.loadout import Item, Loadout  # noqa: E402
from skyrunner.world import AIRFIELD_BY_CODE, AIRFIELDS, World  # noqa: E402

out = {}
out["mass"] = {k: [m.empty_lb, m.empty_cg_x_in, [list(t) for t in m.tanks], m.gear_height_ft]
               for k, s in ROSTER.items() for m in [read_mass_data(s.jsbsim_model)]}

spec = ROSTER["c172p"]
md = read_mass_data("c172p")
lo = Loadout(spec, md, fuel_lb=200.0, copilot_aboard=True)
for i, (w, kind) in enumerate([(170, "passenger"), (60, "cargo"), (45, "cargo"), (150, "passenger"), (30, "cargo")]):
    lo.add(Item(100 + i, f"x{i}", kind, w, 1))
ok = lo.auto_balance()
wb = lo.compute()
out["lo"] = {"ok": ok, "assign": {str(k): v for k, v in lo.assignment.items()}, "w": wb.weight_lb, "cg": wb.cg_in,
             "env": wb.in_envelope, "fwd": wb.fwd_limit_in, "aft": wb.aft_limit_in}

J._ids = itertools.count(1)
rng = random.Random(42)
boards = {}
for code in ["FRM", "HAR", "QRY"]:
    js = J.generate_jobs(AIRFIELD_BY_CODE[code], AIRFIELDS, rng, n=6, features={"contraband", "airdrop", "ferry"},
                         drop_point_fn=lambda: (1000.0, -15000.0))
    boards[code] = [[j.id, j.title, j.kind, j.dest, j.payout, [[i.id, i.label, i.weight_lb, i.hot] for i in j.items]]
                    for j in js]
out["boards"] = boards

root = build_patched_root(list(ROSTER.values()))
w = World()
lo = Loadout(spec, md, fuel_lb=md.fuel_capacity_lb * 0.6)
fm = FlightModel(spec, root, md)
af = AIRFIELD_BY_CODE["HAR"]
ux, uy = af.dir
back = af.length / 2 - 25
fm.spawn(af.x - ux * back, af.y - uy * back, af.heading, w.airfield_elev(af), lo)
fm.controls.brake = 1.0
fm.step(0.5, w.ground)
fm.controls.brake = 0.0
fm.controls.throttle = 1.0
for _ in range(300):
    st = fm.step(1 / 30, w.ground)
out["fm"] = [st.x, st.y, st.alt, st.gs_kts, st.heading, st.fuel_lb, st.weight_lb, st.cg_in, fm.n_gear, fm.n_engines]
print(json.dumps(out))
