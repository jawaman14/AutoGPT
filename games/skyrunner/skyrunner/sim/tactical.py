"""Tactical balance: the pilot bot flies real runs against the AI task force.

Each trial is one night's main run in a full Session (JSBSim, radar, police
units, boats, cutters) under one law configuration, flown with one runner
tactic. The rates it measures are used two ways:

  1. directly, to judge the cops-vs-smugglers game people play in 3D
     (is low flying a free win? can the helicopter ever catch anything?)
  2. to calibrate `hq.resolve_abstract`, so thousands of simulated seasons
     rest on flown numbers rather than guesses
"""
from __future__ import annotations

import math
import random
from concurrent.futures import ProcessPoolExecutor
from dataclasses import asdict, dataclass

from ..bots.pilot import BotStyle, Leg, PilotBot, fly, plan_fuel_lb
from ..hq import ZONE_CENTRE
from ..jobs import CONTRABAND, Job, _item, airdrop_job, new_id
from ..world import AIRFIELD_BY_CODE

# zone -> (origin, destination or "SEA")
MISSIONS = {"west": ("FRM", "QRY"), "north": ("FRM", "EGL"), "sea": ("COV", "SEA")}

BOT_CRASH_CAP = 0.06

LAW_CONFIGS = {
    # name: (heli, interceptor, cutter, aerostat, patrol_match, tip)
    "light": (1, 0, 0, False, False, False),
    "standard": (1, 1, 1, False, False, False),
    "heavy": (2, 2, 1, False, False, False),
    "aerostat": (1, 1, 1, True, False, False),
    "patrol": (1, 1, 1, False, True, False),
    "tipped": (1, 1, 1, False, False, True),
    "all_in": (2, 2, 1, True, True, True),
}
TACTICS = {
    "low": BotStyle(agl_m=50.0, transponder_off=True, lookahead_s=35.0),
    "high": BotStyle(agl_m=450.0, transponder_off=False, evade=False),
    "evasive": BotStyle(agl_m=50.0, evade_agl_m=45.0, transponder_off=True, lookahead_s=35.0),  # + scanner & detector
}


@dataclass
class TacticalTrial:
    zone: str
    law: str
    tactic: str
    aircraft: str
    seed: int
    detected: bool = False  # painted by a radar or seen (a track exists)
    flagged: bool = False  # the task force decided it was a smuggler (wanted)
    intercepted: bool = False
    busted: bool = False
    crashed: bool = False
    delivered: bool = False
    boat_seized: bool = False
    outcome: str = ""
    minutes: float = 0.0
    first_detect_s: float | None = None


def _contraband_job(origin: str, dest: str, rng: random.Random) -> Job:
    jid = new_id()
    name, lo, hi = CONTRABAND[0]
    items = [_item(name, "cargo", rng.uniform(lo, hi), jid, hot=True) for _ in range(3)]
    return Job(jid, f"No questions asked -> {dest}", "contraband", origin, dest, items, 6000)


def run_trial(zone: str, law: str, tactic: str, seed: int, aircraft: str = "c172p") -> TacticalTrial:
    from ..game import Session

    rng = random.Random(seed)
    origin, dest = MISSIONS[zone]
    heli, inter, cutter, aerostat, patrol, tip = LAW_CONFIGS[law]
    features = {"contraband", "airdrop", "interceptors", "cutters", "df", "rivals"}
    s = Session(seed=seed, location=origin, owned={aircraft}, aircraft_key=aircraft, features=features)
    s.police.features.discard("rivals")  # measure the law, not the rival gangs
    s.police.features.add("aerostat")  # available, but only raised when the posture says so
    s.police.stock = {"heli": heli, "interceptor": inter, "cutter": cutter}
    if tactic == "evasive":
        s.gear |= {"scanner", "detector"}
        s.features |= {"scanner", "detector"}
    s.set_copilot("ai")
    s.transponder = True
    s.update(1 / 30)  # settle on the ramp
    job = airdrop_job(AIRFIELD_BY_CODE[origin], _drop_point(s, rng), rng) if dest == "SEA" else _contraband_job(origin, dest, rng)
    s.boards[origin] = [job]
    err = s.accept_job(job)
    if err:
        raise RuntimeError(err)
    s.loadout.auto_balance()
    s.loadout.pending.clear()
    s.fm.apply_loadout(s.loadout)
    af = AIRFIELD_BY_CODE[origin]
    legs = ([Leg("drop", *job.drop_point), Leg("land", af.x, af.y, origin)] if job.is_airdrop
            else [Leg("land", AIRFIELD_BY_CODE[dest].x, AIRFIELD_BY_CODE[dest].y, dest)])
    s.set_fuel(plan_fuel_lb(s, legs))
    bot = PilotBot(s, legs, style=TACTICS[tactic])
    # the night's law posture
    if aerostat:
        s.police.set_aerostat(True)
        s.police.aerostat_ready_t = s.time  # already up
    if patrol:
        s.police.launch("heli", goal=ZONE_CENTRE[zone])
    if cutter and (patrol or zone == "sea"):
        s.police.stock["cutter"] -= 1  # on picket offshore, not tied up in the harbour
        s.maritime.new_cutter(at=_picket_point("sea", rng))
    if tip:
        tx, ty = s.job_xy(job)
        s.police.features.add("informants")
        s.police.add_tip(tx + rng.uniform(-1200, 1200), ty + rng.uniform(-1200, 1200), 2500,
                         "informant: a load moves tonight", squawk=s.squawk, target_id="runner")
    tr = TacticalTrial(zone, law, tactic, aircraft, seed)
    events: list[str] = []
    s.bus.subscribe("*", lambda ev: events.append(ev.kind))

    def frame(sess):
        c = sess.police.cases.get("runner")
        if c and (c.detected_by or c.wanted) and not tr.detected:
            tr.detected = True
            tr.first_detect_s = sess.time
        if c and c.wanted:
            tr.flagged = True
        if any(u.sees_player and u.faction == "police" and u.target_id == "runner" for u in sess.police.units):
            tr.intercepted = True

    out = fly(s, bot, max_time=2400, on_frame=frame)
    # a hot load on a strip takes a minute to unload: the police may yet arrive
    t_end = s.time + 120
    while s.unloading and s.time < t_end and s.phase == "parked":
        s.update(1 / 10)
    # let the boat finish its trip to the cove (airdrops pay on arrival)
    if job.is_airdrop and s.phase not in ("crashed", "busted"):
        t_end = s.time + 900
        while s.time < t_end and not job.resolved:
            s.update(1 / 10)
    tr.busted = s.phase == "busted" or "busted" in events
    tr.crashed = s.phase == "crashed" or "crashed" in events
    tr.boat_seized = "boat_seized" in events
    tr.delivered = ("job_delivered" in events) or ("bales_delivered" in events and not tr.boat_seized)
    tr.outcome = s.last_outcome or out
    tr.minutes = s.time / 60
    return tr


def _picket_point(zone: str, rng: random.Random) -> tuple[float, float]:
    x, y = ZONE_CENTRE[zone]
    return x + rng.uniform(-3000, 3000), y + rng.uniform(-3000, 3000)


def _drop_point(s, rng: random.Random) -> tuple[float, float]:
    from ..maritime import random_drop_point

    return random_drop_point(s.world, rng, near=s.maritime.cove)


def _job(args) -> dict:
    zone, law, tactic, seed, aircraft = args
    try:
        return asdict(run_trial(zone, law, tactic, seed, aircraft))
    except Exception as e:  # a crash in the rig is a result too
        return asdict(TacticalTrial(zone, law, tactic, aircraft, seed, outcome=f"error: {e}"))


def sweep(seeds: int = 4, zones=None, laws=None, tactics=None, aircraft: str = "c172p", workers: int = 4) -> list[dict]:
    zones = zones or list(MISSIONS)
    laws = laws or list(LAW_CONFIGS)
    tactics = tactics or list(TACTICS)
    jobs = [(z, l, t, 100 + i, aircraft) for z in zones for l in laws for t in tactics for i in range(seeds)]
    with ProcessPoolExecutor(workers) as ex:
        return list(ex.map(_job, jobs))


def rates(results: list[dict], **where) -> dict:
    rs = [r for r in results if all(r[k] == v for k, v in where.items()) and not r["outcome"].startswith("error")]
    n = len(rs)
    if not n:
        return {"n": 0}
    f = lambda k: sum(r[k] for r in rs) / n  # noqa: E731
    det = [r for r in rs if r["flagged"]]
    inter = [r for r in rs if r["intercepted"]]
    return {
        "n": n, "detected": f("detected"), "flagged": f("flagged"), "intercepted": f("intercepted"),
        "busted": f("busted"), "crashed": f("crashed"), "delivered": f("delivered"), "boat_seized": f("boat_seized"),
        "intercept_if_flagged": sum(r["intercepted"] for r in det) / len(det) if det else None,
        "bust_if_intercepted": sum(r["busted"] for r in inter) / len(inter) if inter else None,
    }


def calibrate(results: list[dict]):
    """Fit hq.Calibration to flown results. The abstract resolver's 'detected'
    means the task force has decided it's a smuggler, i.e. our 'flagged'."""
    from ..hq import Calibration

    cal = Calibration()
    for z in MISSIONS:
        base = rates(results, zone=z, law="standard")
        aer = rates(results, zone=z, law="aerostat")
        if base.get("n", 0) >= 4:
            cal.detect[z] = round(min(0.9, base["flagged"]), 3)
            # the bot crashes more than a competent human on low-level legs: cap it
            cal.crash[z] = round(min(BOT_CRASH_CAP, max(0.01, base["crashed"])), 3)
        if aer.get("n", 0) >= 4 and base.get("n", 0) >= 4:
            cal.aerostat_detect[z] = round(max(0.0, aer["flagged"] - base["flagged"]), 3)
    flagged = [r for r in results if r["law"] == "standard" and r["flagged"]]
    if len(flagged) >= 6:
        p = sum(r["intercepted"] for r in flagged) / len(flagged)
        # standard posture: 1 heli + 1 interceptor, patrol elsewhere (match 0.8)
        haz = min(3.0, -math.log(max(0.05, 1 - p)) / 0.8)  # patrol elsewhere: match 0.8
        w = cal.intercept_per_unit["heli"] + cal.intercept_per_unit["interceptor"]  # 1 heli + 1 interceptor
        cal.intercept_k = round(haz / math.log1p(w), 3)
    inter = [r for r in results if r["intercepted"]]
    if len(inter) >= 6:
        cal.bust_given_intercept = round(min(0.9, sum(r["busted"] for r in inter) / len(inter)), 3)
    return cal
