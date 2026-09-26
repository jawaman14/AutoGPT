class_name Session
extends RefCounted
## Game session: the authoritative simulation for one match.
##
## It holds the runner crew's aircraft (JSBSim), the task force, boats, AI
## runs, jobs and economy. Every action goes through command(role, name, args)
## so local menus, network clients and AI crew obey the same rules. No
## rendering in here: the whole game loop runs headless (tests, bots,
## dedicated servers).

const FT := 0.3048
const FUEL_PRICE_PER_LB := 1.1
const LOADMASTER_FEE := 150
const START_MONEY := 3000
const START_FIELD := "HAR"
const OFF_FIELD_MAX_GS_KTS := 15.0
const KICK_MAX_KTS := 130.0
const KICK_TIME := {"copilot": 2.0, "pilot": 4.0}
const PUMP_RATE_LB_MIN := {"copilot": 60.0, "pilot": 25.0}
const TURNAROUND_S := {"solo": 20.0, "crew": 10.0}  ## push the aircraft round by hand
const UNLOAD_HOT_S := 60.0  ## the buyers count the goods on the strip
const RAID_RANGE_M := 2000.0
const SPOTTER_FEE := 400
const SPOTTER_RANGE_M := 5000.0
const SPOTTER_DELAY_S := 5.0
const SPOTTER_MOVE_S := 60.0
const INFORMANT_BASE := 0.30
const SPOTTER_LEAK := 0.15
const FERRY_FUEL_TIP := 0.25
const GEAR := {
	"scanner": [1800, "Radio scanner: hear police dispatch (unless encrypted)"],
	"detector": [2500, "Radar detector: warns when a radar paints you"],
	"ferry_tank": [3000, "Ferry bladder tank: extra fuel in the cabin"],
}
const RUNNER_FEATURES := ["contraband", "airdrop", "ferry", "scanner", "detector", "spotters", "copilot"]
const SANDBOX_FEATURES := ["contraband", "airdrop", "ferry", "scanner", "detector", "spotters", "copilot",
	"interceptors", "rivals", "informants", "cutters", "df"]


class FlightLog:
	var departed_from = null
	var airborne := false
	var max_bank := 0.0
	var max_touchdown_fpm := 0.0
	var last_touchdown_fpm := 0.0
	var touchdowns_seen := 0

	func _init(touchdowns_seen_ := 0) -> void:
		touchdowns_seen = touchdowns_seen_


class Spotter:
	var code: String
	var moving_to = null
	var move_t := 0.0
	var last_report_t := -1e9

	func _init(code_: String) -> void:
		code = code_


static func set_of(items) -> Dictionary:
	if items is Dictionary:
		return items.duplicate()
	var d := {}
	for i in items:
		d[i] = true
	return d


var world: World
var seed := 1
var money := START_MONEY
var owned := {"c172p": true}
var aircraft_key := "c172p"
var phase := "parked"  ## parked | flying | crashed | busted
var location = START_FIELD
var messages: Array = []  ## [[t, text]]
var active_jobs: Array = []
var boards := {}
var jsbsim_root := ""
var save_path := ""
var mode := Roles.SOLO
var features := {}
var humans := {}  ## role -> name
var gear := {}

var rng: PyRandom
var _mass := {}
var bus: EventBus
var radio: RadioNet
var police: PoliceSystem
var maritime: Maritime
var smugglers: Array = []
var director: AISmuggler.Director
var mapper: ControlMapper
var autopilot: Autopilot
var log: FlightLog
var time := 0.0
var fm: FlightModel
var loadout: Loadout
var state: FlightModel.FlightState
var last_outcome := ""
var law_log: Array = []
var scanner_log: Array = []
var scanner_channels := ["police"]  ## what the runner's scanner is programmed for (RadioNet.REALISM)
var upgrades := {"runner": {}, "law": {}}  ## bought tree nodes (Upgrades)
var law_funds := 8000.0  ## the task force's upgrade money: a budget plus forfeiture from busts and seizures
var econ: Economy  ## the markets: what each good is worth where (Economy)
var _news_seen := 0
var stash_net: StashNet = null  ## the organisation's stash houses (maps that have them)
var _stash_ai_t := 0.0
var arsenals := {}  ## "org" | "law" | "rival" -> Arsenal (Arsenal.REALISM)
var ground: GroundWar = null  ## squads, firefights and turf on the roads (GroundWar; live play asks for it)
var arng: PyRandom  ## gun runs and arsenal draws, off the board and parity streams
var ai_law_upgrades := false  ## the AI chief buys law upgrades as money comes in (live play; off in sims and tests)
var urng: PyRandom  ## upgrade draws (spoiled tips, leaks), off the parity streams
var _ai_buy_t := 0.0
var _lookout_seen := {}
var intel := {}  ## unit -> [t, x, y, source]
var spotters: Array = []
var transponder := true
var squawk := ""
var squawk_code := "1200"  ## Mode A: 1200 VFR; 7500 hijack, 7600 radio failure, 7700 emergency
var kick_queue := 0
var kick_t := 0.0
var kicker = null
var auto_kick := true
var pumping := false
var copilot = null  ## "human" | "ai" | null
var campaign = null  ## set by Campaign.attach
var runner_score := {"bales_delivered": 0, "escapes": 0}
var fuel_caches := {}  ## shady strips: fuel you flew in yourself
var turnaround_t := 0.0
var unloading: Array = []
var unload_t := 0.0
var pilot_input := {}  ## police pilots' sticks
var _scanner_seen := 0.0
var map_seed := 0  ## the island this session is on (0 = classic)
var nights = null  ## NightDirector when the Organisation layer is on
var weather := {}  ## {sky, wind_kt, wind_dir, moon}; empty = calm and clear (the tactical sims fly that)
var weather_rev := 0
var _tied := false  ## parked at idle in weather: tied down, the wind can't flip it
var hand_tremor := Vector2.ZERO  ## set each frame by the pilot's Nerves (the 3D client)  ## bumped on every change, so the renderer knows to follow


## opts: world, seed, money, owned, aircraft_key, location, jsbsim_root, save_path, mode, features, humans, gear
func _init(opts := {}) -> void:
	world = opts.get("world", null)
	if world == null:
		World.use_map(int(opts.get("map_seed", World.layout.map_seed)))  # 0 = the classic island
		world = World.new()
	map_seed = world.map.map_seed
	seed = opts.get("seed", 1)
	money = opts.get("money", START_MONEY)
	owned = set_of(opts.get("owned", ["c172p"]))
	aircraft_key = opts.get("aircraft_key", "c172p")
	location = opts.get("location", START_FIELD)
	save_path = opts.get("save_path", "")
	mode = opts.get("mode", Roles.SOLO)
	humans = opts.get("humans", {}).duplicate()
	gear = set_of(opts.get("gear", []))
	if opts.get("features") == null:
		features = set_of(PoliceSystem.LAW_FEATURES if mode == Roles.POLICE else SANDBOX_FEATURES)
	else:
		features = set_of(opts.features)
	rng = PyRandom.new()
	rng.seed(seed)
	jsbsim_root = opts.get("jsbsim_root", "")
	if jsbsim_root == "":
		jsbsim_root = MassData.patched_root()
	for k in Aircraft.ROSTER:
		_mass[k] = MassData.read(Aircraft.ROSTER[k].jsbsim_model)
	bus = EventBus.new()
	radio = RadioNet.new(_rng(seed + 7))
	radio.world = world
	urng = _rng(seed + 31)
	econ = Economy.new(_rng(seed + 51))
	arng = _rng(seed + 71)
	if Arsenal.REALISM:
		for side in ["org", "law", "rival"]:
			arsenals[side] = Arsenal.new(side)
		var saved: Dictionary = opts.get("arsenal", {})
		if not saved.is_empty():
			arsenals["org"] = Arsenal.from_dict(saved)
			arsenals["org"].side = "org"
	if not world.map.stashes.is_empty():
		stash_net = StashNet.new(world.map.stashes, _rng(seed + 41))
	ai_law_upgrades = opts.get("ai_law_upgrades", false)
	if GroundWar.ENABLED and opts.get("ground_war", false):
		ground = GroundWar.new(self, _rng(seed + 61), _rng(seed + 67))
	for side in ["runner", "law"]:
		for id in opts.get("upgrades", {}).get(side, []):
			upgrades[side][id] = true
	var law := {}
	for f in features:
		if PoliceSystem.LAW_FEATURES.has(f):
			law[f] = true
	police = PoliceSystem.new(world, _rng(seed + 99), radio, "human" if humans.has(Roles.CONTROLLER) else "ai", law)
	radio.df_stations = []
	for a in world.airfields:
		if a.police:
			radio.df_stations.append([a.code, a.x, a.y])
	radio.df_enabled = features.has("df")
	maritime = Maritime.new(world, _rng(seed + 13))
	director = AISmuggler.Director.new(_rng(seed + 21))
	mapper = ControlMapper.new()
	autopilot = Autopilot.new()
	log = FlightLog.new()
	squawk = "N%d%s" % [rng.randint(100, 999), rng.choice(Array("ABCDEFGHJK".split("")))]
	copilot = "human" if humans.has(Roles.COPILOT) else null
	for g in gear:
		if g in Upgrades.GEAR_NODES:
			upgrades["runner"][g] = true
	for g in ["scanner", "detector"]:  # boxes on the panel (the ferry tank is a loadout item)
		if upgrades["runner"].has(g):
			gear[g] = true
	apply_upgrades()
	if features.has("hq"):
		# no human boss: the pilot runs the organisation (AI only when nobody flies);
		# no human chief: a human controller runs the budget, else the AI chief does
		var runner_ai = "adaptive" if mode == Roles.POLICE and not humans.has(Roles.BOSS) else null
		var law_ai = null if (humans.has(Roles.CHIEF) or humans.has(Roles.CONTROLLER)) else "adaptive"
		nights = NightDirector.new(self, runner_ai, law_ai)
	_switch_aircraft(aircraft_key, 0.6)
	if opts.has("weather"):
		var w = opts["weather"]
		set_weather(w if w is Dictionary else {"sky": str(w)})
	spawn_at(location if location != null else START_FIELD)
	if police.controller == "ai":
		if features.has("aerostat"):
			police.set_aerostat(true)
		if features.has("encryption"):
			police.set_encryption(true)


## Break the reference cycles (night director, campaign, bus subscribers) so a
## finished Session is freed; batch simulators build thousands of them.
func dispose() -> void:
	if nights != null:
		nights.sess = null
	nights = null
	if campaign != null:
		campaign.sess = null
	campaign = null
	bus._subs.clear()


static func _rng(s: int) -> PyRandom:
	var r := PyRandom.new()
	r.seed(s)
	return r


# ================================================================ helpers
func runner_active() -> bool:
	return mode != Roles.POLICE


var spec: Aircraft.Spec:
	get:
		return Aircraft.ROSTER[aircraft_key]


var airfield: Airfield:
	get:
		return World.AIRFIELD_BY_CODE.get(location) if location else null


func say(text: String) -> void:
	messages.append([time, text])
	Py.keep_last(messages, 8)


func law_say(text: String) -> void:
	law_log.append([time, text])
	Py.keep_last(law_log, 40)


func carrying_hot() -> bool:
	for i in loadout.items.values():
		if i.hot:
			return true
	return false


func hot_value() -> int:
	var s := 0
	for j in active_jobs:
		if j.hot():
			s += j.payout
	return s


func job_xy(job: Jobs.Job) -> Array:
	return job.target_xy()


func find_job(job_id: int) -> Jobs.Job:
	for j in active_jobs:
		if j.id == job_id:
			return j
	for board in boards.values():
		for j in board:
			if j.id == job_id:
				return j
	return null


var parked: bool:
	get:
		var s := state
		return (runner_active() and phase == "parked" and s != null and s.on_ground and s.gs_kts < 1.5
			and location != null)


func crew_count() -> int:
	var n := 1 + (1 if copilot else 0)
	var af := airfield
	if af and af.kind in ["hub", "regional"]:
		n += 2  # ramp crew
	return n


## [endurance hours, still-air range km] from live fuel flow incl. ferry fuel.
func range_estimate() -> Array:
	var s := state
	if s == null or s.fuel_flow_pph < 1.0:
		return [0.0, 0.0]
	var fuel: float = s.fuel_lb + loadout.ferry_fuel_lb()
	var hours := fuel / s.fuel_flow_pph
	return [hours, hours * maxf(s.gs_kts, 1.0) * 1.852]


# ================================================================ aircraft
func _switch_aircraft(key: String, fuel_frac = null) -> void:
	var sp: Aircraft.Spec = Aircraft.ROSTER[key]
	var mass: MassData = _mass[key]
	var fuel: float = mass.fuel_capacity_lb() * (fuel_frac if fuel_frac != null else 0.5)
	aircraft_key = key
	loadout = Loadout.new(sp, mass, fuel, Py.truthy(copilot))
	fm = FlightModel.new(sp, jsbsim_root, mass)


func spawn_at(code: String) -> void:
	var af := World.airfield(code)
	var back := af.length / 2 - 25  # line up 25 m in from the threshold of end 0
	var x := af.x - af.ux * back
	var y := af.y - af.uy * back
	fm.spawn(x, y, af.heading, world.airfield_elev(af), loadout)
	fm.controls.brake = 1.0
	fm.step(0.5, world.ground)  # settle onto the gear
	_after_spawn()
	location = code
	phase = "parked"
	if not boards.has(code):
		refresh_board(code)


## Start in the air (offshore entry for long runs).
func spawn_airborne(x: float, y: float, heading: float, alt_agl: float, speed_kts: float) -> void:
	fm.spawn(x, y, heading, 0.0, loadout, world.ground(x, y) + alt_agl, speed_kts)
	_after_spawn()
	mapper.controls.throttle = 0.75
	fm.controls.brake = 0.0
	location = null
	phase = "flying"
	log.airborne = true


func _after_spawn() -> void:
	_apply_wind()
	mapper.reset()
	autopilot.disengage()
	kick_queue = 0
	pumping = false
	log = FlightLog.new(fm.touchdowns)
	state = fm.state()
	fm.controls.brake = 1.0


## Tonight's weather (the HQ season's, or --weather in the sandbox): cloud, rain
## and a dark moon shorten how far a police crew can see you; wind and
## turbulence go to JSBSim.
func set_weather(w: Dictionary) -> void:
	var sky: String = w.get("sky", "clear")
	if not HQ.SKIES.has(sky):
		sky = "clear"
	var wr: Array = HQ.SKIES[sky][1]
	weather = {"sky": sky, "wind_kt": int(w.get("wind_kt", (wr[0] + wr[1]) / 2)), "wind_dir": int(w.get("wind_dir", 250)),
		"moon": float(w.get("moon", 0.5))}
	police.visibility = HQ.SKIES[sky][2] * (0.8 + 0.4 * weather["moon"])
	police.sensors.weather = {"sky": sky, "wind_kt": float(weather["wind_kt"])}  # sea and rain clutter
	econ.storm = sky == "storm"
	weather_rev += 1
	_apply_wind()


func _apply_wind() -> void:
	if weather.is_empty() or fm == null:
		return
	var fps: float = 0.0 if _tied else weather["wind_kt"] * 1.68781
	var toward := deg_to_rad(weather["wind_dir"] + 180.0)  # wind is named for where it blows from
	fm.fdm.set_property("atmosphere/wind-north-fps", cos(toward) * fps)
	fm.fdm.set_property("atmosphere/wind-east-fps", sin(toward) * fps)
	fm.fdm.set_property("atmosphere/turb-type", 0 if _tied else 4)  # MIL-F-8785C (Dryden)
	fm.fdm.set_property("atmosphere/turbulence/milspec/severity", {"clear": 1, "cloud": 2, "storm": 3}[weather["sky"]])
	if fm.has("atmosphere/turbulence/milspec/windspeed_at_20ft_fps"):
		fm.fdm.set_property("atmosphere/turbulence/milspec/windspeed_at_20ft_fps", fps)


func refresh_board(code: String) -> void:
	var af := World.airfield(code)
	boards[code] = Jobs.generate(af, world.airfields, rng, 6, features,
		func(): return Maritime.random_drop_point(world, rng, maritime.cove))
	if stash_net != null and features.has("contraband") and af.kind in ["shady", "bush"]:
		var sj = stash_net.job_from(af, rng)
		if sj != null:
			boards[code].append(sj)
	if Arsenal.REALISM and stash_net != null and features.has("contraband") and af.kind in ["shady", "bush"] and arng.random() < 0.5:
		var gj = Arsenal.gun_run(af, world.airfields, stash_net, arng)
		if gj != null:
			boards[code].append(gj)
	if Economy.REALISM:
		for j in boards[code]:  # today's prices
			j.price_mult = econ.job_mult(j)
			j.payout = int(j.payout * j.price_mult)


# ================================================================ commands
## The single entry point for every non-flight action: [ok, message].
func command(role: String, name: String, args := {}) -> Array:
	if not Roles.valid(role):
		return [false, "Unknown role %s." % role]
	if not Roles.allowed(role, name):
		return [false, "%s can't do '%s'." % [role, name]]
	var handler := "_cmd_" + name
	if not has_method(handler):
		return [false, "Unknown command %s." % name]
	var err = call(handler, role, args)
	if err:
		return [false, err]
	return [true, "ok"]


## A numeric command argument, or null when missing or not a number. GDScript has
## no try/except, so commands from the network are validated here instead.
static func _num(args: Dictionary, k: String, default = null):
	var v = args.get(k)
	if v is int or v is float:
		return float(v)
	if v is String and v.is_valid_float():
		return v.to_float()
	return default


static func _point(args: Dictionary):
	var x = _num(args, "x")
	var y = _num(args, "y")
	return [x, y] if x != null and y != null else null


func _cmd_accept_job(role: String, a: Dictionary):
	var job := find_job(int(_num(a, "job_id", -1)))
	return accept_job(job) if job else "No such job."


func _cmd_drop_job(role: String, a: Dictionary):
	var job := find_job(int(_num(a, "job_id", -1)))
	if job == null:
		return "No such job."
	drop_job(job)
	return null


func _cmd_move_item(role: String, a: Dictionary):
	if not parked:
		return "Loading happens on the ground, stopped."
	var iid := int(_num(a, "item_id", -1))
	if not loadout.items.has(iid):
		return "No such item."
	if a.has("station"):  # direct placement (the load screen); -1 = back to the ramp
		var st = _num(a, "station")
		if st == null:
			return "Bad arguments for move_item."
		return place_item(iid, int(st))
	cycle_item(iid, int(_num(a, "direction", 1)))
	return null


func _cmd_loadmaster(role: String, a: Dictionary):
	return null if hire_loadmaster() else "Loadmaster couldn't fit everything."


func _cmd_set_fuel(role: String, a: Dictionary):
	if not parked:
		return "Refuel on the ground."
	set_fuel(float(_num(a, "lb", 0.0)))
	return null


func _cmd_fill_ferry(role: String, a: Dictionary):
	return fill_ferry(float(_num(a, "lb", 0.0)))


func _cmd_buy_aircraft(role: String, a: Dictionary):
	if not Aircraft.ROSTER.has(str(a.get("key", ""))):
		return "Bad arguments for buy_aircraft: unknown aircraft"
	return buy_or_switch(str(a["key"]))


func _cmd_buy_gear(role: String, a: Dictionary):
	return buy_gear(str(a.get("name", "")))


func _cmd_hire_spotter(role: String, a: Dictionary):
	var code = a.get("code")
	return hire_spotter(code if code else location)


func _cmd_spotter_move(role: String, a: Dictionary):
	var code = a.get("code")
	if not World.AIRFIELD_BY_CODE.has(code) or spotters.is_empty():
		return "No spotter / unknown field."
	var sp: Spotter = spotters[mini(int(_num(a, "index", 0)), spotters.size() - 1)]
	sp.moving_to = code
	sp.move_t = SPOTTER_MOVE_S
	say("Spotter heading to %s (60 s)" % World.airfield(code).name)
	return null


## Dial a Mode A code: four octal digits. 1200 is plain VFR; 7500/7600/7700 are
## the emergency codes, and Center reacts to them (police.gd _classify).
func _cmd_squawk(role: String, a: Dictionary):
	var code := str(a.get("code", "")).strip_edges()
	if code.length() != 4 or not code.is_valid_int() or code.contains("8") or code.contains("9"):
		return "Bad arguments for squawk: four octal digits, 0000-7777"
	squawk_code = code
	say("Squawking %s%s" % [code, {"7500": " (hijack)", "7600": " (radio failure)", "7700": " (emergency)"}.get(code, "")])
	return null


func _cmd_upgrade(role: String, a: Dictionary):
	return buy_upgrade(Roles.side(role), str(a.get("id", "")))


## The jammer van (law upgrade): a 5 km zone for three minutes around a point.
func _cmd_jam(role: String, a: Dictionary):
	if not upgrades["law"].has("jammer"):
		return "No jammer van (a Signals upgrade)."
	var p = _point(a)
	if p == null:
		return "Bad arguments for jam: need x and y"
	radio.jammed_zones = radio.jammed_zones.filter(func(z): return z.size() < 4 or z[3] > time)
	radio.jammed_zones.append([p[0], p[1], 5000.0, time + 180.0])
	law_say("Jammer van on station at %.1f, %.1f km: 5 km, three minutes" % [p[0] / 1000, p[1] / 1000])
	return null


func _cmd_transponder(role: String, a: Dictionary):
	var on = a.get("on")
	transponder = (not transponder) if on == null else Py.truthy(on)
	var on_text := ("ON, %s squawking %s" % [squawk, squawk_code]) if SensorNet.REALISM else "ON, squawking " + squawk
	say("Transponder %s" % [on_text if transponder else "OFF"])
	return null


func _cmd_turn_around(role: String, a: Dictionary):
	return turn_around()


func _cmd_autopilot(role: String, a: Dictionary):
	var on = a.get("on")
	on = (not autopilot.engaged) if on == null else Py.truthy(on)
	if on:
		if state == null or state.on_ground:
			return "Autopilot needs to be airborne."
		autopilot.engage(state, fm.controls.elevator)
		autopilot.min_ias_kts = spec.approach_kts * 1.05
		say("Autopilot ON: holding %s ft, heading %s" % [Py.f(state.alt / FT, 0), Py.f(state.heading, 0)])
	else:
		autopilot.disengage()
		say("Autopilot OFF")
	return null


func _cmd_kick(role: String, a: Dictionary):
	return request_kick(role, int(_num(a, "count", 1)))


func _cmd_auto_kick(role: String, a: Dictionary):
	var on = a.get("on")
	auto_kick = (not auto_kick) if on == null else Py.truthy(on)
	return null


func _cmd_pump(role: String, a: Dictionary):
	if loadout.ferry_tanks().is_empty():
		return "No ferry tank aboard."
	var on = a.get("on")
	pumping = (not pumping) if on == null else Py.truthy(on)
	say("Ferry pump %s" % ("ON" if pumping else "OFF"))
	return null


func _cmd_call_boat(role: String, a: Dictionary):
	return call_boat(Py.truthy(a.get("brief", false)))


func _cmd_boat_goto(role: String, a: Dictionary):
	var boats := maritime.boats.filter(func(b): return b.kind == "gofast" and not (b.state in ["seized", "delivered"]))
	if boats.is_empty():
		return "No boat at sea."
	var p = _point(a)
	if p == null:
		return "Bad arguments for boat_goto: need x and y"
	boats[0].goal = p
	boats[0].state = "to_rendezvous"
	return null


func _cmd_confirm(role: String, a: Dictionary):
	if phase in ["crashed", "busted"]:
		respawn()
	return null


func _cmd_hq(role: String, a: Dictionary):
	if nights == null:
		return "No HQ in this game (needs layer 5)."
	if role == Roles.PILOT and humans.has(Roles.BOSS):
		return "%s is the boss - ask them." % humans[Roles.BOSS]
	if role == Roles.CONTROLLER and humans.has(Roles.CHIEF):
		return "%s holds the budget - ask them." % humans[Roles.CHIEF]
	var args := a.duplicate()
	var order := str(args.get("order", ""))
	args.erase("order")
	return nights.order(Roles.side(role), order, args)


func _cmd_chat(role: String, a: Dictionary):
	var text := str(a.get("text", "")).substr(0, 200)
	if Roles.side(role) == "runner":
		say("[%s] %s" % [role, text])
		# crew radio is real radio: from the aircraft, anyone listening can hear it
		if RadioNet.REALISM and role in [Roles.PILOT, Roles.COPILOT] and state != null and not state.on_ground:
			_df_on(radio.transmit(time, "runner", squawk, text, [state.x, state.y, state.alt],
				1.0 if upgrades["runner"].has("burst_radio") else -1.0))
	else:
		law_say("[%s] %s" % [role, text])
	return null


# law side
## Dispatch on the tactical channel: a scanner programmed only for dispatch goes
## quiet. Free, unlike encryption - but a runner can program the scanner too.
func _cmd_radio_channel(role: String, a: Dictionary):
	var ch := str(a.get("channel", ""))
	if not (ch in ["police", "police_tac"]):
		return "Bad arguments for radio_channel: police or police_tac"
	radio.police_channel = ch
	law_say("Dispatch now on the %s channel" % ("tactical" if ch == "police_tac" else "main"))
	return null


func _cmd_launch(role: String, a: Dictionary):
	var kind := str(a.get("kind", ""))
	var goal = _point(a)
	if kind == "cutter":
		if not features.has("cutters"):
			return "No cutter assigned."
		if police.stock.get("cutter", 0) <= 0:
			return "No cutter available."
		police.stock["cutter"] -= 1
		var c := maritime.new_cutter(goal)
		radio.transmit(time, "police", c.id, "underway from the harbor", [c.x, c.y])
		return null
	return police.launch(kind, a.get("base"), null, goal)


func _cmd_dispatch(role: String, a: Dictionary):
	var point = _point(a)
	var target = police.resolve(a.get("target"))
	var b := maritime.boat(a.get("unit"))
	if b != null and b.kind == "cutter":
		if point == null and target:
			var tr: SensorNet.Track = police.sensors.tracks.get(target)
			point = [tr.x, tr.y] if tr else null
		if point == null:
			return "Cutters need a point."
		b.goal = point
		b.state = "patrol"
		return null
	return police.dispatch(str(a.get("unit", "")), target, point)


func _cmd_recall(role: String, a: Dictionary):
	var b := maritime.boat(a.get("unit"))
	if b != null and b.kind == "cutter":
		b.state = "return"
		b.goal = null
		return null
	return police.recall(str(a.get("unit", "")))


## Police pilot seat: take the controls of an airborne unit, or launch one.
func _cmd_claim_unit(role: String, a: Dictionary):
	var ps := police
	if Py.any(ps.units, func(u): return u.pilot == role):
		return "You're already flying one."
	var unit = a.get("unit")
	if unit:
		var u = Py.first(ps.units, func(u): return u.id == unit and u.faction() == "police" and u.state != "crashed")
		if u == null or u.pilot:
			return "Can't take that one."
		u.pilot = role
		law_say("%s has the controls of %s" % [humans.get(role, role), u.id])
		return null
	var kind := str(a.get("kind", "interceptor"))
	if not (kind in ["heli", "interceptor"]):
		return "Helicopter or interceptor."
	var err = ps.launch(kind)
	if err:
		return err
	ps.pending_claim[role] = kind
	law_say("%s launching for %s" % [kind, humans.get(role, role)])
	return null


func _cmd_release_unit(role: String, a: Dictionary):
	for u in police.units:
		if u.pilot == role:
			u.pilot = null
			return null
	return "Not flying anything."


func set_pilot_input(role: String, roll: float, pitch: float, throttle: float) -> void:
	pilot_input[role] = [roll, pitch, throttle]


func _cmd_encrypt(role: String, a: Dictionary):
	return police.set_encryption(Py.truthy(a.get("on", true)))


func _cmd_aerostat(role: String, a: Dictionary):
	return police.set_aerostat(Py.truthy(a.get("on", true)))


# ================================================================ ground ops
## Returns an error string, or null on success.
func accept_job(job: Jobs.Job):
	if not parked or location != job.origin:
		return "You need to be parked at the job's origin."
	if job.hot() and not features.has("contraband"):
		return "Not that kind of pilot. Yet."
	var seats := spec.seat_count() - (1 if copilot else 0)
	var pax_now := Py.count(loadout.items.values(), func(i): return i.kind == "passenger")
	var pax_new := Py.count(job.items, func(i): return i.kind == "passenger")
	if pax_now + pax_new > seats:
		return "Not enough seats (%d free in a %s)." % [seats, spec.name]
	job.accepted_at = time
	if job.kind == "fugitive":
		police.suspicion = maxf(police.suspicion, 60.0)  # already being looked for
	active_jobs.append(job)
	boards[job.origin].erase(job)
	for item in job.items:
		loadout.add(item)
	_ramp_load(job)
	fm.apply_loadout(loadout)
	if job.is_airdrop():
		var boat := maritime.new_gofast(job.drop_point, job.id)
		job.boat_id = boat.id
		say("%s is heading out to the rendezvous." % boat.id)
	if job.hot():
		_informant_roll(job)
	bus.emit("job_accepted", time, "", ["runner"], {"job_id": job.id, "hot": job.hot()})
	return null


func _informant_roll(job: Jobs.Job) -> void:
	_spy_roll(job)
	if not features.has("informants") or nights != null:
		return  # with HQs, informants are the Task Force's to recruit
	if upgrades["runner"].has("bug_sweep") and urng.random() < 0.5:
		return  # the sweep found the wire
	var chance := 1 - (1 - INFORMANT_BASE) * (1 - SPOTTER_LEAK) ** spotters.size()
	if rng.random() < chance:
		var p := job_xy(job)
		var x: float = p[0] + rng.uniform(-1500, 1500)
		var y: float = p[1] + rng.uniform(-1500, 1500)
		var where := "a drop at sea" if job.is_airdrop() else World.airfield(job.dest).name
		police.add_tip(x, y, 3000, "informant: load moving tonight, %s, aircraft %s" % [where, squawk], squawk, "runner")


## Espionage on a hot job: the task force's undercover agent may leak the exact
## destination; the organisation's double agent feeds them a false one.
func _spy_roll(job: Jobs.Job) -> void:
	if upgrades["law"].has("undercover") and urng.random() < 0.5:
		var p := job_xy(job)
		police.add_tip(p[0], p[1], 800, "undercover: the load goes to %s" % (World.airfield(job.dest).name if not job.is_airdrop() else "a drop at sea"),
			squawk, "runner")
	if upgrades["runner"].has("double_agent"):
		var decoys: Array = world.airfields.filter(func(a): return a.code != job.dest and a.kind in ["bush", "shady"])
		if not decoys.is_empty():
			var af: Airfield = decoys[urng.randint(0, decoys.size() - 1)]
			police.add_tip(af.x, af.y, 2500, "informant: a load lands at %s tonight" % af.name, "", null)


## The ramp crew's idea of loading: first free spot from the front.
## Rarely what you want for the CG.
func _ramp_load(job: Jobs.Job) -> void:
	var lo := loadout
	var weights := lo.station_weights(true)
	for item in job.items:
		for s in Py.sorted_by(lo.valid_stations(item), func(i): return lo.spec.stations[i].x_in):
			if lo.can_place(item, s) and weights[s] + item.weight_lb <= lo.spec.stations[s].max_lb:
				lo.assignment[item.id] = s
				lo.queue_move(item)
				weights[s] += item.weight_lb
				break


func drop_job(job: Jobs.Job) -> void:
	if not parked or not active_jobs.has(job):
		return
	active_jobs.erase(job)
	loadout.remove_job(job.id)
	if job.boat_id:
		var b := maritime.boat(job.boat_id)
		if b:
			maritime.boats.erase(b)
	if location == job.origin:
		job.accepted_at = null
		job.boat_id = null
		if not boards.has(job.origin):
			boards[job.origin] = []
		boards[job.origin].append(job)
	else:
		say("Dumped '%s' at %s. No pay." % [job.title, location])
	fm.apply_loadout(loadout)


func hire_loadmaster() -> bool:
	if not parked:
		return false
	money -= LOADMASTER_FEE
	var before := loadout.assignment.duplicate()
	var ok := loadout.auto_balance()
	loadout.requeue_changed(before)
	fm.apply_loadout(loadout)
	say("Loadmaster re-planned the load (-$%d)" % LOADMASTER_FEE + ("" if ok else " but some items don't fit!"))
	return ok


func cycle_item(item_id: int, direction := 1) -> void:
	if not parked:
		return
	loadout.cycle(loadout.items[item_id], direction)
	fm.apply_loadout(loadout)


## Put an item at a given station (-1 = unload to the ramp). Returns an error or null.
func place_item(item_id: int, station: int):
	if not parked:
		return "Loading happens on the ground, stopped."
	if not loadout.items.has(item_id):
		return "No such item."
	var item: Loadout.Item = loadout.items[item_id]
	if station < 0:
		loadout.assignment.erase(item_id)
		loadout.pending.erase(item_id)
	else:
		if station >= loadout.spec.stations.size():
			return "No such station."
		if not loadout.can_place(item, station):
			return "%s won't go in %s." % [item.label, loadout.spec.stations[station].name]
		if loadout.assignment.get(item_id) == station:
			return null
		loadout.assignment[item_id] = station
		loadout.queue_move(item)
	fm.apply_loadout(loadout)
	return null


## [price per lb, lb available] at the current field.
func fuel_source() -> Array:
	var af := airfield
	if af == null:
		return [FUEL_PRICE_PER_LB * econ.fuel_mult(), 0.0]
	var cache: float = fuel_caches.get(af.code, 0.0)
	if af.kind in ["hub", "regional"]:
		return [FUEL_PRICE_PER_LB * econ.fuel_mult(), 1e9]
	if af.kind == "bush":
		return [FUEL_PRICE_PER_LB * 2 * econ.fuel_mult(), 1e9 if cache <= 0 else cache]  # farmer's drums, or your cache
	return [0.0, cache] if cache > 0 else [0.0, 0.0]  # shady strips: only what you flew in


## Take fuel from the field's supply; returns what you got (and charges for it).
func _draw_fuel(want_lb: float) -> float:
	var src := fuel_source()
	var price: float = src[0]
	var code: String = location
	var cache: float = fuel_caches.get(code, 0.0)
	var got := minf(want_lb, src[1])
	if cache > 0:
		fuel_caches[code] = cache - minf(got, cache)
		price = 0.0
	money -= int(Py.round_int(got * price))
	return got


func set_fuel(target_lb: float) -> void:
	if not parked:
		return
	var lo := loadout
	var cur := fm.fuel_lb()
	var target := maxf(10.0, minf(lo.mass.fuel_capacity_lb(), target_lb))
	if target > cur:
		target = cur + _draw_fuel(target - cur)
		if target <= cur + 0.5:
			say("No fuel for sale here - fly drums in to build a cache.")
	lo.fuel_lb = target
	fm.apply_loadout(lo)


func fill_ferry(lb: float):
	if not parked:
		return "Refuel on the ground."
	var tanks := loadout.ferry_tanks()
	if tanks.is_empty():
		return "No ferry tank installed."
	var t: Loadout.Item = tanks[0]
	var before := t.fuel_lb
	var want := maxf(0.0, minf(t.fuel_cap_lb, lb) - before)
	var got := _draw_fuel(want) if want > 0 else 0.0
	t.set_fuel(before + got if want > 0 else lb)
	if want > 0 and got <= 0.5:
		return "No fuel for sale here."
	if t.fuel_lb > before:
		var af := airfield
		if af and af.police and features.has("informants") and rng.random() < FERRY_FUEL_TIP:
			police.add_tip(af.x, af.y, 20000, "fuel desk: %s bought ferry fuel at %s" % [squawk, af.name], squawk, "runner")
	fm.apply_loadout(loadout)
	return null


# ================================================================ upgrade trees
func has_upgrade(id: String) -> bool:
	return upgrades["runner"].has(id) or upgrades["law"].has(id)


## Buy a tree node for `side` (Upgrades): the runner pays from the pilot's money,
## the task force from its funds. The old hangar gear goes through buy_gear.
func buy_upgrade(side: String, id: String):
	if not upgrades.has(side):
		return "Bad side."
	var funds := money if side == "runner" else int(law_funds)
	var why := Upgrades.blocker(side, id, upgrades[side], funds)
	if why != "":
		return why
	var n := Upgrades.node(side, id)
	if side == "runner" and id in Upgrades.GEAR_NODES:
		var err = buy_gear(id)
		if err:
			return err
	elif side == "runner":
		money -= int(n.cost)
		say("Upgrade: %s (-$%s)" % [n.name, Py.money(int(n.cost))])
	else:
		law_funds -= float(n.cost)
		law_say("Upgrade: %s (-$%s)" % [n.name, Py.money(int(n.cost))])
	upgrades[side][id] = true
	if id == "counter_mole" and upgrades["runner"].has("mole"):
		upgrades["runner"].erase("mole")
		say("Your man in dispatch has been found and fired.")
		law_say("Mole hunt: the leak in dispatch is found and fired")
	apply_upgrades()
	bus.emit("upgrade", time, "", [Roles.side(Roles.PILOT) if side == "runner" else "law"], {"side": side, "id": id})
	return null


## Push every owned node's effect into the systems (idempotent: defaults when not owned).
func apply_upgrades() -> void:
	var r: Dictionary = upgrades["runner"]
	var l: Dictionary = upgrades["law"]
	scanner_channels = ["police", "police_tac"] if r.has("prog_scanner") else ["police"]
	police.sensors.mti_min = SensorNet.MTI_MIN_MS * (0.5 if l.has("doppler") else 1.0)
	if l.has("coastal_radar"):
		var cp: Array = maritime.cove
		police.sensors.add_site(SensorNet.RadarSite.new("CST", "Coastal radar", cp[0], cp[1], world.ground(cp[0], cp[1]) + 60.0, 25000.0))
	if l.has("aew"):
		var c: Array = HQ.ZONE_CENTRE["sea"]
		police.sensors.add_site(SensorNet.RadarSite.new("AEW", "Airborne early warning", c[0], c[1], 3000.0, 60000.0,
			{"floor_base": 15.0, "floor_per_m": 0.002, "kind": "aew", "period_s": 10.0}))
	for f in Upgrades.FEATURE_NODES:
		if l.has(f):
			police.features[Upgrades.FEATURE_NODES[f]] = true
			features[Upgrades.FEATURE_NODES[f]] = true
	police.heli_bust_mult = 1.3 if l.has("armed_heli") else 1.0
	police.heli_speed_mult = 1.3 if l.has("blackhawk") else 1.0
	for u in police.units:
		if u.kind == "heli":
			u.speed_mult = police.heli_speed_mult
	maritime.cutter_speed = 1.25 if l.has("fast_cutter") else 1.0
	for b in maritime.boats:
		if b.kind == "cutter":
			b.speed_mult = maritime.cutter_speed
	maritime.seize_mult = (2.0 if r.has("armed_boat") else 1.0) / (1.3 if l.has("fast_cutter") else 1.0)
	police.raid_escape = 0.4 if r.has("strip_guards") else 0.0
	econ.law_kit = l.size()


## Law funds and the AI chief's shopping, plus the runner's lookouts.
func _update_upgrades(dt: float) -> void:
	law_funds += dt * 40.0 / 60.0  # the budget line: ~$2,400 an hour
	if ai_law_upgrades and police.controller == "ai" and time >= _ai_buy_t:
		_ai_buy_t = time + 90.0
		var id := Upgrades.ai_pick(upgrades["law"], int(law_funds))
		if id != "":
			buy_upgrade("law", id)
	if upgrades["runner"].has("lookouts"):
		var here = [state.x, state.y] if state != null else null
		for u in police.units:
			if _lookout_seen.has(u.id) or u.faction() != "police":
				continue
			_lookout_seen[u.id] = true
			if here != null and PyMath.hypot(u.x - here[0], u.y - here[1]) < 12000:
				var brg := UIStyle.bearing_to(here[0], here[1], u.x, u.y)
				say("Lookout: police %s up, %.0f km, bearing %03.0f" % [u.kind, PyMath.hypot(u.x - here[0], u.y - here[1]) / 1000, brg])


func buy_gear(name: String):
	if not GEAR.has(name):
		return "Unknown gear."
	var price: int = GEAR[name][0]
	var feature: String = {"ferry_tank": "ferry"}.get(name, name)
	if not features.has(feature):
		return "Nobody on the island sells that yet."
	if not parked:
		return "Buy gear on the ground."
	if name == "ferry_tank":
		if Py.any(loadout.items.values(), func(i): return i.kind == "tank"):
			return "Already have a ferry tank."
		var tank := Loadout.ferry_tank(Jobs.new_id(), loadout.ferry_capacity())
		loadout.add(tank)
		var spot = Py.first(Py.sorted_by(loadout.valid_stations(tank), func(i): return -spec.stations[i].x_in),
			func(s): return loadout.can_place(tank, s))
		if spot != null:
			loadout.assignment[tank.id] = spot
			loadout.queue_move(tank)
	elif gear.has(name):
		return "Already fitted."
	else:
		gear[name] = true
	money -= price
	if name in Upgrades.GEAR_NODES:
		upgrades["runner"][name] = true
	say("Fitted: %s (-$%s)" % [GEAR[name][1], Py.money(price)])
	fm.apply_loadout(loadout)
	return null


func hire_spotter(code):
	if not features.has("spotters"):
		return "Nobody to hire yet."
	if not World.AIRFIELD_BY_CODE.has(code):
		return "Unknown field."
	if Py.any(spotters, func(s): return s.code == code):
		return "Already watching that strip."
	money -= SPOTTER_FEE
	spotters.append(Spotter.new(code))
	say("Spotter watching %s (-$%d)" % [World.airfield(code).name, SPOTTER_FEE])
	return null


## "human", "ai" or null. Changes the weight in the right seat.
func set_copilot(who) -> void:
	copilot = who
	loadout.copilot_aboard = Py.truthy(who)
	fm.apply_loadout(loadout)


func buy_or_switch(key: String):
	if not parked or not airfield or not airfield.shop:
		return "Aircraft dealers are only at Harbor Intl and Valley Regional."
	if not active_jobs.is_empty():
		return "Deliver or drop your current jobs first."
	var sp: Aircraft.Spec = Aircraft.ROSTER[key]
	if not owned.has(key):
		if money < sp.price:
			return "Need $%s." % Py.money(sp.price)
		money -= sp.price
		owned[key] = true
		say("Bought a %s!" % sp.name)
	_switch_aircraft(key)
	spawn_at(location)
	return null


## After a crash or bust.
func respawn() -> void:
	var code = log.departed_from if log.departed_from else START_FIELD
	if phase == "busted":
		code = START_FIELD
	for j in active_jobs:
		if j.boat_id:
			var b := maritime.boat(j.boat_id)
			if b:
				b.state = "running"
	active_jobs.clear()
	loadout = Loadout.new(spec, loadout.mass, loadout.mass.fuel_capacity_lb() * 0.5, Py.truthy(copilot))
	police.reset()
	spawn_at(code)


## Get out and swing the tail round: the bush pilot's answer to a runway too
## narrow to turn on. Engine off, takes a while.
func turn_around():
	var s := state
	if s == null or not s.on_ground or s.gs_kts > 1.5 or not (phase in ["parked", "flying"]):
		return "Stop on the ground first."
	if turnaround_t > 0:
		return "Already pushing her round."
	turnaround_t = TURNAROUND_S["crew" if crew_count() > 1 else "solo"]
	say("Pushing the aircraft round (%s s)..." % Py.f(turnaround_t, 0))
	return null


func _finish_turnaround() -> void:
	var s := state
	fm.spawn(s.x, s.y, fposmod(s.heading + 180.0, 360.0), world.ground(s.x, s.y), loadout)
	fm.controls.brake = 1.0
	fm.step(0.3, world.ground)
	state = fm.state()
	mapper.reset()
	say("Turned round.")


# ================================================================ in-flight crew work
func request_kick(role: String, count := 1):
	var s := state
	if s == null or s.on_ground:
		return "Kick them out in the air, not on the ramp."
	if s.ias_kts > KICK_MAX_KTS:
		return "Too fast to open the door (max %s kt)." % Py.f(KICK_MAX_KTS, 0)
	if _droppables().is_empty():
		return "Nothing to kick."
	if role == Roles.PILOT and not copilot:
		if not autopilot.engaged:
			return "Engage the autopilot [U] before you leave the controls."
		kicker = "pilot"
	else:
		kicker = "copilot"
	kick_queue = mini(_droppables().size(), kick_queue + maxi(1, count))
	return null


func _droppables() -> Array:
	var lo := loadout
	return lo.items.values().filter(func(i): return i.droppable and lo.assignment.has(i.id) and not lo.pending.has(i.id))


func _crew_work(dt: float, s: FlightModel.FlightState) -> void:
	var lo := loadout
	# loading on the ground
	if s.on_ground and s.gs_kts < 1.0 and not lo.pending.is_empty():
		if not lo.work(dt, crew_count()).is_empty():
			fm.apply_loadout(lo)
			if lo.pending.is_empty():
				say("Loading complete.")
	# AI co-pilot habits
	if copilot == "ai" and not s.on_ground:
		if not lo.ferry_tanks().is_empty() and lo.ferry_fuel_lb() > 0 and fm.wing_fuel_room() > 0.3 * lo.mass.fuel_capacity_lb():
			pumping = true
		if auto_kick and kick_queue == 0 and not _droppables().is_empty():
			for j in active_jobs:
				if j.is_airdrop() and Py.dist2([s.x, s.y], j.drop_point) < 450 and s.ias_kts <= KICK_MAX_KTS:
					request_kick(Roles.COPILOT, _droppables().size())
					break
	# kicking
	if kick_queue > 0:
		if s.on_ground or s.ias_kts > KICK_MAX_KTS + 5:
			kick_queue = 0
			say("Door closed: too fast / on the ground.")
		else:
			kick_t += dt
			if kick_t >= KICK_TIME[kicker if kicker else "copilot"]:
				kick_t = 0.0
				_kick_one(s)
	# ferry pump
	if pumping:
		var tanks := lo.ferry_tanks()
		if tanks.is_empty() or lo.ferry_fuel_lb() <= 0.1 or fm.wing_fuel_room() < 0.5:
			pumping = false
			say("Ferry pump OFF (tank dry or wings full).")
		else:
			var rate: float = PUMP_RATE_LB_MIN["copilot" if copilot else "pilot"] / 60.0
			var t: Loadout.Item = tanks[0]
			var move := minf(rate * dt, t.fuel_lb)
			var added := fm.add_fuel(move)
			t.set_fuel(t.fuel_lb - added)
			fm.apply_loadout(lo)


func _kick_one(s: FlightModel.FlightState) -> void:
	var items := _droppables()
	if items.is_empty():
		kick_queue = 0
		return
	var item: Loadout.Item = Py.max_by(items, func(i): return spec.stations[loadout.assignment[i.id]].x_in)  # nearest the door
	loadout.remove_item(item.id)
	fm.apply_loadout(loadout)
	var vz := s.vs_fpm * 0.00508
	maritime.drop_bale(item.job_id, s.x, s.y, s.alt - 1.5, s.vx, s.vy, vz, item.weight_lb)
	kick_queue -= 1
	var left := _droppables().size()
	bus.emit("bale_kicked", time, "", ["runner"], {"job_id": item.job_id})
	say("Bale away! (%d left)" % left)


## The task force's DF net on a runner transmission (RadioNet.REALISM): bearings
## from the police strips and any DF-equipped helicopter; a fix with its error
## ellipse becomes a track, a tip and suspicion.
func _df_on(msg: RadioNet.RadioMsg) -> void:
	if not features.has("df"):
		return
	var mobile := []
	if upgrades["law"].has("heli_df"):
		for u in police.units:
			if u.kind == "heli" and u.faction() == "police" and u.state != "crashed":
				mobile.append([u.id, u.x, u.y, u.z])
	var df := radio.direction_find(msg, mobile)
	if df.bearings.is_empty():
		return
	if upgrades["law"].has("intercept"):
		# they heard the words, not just the carrier
		law_say("[intercept] %s: %s" % [msg.sender, msg.text])
		police.case("runner").suspicion = minf(100.0, police.case("runner").suspicion + 10.0)
	if df.fix == null:
		law_say("DF: %d bearing on a runner transmission (%.0f s) - no fix" % [df.bearings.size(), msg.dur])
		return
	var e: Array = df.ellipse
	law_say("DF: %d bearings, fix within %.1f x %.1f km" % [df.bearings.size(), e[0] / 1000, e[1] / 1000])
	police.sensors.add_fix("runner", df.fix[0], df.fix[1], time, "DF")
	police.tips.append(PoliceSystem.Tip.new(time, df.fix[0], df.fix[1], maxf(500.0, e[0]), "DF fix"))
	var c := police.case("runner")
	c.last_known = [df.fix[0], df.fix[1], time]
	# a tight fix on a long call is worth more than a smear on a burst
	c.suspicion = minf(100.0, c.suspicion + (30.0 if e[0] < 2000 else 15.0))


func call_boat(brief := false):
	var s := state
	var boats := maritime.boats.filter(func(b): return b.kind == "gofast" and not (b.state in ["seized", "delivered"]))
	if boats.is_empty():
		return "No boat is out."
	var b: Maritime.Boat = boats[0]
	var pos = [s.x, s.y] if s else null
	var msg: RadioNet.RadioMsg
	if RadioNet.REALISM:
		# a brevity codeword is a one-second burst the DF barely gets; a real call lasts
		var text := "rain check" if brief else "%s, %s, come to me, over water, bales ready" % [b.id, squawk]
		var burst: bool = brief or upgrades["runner"].has("burst_radio")
		msg = radio.transmit(time, "boat", squawk, text, [s.x, s.y, s.alt] if s else null, 1.0 if burst else -1.0)
		if msg.jammed:
			say("Called %s - nothing but a carrier. Jammed." % b.id)
			_df_on(msg)
			return null
		if s != null and not radio.can_hear([s.x, s.y, s.alt], [b.x, b.y, 2.0]):
			say("Called %s - no answer (out of radio range: climb, or get round the hill)." % b.id)
			_df_on(msg)
			return null
	else:
		msg = radio.transmit(time, "runner", squawk, "%s, come to me" % b.id, pos)
	var over_water := s != null and world.is_water(s.x, s.y)
	if over_water:
		b.goal = [s.x, s.y]
		b.state = "to_rendezvous"
	say("Called %s." % b.id + ("" if over_water else " (Over land: boat holds position.)"))
	if RadioNet.REALISM:
		_df_on(msg)
		return null
	var df = radio.direction_find(msg) if features.has("df") else null
	if df and not df.bearings.is_empty():
		law_say("DF: %d bearing(s) on a runner transmission" % df.bearings.size())
		if df.fix:
			police.sensors.add_fix("runner", df.fix[0], df.fix[1], time, "DF")
			police.tips.append(PoliceSystem.Tip.new(time, df.fix[0], df.fix[1], 800, "DF fix"))
			police.case("runner").last_known = [df.fix[0], df.fix[1], time]
			police.case("runner").suspicion = minf(100.0, police.case("runner").suspicion + 30)
	return null


# ================================================================ tick
## Advance one frame. `bot_controls` (from a bot) replaces the pilot's input and autopilot.
func update(dt: float, inp: ControlMapper.InputFrame = null, bot_controls: FlightModel.Controls = null) -> void:
	time += dt
	if inp == null:
		inp = ControlMapper.InputFrame.new()
	if runner_active():
		_update_runner(dt, inp, bot_controls)
	_update_world(dt)
	if campaign != null:
		campaign.tick(self)
	if nights != null:
		nights.tick(dt)


func _update_runner(dt: float, inp: ControlMapper.InputFrame, bot_controls: FlightModel.Controls) -> void:
	if phase in ["crashed", "busted"]:
		if inp.pressed.has("confirm"):
			respawn()
		return
	if turnaround_t > 0:
		turnaround_t -= dt
		if turnaround_t <= 0:
			_finish_turnaround()
		fm.controls = FlightModel.Controls.make({"brake": 1.0})
		state = fm.step(dt, world.ground)
		return
	var pilot_aft: bool = kicker == "pilot" and kick_queue > 0
	if pilot_aft:
		inp = ControlMapper.InputFrame.new()  # nobody at the controls
	elif autopilot.engaged and (_any_held(inp, ["pitch_up", "pitch_down", "roll_left", "roll_right"]) or inp.stick != null):
		autopilot.disengage()
		say("Autopilot disconnected")
	var controls := mapper.update(dt, inp)
	if bot_controls != null and not pilot_aft:
		controls = bot_controls
	elif state != null and autopilot.engaged:
		controls = autopilot.update(dt, state, controls)
	elif hand_tremor != Vector2.ZERO:
		# a frightened pilot's hands (Nerves): only on human hands, never the bot or the autopilot
		controls = controls.copy()
		controls.aileron = clampf(controls.aileron + hand_tremor.x, -1.0, 1.0)
		controls.elevator = clampf(controls.elevator + hand_tremor.y, -1.0, 1.0)
	if parked and not _any_held(inp, ["throttle_up", "brake"]) and controls.throttle < 0.05:
		controls.brake = 1.0  # parking brake while in menus
	if phase == "parked" and loadout.busy() and controls.throttle > 0.05:
		controls.throttle = 0.0
		controls.brake = 1.0
		if messages.is_empty() or time - messages.back()[0] > 4:
			var what := "Still loading" if not loadout.pending.is_empty() else "Cargo still on the ramp! Load it [L] or drop the job [J]"
			say(what + ".")
	if not weather.is_empty():
		var tie: bool = phase == "parked" and controls.throttle < 0.05
		if tie != _tied:
			_tied = tie
			_apply_wind()
	fm.controls = controls
	var s := fm.step(dt, world.ground)
	state = s
	if s.valid:
		loadout.fuel_lb = s.fuel_lb
	_rules(dt, s)
	if not (phase in ["crashed", "busted"]):
		_crew_work(dt, s)
	if phase == "parked" and not unloading.is_empty():
		_unload_tick(dt)


static func _any_held(inp: ControlMapper.InputFrame, keys: Array) -> bool:
	for k in keys:
		if inp.held.has(k):
			return true
	return false


func runner_signature() -> SensorNet.Signature:
	var s := state
	if s == null or not runner_active() or phase != "flying":
		return null
	var agl := s.alt - world.ground(s.x, s.y) - fm.mass.gear_height_ft * FT
	var sig := SensorNet.Signature.new("runner", s.x, s.y, s.alt, agl, s.vx, s.vy, "air", transponder, squawk)
	sig.code = squawk_code
	sig.rcs = float(SensorNet.RCS.get(spec.key, 1.0))
	var r: Dictionary = upgrades["runner"]
	sig.visual = 0.7 if r.has("quiet_prop") else (0.8 if r.has("dark_paint") else 1.0)
	sig.spoofed = transponder and r.has("spoofer")
	return sig


func _update_world(dt: float) -> void:
	var targets := []
	var sig := runner_signature()
	if sig != null:
		targets.append(PoliceSystem.Target.new(sig, carrying_hot(), hot_value(), squawk if transponder else "runner"))
	# AI runs (police mode)
	if mode == Roles.POLICE:
		var active := smugglers.filter(func(a): return a.active())
		if director.due(time, active.size()):
			_spawn_ai_run()
			director.schedule_next(time)
	var law_air := []
	for u in police.units:
		if u.faction() == "police" and u.state != "crashed":
			law_air.append([u.x, u.y, u.z])
	for a in smugglers:
		if not a.active():
			continue
		var tr: String = a.update(dt, world, law_air,
			func(jid, x, y, z, vx, vy): maritime.drop_bale(jid, x, y, z, vx, vy, 0.0, 60))
		if tr == "escaped":
			runner_score["escapes"] += 1
			law_say("%s left the area - escaped" % police.alias(a.id))
		elif tr == "crashed":
			law_say("%s crashed" % police.alias(a.id))
		if a.active():
			targets.append(PoliceSystem.Target.new(a.signature(world), a.hot, 5000 if a.hot else 0, a.id))

	for u in police.units:
		if u.pilot:
			u.stick = pilot_input.get(u.pilot, u.stick)
	var outcomes := police.tick(dt, time, targets)
	for tid in outcomes:
		var what: String = outcomes[tid]
		if tid == "runner":
			_police_outcome(what)
		else:
			var a = Py.first(smugglers, func(s): return s.id == tid)
			if a:
				a.state = "busted"
				bus.emit("ai_busted", time, "", ["law"], {"id": tid})
	for e in police.events:
		say(e)
	police.events.clear()
	for e in police.law_events:
		law_say(e)
		if upgrades["runner"].has("mole") and not e.begins_with("Upgrade"):
			say("[mole] " + e)  # the man in dispatch hears every order, encrypted or not
	police.law_events.clear()
	_update_upgrades(dt)
	_update_stashes(dt)
	_update_economy(dt)

	# maritime: cutters go where the task force suspects a drop
	var law_goals := []
	for t in police.tips:
		if time - t.t < 600 and t.text in ["possible airdrop", "DF fix"]:
			law_goals.append([t.x, t.y])
	if police.controller == "ai" and not law_goals.is_empty() and features.has("cutters") and police.stock.get("cutter", 0) > 0:
		police.stock["cutter"] -= 1
		var c := maritime.new_cutter(law_goals.back())
		radio.transmit(time, "police", c.id, "underway to suspected drop", [c.x, c.y])
	maritime.update(dt, law_goals if police.controller == "ai" else [])
	for ev in maritime.events:
		_maritime_event(ev[0], ev[1])
	maritime.events.clear()
	_update_intel(dt)


func _spawn_ai_run() -> void:
	director.serial += 1
	var r := director.rng
	var ee := AISmuggler.entry_and_exit(r)
	var drop := Maritime.random_drop_point(world, r, maritime.cove)
	var jid := Jobs.new_id()
	var a := AISmuggler.new("Runner-%d" % director.serial, ee[0][0], ee[0][1], 150.0, ee[2], drop, ee[1], jid,
		{"bales_left": r.randint(4, 7)})
	smugglers.append(a)
	maritime.new_gofast(drop, jid)
	law_say("Intel: a run is expected tonight.")


func _police_outcome(what: String) -> void:
	if what == "busted":
		_bust("forced down by police")
	elif what == "clean":
		var fine := 500 if not transponder else 0
		money -= fine
		say("Police forced you down and searched the aircraft: clean." + (" Fined $%d for no transponder." % fine if fine else ""))
	elif what == "hijacked":
		var lost := active_jobs.filter(func(j): return j.hot())
		for j in lost:
			active_jobs.erase(j)
			loadout.remove_job(j.id)
		fm.apply_loadout(loadout)
		say("Rivals forced you to jettison the goods!")
		bus.emit("hijacked", time, "", ["runner"], {"jobs": lost.map(func(j): return j.id)})


func _maritime_event(kind: String, data: Dictionary) -> void:
	var job = Py.first(active_jobs, func(j): return j.id == data.get("job_id"))
	if kind == "bales_delivered":
		var n: int = data["count"]
		runner_score["bales_delivered"] += n
		if job:
			var pay := int(job.payout * n / float(maxi(1, job.bales_total)))
			money += pay
			job.bales_delivered = n
			_resolve_job(job, "%s made the cove with %d/%d bales: +$%s" % [data["boat"], n, job.bales_total, Py.money(pay)])
		bus.emit("bales_delivered", time, "", ["runner"], {"count": n, "job_id": data.get("job_id")})
	elif kind == "boat_seized":
		police.score["boats_seized"] += 1
		police.score["bales_seized"] += data["count"]
		law_say("%s seized %s with %d bales" % [data["cutter"], data["boat"], data["count"]])
		law_funds += 1500.0 + 100.0 * data["count"]  # asset forfeiture
		econ.record_seizure("marijuana", "sea")
		if upgrades["runner"].has("armed_boat"):
			law_funds += 1500.0
			_seize_weapons({"rifle": 2}, data["boat"])
			law_say("Firearms aboard %s: a federal charge on top" % data["boat"])
		if job:
			_resolve_job(job, "Coast Guard took %s! Job lost." % data["boat"])
		bus.emit("boat_seized", time, "", ["runner", "law"], data)
	elif kind == "bale_seized":
		police.score["bales_seized"] += 1
		law_say("%s recovered a floating bale" % data["cutter"])
	elif kind == "bale_splash" and job:
		say("Splash - bale in the water.")
	elif kind == "bale_lost" and job:
		say("Bale lost (%s)." % data["why"])
	elif kind == "boat_fleeing" and job:
		say("%s: cutter on us, running!" % data["boat"])
	elif kind == "boat_returning" and job:
		say("%s: cutter's gone, heading back to the rendezvous." % data["boat"])
	elif kind == "cutter_contact":
		radio.transmit(time, "police", data["cutter"], "surface contact, go-fast, pursuing", [data["x"], data["y"]])


func _resolve_job(job: Jobs.Job, text: String) -> void:
	job.resolved = true
	active_jobs.erase(job)
	say(text)


## Scanner intercepts and spotter reports -> runner-side knowledge of police.
func _update_intel(dt: float) -> void:
	var rx = null
	if state != null:
		rx = [state.x, state.y, state.alt]
	elif location != "":
		rx = [World.airfield(location).x, World.airfield(location).y, null]
	if gear.has("scanner") and features.has("scanner") and RadioNet.REALISM and rx != null:
		# the scanner hears what's in radio range of the aircraft, on its programmed channels
		for e in radio.scanner_at(_scanner_seen, rx, scanner_channels):
			scanner_log.append(e)
		for m in radio.log:
			if m.t > _scanner_seen and m.channel in scanner_channels and not m.encrypted and not m.jammed \
					and m.x != null and radio.can_hear([m.x, m.y, m.z], rx):
				intel[m.sender] = [m.t, m.x, m.y, "scanner"]
		Py.keep_last(scanner_log, 30)
	elif gear.has("scanner") and features.has("scanner"):
		for e in radio.scanner(_scanner_seen):
			scanner_log.append(e)
		for m in radio.channel("police", _scanner_seen):
			if not m.encrypted and m.x != null:
				intel[m.sender] = [m.t, m.x, m.y, "scanner"]
		Py.keep_last(scanner_log, 30)
	_scanner_seen = time
	for sp in spotters:
		if sp.moving_to:
			sp.move_t -= dt
			if sp.move_t <= 0:
				sp.code = sp.moving_to
				sp.moving_to = null
				say("Spotter in position at %s." % World.airfield(sp.code).name)
			continue
		if time - sp.last_report_t < 8.0:
			continue
		sp.last_report_t = time
		var af := World.airfield(sp.code)
		var seen := police.units.filter(func(u): return u.faction() == "police" and u.state != "crashed" \
			and PyMath.hypot(u.x - af.x, u.y - af.y) < SPOTTER_RANGE_M)
		for u in seen:
			intel[u.id] = [time + SPOTTER_DELAY_S, u.x, u.y, "spotter@" + sp.code]
		if not seen.is_empty():
			say("Spotter@%s: %d police unit(s) near the strip!" % [sp.code, seen.size()])
	# forget stale intel
	var fresh := {}
	for k in intel:
		if time - intel[k][0] < 90:
			fresh[k] = intel[k]
	intel = fresh


# ================================================================ rules
func _crash(reason: String) -> void:
	phase = "crashed"
	var fee := maxi(2500, int(spec.price * 0.12))
	money -= fee
	var lost := active_jobs.size()
	last_outcome = "CRASH: %s. Repairs -$%s." % [reason, Py.money(fee)] + (" %d job(s) lost." % lost if lost else "")
	say(last_outcome)
	bus.emit("crashed", time, "", ["runner", "law"], {"reason": reason})


func _bust(how: String) -> void:
	phase = "busted"
	var fine := 1500 + int(maxi(0, money) * 0.25)
	law_funds += 3000.0  # the aircraft and the cash, forfeited
	for j in active_jobs:
		if j.hot():
			econ.record_seizure(Economy.good_of(j), Economy.job_market(j))
			_seize_weapons(Arsenal.weapons_of(j), "the aircraft")
	if upgrades["runner"].has("strip_guards"):
		fine = int(fine * 1.5)  # an armed-bust case
		how += ", with the armed guards"
	money -= fine
	last_outcome = "BUSTED (%s). Fine and impound -$%s. Cargo seized." % [how, Py.money(fine)]
	say(last_outcome)
	police.score["busts"] += 1
	law_say("BUST: %s (%s)" % [squawk, how])
	bus.emit("busted", time, "", ["runner", "law"], {"how": how})


func _rules(dt: float, s: FlightModel.FlightState) -> void:
	var lg := log
	if fm.crash_reason:
		_crash(fm.crash_reason)
		return
	if not s.valid:
		_crash("Airframe failure")
		return
	var af_here := world.airfield_at(s.x, s.y, 4.0)

	# --- leaving / flying
	if not s.on_ground and s.agl > 3.0:
		if not lg.airborne:
			lg.airborne = true
			lg.departed_from = lg.departed_from if lg.departed_from else location
		if phase == "parked":
			if not unloading.is_empty():
				say("Took off with the load still aboard - no deal.")
				unloading = []
			phase = "flying"
			location = null
			police.reset(true)
		lg.max_bank = maxf(lg.max_bank, absf(s.roll))
	elif phase == "parked" and s.gs_kts > 3:
		lg.departed_from = lg.departed_from if lg.departed_from else location

	# --- collisions
	if world.tree_hit(s.x, s.y, s.alt - fm.mass.gear_height_ft * FT, 4.0):
		_crash("Hit trees")
		return
	if absf(s.x) > World.HALF + 3000 or absf(s.y) > World.HALF + 3000:
		if messages.is_empty() or time - messages.back()[0] > 6:
			say("Leaving the operating area - turn back!")

	# --- touchdowns
	if fm.touchdowns != lg.touchdowns_seen:
		lg.touchdowns_seen = fm.touchdowns
		var fpm := -fm.last_touchdown_fpm
		lg.last_touchdown_fpm = fpm
		lg.max_touchdown_fpm = maxf(lg.max_touchdown_fpm, fpm)
		var limit := spec.gear_limit_fpm * (0.75 if loadout.compute(null, false).overweight_lb > 0 else 1.0) \
			* (1.5 if upgrades["runner"].has("heavy_gear") else 1.0)
		if fpm > limit:
			_crash("Gear collapsed on a %s fpm touchdown" % Py.f(fpm, 0))
			return
		if lg.airborne:
			say("Touchdown %s fpm" % Py.f(fpm, 0) + (" - butter!" if fpm < 150 else ""))

	if s.on_ground:
		autopilot.disengage()
		if world.is_water(s.x, s.y) and af_here == null:
			_crash("Ditched in the sea")
			return
		if absf(s.roll) > 12:
			_crash("Wingtip strike")
			return
		if s.pitch < -7:
			_crash("Prop strike - nosed over")
			return
		if af_here == null and s.gs_kts > OFF_FIELD_MAX_GS_KTS:
			_crash("Ran off the strip into rough ground")
			return
		if s.gs_kts < 1.0 and af_here != null and lg.airborne:
			_arrive(af_here, s)


func _arrive(af: Airfield, s: FlightModel.FlightState) -> void:
	phase = "parked"
	location = af.code
	if police.landing_check(s, af, carrying_hot()):
		_bust("arrested on landing at %s" % af.name)
		return
	var delivered := active_jobs.filter(func(j): return j.dest == af.code)
	for job in delivered.filter(func(j): return j.stash != "" and stash_net != null):
		_truck_out(job, af)
	delivered = delivered.filter(func(j): return j.stash == "")
	var hot_here := delivered.filter(func(j): return j.hot() and af.kind in ["bush", "shady"])
	if not hot_here.is_empty():
		# the buyers count it before they pay: sit tight and hope nobody followed you in
		unloading = hot_here
		unload_t = UNLOAD_HOT_S
		say("Unloading - %s s. Watch the sky." % Py.f(UNLOAD_HOT_S, 0))
		delivered = delivered.filter(func(j): return not hot_here.has(j))
	for job in delivered:
		_complete_delivery(job, af)
	fm.apply_loadout(loadout)
	police.reset(true)
	log = FlightLog.new(fm.touchdowns)
	refresh_board(af.code)
	if delivered.is_empty() and hot_here.is_empty():
		say("Parked at %s." % af.name)
	bus.emit("landed", time, "", ["runner"], {"code": af.code})
	save()


## A stash job landed: the load goes on the crew's truck, graded for the flight
## now and paid when (if) the truck reaches the stash.
func _truck_out(job: Jobs.Job, af: Airfield) -> void:
	var g := _grade(job)
	var c := police.case("runner")
	var risk := (0.15 if af.police else 0.0) + (0.1 if (c.tipped or c.wanted) else 0.0)
	var t := stash_net.dispatch(job, af, time, g[0], risk)
	if ground != null:
		# by road; the roadblock roll gives way to the checkpoints on the ground
		var st: Dictionary = stash_net.get_stash(job.stash)
		t.route = ground.graph.route(Vector2(af.x, af.y), Vector2(st.x, st.y))
		t.dur = StashNet.TRUCK_LOAD_S + RoadGraph.length(t.route) / StashNet.TRUCK_MS
		t.stop_at = -1.0
	active_jobs.erase(job)
	loadout.remove_job(job.id)
	say("Load's on the truck to %s: about %d min by road." % [stash_net.get_stash(job.stash).name, int(ceil(t.dur / 60.0))])
	bus.emit("truck_out", time, "", ["runner"], {"job_id": job.id, "stash": job.stash})


func _update_stashes(dt: float) -> void:
	if stash_net == null:
		return
	var results := stash_net.update(dt, time, police.units.filter(func(u): return u.faction() == "police"))
	if ground != null:
		ground.update(dt)
		for r in ground.truck_contacts():
			stash_net.trucks.erase(r[0])
			results.append(r)
		for e in ground.events:
			if e[0] in ["runner", "both"]:
				say(e[1])
			if e[0] in ["law", "both"]:
				law_say(e[1])
		ground.events.clear()
	for r in results:
		var t: StashNet.Truck = r[0]
		var st: Dictionary = stash_net.get_stash(t.stash)
		if r[1] == "hijacked":
			say("Los Cuervos hit the truck to %s. The load is theirs." % st.name)
			law_say("Word on the street: Los Cuervos hijacked a truck near %s" % st.name)
			bus.emit("truck_hijacked", time, "", ["runner"], {"stash": t.stash})
			continue
		if r[1] == "delivered" and not t.weapons.is_empty() and t.gun_mode == "stock" and Arsenal.REALISM:
			_stock_weapons(t.weapons, st.id)
			say("Truck in at %s: %s into the armoury here" % [st.name, Arsenal.describe(t.weapons)])
			bus.emit("job_delivered", time, "", ["runner"], {"job_id": t.job_id, "pay": 0, "dest": t.stash, "hot": true})
		elif r[1] == "delivered":
			money += t.pay
			econ.record_delivery("guns" if not t.weapons.is_empty() else "cocaine", st.zone)
			say("Truck in at %s: +$%s" % [st.name, Py.money(t.pay)])
			bus.emit("job_delivered", time, "", ["runner"], {"job_id": t.job_id, "pay": t.pay, "dest": t.stash, "hot": true})
		else:
			say("The truck to %s was stopped (%s). The load is gone." % [st.name, r[2]])
			law_say("Truck stopped on the road to %s: %d crates seized" % [st.name, t.items])
			law_funds += 2000.0 + 300.0 * t.items
			econ.record_seizure("guns" if not t.weapons.is_empty() else "cocaine", st.zone)
			_seize_weapons(t.weapons, "the truck")
			police.case("runner").suspicion = minf(100.0, police.case("runner").suspicion + 15.0)
			bus.emit("truck_seized", time, "", ["runner", "law"], {"stash": t.stash})
	# the AI task force raids a stash it knows is busy
	if police.controller == "ai" and time >= _stash_ai_t and ground == null:
		_stash_ai_t = time + 60.0
		for st in stash_net.known():
			if not st.burned and st.heat >= 55.0 and urng.random() < 0.3:
				_raid(st.id)
				break


## The markets move: police and rival traffic near each market, the rivals'
## turf (the HQ season's, when there is one), and the news.
func _update_economy(dt: float) -> void:
	var cops := []
	var rivals := []
	for u in police.units:
		if u.state != "crashed":
			(cops if u.faction() == "police" else rivals).append([u.x, u.y])
	for c in maritime.boats:
		if c.kind == "cutter":
			cops.append([c.x, c.y])
	for a in smugglers:
		if a.active() and a.kind == "rival":
			rivals.append([a.x, a.y])
	var turf := {}
	if nights != null and nights.season != null and nights.season.rival != null:
		turf = nights.season.rival.turf
	if ground != null:
		cops += ground.positions("police")
		rivals += ground.positions("rival")
		turf = ground.turf(turf)
	econ.update(dt, time, cops, rivals, turf)
	while _news_seen < econ.news.size():
		say("Market news: " + econ.news[_news_seen][1])
		_news_seen += 1
	if _news_seen > 12:
		_news_seen = econ.news.size()


func _raid(id: String):
	var why := stash_net.raid(id)
	if why != "":
		return why
	var st: Dictionary = stash_net.get_stash(id)
	var taken := stash_net.trucks_to(id)
	for t in taken:
		stash_net.trucks.erase(t)
	law_funds += 2000.0 + 1500.0 * taken.size()
	econ.record_seizure("cocaine", st.zone)
	for t in taken:
		_seize_weapons(t.weapons, "the truck at the door")
	if Arsenal.REALISM and arsenals.has("org") and arsenals["org"].cache == id and not arsenals["org"].is_empty():
		var moved: Dictionary = arsenals["org"].seize_into(arsenals["law"])
		arsenals["org"].cache = ""
		econ.record_seizure("guns", st.zone)
		law_say("The armoury at %s: %s seized - issued to the patrols" % [st.name, Arsenal.describe(moved)])
		say("They found the armoury at %s: %s gone to the police." % [st.name, Arsenal.describe(moved)])
	law_say("Raid on %s: burned%s" % [st.name, (", %d truck(s) taken at the door" % taken.size()) if taken else ""])
	say("The police raided %s. It's burned%s." % [st.name, " - and the truck with it" if taken else ""])
	bus.emit("stash_raided", time, "", ["runner", "law"], {"stash": id})
	return null


# ================================================================ arsenals and gun running
## Weapons taken by the police go into their arsenal and arm their patrols.
func _seize_weapons(weapons: Dictionary, where: String) -> void:
	if not Arsenal.REALISM or weapons.is_empty() or not arsenals.has("law"):
		return
	var n: int = arsenals["law"].take_seized(weapons)
	if n > 0:
		law_say("Weapons recovered from %s: %s - into the arsenal" % [where, Arsenal.describe(weapons)])
		bus.emit("weapons_seized", time, "", ["law"], {"weapons": weapons, "where": where})


func _stock_weapons(weapons: Dictionary, stash_id: String) -> void:
	var org: Arsenal = arsenals["org"]
	org.add_all(weapons)
	if stash_id != "":
		org.cache = stash_id  # the guns sit where the truck left them
	bus.emit("weapons_stocked", time, "", ["runner"], {"weapons": weapons, "cache": org.cache})


## The fence's price for one weapon (a cut under the street) and the dealer's (a mark-up).
func weapon_price(tier: String, buying: bool) -> int:
	var m := econ.mult("guns", "town")
	return int(Arsenal.TIERS[tier].price * m * (1.4 if buying else 0.8))


func _cmd_gun_mode(role: String, a: Dictionary):
	var job = find_job(int(_num(a, "job_id", -1)))
	if job == null:
		job = Py.first(active_jobs, func(j): return not j.weapons.is_empty())
	if job == null or job.weapons.is_empty():
		return "No gun run to set."
	var m := str(a.get("mode", "stock" if job.gun_mode == "sell" else "sell"))
	if not m in ["sell", "stock"]:
		return "Sell or stock."
	job.gun_mode = m
	for t in stash_net.trucks if stash_net != null else []:
		if t.job_id == job.id:
			t.gun_mode = m
	say("Gun run: %s on delivery." % ("sell them" if m == "sell" else "keep them for our soldiers"))
	return null


func _cmd_sell_weapons(role: String, a: Dictionary):
	if not Arsenal.REALISM:
		return "No arsenal."
	var tier := str(a.get("tier", ""))
	var n := int(_num(a, "n", 1))
	if not Arsenal.TIERS.has(tier) or n <= 0:
		return "Sell what?"
	var k: int = arsenals["org"].take(tier, n)
	if k == 0:
		return "None of those in the armoury."
	var pay := weapon_price(tier, false) * k
	money += pay
	econ.record_delivery("guns", "town")
	say("Sold %d %s to the fence: +$%s" % [k, Arsenal.TIERS[tier].name.to_lower(), Py.money(pay)])
	return null


func _cmd_buy_weapons(role: String, a: Dictionary):
	if not Arsenal.REALISM:
		return "No arsenal."
	var tier := str(a.get("tier", ""))
	var n := int(_num(a, "n", 1))
	if not Arsenal.TIERS.has(tier) or n <= 0:
		return "Buy what?"
	var cost := weapon_price(tier, true) * n
	if money < cost:
		return "Need $%s." % Py.money(cost)
	money -= cost
	arsenals["org"].add(tier, n)
	say("Bought %d %s from a dealer: -$%s" % [n, Arsenal.TIERS[tier].name.to_lower(), Py.money(cost)])
	return null


func _cmd_set_cache(role: String, a: Dictionary):
	if not Arsenal.REALISM:
		return "No arsenal."
	var id := str(a.get("stash", ""))
	if id != "" and (stash_net == null or stash_net.get_stash(id) == null or stash_net.get_stash(id).burned):
		return "No such stash."
	arsenals["org"].cache = id
	say("The guns are kept at %s now." % ("the club" if id == "" else stash_net.get_stash(id).name))
	return null


# ================================================================ the ground war
func _faction_of(role: String) -> String:
	return "police" if Roles.side(role) == "law" else "org"


func _cmd_squad_order(role: String, a: Dictionary):
	if ground == null:
		return "No ground war here."
	var q = ground.get_squad(str(a.get("id", "")))
	if q == null or q.faction != _faction_of(role):
		return "Not one of ours."
	var o: Dictionary = a.get("order", {}) if a.get("order") is Dictionary else {"type": str(a.get("order", ""))}
	for k in ["x", "y", "stash", "market", "squad", "job_id"]:
		if a.has(k) and not o.has(k):
			o[k] = a[k]
	var err: String = ground.order(q, o)
	if err != "":
		return err
	q.human = true
	if o.get("type", "") == "stakeout" and o.has("stash"):
		ground.stakeouts[str(o.stash)] = q.id
	return null


func _cmd_recruit_squad(role: String, a: Dictionary):
	if ground == null:
		return "No ground war here."
	var r = ground.recruit(_faction_of(role), str(a.get("kind", "foot")))
	if r is String:
		return r
	var text := "Raised %s: %s" % [r.id, Arsenal.describe(r.loadout)]
	if r.faction == "org":
		say(text)
	else:
		law_say(text)
	return null


func _cmd_disband_squad(role: String, a: Dictionary):
	if ground == null:
		return "No ground war here."
	var q = ground.get_squad(str(a.get("id", "")))
	if q == null or q.faction != _faction_of(role):
		return "Not one of ours."
	if q.fight != null:
		return "They're in a firefight."
	ground.disband(q)
	return null


func _cmd_raid_stash(role: String, a: Dictionary):
	if stash_net == null:
		return "No stash houses on this map."
	return _raid(str(a.get("id", "")))


func _complete_delivery(job: Jobs.Job, af: Airfield) -> void:
	var drums := job.items.filter(func(i): return i.label == "Fuel drum")
	if not drums.is_empty() and af.kind in ["bush", "shady"]:
		var fuel := Py.sum_by(drums, func(i): return i.weight_lb) * 0.9
		fuel_caches[af.code] = fuel_caches.get(af.code, 0.0) + fuel
		say("%s lb of fuel cached at %s." % [Py.f(fuel, 0), af.name])
	if Arsenal.REALISM and not job.weapons.is_empty() and job.gun_mode == "stock":
		_stock_weapons(job.weapons, "")
		active_jobs.erase(job)
		loadout.remove_job(job.id)
		say("Delivered '%s': %s into the organisation's armoury" % [job.title, Arsenal.describe(job.weapons)])
		bus.emit("job_delivered", time, "", ["runner"], {"job_id": job.id, "pay": 0, "dest": af.code, "hot": true})
		return
	var g := _grade(job)
	money += g[0]
	if job.hot():
		econ.record_delivery(Economy.good_of(job), Economy.job_market(job))
	active_jobs.erase(job)
	loadout.remove_job(job.id)
	say(("Delivered '%s': +$%s %s" % [job.title, Py.money(g[0]), g[1]]).strip_edges(false, true))
	bus.emit("job_delivered", time, "", ["runner"], {"job_id": job.id, "pay": g[0], "dest": af.code, "hot": job.hot()})


## A hot load being counted out on a bush/shady strip. Police arriving = raid.
func _unload_tick(dt: float) -> void:
	if unloading.is_empty():
		return
	var s := state
	for u in police.units:
		if (u.faction() == "police" and u.state != "crashed"
				and PyMath.hypot(u.x - s.x, u.y - s.y) < RAID_RANGE_M and u.z - s.alt < 600):
			unloading = []
			_bust("raided on the ground at %s" % (airfield.name if airfield else "the strip"))
			return
	unload_t -= dt
	if unload_t <= 0:
		var af := airfield
		for job in unloading:
			if active_jobs.has(job):
				_complete_delivery(job, af)
		unloading = []
		fm.apply_loadout(loadout)
		save()


## [pay, notes]
func _grade(job: Jobs.Job) -> Array:
	var pay := float(job.payout)
	var notes := []
	if Economy.REALISM and job.hot():
		# contraband sells at the street price on the day it arrives
		var move := econ.job_mult(job) / maxf(0.05, job.price_mult)
		pay *= move
		if absf(move - 1.0) >= 0.03:
			notes.append("(street price %+d%%)" % int(round((move - 1.0) * 100.0)))
	var lg := log
	var left = job.time_left(time)
	if left != null and left < 0:
		pay *= 0.4
		notes.append("(late)")
	if Py.any(job.items, func(i): return i.fragile) and lg.max_touchdown_fpm > 400:
		pay *= 0.5
		notes.append("(breakage)")
	if job.comfort and (lg.max_bank > 45 or lg.max_touchdown_fpm > 300):
		pay *= 0.7
		notes.append("(VIP unhappy)")
	if lg.last_touchdown_fpm < 150:
		pay *= 1.1
		notes.append("(smooth landing bonus)")
	return [int(pay), " ".join(notes)]


# ================================================================ persistence
func save() -> void:
	if save_path == "":
		return
	DirAccess.make_dir_recursive_absolute(save_path.get_base_dir())
	var o := owned.keys()
	o.sort()
	var g := gear.keys()
	g.sort()
	var data := {
		"money": money,
		"owned": o,
		"aircraft": aircraft_key,
		"location": location if parked else (log.departed_from if log.departed_from else START_FIELD),
		"gear": g,
		"upgrades": Py.sorted_by(upgrades["runner"].keys(), func(k): return k),
		"map_seed": map_seed,
	}
	if arsenals.has("org"):
		data["arsenal"] = arsenals["org"].to_dict()
	if campaign != null:
		data["campaign"] = campaign.to_dict()
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "  "))


static func read_save(path: String) -> Dictionary:
	if path == "" or not FileAccess.file_exists(path):
		return {}
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if d is Dictionary else {}


static func load_or_new(path: String, opts := {}) -> Session:
	var data := read_save(path)
	var o := {}
	o.merge(opts)
	# the save's island wins unless the caller asked for a specific one
	if not opts.has("map_seed"):
		o["map_seed"] = int(data.get("map_seed", 0))
	World.use_map(int(o["map_seed"]))
	o["money"] = int(data.get("money", START_MONEY))
	var owned_list := (data.get("owned", ["c172p"]) as Array).filter(func(k): return Aircraft.ROSTER.has(k))
	o["owned"] = owned_list if not owned_list.is_empty() else ["c172p"]
	o["aircraft_key"] = data.aircraft if Aircraft.ROSTER.has(data.get("aircraft", "")) else "c172p"
	o["location"] = data.location if World.AIRFIELD_BY_CODE.has(data.get("location", "")) else START_FIELD
	o["gear"] = (data.get("gear", []) as Array).filter(func(k): return GEAR.has(k))
	o["upgrades"] = {"runner": (data.get("upgrades", []) as Array).filter(func(k): return Upgrades.side_of(k) == "runner")}
	if data.get("arsenal") is Dictionary:
		o["arsenal"] = data["arsenal"]
	o["save_path"] = path
	return Session.new(o)
