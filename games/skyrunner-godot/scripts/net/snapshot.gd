class_name Snapshot
extends RefCounted
## Role-filtered snapshots: what each seat is allowed to know.
##
## The runner crew gets its own aircraft, load, jobs, boat and whatever intel it
## has gathered on the police (scanner, spotters, eyeballs). The task force gets
## radar tracks, tips and its own units - never the runner's true position.
## Everything is plain JSON so any client (Godot, web, bot) can consume it.

const PROTOCOL_VERSION := 2


static func _r(v, nd := 1) -> float:
	if v == null:
		return 0.0
	var f := float(v)
	return Py.round_n(f, nd) if is_finite(f) else 0.0


static func build(sess: Session, role: String, seq := 0) -> Dictionary:
	var side := Roles.side(role)
	var snap := {"t": "snap", "v": PROTOCOL_VERSION, "seq": seq, "time": _r(sess.time, 2), "mode": sess.mode,
		"role": role, "side": side}
	if side == "runner":
		snap.merge(_runner(sess, role), true)
	else:
		snap.merge(_law(sess), true)
		if role == Roles.INTERCEPTOR:
			snap.merge(_police_pilot(sess, role), true)
	if sess.nights != null:
		snap["season"] = sess.nights.view(side)
	return snap


static func _xy(p: Array) -> Dictionary:
	return {"x": _r(p[0]), "y": _r(p[1])}


static func _pose(x, y, z, heading, pitch := 0.0, roll := 0.0) -> Dictionary:
	return {"x": _r(x), "y": _r(y), "z": _r(z), "heading": _r(heading), "pitch": _r(pitch), "roll": _r(roll)}


static func _with(d: Dictionary, extra: Dictionary) -> Dictionary:
	d.merge(extra, true)
	return d


## The police pilot's cockpit: own unit exact, other aircraft only if seen.
static func _police_pilot(sess: Session, role: String) -> Dictionary:
	var ps: PoliceSystem = sess.police
	var me = Py.first(ps.units, func(u): return u.pilot == role)
	var out := {"me": null, "visual": [], "claim_pending": ps.pending_claim.has(role)}
	if me == null:
		return out
	out["me"] = _with(_pose(me.x, me.y, me.z, me.heading, 0.0, me.bank), {"id": me.id, "kind": me.kind,
		"speed_kts": _r(me.speed / 0.514444), "fuel_s": _r(me.fuel_s), "state": me.state,
		"agl": _r(me.z - sess.world.ground(me.x, me.y))})
	var sig = sess.runner_signature()
	if sig != null and ps._can_see(me, sig):
		var st: FlightModel.FlightState = sess.state
		out["visual"].append(_with(_pose(st.x, st.y, st.alt, st.heading, st.pitch, st.roll), {"id": ps.alias("runner"),
			"kind": "runner", "type": sess.spec.key, "dist": _r(me.dist_to(sig))}))
	for a in sess.smugglers:
		if a.active():
			var asig: SensorNet.Signature = a.signature(sess.world)
			if ps._can_see(me, asig):
				out["visual"].append(_with(_pose(a.x, a.y, a.z, a.heading), {"id": ps.alias(a.id), "kind": "ai",
					"type": "c310", "dist": _r(me.dist_to(asig))}))
	for u in ps.units:
		if u != me and u.state != "crashed" and me.dist_to(u) < PoliceSystem.SIGHT_RANGE_M * 1.5:
			out["visual"].append(_with(_pose(u.x, u.y, u.z, u.heading, 0.0, u.bank), {"id": u.id, "kind": u.kind,
				"type": u.kind, "dist": _r(me.dist_to(u))}))
	var c = ps.cases.get("runner")
	out["bust_meter"] = _r(c.bust_meter) if c != null else 0.0
	return out


static func _runner(sess: Session, role: String) -> Dictionary:
	var out := {"money": sess.money, "messages": sess.messages.slice(-8).map(func(m): return m[1])}
	if sess.campaign != null:
		var ch: Campaign.Chapter = sess.campaign.chapter
		out["campaign"] = {"chapter": ch.num, "year": ch.year, "title": ch.title,
			"objectives": sess.campaign.objective_lines()}
	var s: FlightModel.FlightState = sess.state
	if s != null and sess.runner_active():
		var he: Array = sess.range_estimate()
		out["aircraft"] = {
			"type": sess.spec.name, "x": _r(s.x), "y": _r(s.y), "alt": _r(s.alt), "heading": _r(s.heading),
			"ias": _r(s.ias_kts), "gs": _r(s.gs_kts), "vs": _r(s.vs_fpm, 0), "fuel": _r(s.fuel_lb),
			"pitch": _r(s.pitch), "roll": _r(s.roll), "key": sess.spec.key, "throttle": _r(sess.fm.controls.throttle, 2),
			"flaps": _r(sess.fm.controls.flaps, 2),
			"ferry_fuel": _r(sess.loadout.ferry_fuel_lb()), "endurance_h": _r(he[0], 2), "range_km": _r(he[1]),
			"phase": sess.phase, "location": sess.location, "parked": sess.parked, "on_ground": s.on_ground,
			"transponder": sess.transponder, "squawk": sess.squawk, "code": sess.squawk_code, "autopilot": sess.autopilot.engaged,
			"detector": sess.police.detector() if sess.gear.has("detector") else null,
			"painters": sess.police.painters() if sess.gear.has("detector") and sess.has_upgrade("bearing_detector") else [],
			"pumping": sess.pumping, "kick_queue": sess.kick_queue, "auto_kick": sess.auto_kick,
			"copilot": sess.copilot, "wanted": sess.police.wanted, "suspicion": _r(sess.police.suspicion),
			"outcome": sess.last_outcome if sess.phase in ["crashed", "busted"] else "",
			"unloading_s": _r(sess.unload_t) if not sess.unloading.is_empty() else 0.0,
		}
	out["loadout"] = _loadout(sess)
	out["jobs"] = sess.active_jobs.map(func(j): return _job(sess, j))
	out["board"] = sess.boards.get(sess.location, []).map(func(j): return _job(sess, j)) if sess.parked else []
	var boats := []
	for b in sess.maritime.boats:
		if b.kind == "gofast":
			boats.append({"id": b.id, "x": _r(b.x), "y": _r(b.y), "heading": _r(b.heading), "state": b.state,
				"cargo": b.cargo.size()})
	out["boats"] = boats
	var bales := []
	for b in sess.maritime.bales:
		if b.state in ["falling", "floating"]:
			bales.append({"x": _r(b.x), "y": _r(b.y), "state": b.state})
	out["bales"] = bales
	var intel := []
	for k in sess.intel:
		var v: Array = sess.intel[k]
		if v[0] <= sess.time:
			intel.append({"unit": k, "x": _r(v[1]), "y": _r(v[2]), "age": _r(maxf(0.0, sess.time - v[0])), "source": v[3]})
	if s != null:
		for u in sess.police.units:  # what you can see out of the window
			if u.state != "crashed" and PyMath.hypot3(u.x - s.x, u.y - s.y, u.z - s.alt) < PoliceSystem.SIGHT_RANGE_M:
				intel.append({"unit": u.id, "x": _r(u.x), "y": _r(u.y), "z": _r(u.z), "heading": _r(u.heading),
					"bank": _r(u.bank), "kind": u.kind, "age": 0.0, "source": "visual"})
		for c in sess.maritime.boats:
			if c.kind == "cutter" and PyMath.hypot(c.x - s.x, c.y - s.y) < 9000:
				intel.append({"unit": c.id, "x": _r(c.x), "y": _r(c.y), "age": 0.0, "source": "visual"})
	out["intel"] = intel
	out["scanner"] = sess.scanner_log.slice(-8).map(func(m): return m[1]) if sess.gear.has("scanner") else null
	out["upgrades"] = sess.upgrades["runner"].keys()
	out["market"] = sess.econ.board()
	if sess.stash_net != null:
		out["stashes"] = sess.stash_net.stashes.map(func(st): return {"id": st.id, "name": st.name, "x": st.x, "y": st.y,
			"strip": st.strip, "heat": _r(st.heat), "burned": st.burned})
		out["trucks"] = sess.stash_net.trucks.map(func(t): return _with({"stash": t.stash, "title": t.title,
			"eta": _r(maxf(0.0, t.t0 + t.dur - sess.time))}, _xy(t.pos(sess.time))))
	out["spotters"] = sess.spotters.map(func(sp): return {"code": sp.code, "moving_to": sp.moving_to})
	if role == Roles.SPOTTER:
		for sp in sess.spotters:
			var af := World.airfield(sp.code)
			for u in sess.police.units:
				if u.faction() == "police" and u.state != "crashed" and PyMath.hypot(u.x - af.x, u.y - af.y) < 5000:
					intel.append({"unit": u.id, "x": _r(u.x), "y": _r(u.y), "age": 0.0, "source": "eyes@" + sp.code})
	return out


static func _track(ps: PoliceSystem, t: SensorNet.Track, now: float) -> Dictionary:
	var d := {"id": ps.alias(t.target_id), "x": _r(t.x), "y": _r(t.y), "vx": _r(t.vx), "vy": _r(t.vy),
		"age": _r(t.age(now)), "source": t.source, "squawk": t.squawk}
	if SensorNet.REALISM:
		d["code"] = t.code
		d["alt"] = _r(t.alt) if t.alt != null else null
		d["trail"] = t.trail.map(func(p): return [_r(p[0]), _r(p[1])])
	return d


static func _loadout(sess: Session) -> Dictionary:
	var lo: Loadout = sess.loadout
	var wb = lo.compute()
	var weights: Array = lo.station_weights(true)
	var stations := []
	for i in lo.spec.stations.size():
		var st: Aircraft.Station = lo.spec.stations[i]
		stations.append({"i": i, "name": st.name, "arm": st.x_in, "max": st.max_lb, "kind": st.kind,
			"weight": _r(weights[i])})
	var items := []
	# sorted by (job_id, id); ids are unique so a composite numeric key is exact
	for it in Py.sorted_by(lo.items.values(), func(i): return float(i.job_id) * 1e7 + i.id):
		items.append({"id": it.id, "label": it.label, "kind": it.kind, "weight": _r(it.weight_lb), "hot": it.hot,
			"droppable": it.droppable, "job": it.job_id,
			"station": lo.spec.stations[lo.assignment[it.id]].name if lo.assignment.has(it.id) else null,
			"pending": _r(lo.pending.get(it.id, 0.0))})
	return {
		"aircraft": sess.spec.name,
		"stations": stations,
		"items": items,
		"wb": {"weight": _r(wb.weight_lb), "cg": _r(wb.cg_in, 2), "fwd": _r(wb.fwd_limit_in, 2),
			"aft": _r(wb.aft_limit_in, 2), "ok": wb.ok(), "mtow": lo.spec.mtow_lb, "overweight": _r(wb.overweight_lb)},
		"envelope": lo.spec.envelope.map(func(p): return [p[0], p[1]]),
		"fuel": _r(lo.fuel_lb), "fuel_cap": _r(lo.mass.fuel_capacity_lb()),
		"crew": sess.crew_count(),
	}


static func _job(sess: Session, j: Jobs.Job) -> Dictionary:
	var xy: Array = sess.job_xy(j)
	var tl = j.time_left(sess.time)
	return {"id": j.id, "title": j.title, "dest": j.dest_label(), "x": _r(xy[0]), "y": _r(xy[1]), "payout": j.payout,
		"hot": j.hot(), "airdrop": j.is_airdrop(), "bales": j.bales_total, "weight": _r(j.weight_lb()),
		"pax": Py.count(j.items, func(i): return i.kind == "passenger"), "notes": j.notes,
		"time_left": _r(tl) if tl != null else null}


static func _law(sess: Session) -> Dictionary:
	var ps: PoliceSystem = sess.police
	var now := sess.time
	var law_units := []
	var police_units := ps.units.filter(func(u): return u.faction() == "police")
	for u in police_units:
		law_units.append({"id": u.id, "kind": u.kind, "x": _r(u.x), "y": _r(u.y), "z": _r(u.z), "heading": _r(u.heading),
			"state": u.state, "target": ps.alias(u.target_id), "sees": u.sees_player})
	var cutters: Array = sess.maritime.boats.filter(func(b): return b.kind == "cutter")
	for c in cutters:
		law_units.append({"id": c.id, "kind": "cutter", "x": _r(c.x), "y": _r(c.y), "z": 0.0, "heading": _r(c.heading),
			"state": c.state, "target": c.target_id, "sees": c.target_id != null})
	var boats := []
	for b in sess.maritime.boats:
		if b.kind != "gofast" or b.state == "delivered":
			continue
		var seen := Py.any(cutters, func(c): return PyMath.hypot(b.x - c.x, b.y - c.y) < 7000) or Py.any(
			police_units, func(u): return PyMath.hypot(b.x - u.x, b.y - u.y) < PoliceSystem.SIGHT_RANGE_M)
		if seen:
			boats.append({"id": b.id, "x": _r(b.x), "y": _r(b.y), "heading": _r(b.heading), "state": b.state})
	var aer = ps.sensors.site("AER")
	var aerostat := "down"
	if aer != null and aer.active:
		aerostat = "up"
	elif Py.truthy(ps.aerostat_ready_t):
		aerostat = "raising"
	var feats := ps.features.keys()
	feats.sort()
	return {
		"tracks": ps.sensors.tracks.values().map(func(t): return _track(ps, t, now)),
		"cases": ps.cases.values().filter(func(c): return c.suspicion > 0 or c.wanted or c.tipped).map(
			func(c): return {"id": ps.alias(c.target_id), "suspicion": _r(c.suspicion), "wanted": c.wanted, "tipped": c.tipped}),
		"units": law_units,
		"boats": boats,
		"tips": ps.tips.slice(-8).map(func(t): return {"x": _r(t.x), "y": _r(t.y), "r": _r(t.radius), "text": t.text,
			"age": _r(now - t.t)}),
		"stock": ps.stock.duplicate(),
		"features": feats,
		"encrypted": sess.radio.encrypted,
		"radio_channel": sess.radio.police_channel,
		"upgrades": sess.upgrades["law"].keys(),
		"stashes": [] if sess.stash_net == null else sess.stash_net.known().map(func(st): return {"id": st.id, "name": st.name,
			"x": st.x, "y": st.y, "heat": _r(st.heat), "burned": st.burned}),
		"law_funds": int(sess.law_funds),
		"market": sess.econ.board(),
		"jammed": sess.radio.jammed_zones.filter(func(z): return z.size() < 4 or z[3] > now).map(
			func(z): return [_r(z[0]), _r(z[1]), _r(z[2])]),
		"df": sess.radio.df_log.filter(func(d): return now - d.t < 120.0).map(func(d): return {
			"age": _r(now - d.t), "fix": d.fix, "ellipse": d.ellipse,
			"bearings": d.bearings.map(func(b): return [b.station, _r(b.x), _r(b.y), _r(b.deg, 1)])}),
		"aerostat": aerostat,
		"radars": ps.sensors.sites.map(func(s): return {"code": s.code, "x": _r(s.x), "y": _r(s.y), "range": _r(s.range_m),
			"active": s.active, "kind": s.kind, "beam": _r(s.beam(now), 1), "period": s.period_s}),
		"score": ps.score.duplicate(),
		"runner_score": sess.runner_score.duplicate(),
		"messages": sess.law_log.slice(-12).map(func(m): return m[1]),
	}
