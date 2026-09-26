"""Role-filtered snapshots: what each seat is allowed to know.

The runner crew gets its own aircraft, load, jobs, boat and whatever intel it
has gathered on the police (scanner, spotters, eyeballs). The task force gets
radar tracks, tips and its own units - never the runner's true position.
Everything is plain JSON so any client (Panda3D, web, bot) can consume it.
"""
from __future__ import annotations

import math

from ..police import SIGHT_RANGE_M
from ..roles import Role, Side
from ..world import AIRFIELD_BY_CODE

PROTOCOL_VERSION = 2


def _r(v: float, nd: int = 1) -> float:
    return round(float(v), nd) if v is not None and math.isfinite(v) else 0.0


def build_snapshot(sess, role: Role, seq: int = 0) -> dict:
    role = Role(role)
    snap = {
        "t": "snap",
        "v": PROTOCOL_VERSION,
        "seq": seq,
        "time": _r(sess.time, 2),
        "mode": sess.mode.value,
        "role": role.value,
        "side": role.side.value,
    }
    if role.side == Side.RUNNER:
        snap.update(_runner(sess, role))
    else:
        snap.update(_law(sess))
        if role == Role.INTERCEPTOR:
            snap.update(_police_pilot(sess, role))
    if sess.nights is not None:
        snap["season"] = sess.nights.view(role.side.value)
    return snap


def _pose(x, y, z, heading, pitch=0.0, roll=0.0) -> dict:
    return {"x": _r(x), "y": _r(y), "z": _r(z), "heading": _r(heading), "pitch": _r(pitch), "roll": _r(roll)}


def _police_pilot(sess, role: Role) -> dict:
    """The police pilot's cockpit: own unit exact, other aircraft only if seen."""
    ps = sess.police
    me = next((u for u in ps.units if u.pilot == role.value), None)
    out: dict = {"me": None, "visual": [], "claim_pending": role.value in ps.pending_claim}
    if me is None:
        return out
    out["me"] = dict(_pose(me.x, me.y, me.z, me.heading, 0.0, me.bank), id=me.id, kind=me.kind,
                     speed_kts=_r(me.speed / 0.514444), fuel_s=_r(me.fuel_s), state=me.state,
                     agl=_r(me.z - sess.world.ground(me.x, me.y)))
    sig = sess.runner_signature()
    if sig is not None and ps._can_see(me, sig):
        st = sess.state
        out["visual"].append(dict(_pose(st.x, st.y, st.alt, st.heading, st.pitch, st.roll), id=ps.alias("runner"),
                                  kind="runner", type=sess.spec.key, dist=_r(me.dist_to(sig))))
    for a in sess.smugglers:
        if a.active:
            asig = a.signature(sess.world)
            if ps._can_see(me, asig):
                out["visual"].append(dict(_pose(a.x, a.y, a.z, a.heading), id=ps.alias(a.id), kind="ai",
                                          type="c310", dist=_r(me.dist_to(asig))))
    for u in ps.units:
        if u is not me and u.state != "crashed" and me.dist_to(u) < SIGHT_RANGE_M * 1.5:
            out["visual"].append(dict(_pose(u.x, u.y, u.z, u.heading, 0.0, u.bank), id=u.id, kind=u.kind,
                                      type=u.kind, dist=_r(me.dist_to(u))))
    c = ps.cases.get("runner")
    out["bust_meter"] = _r(c.bust_meter) if c else 0.0
    return out


def _runner(sess, role: Role) -> dict:
    out: dict = {"money": sess.money, "messages": [m for _, m in sess.messages[-8:]]}
    if sess.campaign is not None:
        ch = sess.campaign.chapter
        out["campaign"] = {"chapter": ch.num, "year": ch.year, "title": ch.title,
                           "objectives": sess.campaign.objective_lines()}
    s = sess.state
    if s is not None and sess.runner_active:
        hours, range_km = sess.range_estimate()
        out["aircraft"] = {
            "type": sess.spec.name, "x": _r(s.x), "y": _r(s.y), "alt": _r(s.alt), "heading": _r(s.heading),
            "ias": _r(s.ias_kts), "gs": _r(s.gs_kts), "vs": _r(s.vs_fpm, 0), "fuel": _r(s.fuel_lb),
            "pitch": _r(s.pitch), "roll": _r(s.roll), "key": sess.spec.key, "throttle": _r(sess.fm.controls.throttle, 2),
            "flaps": _r(sess.fm.controls.flaps, 2),
            "ferry_fuel": _r(sess.loadout.ferry_fuel_lb()), "endurance_h": _r(hours, 2), "range_km": _r(range_km),
            "phase": sess.phase, "location": sess.location, "parked": sess.parked, "on_ground": s.on_ground,
            "transponder": sess.transponder, "squawk": sess.squawk, "autopilot": sess.autopilot.engaged,
            "detector": sess.police.detector() if "detector" in sess.gear else None,
            "pumping": sess.pumping, "kick_queue": sess.kick_queue, "auto_kick": sess.auto_kick,
            "copilot": sess.copilot, "wanted": sess.police.wanted, "suspicion": _r(sess.police.suspicion),
            "outcome": sess.last_outcome if sess.phase in ("crashed", "busted") else "",
            "unloading_s": _r(sess.unload_t) if sess.unloading else 0.0,
        }
    out["loadout"] = _loadout(sess)
    out["jobs"] = [_job(sess, j) for j in sess.active_jobs]
    out["board"] = [_job(sess, j) for j in sess.boards.get(sess.location, [])] if sess.parked else []
    out["boats"] = [{"id": b.id, "x": _r(b.x), "y": _r(b.y), "heading": _r(b.heading), "state": b.state,
                     "cargo": len(b.cargo)} for b in sess.maritime.boats if b.kind == "gofast"]
    out["bales"] = [{"x": _r(b.x), "y": _r(b.y), "state": b.state} for b in sess.maritime.bales
                    if b.state in ("falling", "floating")]
    intel = [{"unit": k, "x": _r(v[1]), "y": _r(v[2]), "age": _r(max(0.0, sess.time - v[0])), "source": v[3]}
             for k, v in sess.intel.items() if v[0] <= sess.time]
    if s is not None:
        for u in sess.police.units:  # what you can see out of the window
            if u.state != "crashed" and math.dist((u.x, u.y, u.z), (s.x, s.y, s.alt)) < SIGHT_RANGE_M:
                intel.append({"unit": u.id, "x": _r(u.x), "y": _r(u.y), "z": _r(u.z), "heading": _r(u.heading),
                              "bank": _r(u.bank), "kind": u.kind, "age": 0.0, "source": "visual"})
        for c in sess.maritime.boats:
            if c.kind == "cutter" and math.hypot(c.x - s.x, c.y - s.y) < 9000:
                intel.append({"unit": c.id, "x": _r(c.x), "y": _r(c.y), "age": 0.0, "source": "visual"})
    out["intel"] = intel
    out["scanner"] = [text for _, text in sess.scanner_log[-8:]] if "scanner" in sess.gear else None
    out["spotters"] = [{"code": sp.code, "moving_to": sp.moving_to} for sp in sess.spotters]
    if role == Role.SPOTTER:
        seen = []
        for sp in sess.spotters:
            af = AIRFIELD_BY_CODE[sp.code]
            for u in sess.police.units:
                if u.faction == "police" and u.state != "crashed" and math.hypot(u.x - af.x, u.y - af.y) < 5000:
                    seen.append({"unit": u.id, "x": _r(u.x), "y": _r(u.y), "age": 0.0, "source": f"eyes@{sp.code}"})
        out["intel"] += seen
    return out


def _loadout(sess) -> dict:
    lo = sess.loadout
    wb = lo.compute()
    weights = lo.station_weights(planned=True)
    return {
        "aircraft": sess.spec.name,
        "stations": [{"i": i, "name": st.name, "arm": st.x_in, "max": st.max_lb, "kind": st.kind,
                      "weight": _r(weights[i])} for i, st in enumerate(lo.spec.stations)],
        "items": [{"id": it.id, "label": it.label, "kind": it.kind, "weight": _r(it.weight_lb), "hot": it.hot,
                   "droppable": it.droppable, "job": it.job_id,
                   "station": lo.spec.stations[lo.assignment[it.id]].name if it.id in lo.assignment else None,
                   "pending": _r(lo.pending.get(it.id, 0.0))}
                  for it in sorted(lo.items.values(), key=lambda i: (i.job_id, i.id))],
        "wb": {"weight": _r(wb.weight_lb), "cg": _r(wb.cg_in, 2), "fwd": _r(wb.fwd_limit_in, 2),
               "aft": _r(wb.aft_limit_in, 2), "ok": wb.ok, "mtow": lo.spec.mtow_lb,
               "overweight": _r(wb.overweight_lb)},
        "envelope": [list(p) for p in lo.spec.envelope],
        "fuel": _r(lo.fuel_lb), "fuel_cap": _r(lo.mass.fuel_capacity_lb),
        "crew": sess.crew_count(),
    }


def _job(sess, j) -> dict:
    x, y = sess.job_xy(j)
    tl = j.time_left(sess.time)
    return {"id": j.id, "title": j.title, "dest": j.dest_label(), "x": _r(x), "y": _r(y), "payout": j.payout,
            "hot": j.hot, "airdrop": j.is_airdrop, "bales": j.bales_total, "weight": _r(j.weight_lb),
            "pax": sum(1 for i in j.items if i.kind == "passenger"), "notes": j.notes,
            "time_left": _r(tl) if tl is not None else None}


def _law(sess) -> dict:
    ps = sess.police
    now = sess.time
    law_units = [{"id": u.id, "kind": u.kind, "x": _r(u.x), "y": _r(u.y), "z": _r(u.z), "heading": _r(u.heading),
                  "state": u.state, "target": ps.alias(u.target_id), "sees": u.sees_player}
                 for u in ps.units if u.faction == "police"]
    cutters = [b for b in sess.maritime.boats if b.kind == "cutter"]
    law_units += [{"id": c.id, "kind": "cutter", "x": _r(c.x), "y": _r(c.y), "z": 0.0, "heading": _r(c.heading),
                   "state": c.state, "target": c.target_id, "sees": c.target_id is not None} for c in cutters]
    boats = []
    for b in sess.maritime.boats:
        if b.kind != "gofast" or b.state in ("delivered",):
            continue
        seen = any(math.hypot(b.x - c.x, b.y - c.y) < 7000 for c in cutters) or any(
            math.hypot(b.x - u.x, b.y - u.y) < SIGHT_RANGE_M for u in ps.units if u.faction == "police")
        if seen:
            boats.append({"id": b.id, "x": _r(b.x), "y": _r(b.y), "heading": _r(b.heading), "state": b.state})
    aer = ps.sensors.site("AER")
    return {
        "tracks": [{"id": ps.alias(t.target_id), "x": _r(t.x), "y": _r(t.y), "vx": _r(t.vx), "vy": _r(t.vy),
                    "age": _r(t.age(now)), "source": t.source, "squawk": t.squawk}
                   for t in ps.sensors.tracks.values()],
        "cases": [{"id": ps.alias(c.target_id), "suspicion": _r(c.suspicion), "wanted": c.wanted, "tipped": c.tipped}
                  for c in ps.cases.values() if c.suspicion > 0 or c.wanted or c.tipped],
        "units": law_units,
        "boats": boats,
        "tips": [{"x": _r(t.x), "y": _r(t.y), "r": _r(t.radius), "text": t.text, "age": _r(now - t.t)}
                 for t in ps.tips[-8:]],
        "stock": dict(ps.stock),
        "features": sorted(ps.features),
        "encrypted": sess.radio.encrypted,
        "aerostat": "up" if aer and aer.active else ("raising" if ps.aerostat_ready_t else "down"),
        "radars": [{"code": s.code, "x": _r(s.x), "y": _r(s.y), "range": _r(s.range_m), "active": s.active}
                   for s in ps.sensors.sites],
        "score": dict(ps.score),
        "runner_score": dict(sess.runner_score),
        "messages": [m for _, m in sess.law_log[-12:]],
    }
