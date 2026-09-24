"""HQ bots: strategy archetypes for the Organisation and the Task Force.

Each policy is a function `policy(season, rng, memory)` that issues orders
through the same `runner_cmd` / `law_cmd` gate a human uses, then says ready.
They exist to fill empty HQ seats and, more importantly, to be pitted against
each other thousands of times by `skyrunner.sim.strategic` to find dominant
strategies, dead mechanics and runaway leads.

Archetypes are deliberately one-dimensional; 'adaptive' mixes them and
'random' explores everything (which tells us what each action is worth).
"""
from __future__ import annotations

import random

from ..hq import BRIBES, FRONTS, LAW_COSTS_K, ZONES, Season


# ------------------------------------------------------------------ helpers
def _launder_all(ss: Season) -> None:
    ss.runner_cmd("launder")


def _pick_route(ss: Season, rng: random.Random, mem: dict, avoid: str | None = None) -> None:
    zones = [z for z in ZONES if z != avoid] or list(ZONES)
    # don't be predictable: avoid last night's route half the time
    last = mem.get("last_route")
    if last in zones and len(zones) > 1 and rng.random() < 0.5:
        zones.remove(last)
    z = rng.choice(zones)
    ss.runner_cmd("route", zone=z)
    mem["last_route"] = z


def _grow(ss: Season, rng: random.Random) -> None:
    """Spend spare dirty money on capacity: fronts first, then aircraft."""
    o = ss.org
    reserve = 12_000
    if o.dirty - reserve > FRONTS["car_lot"][0] and o.capacity < 25_000:
        ss.runner_cmd("buy_front", kind="car_lot" if o.dirty < 60_000 else "marina")
    elif o.dirty - reserve > 25_000 and o.tier == 0:
        ss.runner_cmd("upgrade")
    elif o.dirty - reserve > FRONTS["laundromat"][0] and o.capacity < 10_000:
        ss.runner_cmd("buy_front", kind="laundromat")


# ------------------------------------------------------------------ organisation
def runner_greedy(ss: Season, rng: random.Random, mem: dict) -> None:
    """Fly everything, every night, over the richest route. Spend on growth."""
    ss.runner_cmd("route", zone="sea")
    ss.runner_cmd("crews", n=2)
    _grow(ss, rng)
    _launder_all(ss)
    ss.runner_cmd("ready")


def runner_cautious(ss: Season, rng: random.Random, mem: dict) -> None:
    """Lawyer on retainer, loyal crews, burner phones, lie low when hot."""
    o = ss.org
    if not o.lawyer:
        ss.runner_cmd("lawyer", on=True)
    if o.loyalty < 0.6:
        ss.runner_cmd("loyalty")
    view = ss.view("runner")
    if view["evidence_rumor"] in ("serious", "closing in") or o.heat > 70:
        ss.runner_cmd("opsec")
        if o.heat > 70:
            ss.runner_cmd("lie_low")
    else:
        ss.runner_cmd("crews", n=1)
    _pick_route(ss, rng, mem)
    _launder_all(ss)
    ss.runner_cmd("ready")


def runner_corrupt(ss: Season, rng: random.Random, mem: dict) -> None:
    """Buy the dispatcher and the harbour; fly around the patrol you know about."""
    o = ss.org
    for b in ("dispatcher", "harbor"):
        if b not in o.bribes and o.dirty > BRIBES[b][0] + 6_000:
            ss.runner_cmd("bribe", who=b)
    leak = ss.law.patrol if "dispatcher" in o.bribes else None
    ss.runner_cmd("crews", n=1)
    _grow(ss, rng)
    _pick_route(ss, rng, mem, avoid=leak)
    _launder_all(ss)
    ss.runner_cmd("ready")


def runner_shadow(ss: Season, rng: random.Random, mem: dict) -> None:
    """Decoys and misdirection; counter-intel sweeps; never the same route."""
    o = ss.org
    if "detector" not in o.gear and o.dirty > 8_000:
        ss.runner_cmd("gear", name="detector")
    ss.runner_cmd("decoys", n=2)
    if ss.night % 3 == 0:
        ss.runner_cmd("counterintel")
    else:
        ss.runner_cmd("crews", n=1)
    if o.loyalty < 0.5:
        ss.runner_cmd("loyalty")
    _pick_route(ss, rng, mem)
    _launder_all(ss)
    ss.runner_cmd("ready")


def runner_launderer(ss: Season, rng: random.Random, mem: dict) -> None:
    """Build the laundering pipeline early, keep the operation small and steady."""
    o = ss.org
    if o.dirty > FRONTS["car_lot"][0] + 4_000:
        ss.runner_cmd("buy_front", kind="car_lot" if o.capacity < 20_000 else "marina")
    if ss.law.evidence > 45 and not o.lawyer:
        ss.runner_cmd("lawyer", on=True)
    ss.runner_cmd("crews", n=1)
    _pick_route(ss, rng, mem)
    _launder_all(ss)
    ss.runner_cmd("ready")


def runner_adaptive(ss: Season, rng: random.Random, mem: dict) -> None:
    """A reasonable human: grow while it's quiet, defend when the case builds."""
    o = ss.org
    if "scanner" not in o.gear and o.dirty > 8_000:
        ss.runner_cmd("gear", name="scanner")
    view = ss.view("runner")
    danger = {"thin": 0, "building": 1, "serious": 2, "closing in": 3}[view["evidence_rumor"]]
    if danger >= 2:
        if not o.lawyer:
            ss.runner_cmd("lawyer", on=True)
        ss.runner_cmd("opsec")
        if mem.get("informant_suspected") or danger == 3:
            ss.runner_cmd("counterintel")
        elif o.loyalty < 0.6:
            ss.runner_cmd("loyalty")
    else:
        if o.lawyer and danger == 0:
            ss.runner_cmd("lawyer", on=False)
        _grow(ss, rng)
        if o.dirty > 10_000:
            ss.runner_cmd("crews", n=1 if o.heat > 50 else 2)
    if o.heat > 55 and danger < 2 and rng.random() < 0.5:
        ss.runner_cmd("decoys", n=1)
    # a bust last night smells like a rat
    last = ss.reports[-1] if ss.reports else None
    mem["informant_suspected"] = bool(last and any(r.busted and r.kind == "main" for r in last.runs))
    leak = ss.law.patrol if "dispatcher" in o.bribes else None
    if "dispatcher" not in o.bribes and ss.night >= 3 and o.dirty > 20_000 and danger < 2:
        ss.runner_cmd("bribe", who="dispatcher")
    _pick_route(ss, rng, mem, avoid=leak)
    _launder_all(ss)
    ss.runner_cmd("ready")


def runner_smart(ss: Season, rng: random.Random, mem: dict) -> None:
    """Uses every source it has: scanner first, then the dispatcher, routes weighted
    by radar exposure, decoys when the heat draws attention, defence when the case
    builds, growth while it's quiet."""
    o = ss.org
    view = ss.view("runner")
    danger = {"thin": 0, "building": 1, "serious": 2, "closing in": 3}[view["evidence_rumor"]]
    if "scanner" not in o.gear and o.dirty > 6_000:
        ss.runner_cmd("gear", name="scanner")
    elif "dispatcher" not in o.bribes and o.dirty > 12_000:
        ss.runner_cmd("bribe", who="dispatcher")
    if danger >= 2:
        if not o.lawyer:
            ss.runner_cmd("lawyer", on=True)
        ss.runner_cmd("opsec")
        if danger == 3 or mem.get("rat"):
            ss.runner_cmd("counterintel")
    else:
        if o.lawyer and danger == 0:
            ss.runner_cmd("lawyer", on=False)
        if o.loyalty < 0.45:
            ss.runner_cmd("loyalty")
        _grow(ss, rng)
        ss.runner_cmd("crews", n=1 if o.heat > 45 or o.dirty < 15_000 else 2)
    if o.heat > 40:
        ss.runner_cmd("decoys", n=1)
    last = ss.reports[-1] if ss.reports else None
    mem["rat"] = bool(last and any(r.busted and r.kind == "main" and not r.intercepted for r in last.runs))
    z = rng.choices(ZONES, weights=[0.45, 0.25, 0.30])[0]  # west is the least watched
    if z == mem.get("last_route") and rng.random() < 0.5:
        z = rng.choice([x for x in ZONES if x != z])
    mem["last_route"] = z
    ss.runner_cmd("route", zone=z)
    _launder_all(ss)
    ss.runner_cmd("ready")


def runner_random(ss: Season, rng: random.Random, mem: dict) -> None:
    """Uniformly random legal orders: explores the action space for the sim."""
    options = [
        ("crews", {"n": rng.randint(0, 2)}), ("decoys", {"n": rng.randint(1, 2)}),
        ("bribe", {"who": rng.choice(list(BRIBES))}), ("loyalty", {}), ("lawyer", {"on": rng.random() < 0.5}),
        ("opsec", {}), ("counterintel", {}), ("lie_low", {}), ("upgrade", {}),
        ("buy_front", {"kind": rng.choice(list(FRONTS))}), ("gear", {"name": rng.choice(["scanner", "detector"])}),
    ]
    rng.shuffle(options)
    mem.setdefault("used", [])
    for name, args in options[:4]:
        if ss.runner_cmd(name, **args) is None:
            mem["used"].append(name)
    _pick_route(ss, rng, mem)
    _launder_all(ss)
    ss.runner_cmd("ready")


# ------------------------------------------------------------------ task force
def _predict_zone(ss: Season, rng: random.Random, mem: dict) -> str:
    """Where did we see them last? Tips win; else frequency of detections, noisily."""
    seen = mem.setdefault("seen", {z: 1.0 for z in ZONES})
    if ss.reports:
        for r in ss.reports[-1].runs:
            if r.detected and r.kind == "main":
                seen[r.zone] += 1.0
    weights = [seen[z] for z in ZONES]
    return rng.choices(ZONES, weights=weights)[0]


def _fund_units(ss: Season, heli: int, interceptor: int, cutter: int) -> None:
    for unit, n in (("interceptor", interceptor), ("heli", heli), ("cutter", cutter)):
        while n > 0 and ss.law_cmd("fund", unit=unit, n=n) is not None:
            n -= 1


def law_interdiction(ss: Season, rng: random.Random, mem: dict) -> None:
    """All money into aircraft, boats and radar."""
    ss.law_cmd("patrol", zone=_predict_zone(ss, rng, mem))
    ss.law_cmd("aerostat")
    _fund_units(ss, 1, 2, 1)
    _fund_units(ss, 2, 2, 1)
    ss.law_cmd("ready")


def law_investigator(ss: Season, rng: random.Random, mem: dict) -> None:
    """Follow the money and the people: informants, wiretaps, audits."""
    L = ss.law
    ss.law_cmd("patrol", zone=_predict_zone(ss, rng, mem))
    if L.informants < 2:
        ss.law_cmd("recruit")
    ss.law_cmd("wiretap")
    if ss.night % 2 == 0 or ss.org.heat > 40:
        ss.law_cmd("audit")
    if ss.night % 3 == 0:
        ss.law_cmd("ia_sweep")
    _fund_units(ss, 1, 0, 0)
    ss.law_cmd("ready")


def law_balanced(ss: Season, rng: random.Random, mem: dict) -> None:
    L = ss.law
    ss.law_cmd("patrol", zone=_predict_zone(ss, rng, mem))
    if L.informants < 1:
        ss.law_cmd("recruit")
    elif L.evidence >= 20:
        ss.law_cmd("wiretap")
    else:
        ss.law_cmd("audit")
    _fund_units(ss, 1, 1, 1)
    if L.budget_k > LAW_COSTS_K["aerostat"] + 4:
        ss.law_cmd("aerostat")
    ss.law_cmd("ready")


def law_adaptive(ss: Season, rng: random.Random, mem: dict) -> None:
    """React to the news: evaded patrols mean a leak; spending means laundering."""
    L, o = ss.law, ss.org
    last = ss.reports[-1] if ss.reports else None
    if last and any(r.busted or r.boat_seized for r in last.runs):
        ss.law_cmd("press")
    evaded = mem.get("evaded", 0)
    if last and ss.plan_hist and ss.plan_hist[-1].get("patrol") and not any(r.intercepted for r in last.runs):
        evaded += 1
    mem["evaded"] = evaded
    if evaded >= 2 and ss.night % 2 == 0:
        ss.law_cmd("ia_sweep")
        mem["evaded"] = 0
    elif evaded >= 1 and not L.encryption and L.budget_k > 14:
        ss.law_cmd("encryption")
    if L.informants < 2 and o.heat > 25:
        ss.law_cmd("recruit")
    if L.evidence >= 20:
        ss.law_cmd("wiretap")
    if len(o.fronts) > 1 and ss.night % 2 == 1:
        ss.law_cmd("audit")
    ss.law_cmd("patrol", zone=_predict_zone(ss, rng, mem))
    heavy = o.heat > 40
    _fund_units(ss, 1, 2 if heavy else 1, 1)
    if L.budget_k >= LAW_COSTS_K["aerostat"]:
        ss.law_cmd("aerostat")
    ss.law_cmd("ready")


def law_random(ss: Season, rng: random.Random, mem: dict) -> None:
    options = ["aerostat", "recruit", "wiretap", "audit", "ia_sweep", "encryption", "press"]
    rng.shuffle(options)
    mem.setdefault("used", [])
    for name in options[:3]:
        if ss.law_cmd(name) is None:
            mem["used"].append(name)
    ss.law_cmd("patrol", zone=rng.choice(ZONES))
    _fund_units(ss, rng.randint(0, 2), rng.randint(0, 2), rng.randint(0, 1))
    ss.law_cmd("ready")


RUNNER_POLICIES = {
    "greedy": runner_greedy, "cautious": runner_cautious, "corrupt": runner_corrupt,
    "shadow": runner_shadow, "launderer": runner_launderer, "adaptive": runner_adaptive,
    "smart": runner_smart, "random": runner_random,
}
LAW_POLICIES = {
    "interdiction": law_interdiction, "investigator": law_investigator, "balanced": law_balanced,
    "adaptive": law_adaptive, "random": law_random,
}
