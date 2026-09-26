extends TestCase
## Parity with the Python world (seed 7) plus the behavioural checks from
## tests/test_world.py.

var w: World


func before_each() -> void:
	if w == null:
		w = World.new()


func test_island_matches_python() -> void:
	var pts := [[0, 0], [-6500, -1500], [1000, 9000], [-10000, 5500], [5000, 5200], [-12000, -3000],
		[3333.3, -4444.4], [15000, 15000], [-9000, -9500], [8000, 2000]]
	var want_h := [199.65846252441406, 300.70172119140625, 1150.0, 456.0588073730469, 856.1360473632812,
		134.89117431640625, 213.37680053710938, -59.98774719238281, 8.0, 191.661376953125]
	var want_g := [199.65846252441406, 300.701732285796, 1150, 454.93798654835257, 856.1360473632812,
		134.89117431640625, 213.37680053710938, 0.0, 8, 191.661376953125]
	for i in pts.size():
		check_near(w.height(pts[i][0], pts[i][1]), want_h[i], 1e-3, "height %s" % [pts[i]])
		check_near(w.ground(pts[i][0], pts[i][1]), want_g[i], 1e-3, "ground %s" % [pts[i]])
	var want_elev := {"HAR": 8.0, "VAL": 170.5540528331577, "FRM": 300.701732285796, "PNR": 415.5277599691912,
		"EGL": 1150.0, "COV": 3.0, "QRY": 454.93798654835257, "ISL": 12.0}
	for code in want_elev:
		check_near(w.field_elev[code], want_elev[code], 1e-6, "field elevation " + code)


func test_trees_match_python() -> void:
	check_eq(w.tree_count(), 8222, "tree count")
	var trees := w.terrain.get_trees()
	var want := {0: [-4548.37548828125, 2803.35107421875, 969.9747924804688, 13.419588088989258],
		1: [-13069.546875, -1755.08251953125, 164.98287963867188, 12.338679313659668],
		1000: [-5977.875, 3377.7724609375, 970.0, 16.11005973815918],
		8221: [9756.0478515625, 8319.6875, 465.4317626953125, 16.0]}
	for i in want:
		for k in 4:
			check_near(trees[i * 4 + k], want[i][k], 1e-3, "tree %d[%d]" % [i, k])
	var t5 := [trees[20], trees[21], trees[22]]
	check(w.tree_hit(t5[0] + 1, t5[1], t5[2] + 2), "flying into a tree")
	check(not w.tree_hit(0.0, 0.0, 500.0), "clear air")
	check_near(w.obstacle_top(t5[0], t5[1]), 517.8279418945312, 1e-3, "obstacle top at a tree")
	check_near(w.obstacle_top(-6500.0, -1500.0), 300.701732285796, 1e-3, "obstacle top on a runway")


func test_line_of_sight_matches_python() -> void:
	check(not w.line_of_sight([-9000, -9500, 40], [-10000, 5500, 300]), "HAR to QRY blocked")
	check(w.line_of_sight([2500, -3000, 200], [5000, 3000, 600]), "VAL climb-out visible")
	check(not w.line_of_sight([0, -12000, 500], [0, 12000, 500]), "ridge blocks north-south")


# ---- ported from tests/test_world.py
func test_runways_are_flat_dry_and_clear() -> void:
	for af in w.airfields:
		var elev: float = w.airfield_elev(af)
		check(elev > 0, af.code + " above sea")
		for along in [-0.5, -0.25, 0, 0.25, 0.5]:
			for across in [-0.5, 0, 0.5]:
				var x: float = af.x + af.ux * along * af.length + af.uy * across * af.width
				var y: float = af.y + af.uy * along * af.length - af.ux * across * af.width
				check_near(w.ground(x, y), elev, 1e-6 * maxf(1.0, elev), "%s flat at %s,%s" % [af.code, along, across])
				check(not w.tree_hit(x, y, elev + 2), "%s clear at %s,%s" % [af.code, along, across])


## At least one end must be landable: a 4 deg path from 1.5 km out clears terrain.
func test_every_strip_has_an_open_approach() -> void:
	for af in w.airfields:
		var elev: float = w.airfield_elev(af)
		var any_ok := false
		for end in [0, 1]:
			var t: Array = af.threshold(end)
			var s := -1.0 if end == 0 else 1.0
			var clear := true
			for d in range(150, 1500, 50):
				if not (w.ground(t[0] + s * af.ux * d, t[1] + s * af.uy * d) < elev + d * tan(deg_to_rad(4)) - 5):
					clear = false
					break
			any_ok = any_ok or clear
		check(any_ok, af.code)


func test_special_strips() -> void:
	var egl := World.airfield("EGL")  # plateau: cliff edges
	check(w.height(egl.x + egl.uy * 300, egl.y - egl.ux * 300) < w.airfield_elev(egl) - 200, "EGL cliff")
	var qry := World.airfield("QRY")  # trench: walls beside the strip
	check(w.height(qry.x + qry.uy * 50, qry.y - qry.ux * 50) > w.airfield_elev(qry) + 30, "QRY walls")
	var pnr := World.airfield("PNR")  # one-way: terrain rises steeply past the far end
	var f: Array = pnr.threshold(1)
	check(w.ground(f[0] + pnr.ux * 600, f[1] + pnr.uy * 600) > w.airfield_elev(pnr) + 200, "PNR rising ground")


func test_line_of_sight_blocked_by_ridge() -> void:
	check(w.line_of_sight([0, -3000, 1500], [0, 12000, 1500]))
	check(not w.line_of_sight([0, -3000, 200], [0, 12000, 200]))


func test_nearest_airfield() -> void:
	var r := w.nearest_airfield(-6400, -1500)
	check_eq(r[0].code, "FRM")
	check_near(r[1], 100.0, 1e-9)


func test_world_is_shared_per_seed() -> void:
	var t0 := Time.get_ticks_msec()
	var w2 := World.new()
	check(w2.terrain == w.terrain, "same terrain object")
	check(Time.get_ticks_msec() - t0 < 50, "no regeneration")
