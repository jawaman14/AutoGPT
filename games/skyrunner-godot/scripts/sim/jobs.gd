class_name Jobs
extends RefCounted
## Job board generation.

static var _next_id := 1

const PASSENGER_NAMES := ["Hiker", "Surveyor", "Doctor", "Tourist", "Fisherman", "Geologist", "Photographer",
	"Ranger", "Honeymooner", "Mechanic", "Priest", "Journalist"]
const CARGO_TYPES := [
	["Mail sacks", 12, 25, false],
	["Tool crate", 30, 70, false],
	["Fuel drum", 75, 90, false],
	["Generator", 90, 140, false],
	["Food supplies", 20, 45, false],
	["Glass panels", 25, 60, true],
	["Lab samples", 5, 15, true],
]
const CONTRABAND := [
	["Unmarked crate", 25, 60],
	["'Coffee' sacks", 20, 40],
	["Sealed case", 8, 20],
]


## Unique id shared by jobs and items (and ferry tanks).
static func new_id() -> int:
	var i := _next_id
	_next_id += 1
	return i


class Job:
	var id: int
	var title: String
	var kind: String  ## passenger | cargo | medical | contraband | fugitive | airdrop
	var origin: String
	var dest: String
	var items: Array  ## [Loadout.Item]
	var payout: int
	var deadline_s = null  ## sim seconds after acceptance
	var accepted_at = null
	var notes := ""
	var comfort := false  ## passengers who hate steep banks / hard landings
	var drop_point = null  ## airdrop jobs: [x, y] rendezvous at sea
	var boat_id = null
	var bales_total := 0
	var bales_delivered := 0
	var resolved := false

	func _init(id_: int, title_: String, kind_: String, origin_: String, dest_: String, items_: Array, payout_: int, opts := {}) -> void:
		id = id_
		title = title_
		kind = kind_
		origin = origin_
		dest = dest_
		items = items_
		payout = payout_
		for k in opts:
			set(k, opts[k])

	func is_airdrop() -> bool:
		return drop_point != null

	func target_xy() -> Array:
		if drop_point != null:
			return drop_point
		var af: Airfield = World.airfield(dest)
		return [af.x, af.y]

	func dest_label() -> String:
		return "DROP" if drop_point != null else dest

	func hot() -> bool:
		for i in items:
			if i.hot:
				return true
		return false

	func weight_lb() -> float:
		var s := 0.0
		for i in items:
			s += i.weight_lb
		return s

	func time_left(now: float):
		if deadline_s == null or accepted_at == null:
			return null
		return deadline_s - (now - accepted_at)


static func item(label: String, kind: String, kg: float, job_id: int, opts := {}) -> Loadout.Item:
	return Loadout.Item.new(new_id(), label, kind, Py.round_n(kg * Aircraft.LB_PER_KG, 1), job_id, opts)


static func _dist_km(a: Airfield, b: Airfield) -> float:
	return PyMath.hypot(a.x - b.x, a.y - b.y) / 1000


## Pay multiplier for hard destinations: short, narrow, high or odd strips.
static func _difficulty(dest: Airfield) -> float:
	var m := 1.0
	if dest.length < 300:
		m += 0.6
	elif dest.length < 500:
		m += 0.3
	if dest.setting in ["plateau", "pit"]:
		m += 0.4
	return m


static func airdrop_job(origin: Airfield, drop_point: Array, rng: PyRandom, bales := 0) -> Job:
	var jid := new_id()
	var n: int = bales if bales else rng.randint(3, 6)
	var items := []
	for k in n:
		items.append(item("Bale", "cargo", rng.uniform(22, 32), jid, {"hot": true, "droppable": true}))
	var dist := PyMath.hypot(drop_point[0] - origin.x, drop_point[1] - origin.y) / 1000
	var pay := int(n * (700 + dist * 40))
	return Job.new(jid, "Kick %d bales to the boat" % n, "airdrop", origin.code, "SEA", items, pay, {
		"notes": "Fly to the rendezvous, kick the bales near the boat [K]. Paid per bale landed at the cove.",
		"drop_point": drop_point, "bales_total": n})


## features: Dictionary used as a set (feature -> true), or null for the default.
static func generate(origin: Airfield, airfields: Array, rng: PyRandom, n := 6, features = null, drop_point_fn = null) -> Array:
	if features == null:
		features = {"contraband": true, "airdrop": true}
	var jobs := []
	var others := []
	for a in airfields:
		if a.code != origin.code:
			others.append(a)
	var shady_origin := origin.kind in ["shady", "bush"]
	if features.has("airdrop") and drop_point_fn != null and shady_origin:
		jobs.append(airdrop_job(origin, drop_point_fn.call(), rng))
	if features.has("ferry") and origin.kind in ["hub", "regional"]:
		var bush := []
		for a in airfields:
			if a.kind in ["shady", "bush"]:
				bush.append(a)
		var dest: Airfield = rng.choice(bush)
		var jid := new_id()
		var cnt := rng.randint(1, 3)
		var items := []
		for k in cnt:
			items.append(item("Fuel drum", "cargo", rng.uniform(75, 90), jid))
		var w := Py.sum_by(items, func(i): return i.weight_lb)
		jobs.append(Job.new(jid, "Fuel cache x%d -> %s" % [cnt, dest.name], "cargo", origin.code, dest.code, items,
			int(150 + w * 0.8), {"notes": "Stocks a fuel cache there for your own runs."}))
	while jobs.size() < n:
		var dest: Airfield = rng.choice(others)
		var jid := new_id()
		var dist := _dist_km(origin, dest)
		var diff := _difficulty(dest)
		var roll := rng.random()
		if not features.has("contraband") and roll < 0.45:
			roll = 0.45 + roll  # no hot work offered yet
		if shady_origin and roll < 0.35:
			var c: Array = rng.choice(CONTRABAND)
			var cnt := rng.randint(1, 4)
			var items := []
			for k in cnt:
				items.append(item(c[0], "cargo", rng.uniform(c[1], c[2]), jid, {"hot": true}))
			var w := Py.sum_by(items, func(i): return i.weight_lb)
			var pay := int((900 + w * 9 + dist * 120) * diff)
			jobs.append(Job.new(jid, "No questions asked -> " + dest.name, "contraband", origin.code, dest.code, items, pay,
				{"notes": "Radar will flag you. Police will chase."}))
		elif shady_origin and roll < 0.45:
			var kg := rng.uniform(65, 105)
			var items := [item("Nervous man", "passenger", kg, jid, {"hot": true}),
				item("Duffel bag", "cargo", rng.uniform(15, 35), jid, {"hot": true})]
			var pay := int((2500 + dist * 180) * diff)
			jobs.append(Job.new(jid, "Fugitive extraction -> " + dest.name, "fugitive", origin.code, dest.code, items, pay,
				{"notes": "Wanted man. Police are already looking."}))
		elif roll < 0.72:
			var cnt := rng.randint(1, 3)
			var items := []
			for k in cnt:
				items.append(item(rng.choice(PASSENGER_NAMES), "passenger", rng.uniform(55, 110), jid))
				if rng.random() < 0.6:
					items.append(item("Luggage", "cargo", rng.uniform(8, 25), jid))
			var comfort := rng.random() < 0.3
			var pay := int((150 + 60 * cnt + dist * 22 * cnt) * diff * (1.4 if comfort else 1.0))
			var title := "%sCharter x%d -> %s" % ["VIP " if comfort else "", cnt, dest.name]
			jobs.append(Job.new(jid, title, "passenger", origin.code, dest.code, items, pay, {"comfort": comfort,
				"notes": "Keep bank under 45 deg and land softly." if comfort else ""}))
		elif roll < 0.85 and dest.kind == "bush":
			var items := [item("Medical kit", "cargo", rng.uniform(10, 30), jid, {"fragile": true})]
			var deadline := 60 * maxf(4.0, dist * 0.55 + 2.5)
			var pay := int((300 + dist * 30) * diff)
			jobs.append(Job.new(jid, "URGENT medical -> " + dest.name, "medical", origin.code, dest.code, items, pay,
				{"deadline_s": deadline, "notes": "Deadline. Fragile."}))
		else:
			var ct: Array = rng.choice(CARGO_TYPES)
			var cnt := rng.randint(1, 4)
			var items := []
			for k in cnt:
				items.append(item(ct[0], "cargo", rng.uniform(ct[1], ct[2]), jid, {"fragile": ct[3]}))
			var w := Py.sum_by(items, func(i): return i.weight_lb)
			var pay := int((120 + w * 1.6 + dist * w * 0.09) * diff * (1.3 if ct[3] else 1.0))
			jobs.append(Job.new(jid, "%s x%d -> %s" % [ct[0], cnt, dest.name], "cargo", origin.code, dest.code, items, pay,
				{"notes": "Fragile." if ct[3] else ""}))
	return jobs
