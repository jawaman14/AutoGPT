class_name Aircraft
extends RefCounted
## Aircraft roster.
##
## Every flyable aircraft is a stock JSBSim model. The game adds what JSBSim
## does not know about: load stations (seats / cargo bays) in JSBSim
## structural-frame inches, a certified weight & CG envelope, price, and visual
## parameters for the procedural 3D model. Station and envelope numbers are
## loosely based on POH figures, adjusted to each JSBSim model's datum.

const LB_PER_KG := 2.20462


class Station:
	var name: String
	var x_in: float
	var y_in: float
	var z_in: float
	var max_lb: float
	var kind: String  ## pilot | seat | cargo

	func _init(p_name: String, x: float, y: float, z: float, max_lb_: float, kind_: String) -> void:
		name = p_name
		x_in = x
		y_in = y
		z_in = z
		max_lb = max_lb_
		kind = kind_

	func accepts(item_kind: String) -> bool:
		if kind == "pilot":
			return false
		if item_kind == "passenger":
			return kind == "seat"
		return true  # cargo can be strapped into seats too


class Visual:
	var wing: String  ## high | low
	var engines: int
	var length_m: float
	var span_m: float
	var color: Color
	var stripe: Color
	var tricycle := true

	func _init(wing_: String, engines_: int, length_: float, span_: float, color_: Color, stripe_: Color, tricycle_ := true) -> void:
		wing = wing_
		engines = engines_
		length_m = length_
		span_m = span_
		color = color_
		stripe = stripe_
		tricycle = tricycle_


class Spec:
	var key: String
	var jsbsim_model: String
	var name: String
	var price: int
	var mtow_lb: float
	var stations: Array  ## [Station]
	var envelope: Array  ## [[cg_in, weight_lb]], counter-clockwise
	var rotate_kts: float
	var approach_kts: float
	var max_flap_kts: float
	var visual: Visual
	var description := ""
	var ground_roll_m := 180.0  ## landing roll at MTOW, sea level, full flaps
	var gear_limit_fpm := 700.0  ## touchdown sink rate beyond which the gear collapses
	var toe_brake_steering := false  ## JSBSim model has no nosewheel steering

	func _init(d: Dictionary) -> void:
		for k in d:
			set(k, d[k])

	## Rough ground-roll estimate: ~W^2 (energy at a fixed CL) and density altitude.
	func est_landing_roll(weight_lb: float, elev_m: float) -> float:
		return ground_roll_m * (weight_lb / mtow_lb) ** 2 * (1 + 0.12 * elev_m / 1000)

	func pilot_station() -> int:
		for i in stations.size():
			if stations[i].kind == "pilot":
				return i
		return -1

	func seat_count() -> int:
		var n := 0
		for st in stations:
			if st.kind == "seat":
				n += 1
		return n


static func _pairs(prefix: String, x: float, y: float, z: float, max_lb: float, kind: String) -> Array:
	return [Station.new(prefix + " L", x, -y, z, max_lb, kind), Station.new(prefix + " R", x, y, z, max_lb, kind)]


static func _stations(parts: Array) -> Array:
	var out := []
	for p in parts:
		if p is Array:
			out.append_array(p)
		else:
			out.append(p)
	return out


static var ROSTER: Dictionary = _roster()


static func spec(key: String) -> Spec:
	return ROSTER[key]


static func _roster() -> Dictionary:
	var c172p := Spec.new({
		"key": "c172p", "jsbsim_model": "c172p", "name": "Cessna 172P Skyhawk", "price": 0, "mtow_lb": 2400.0,
		"stations": _stations([Station.new("Pilot", 36, -14, 24, 250, "pilot"), Station.new("Co-pilot", 36, 14, 24, 250, "seat"),
			_pairs("Rear", 70, 14, 24, 250, "seat"), Station.new("Baggage A", 95, 0, 24, 120, "cargo"),
			Station.new("Baggage B", 123, 0, 24, 50, "cargo")]),
		"envelope": [[35.0, 1500.0], [47.3, 1500.0], [47.3, 2400.0], [39.5, 2400.0], [35.0, 1950.0]],
		"rotate_kts": 55.0, "approach_kts": 65.0, "max_flap_kts": 85.0,
		"visual": Visual.new("high", 1, 8.3, 11.0, Color(0.93, 0.93, 0.95), Color(0.75, 0.1, 0.1)),
		"description": "The starter. Forgiving, slow, 4 seats, little payload with full tanks.",
		"ground_roll_m": 175.0})
	var c182 := Spec.new({
		"key": "c182", "jsbsim_model": "c182", "name": "Cessna 182 Skylane", "price": 85000, "mtow_lb": 3100.0,
		"stations": _stations([Station.new("Pilot", 36, -14, 24, 250, "pilot"), Station.new("Co-pilot", 36, 14, 24, 250, "seat"),
			_pairs("Rear", 72, 14, 24, 250, "seat"), Station.new("Baggage A", 97, 0, 24, 120, "cargo"),
			Station.new("Baggage B", 116, 0, 24, 80, "cargo")]),
		"envelope": [[33.0, 1700.0], [46.5, 1700.0], [46.5, 3100.0], [40.9, 3100.0], [33.0, 2250.0]],
		"rotate_kts": 55.0, "approach_kts": 70.0, "max_flap_kts": 95.0,
		"visual": Visual.new("high", 1, 8.8, 11.0, Color(0.95, 0.95, 0.9), Color(0.1, 0.25, 0.7)),
		"description": "More power and payload than the 172. Constant-speed prop.",
		"ground_roll_m": 180.0})
	var pa28 := Spec.new({
		"key": "pa28", "jsbsim_model": "pa28", "name": "Piper PA-28 Warrior", "price": 60000, "mtow_lb": 2440.0,
		"stations": _stations([Station.new("Pilot", 80.5, -9.6, 0, 250, "pilot"), Station.new("Co-pilot", 80.5, 9.6, 0, 250, "seat"),
			_pairs("Rear", 118.1, 9.6, 0, 250, "seat"), Station.new("Baggage", 142.8, 0, 0, 200, "cargo")]),
		"envelope": [[83.0, 1650.0], [95.0, 1650.0], [95.0, 2440.0], [88.0, 2440.0], [83.0, 1950.0]],
		"rotate_kts": 60.0, "approach_kts": 70.0, "max_flap_kts": 100.0,
		"visual": Visual.new("low", 1, 7.3, 9.1, Color(0.95, 0.95, 0.95), Color(0.1, 0.45, 0.2)),
		"description": "Low wing: better ground effect float, worse off-strip.",
		"ground_roll_m": 185.0})
	var c310 := Spec.new({
		"key": "c310", "jsbsim_model": "c310", "name": "Cessna 310 (twin)", "price": 240000, "mtow_lb": 5500.0,
		"stations": _stations([Station.new("Nose baggage", -40, 0, 20, 350, "cargo"), Station.new("Pilot", 37, -14, 24, 250, "pilot"),
			Station.new("Co-pilot", 37, 14, 24, 250, "seat"), _pairs("Row 2", 61, 14, 24, 250, "seat"),
			_pairs("Row 3", 85, 14, 24, 250, "seat"), Station.new("Aft baggage", 110, 0, 24, 360, "cargo")]),
		"envelope": [[38.0, 2950.0], [48.5, 2950.0], [48.5, 5500.0], [41.0, 5500.0], [38.0, 4000.0]],
		"rotate_kts": 85.0, "approach_kts": 95.0, "max_flap_kts": 140.0,
		"visual": Visual.new("low", 2, 9.7, 11.3, Color(0.97, 0.97, 0.97), Color(0.6, 0.05, 0.05)),
		"description": "Fast twin with a nose locker. Hungry for runway.",
		"toe_brake_steering": true, "ground_roll_m": 200.0, "gear_limit_fpm": 800.0})
	var dhc6 := Spec.new({
		"key": "dhc6", "jsbsim_model": "DHC6", "name": "DHC-6 Twin Otter", "price": 650000, "mtow_lb": 12500.0,
		"stations": _stations([Station.new("Nose locker", 40, 0, 0, 500, "cargo"), Station.new("Pilot", 93.6, -18.2, 8.4, 250, "pilot"),
			Station.new("Co-pilot", 93.6, 18.2, 8.4, 250, "seat"), _pairs("Row 1", 145, 16, 8, 250, "seat"),
			_pairs("Row 2", 175, 16, 8, 250, "seat"), _pairs("Row 3", 205, 16, 8, 250, "seat"),
			_pairs("Row 4", 235, 16, 8, 250, "seat"), Station.new("Cabin cargo fwd", 160, 0, 0, 1200, "cargo"),
			Station.new("Cabin cargo aft", 265, 0, 0, 1200, "cargo"), Station.new("Aft locker", 330, 0, 10, 500, "cargo")]),
		"envelope": [[206.0, 8000.0], [221.0, 8000.0], [221.0, 12500.0], [208.0, 12500.0]],
		"rotate_kts": 70.0, "approach_kts": 80.0, "max_flap_kts": 120.0,
		"visual": Visual.new("high", 2, 15.8, 19.8, Color(0.95, 0.85, 0.2), Color(0.15, 0.15, 0.15)),
		"description": "STOL workhorse. Two tonnes of payload into a 300 m strip if you get the balance right.",
		"ground_roll_m": 290.0, "gear_limit_fpm": 900.0})
	var r := {}
	for s in [c172p, pa28, c182, c310, dhc6]:
		r[s.key] = s
	return r
