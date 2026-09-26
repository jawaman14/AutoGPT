extends TestCase
## Ported from tests/test_loadout.py


func test_envelope_helpers() -> void:
	var env: Array = Aircraft.spec("c172p").envelope
	check(Loadout.point_in_polygon(42.0, 2000, env))
	check(not Loadout.point_in_polygon(36.0, 2300, env), "forward limit rises with weight")
	var lim := Loadout.cg_limits_at(2400, env)
	check_near(lim[0], 39.5, 1e-9)
	check_near(lim[1], 47.3, 1e-9)


## The load planner's numbers must agree with what JSBSim actually flies.
func test_prediction_matches_jsbsim() -> void:
	for key in Aircraft.ROSTER:
		var spec := Aircraft.spec(key)
		var md := T.masses(key)
		var lo := Loadout.new(spec, md, md.fuel_capacity_lb() * 0.4)
		var n := 0
		for st in spec.stations.size():
			if spec.stations[st].kind == "pilot":
				continue
			var item := Loadout.Item.new(n, "box", "cargo", 20 + 7 * n, 1)
			lo.add(item)
			lo.assignment[item.id] = st
			n += 1
		var fm := FlightModel.new(spec, MassData.patched_root(), md)
		fm.spawn(0, 0, 0, 0, lo)
		var s := fm.step(0.05, T.flat)
		var wb := lo.compute()
		check_near(s.weight_lb, wb.weight_lb, 8, key + " weight")  # fuel burn during the step
		check_near(s.cg_in, wb.cg_in, 0.2, key + " cg")


func test_default_empty_load_is_legal() -> void:
	for key in Aircraft.ROSTER:
		var md := T.masses(key)
		var lo := Loadout.new(Aircraft.spec(key), md, md.fuel_capacity_lb() * 0.5)
		check(lo.compute().ok(), key)


func test_auto_balance_fixes_a_tail_heavy_load() -> void:
	var lo := Loadout.new(Aircraft.spec("c172p"), T.masses("c172p"), 150)
	for it in [Loadout.Item.new(1, "Crate", "cargo", 110, 1), Loadout.Item.new(2, "Bag", "cargo", 45, 1),
			Loadout.Item.new(3, "Pax", "passenger", 190, 1)]:
		lo.add(it)
	lo.assignment = {1: 4, 2: 5, 3: 2}  # everything aft
	check(not lo.compute().in_envelope, "tail heavy")
	check(lo.auto_balance(), "all placed")
	check(lo.compute().ok(), "balanced")


func test_one_passenger_per_seat() -> void:
	var lo := Loadout.new(Aircraft.spec("c172p"), T.masses("c172p"), 150)
	var a := Loadout.Item.new(1, "A", "passenger", 170, 1)
	var b := Loadout.Item.new(2, "B", "passenger", 170, 1)
	lo.add(a)
	lo.add(b)
	lo.assignment[a.id] = 1
	check(not lo.can_place(b, 1))
	check(not lo.can_place(b, 4), "passengers don't ride in the baggage bay")
	check(lo.can_place(b, 2))
