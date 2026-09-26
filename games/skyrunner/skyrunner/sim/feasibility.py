"""Airfield x aircraft x load feasibility, flown by the pilot bot.

A strip that a loaded aircraft can land on but can't leave is a trap, and a
job generator that sends you there is unfair. This sweep finds both.
"""
from __future__ import annotations

import math
from concurrent.futures import ProcessPoolExecutor
from dataclasses import asdict, dataclass

from ..aircraft import ROSTER
from ..bots.pilot import Leg, PilotBot, fly, plan_approach
from ..jobs import new_id
from ..loadout import Item
from ..world import AIRFIELD_BY_CODE, AIRFIELDS

LOADS = {"light": (0.3, 0.0), "half": (0.6, 0.5), "max": (1.0, 1.0)}  # (fuel frac, payload frac)


@dataclass
class Trial:
    aircraft: str
    field: str
    load: str
    test: str  # "takeoff" | "landing"
    ok: bool
    outcome: str
    weight_lb: float
    seconds: float


def _session(key: str, code: str, seed: int = 11):
    from ..game import Session

    s = Session(seed=seed, location=code, owned={key}, aircraft_key=key, features=set())
    s.police.features.clear()
    s.police.tick = lambda *a, **k: {}  # no law in the test rig
    s.police.landing_check = lambda *a, **k: False
    return s


def load_aircraft(sess, fuel_frac: float, payload_frac: float) -> None:
    """Fill fuel, then crates up to payload_frac of what MTOW/stations allow,
    placed by the loadmaster, loaded instantly (this is a test rig)."""
    lo = sess.loadout
    lo.fuel_lb = lo.mass.fuel_capacity_lb * fuel_frac
    base = lo.compute(planned=True).weight_lb
    room = max(0.0, sess.spec.mtow_lb - base) * payload_frac
    while room > 20:
        w = min(60.0, room)
        lo.add(Item(new_id(), "Crate", "cargo", w, 0))
        room -= w
        if not lo.auto_balance():
            lo.remove_item(max(lo.items))
            lo.auto_balance()
            break
    lo.pending.clear()
    sess.fm.apply_loadout(lo)
    sess.fm.step(0.2, sess.world.ground)
    sess.state = sess.fm.state()


def takeoff_trial(key: str, code: str, load: str) -> Trial:
    s = _session(key, code)
    load_aircraft(s, *LOADS[load])
    w = s.state.weight_lb
    af = AIRFIELD_BY_CODE[code]
    # a point 3 km toward the nearest other field: the bot picks its own takeoff
    # direction and has to get round any high ground on the way
    far = min((a for a in AIRFIELDS if a.code != code), key=lambda a: math.hypot(a.x - af.x, a.y - af.y))
    d = math.hypot(far.x - af.x, far.y - af.y)
    tx, ty = af.x + (far.x - af.x) / d * 3000, af.y + (far.y - af.y) / d * 3000
    bot = PilotBot(s, [Leg("goto", tx, ty)])
    t0 = s.time
    fly(s, bot, 400)
    ok = s.phase == "flying" and bot.phase in ("enroute", "done") and not s.fm.crash_reason
    if bot.leg_i >= 1:
        ok = True
    return Trial(key, code, load, "takeoff", ok, s.last_outcome or bot.outcome or "", w, s.time - t0)


def landing_trial(key: str, code: str, load: str) -> Trial:
    af = AIRFIELD_BY_CODE[code]
    start = "HAR" if code != "HAR" else "VAL"
    s = _session(key, start)
    load_aircraft(s, *LOADS[load])
    w = s.state.weight_lb
    roll = s.spec.est_landing_roll(w, s.world.airfield_elev(af))
    ap = plan_approach(s.world, af, s.fm.mass.gear_height_ft * 0.3048, roll)
    dist = min(5000.0, 320.0 / math.tan(math.radians(ap.gamma))) + 2500
    x, y = ap.point(dist)
    agl = max(ap.path_alt(dist) - s.world.ground(x, y), 250.0)
    s.spawn_airborne(x, y, ap.hdg, agl, s.spec.approach_kts * 1.3)
    bot = PilotBot(s, [Leg("land", af.x, af.y, code)])
    bot.phase = "enroute"
    t0 = s.time
    fly(s, bot, 600)
    ok = s.phase == "parked" and s.location == code
    return Trial(key, code, load, "landing", ok, s.last_outcome if not ok else "landed", w, s.time - t0)


def _run(args) -> dict:
    test, key, code, load = args
    fn = takeoff_trial if test == "takeoff" else landing_trial
    try:
        return asdict(fn(key, code, load))
    except Exception as e:  # a crash in the rig is a result too
        return asdict(Trial(key, code, load, test, False, f"error: {e}", 0.0, 0.0))


def sweep(aircraft=None, fields=None, loads=None, workers: int = 4) -> list[dict]:
    aircraft = aircraft or [k for k in ROSTER]
    fields = fields or [a.code for a in AIRFIELDS]
    loads = loads or list(LOADS)
    jobs = [(t, k, c, ld) for k in aircraft for c in fields for ld in loads for t in ("takeoff", "landing")]
    if workers <= 1:
        return [_run(j) for j in jobs]
    with ProcessPoolExecutor(workers) as ex:
        return list(ex.map(_run, jobs))


def table(results: list[dict]) -> str:
    """Markdown: rows = aircraft/load, cols = fields, cell = T/L pass marks."""
    fields = [a.code for a in AIRFIELDS]
    by = {(r["aircraft"], r["load"], r["field"], r["test"]): r for r in results}
    keys = sorted({(r["aircraft"], r["load"]) for r in results},
                  key=lambda k: (list(ROSTER).index(k[0]), list(LOADS).index(k[1])))
    lines = ["| aircraft | load | " + " | ".join(fields) + " |", "|---|---|" + "---|" * len(fields)]
    for ac, ld in keys:
        cells = []
        for f in fields:
            t = by.get((ac, ld, f, "takeoff"))
            la = by.get((ac, ld, f, "landing"))
            mark = lambda r: "·" if r is None else ("✓" if r["ok"] else "✗")  # noqa: E731
            cells.append(f"L{mark(la)} T{mark(t)}")
        lines.append(f"| {ROSTER[ac].name} | {ld} | " + " | ".join(cells) + " |")
    return "\n".join(lines)
