extends TestCase
## The ported core against numbers printed by the Python game
## (tools/reference/gen_core.py -> tests/fixtures/core_ref.json).

var ref: Dictionary


func before_each() -> void:
	if ref.is_empty():
		ref = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/core_ref.json"))


func test_mass_data_matches() -> void:
	for key in ref.mass:
		var md := MassData.read(Aircraft.spec(key).jsbsim_model)
		var want: Array = ref.mass[key]
		check_near(md.empty_lb, want[0], 1e-9, key + " empty")
		check_near(md.empty_cg_x_in, want[1], 1e-9, key + " cg")
		check_eq(md.tanks.size(), want[2].size(), key + " tanks")
		for i in mini(md.tanks.size(), want[2].size()):
			check_near(md.tanks[i][0], want[2][i][0], 1e-9, key + " tank x")
			check_near(md.tanks[i][1], want[2][i][1], 1e-9, key + " tank cap")
		check_near(md.gear_height_ft, want[3], 1e-9, key + " gear height")


func test_auto_balance_matches() -> void:
	var spec := Aircraft.spec("c172p")
	var lo := Loadout.new(spec, MassData.read("c172p"), 200.0, true)
	var defs := [[170, "passenger"], [60, "cargo"], [45, "cargo"], [150, "passenger"], [30, "cargo"]]
	for i in defs.size():
		lo.add(Loadout.Item.new(100 + i, "x%d" % i, defs[i][1], defs[i][0], 1))
	var ok := lo.auto_balance()
	var wb := lo.compute()
	check_eq(ok, ref.lo.ok, "all placed")
	for k in ref.lo.assign:
		check_eq(lo.assignment.get(int(k)), int(ref.lo.assign[k]), "item %s station" % k)
	check_eq(lo.assignment.keys(), ref.lo.assign.keys().map(func(k): return int(k)), "assignment order")
	check_near(wb.weight_lb, ref.lo.w, 1e-9, "weight")
	check_near(wb.cg_in, ref.lo.cg, 1e-12, "cg")
	check_eq(wb.in_envelope, ref.lo.env, "envelope")
	check_near(wb.fwd_limit_in, ref.lo.fwd, 1e-12)
	check_near(wb.aft_limit_in, ref.lo.aft, 1e-12)


func test_job_boards_match_seed_for_seed() -> void:
	Jobs._next_id = 1
	var rng := PyRandom.new()
	rng.seed(42)
	for code in ["FRM", "HAR", "QRY"]:
		var js := Jobs.generate(World.airfield(code), World.AIRFIELDS, rng, 6,
			{"contraband": true, "airdrop": true, "ferry": true}, func(): return [1000.0, -15000.0])
		var want: Array = ref.boards[code]
		check_eq(js.size(), want.size(), code + " board size")
		for i in mini(js.size(), want.size()):
			var j: Jobs.Job = js[i]
			var w: Array = want[i]
			check_eq([j.id, j.title, j.kind, j.dest, j.payout], [int(w[0]), w[1], w[2], w[3], int(w[4])], "%s job %d" % [code, i])
			check_eq(j.items.size(), w[5].size(), "%s job %d items" % [code, i])
			for k in mini(j.items.size(), w[5].size()):
				var it: Loadout.Item = j.items[k]
				check_eq([it.id, it.label, it.hot], [int(w[5][k][0]), w[5][k][1], w[5][k][3]])
				check_eq(it.weight_lb, float(w[5][k][2]), "weight %s" % it.label)


func test_patched_aircraft_flies_like_python() -> void:
	var spec := Aircraft.spec("c172p")
	var md := MassData.read("c172p")
	var w := World.new()
	var lo := Loadout.new(spec, md, md.fuel_capacity_lb() * 0.6)
	var fm := FlightModel.new(spec, MassData.patched_root(), md)
	var af := World.airfield("HAR")
	var back := af.length / 2 - 25
	fm.spawn(af.x - af.ux * back, af.y - af.uy * back, af.heading, w.airfield_elev(af), lo)
	fm.controls.brake = 1.0
	fm.step(0.5, w.ground)
	fm.controls.brake = 0.0
	fm.controls.throttle = 1.0
	var st: FlightModel.FlightState
	for i in 300:
		st = fm.step(1.0 / 30, w.ground)
	var want: Array = ref.fm
	var got := [st.x, st.y, st.alt, st.gs_kts, st.heading, st.fuel_lb, st.weight_lb, st.cg_in]
	var names := ["x", "y", "alt", "gs", "heading", "fuel", "weight", "cg"]
	for i in got.size():
		check_near(got[i], want[i], absf(want[i]) * 1e-12 + 1e-9, "take-off roll " + names[i])
	check_eq(fm.n_gear, int(want[8]), "gear units")
	check_eq(fm.n_engines, int(want[9]), "engines")
