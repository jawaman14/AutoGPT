class_name AutoRunner
extends RefCounted
## AutoRunner: the pilot bot playing the career on its own.
##
## Picks a job at the current field (hot ones first when the layer allows),
## plans fuel, flies it, recovers from crashes and busts, repeats. Used by
## `--watch` (watch the AI, low graphics recommended) and as a soak test:
## hours of play without a human.

var sess: Session
var prefer_hot := true
var bot: PilotBot = null
var flights := 0
var log: Array = []
var _wait := 0.0


func _init(s: Session, prefer_hot_ := true) -> void:
	sess = s
	prefer_hot = prefer_hot_


func _pick():
	var s := sess
	var board: Array = s.boards.get(s.location, [])
	var spec: Aircraft.Spec = s.spec
	var seats := spec.seat_count() - (1 if s.copilot else 0)
	var jobs := Py.filter(board, func(j):
		var pax := Py.count(j.items, func(i): return i.kind == "passenger")
		return pax <= seats and j.weight_lb() < spec.mtow_lb * 0.25)
	if jobs.is_empty():
		return null
	# Python's key is the tuple (hot, payout); payouts are far below 1e12
	return Py.max_by(jobs, func(j): return (1e12 if (prefer_hot and j.hot()) else 0.0) + j.payout)


func step(dt: float) -> FlightModel.Controls:
	var s := sess
	if s.phase in ["crashed", "busted"]:
		_wait += dt
		if _wait > 4.0:
			_wait = 0.0
			log.append(s.last_outcome)
			s.command(Roles.PILOT, "confirm", {})
			bot = null
		return null
	if bot != null and bot.phase != "done":
		return bot.step(dt)
	if not s.parked or not s.unloading.is_empty():
		return null
	_wait += dt
	if _wait < 3.0:  # a moment on the ground between flights
		return null
	_wait = 0.0
	if s.active_jobs.is_empty():
		var job = _pick()
		if job == null:
			s.refresh_board(s.location)
			return null
		if s.accept_job(job) != null:
			return null
	var job: Jobs.Job = s.active_jobs[0]
	if not s.loadout.compute().ok():
		s.hire_loadmaster()
	var legs := PilotBot.mission_for(s, job, s.location)
	s.set_fuel(PilotBot.plan_fuel_lb(s, legs))
	bot = PilotBot.new(s, legs)
	flights += 1
	return bot.step(dt)
