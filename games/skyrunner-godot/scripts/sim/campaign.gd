class_name Campaign
extends RefCounted
## Campaign: Palmetto Cay, 1979-1986.
##
## Each chapter switches on one or two new systems for both sides and sets a few
## objectives. The complexity ramp is the point: by 1982 you're juggling ferry
## fuel, a co-pilot, a boat and informants, but you met each of them alone first.
## See docs/DESIGN.md section 6 for the full storyline, including chapters 5-8.


class Objective:
	var key: String
	var text: String
	var target := 1.0

	func _init(k: String, t: String, target_ := 1.0) -> void:
		key = k
		text = t
		target = target_


class Chapter:
	var num: int
	var year: int
	var title: String
	var briefing: String
	var runner: Array
	var law: Array
	var objectives: Array
	var stock := {"heli": 1, "interceptor": 0, "cutter": 0}
	var setup = null  ## Callable(sess) or null
	var playable := true

	func _init(num_: int, year_: int, title_: String, briefing_: String, runner_: Array, law_: Array,
			objectives_: Array, opts := {}) -> void:
		num = num_
		year = year_
		title = title_
		briefing = briefing_
		runner = runner_
		law = law_
		objectives = objectives_
		for k in opts:
			set(k, opts[k])


static func _manny_job(sess) -> void:
	var here := World.airfield(sess.location if sess.location else "HAR")
	var jid := Jobs.new_id()
	var items := [Loadout.Item.new(Jobs.new_id(), "'Coffee' sacks", "cargo", 90.0, jid, {"hot": true}),
		Loadout.Item.new(Jobs.new_id(), "'Coffee' sacks", "cargo", 90.0, jid, {"hot": true})]
	var dest := "QRY" if here.code != "QRY" else "COV"
	var job := Jobs.Job.new(jid, "Manny's coffee -> " + World.airfield(dest).name, "contraband", here.code, dest, items, 4500,
		{"notes": "Stay under the radar floor. Transponder off means primary-only - and suspicious if they see you."})
	if not sess.boards.has(here.code):
		sess.boards[here.code] = []
	sess.boards[here.code].insert(0, job)


static func _kickers_setup(sess) -> void:
	sess.set_copilot("ai")
	var here := World.airfield(sess.location if sess.location else "HAR")
	var drop := Maritime.random_drop_point(sess.world, sess.rng, sess.maritime.cove)
	if not sess.boards.has(here.code):
		sess.boards[here.code] = []
	sess.boards[here.code].insert(0, Jobs.airdrop_job(here, drop, sess.rng, 4))
	sess.say("Rosa is in the right seat: she loads, kicks and pumps. [K] kick, [O] call the boat.")


## Start offshore to the south with a full ferry tank and bales already aboard.
static func _long_legs_setup(sess) -> void:
	sess.active_jobs.clear()
	sess.set_copilot("ai")
	var lo: Loadout = sess.loadout
	for iid in lo.items.keys():
		lo.remove_item(iid)
	var tank := Loadout.ferry_tank(Jobs.new_id(), lo.ferry_capacity())
	tank.set_fuel(tank.fuel_cap_lb)
	lo.add(tank)
	var drop := Maritime.random_drop_point(sess.world, sess.rng, sess.maritime.cove)
	var job := Jobs.airdrop_job(World.airfield("COV"), drop, sess.rng, 4)
	job.origin = "SOUTH"
	job.accepted_at = sess.time
	sess.active_jobs.append(job)
	for it in job.items:
		lo.add(it)
	lo.auto_balance()
	lo.pending.clear()
	lo.fuel_lb = lo.mass.fuel_capacity_lb() * 0.35
	var boat: Maritime.Boat = sess.maritime.new_gofast(drop, job.id)
	job.boat_id = boat.id
	sess.spawn_airborne(drop[0] * 0.3, -World.HALF + 600, 0.0, 250, 100)
	sess.say("Long Legs: 35% in the wings, the rest in the bladder. Pump it [V] before the engine quits.")


static var CHAPTERS: Array = _chapters()


static func _chapters() -> Array:
	return [
		Chapter.new(1, 1979, "Mail Run",
			"Palmetto Cay, 1979. The bank owns half your Cessna and Rosa's mail contract barely\n"
			+ "covers the fuel. Fly charters and freight, learn to balance a load, and prove you\n"
			+ "can get into Eagle's Nest - the mesa strip nobody else will touch.",
			[], [], [Objective.new("earn_legal", "Earn $5,000 from legal work", 5000), Objective.new("land_EGL", "Land at Eagle's Nest")]),
		Chapter.new(2, 1980, "A Favor for Manny",
			"Manny Arce sells boats at Smuggler's Cove and pays cash. He needs two sacks of\n"
			+ "'coffee' moved to the Old Quarry, quietly. Harbor and Valley radars can't see you\n"
			+ "below their clutter floor - the radar detector tells you when they're painting you.",
			["contraband", "detector"], [], [Objective.new("hot_clean", "Deliver a hot load without ever being wanted")],
			{"setup": Campaign._manny_job}),
		Chapter.new(3, 1981, "Kickers",
			"Landing with the goods is for amateurs. Manny's boat, the Lady Luck, will wait off\n"
			+ "the coast. Rosa rides along to push bales out of the door. Calling the boat on the\n"
			+ "radio helps it find you - and helps anyone listening find you too.",
			["contraband", "detector", "airdrop", "copilot", "scanner"], ["interceptors", "rivals"],
			[Objective.new("kicked", "Kick 4 bales", 4), Objective.new("to_cove", "Get 3 bales to the cove", 3)],
			{"stock": {"heli": 1, "interceptor": 1, "cutter": 0}, "setup": Campaign._kickers_setup}),
		Chapter.new(4, 1982, "Long Legs",
			"The loads come from the south now, farther than the tanks can carry. A bladder in\n"
			+ "the cabin fixes that - if someone pumps it forward. The Coast Guard has a cutter at\n"
			+ "Harbor, and people talk: every hot job you take is a chance for an informant.",
			["contraband", "detector", "airdrop", "copilot", "scanner", "ferry", "spotters"],
			["interceptors", "rivals", "cutters", "informants"],
			[Objective.new("to_cove", "Fly in from the south and get 3 bales to the cove", 3)],
			{"stock": {"heli": 1, "interceptor": 2, "cutter": 1}, "setup": Campaign._long_legs_setup}),
		Chapter.new(5, 1983, "The Balloon", "The task force puts an aerostat radar over the coast.", [], [], [], {"playable": false}),
		Chapter.new(6, 1984, "Blue Water", "Cutters, encrypted police radio and direction finding.", [], [], [], {"playable": false}),
		Chapter.new(7, 1985, "The Leak", "Someone in the crew is talking.", [], [], [], {"playable": false}),
		Chapter.new(8, 1986, "Last Run / Flip", "The biggest run of your life, or Agent Hart's deal.", [], [], [], {"playable": false}),
	]


var index := 0
var progress := {}
var sess = null
var hot_flight_clean := true
var completed_all := false
var show_briefing := true


func _init(index_ := 0, progress_ = null) -> void:
	index = index_
	progress = progress_.duplicate() if progress_ is Dictionary else {}


var chapter: Chapter:
	get:
		return CHAPTERS[index]


func to_dict() -> Dictionary:
	return {"index": index, "progress": progress}


static func from_dict(d) -> Campaign:
	if not (d is Dictionary):
		d = {}
	return Campaign.new(int(d.get("index", 0)), d.get("progress"))


# ------------------------------------------------------------ wiring
func attach(s) -> void:
	sess = s
	s.campaign = self
	s.bus.subscribe("*", _on_event)
	apply(s, progress.is_empty())


func apply(s, run_setup := true) -> void:
	var ch := chapter
	s.features = Session.set_of(ch.runner + ch.law)
	s.police.features = Session.set_of(ch.law)
	s.police.stock = ch.stock.duplicate()
	s.radio.df_enabled = ch.law.has("df")
	for g in ["scanner", "detector"]:
		if ch.runner.has(g):
			s.gear[g] = true  # issued with the chapter
	if not ch.runner.has("copilot") and s.copilot == "ai":
		s.set_copilot(null)
	for code in s.boards.keys():
		s.refresh_board(code)
	if run_setup and ch.setup != null:
		ch.setup.call(s)
	show_briefing = true
	s.say("CHAPTER %d (%d): %s" % [ch.num, ch.year, ch.title])


func objective_lines() -> Array:
	var out := []
	for o in chapter.objectives:
		var v: float = progress.get(o.key, 0.0)
		var mark := "x" if v >= o.target else " "
		var count := " (%d/%d)" % [int(v), int(o.target)] if o.target > 1 and o.key != "earn_legal" else ""
		if o.key == "earn_legal":
			count = " ($%s/$%s)" % [Py.money(int(v)), Py.money(int(o.target))]
		out.append("[%s] %s%s" % [mark, o.text, count])
	return out


# ------------------------------------------------------------ progress
func _bump(key: String, amount := 1.0) -> void:
	if Py.any(chapter.objectives, func(o): return o.key == key):
		progress[key] = progress.get(key, 0.0) + amount


func _on_event(ev: EventBus.Event) -> void:
	var d := ev.data
	if ev.kind == "job_delivered":
		if not d.get("hot"):
			_bump("earn_legal", d.get("pay", 0))
		elif hot_flight_clean:
			_bump("hot_clean")
	elif ev.kind == "landed":
		_bump("land_%s" % d.get("code"))
		hot_flight_clean = true
	elif ev.kind == "bale_kicked":
		_bump("kicked")
	elif ev.kind == "bales_delivered":
		_bump("to_cove", d.get("count", 0))


func tick(s) -> void:
	if s.carrying_hot() and s.police.wanted > 0:
		hot_flight_clean = false
	var ch := chapter
	if ch.objectives.is_empty() or completed_all:
		return
	if Py.all(ch.objectives, func(o): return progress.get(o.key, 0.0) >= o.target):
		s.say("Chapter %d complete: %s!" % [ch.num, ch.title])
		var nxt := index + 1
		if nxt < CHAPTERS.size() and CHAPTERS[nxt].playable:
			index = nxt
			progress = {}
			apply(s)
		else:
			completed_all = true
			s.say("That's the story so far - chapters 5-8 arrive in the next phase. Free play unlocked.")
			for f in ["contraband", "airdrop", "copilot", "scanner", "detector", "ferry", "spotters"]:
				s.features[f] = true
		s.save()
