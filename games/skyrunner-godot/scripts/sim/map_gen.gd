class_name MapGen
extends RefCounted
## Generative islands. A map seed grows an island (land lobes, a mountain spine,
## offshore islets) and sites every strip by its role, so the jobs and the
## cartel war have the geography they need:
##
##   HAR  hub, long asphalt on the south-west coast (the task force's base)
##   VAL  regional, inland lowlands
##   FRM  farm grass strip, western plains           \  west zone: short hauls,
##   QRY  quarry pit strip in the western hills       |  the cartel's contested
##   MSN  mission strip, western foothills  (new)    /   interior
##   EGL  mesa-top dirt strip on the highest ground  \
##   PNR  one-way ridge strip in the north-east       |  north zone: hard strips,
##   ISL  islet strip offshore to the north-east     /   the best pay
##   COV  beach strip in a south-east cove           \  sea zone: airdrops,
##   LGN  lagoon beach strip on the far coast (new)  /   the cartel's home turf
##
## Each strip is scored on flatness, spacing and an open 4-degree approach from
## at least one end, then re-checked on the final terrain. The organisation's
## villa, the task-force HQ and the cartel's compound are sited on gentle
## ground near the strips they work from (`site_hqs`, also used by the classic
## island).

const EXTRA_NAMES := {
	"MSN": ["Mission Hill", "San Rafael Mission", "Padre's Field"],
	"LGN": ["Lagoon Flats", "Mangrove Bar", "Punta Arena"],
}


static func _clear_approach(t: Terrain, x: float, y: float, ux: float, uy: float, length: float, elev: float) -> bool:
	for end in [0, 1]:
		var s := -1.0 if end == 0 else 1.0
		var tx := x + s * ux * length / 2
		var ty := y + s * uy * length / 2
		var ok := true
		for d in range(150, 1500, 50):
			if not (t.height64(tx + s * ux * d, ty + s * uy * d) < elev + d * tan(deg_to_rad(4.0)) - 5):
				ok = false
				break
		if ok:
			return true
	return false


## [score, heading] for a strip at (x, y); score < 0 = unusable.
static func _rate(t: Terrain, x: float, y: float, length: float, width: float, setting: String, min_elev: float,
		elev_override = null, headings: Array = []) -> Array:
	var best := [-1.0, 0.0]
	for hi in 18:
		var hdg := hi * 10.0
		if not headings.is_empty() and not (hdg in headings):
			continue
		var ux := sin(deg_to_rad(hdg))
		var uy := cos(deg_to_rad(hdg))
		var lo := 1e9
		var hi_h := -1e9
		var a := -length / 2 - 60
		while a <= length / 2 + 60:
			for c in [-width / 2, 0.0, width / 2]:
				var z := t.height64(x + ux * a + uy * c, y + uy * a - ux * c)
				lo = minf(lo, z)
				hi_h = maxf(hi_h, z)
			a += 40.0
		if lo < min_elev:
			continue
		var elev: float = elev_override if elev_override != null else t.height64(x, y)
		if not _clear_approach(t, x, y, ux, uy, length, elev):
			continue
		# plateau/pit/beach strips are reshaped by the generator; flat ones must be nearly level already
		var rough: float = (hi_h - lo) * (0.15 if setting in ["plateau", "pit", "beach"] else 1.0)
		var score := 1000.0 / (10.0 + rough)
		if score > best[0]:
			best = [score, hdg]
	return best


static func _polar(cx: float, cy: float, ang_deg: float, r: float) -> Array:
	return [cx + r * sin(deg_to_rad(ang_deg)), cy + r * cos(deg_to_rad(ang_deg))]


## Pick a site inside a sector around the island centre.
static func _site(t: Terrain, rng: PyRandom, placed: Array, centre: Array, sector: Array, radius: Array,
		elev_band: Array, length: float, width: float, setting: String, min_elev := 1.5, tries := 260) -> Array:
	var best := [-1.0, 0.0, 0.0, 0.0]
	for i in tries:
		var p := _polar(centre[0], centre[1], rng.uniform(sector[0], sector[1]), rng.uniform(radius[0], radius[1]))
		var z := t.height64(p[0], p[1])
		if z < elev_band[0] or z > elev_band[1]:
			continue
		if Py.any(placed, func(a): return PyMath.hypot(a.x - p[0], a.y - p[1]) < 3200):
			continue
		var r := _rate(t, p[0], p[1], length, width, setting, min_elev, z if setting == "plateau" else null)
		if r[0] > best[0]:
			best = [r[0], p[0], p[1], r[1]]
	return best


static func _params(rng: PyRandom) -> Dictionary:
	var cx := rng.uniform(-1200, 1200)
	var cy := rng.uniform(-1200, 1200)
	var lobes := [[cx, cy, rng.uniform(11500, 13500), rng.uniform(10500, 12500)]]
	for i in rng.randint(1, 3):  # peninsulas
		var ang := rng.uniform(0, 360)
		var d := rng.uniform(7000, 10000)
		var p := _polar(cx, cy, ang, d)
		lobes.append([p[0], p[1], rng.uniform(3500, 6000), rng.uniform(3500, 6000)])
	# the mountain spine across the northern half, and a lower spur
	var a0 := rng.uniform(-110, -70)
	var a1 := rng.uniform(70, 110)
	var mid := _polar(cx, cy, rng.uniform(-20, 20), rng.uniform(4000, 6500))
	var p0 := _polar(mid[0], mid[1], a0, rng.uniform(7000, 10000))
	var p1 := _polar(mid[0], mid[1], a1, rng.uniform(7000, 10000))
	var ridges := [[p0[0], p0[1], mid[0], mid[1], rng.uniform(2400, 3200), rng.uniform(1050, 1350)],
		[mid[0], mid[1], p1[0], p1[1], rng.uniform(2400, 3200), rng.uniform(900, 1250)]]
	var spur := _polar(cx, cy, rng.uniform(-150, -120), rng.uniform(4000, 7000))
	ridges.append([mid[0], mid[1], spur[0], spur[1], rng.uniform(1800, 2600), rng.uniform(450, 700)])
	# islets: one to the north-east (ISL), others anywhere
	var islets := []
	var ne := _polar(cx, cy, rng.uniform(30, 60), rng.uniform(15500, 17500))
	islets.append([clampf(ne[0], -14800, 14800), clampf(ne[1], -14800, 14800), 1500.0, 9.0])  # low: the strip's own bump lifts it
	for i in rng.randint(0, 2):
		var q := _polar(cx, cy, rng.uniform(0, 360), rng.uniform(15000, 17500))
		islets.append([clampf(q[0], -14800, 14800), clampf(q[1], -14800, 14800), rng.uniform(700, 1200), rng.uniform(15, 40)])
	return {"lobes": lobes, "ridges": ridges, "islets": islets, "base": rng.uniform(0.85, 1.15), "centre": [cx, cy]}


## Grow an island for `map_seed` and site its strips. Deterministic.
static func generate(map_seed: int) -> MapLayout:
	var rng := PyRandom.new()
	rng.seed(map_seed)
	var l := MapLayout.new()
	l.id = "gen-%d" % map_seed
	l.map_seed = map_seed
	l.terrain_seed = 1000 + map_seed
	var params := _params(rng)
	var c: Array = params["centre"]
	var base := Terrain.new()
	base.generate_custom(l.terrain_seed, params, [])
	var placed := []
	var add := func(code: String, name: String, site: Array, length: float, width: float, elev, surface: String,
			kind: String, opts := {}) -> Airfield:
		var af := Airfield.new(code, name, site[1], site[2], site[3], length, width, elev, surface, kind, opts)
		placed.append(af)
		return af
	var s: Array
	# the hub: long, low, coastal, south-west
	s = _site(base, rng, placed, c, [200, 250], [7000, 12500], [2, 30], 1800, 45, "flat")
	add.call("HAR", "Port Harbor Intl", s, 1800, 45, 8.0, "asphalt", "hub", {"shop": true, "police": true, "radar_km": 22.0})
	s = _site(base, rng, placed, c, [120, 200], [1500, 7000], [40, 280], 1000, 30, "flat")
	add.call("VAL", "Valley Regional", s, 1000, 30, null, "asphalt", "regional", {"shop": true, "police": true, "radar_km": 12.0})
	s = _site(base, rng, placed, c, [245, 300], [3500, 9000], [30, 350], 480, 20, "flat")
	add.call("FRM", "Miller's Farm", s, 480, 20, null, "grass", "bush")
	s = _site(base, rng, placed, c, [285, 330], [6000, 11500], [200, 700], 240, 12, "pit")
	add.call("QRY", "Old Quarry", s, 240, 12, null, "dirt", "shady", {"setting": "pit", "haul_road": 0})
	s = _site(base, rng, placed, c, [320, 400], [3000, 9000], [850, 1500], 280, 14, "plateau", 200)
	var egl_elev := base.height64(s[1], s[2])
	add.call("EGL", "Eagle's Nest", s, 280, 14, snappedf(egl_elev, 1.0), "dirt", "bush", {"setting": "plateau"})
	s = _site(base, rng, placed, c, [20, 75], [5000, 11500], [250, 750], 380, 15, "flat")
	add.call("PNR", "Pine Ridge", s, 380, 15, null, "gravel", "bush", {"tree_lines": true})
	s = _site(base, rng, placed, c, [100, 160], [9000, 14000], [0.5, 20], 320, 18, "beach", 0.5)
	add.call("COV", "Smuggler's Cove", s, 320, 18, 3.0, "sand", "shady", {"setting": "beach"})
	var isl: Array = params["islets"][0]
	var r := _rate(base, isl[0], isl[1], 550, 20, "flat", -200.0, 12.0)
	# islet strips face the prevailing wind off the island when no heading scores
	var isl_hdg: float = r[1] if r[0] > 0 else fposmod(rad_to_deg(atan2(isl[0] - c[0], isl[1] - c[1])), 180.0)
	add.call("ISL", "Isla Verde", [0, isl[0], isl[1], isl_hdg], 550, 20, 12.0, "grass", "regional")
	s = _site(base, rng, placed, c, [255, 285], [2500, 7000], [120, 500], 420, 18, "flat")
	add.call("MSN", rng.choice(EXTRA_NAMES["MSN"]), s, 420, 18, null, "grass", "bush")
	s = _site(base, rng, placed, c, [45, 110], [8000, 14000], [0.5, 20], 360, 18, "beach", 0.5)
	add.call("LGN", rng.choice(EXTRA_NAMES["LGN"]), s, 360, 18, 3.0, "sand", "shady", {"setting": "beach"})
	# a strip the sampler couldn't place falls back next to the island centre rather than failing the map
	for af in placed:
		if af.x == 0 and af.y == 0 and af.code != "ISL":
			af.x = c[0] + rng.uniform(-3000, 3000)
			af.y = c[1] + rng.uniform(-3000, 3000)
	l.airfields = placed
	l.params = params
	l.zone_fields = {"west": ["QRY", "FRM", "MSN"], "north": ["EGL", "PNR", "ISL"], "sea": ["COV", "LGN"]}
	var zc := {}
	for z in l.zone_fields:
		var xs := 0.0
		var ys := 0.0
		for code in l.zone_fields[z]:
			xs += l.airfield(code).x
			ys += l.airfield(code).y
		zc[z] = [xs / l.zone_fields[z].size(), ys / l.zone_fields[z].size()]
	# the sea zone's centre is the offshore rendezvous water beyond the cove
	var cov := l.airfield("COV")
	var out := Vector2(cov.x - c[0], cov.y - c[1]).normalized()
	zc["sea"] = [clampf(cov.x + out.x * 3500, -15000, 15000), clampf(cov.y + out.y * 3500, -15000, 15000)]
	l.zone_centre = zc
	# the aerostat moors off the south coast, between the hub and the cove
	var har := l.airfield("HAR")
	var mid := Vector2((har.x + cov.x) / 2, (har.y + cov.y) / 2)
	var south := (mid - Vector2(c[0], c[1])).normalized()
	var aer := mid + south * 4000
	l.aerostat_pos = [clampf(aer.x, -15500, 15500), clampf(aer.y, -15500, 15500)]
	return l


## Gentle, dry ground within `r` of a point, closest to `pref` from it.
static func _pad(w: World, near: Array, r_min: float, r_max: float, elev_min := 4.0, avoid: Array = []) -> Array:
	var best := [1e18, near[0], near[1]]
	var found := false
	for ri in range(int(r_min), int(r_max), 60):
		for k in 24:
			var ang := TAU * k / 24
			var x: float = near[0] + ri * cos(ang)
			var y: float = near[1] + ri * sin(ang)
			var z := w.ground(x, y)
			if z < elev_min or w.airfield_at(x, y, 60) != null:
				continue
			if Py.any(avoid, func(p): return PyMath.hypot(p[0] - x, p[1] - y) < 120):
				continue
			var slope := 0.0
			for d in [[40, 0], [-40, 0], [0, 40], [0, -40]]:
				slope = maxf(slope, absf(w.ground(x + d[0], y + d[1]) - z))
			if w.tree_hit(x, y, z + 3, 25.0):
				slope += 6.0
			var score := slope * 1000.0 + ri
			if score < best[0]:
				best = [score, x, y]
				found = true
	if not found and r_max < 6000:
		return _pad(w, near, r_max, r_max * 2.5, elev_min, avoid)
	return [best[1], best[2]]


## Site the three headquarters on the current terrain (classic or generated).
static func site_hqs(w: World, l: MapLayout) -> Dictionary:
	var har := l.airfield("HAR")
	var cov := l.airfield("COV")
	# task force: beside the hub's terminal, across the runway from the hangars
	var law := [har.x + har.ux * har.length * 0.15 - har.uy * (har.width / 2 + 150),
		har.y + har.uy * har.length * 0.15 + har.ux * (har.width / 2 + 150)]
	law = _pad(w, law, 0, 1200, 3.0)
	# the organisation: a villa on the hill behind the cove
	var org := _pad(w, [cov.x, cov.y], 250, 900, 6.0)  # a short walk from the cove strip
	# the cartel: a compound near its home strip (the lagoon, or the far coast on the classic island)
	var home := l.airfield("LGN")
	var rival_near: Array = [home.x, home.y] if home != null else [l.zone_centre["north"][0] + 6000, l.zone_centre["north"][1] - 9000]
	var rival := _pad(w, rival_near, 400 if home != null else 0, 2500, 6.0, [org, law])
	var face := func(p: Array, target: Array) -> float:
		return fposmod(rad_to_deg(atan2(target[0] - p[0], target[1] - p[1])), 360.0)
	return {
		"org": {"kind": "org", "name": "The Villa", "x": org[0], "y": org[1], "heading": face.call(org, [cov.x, cov.y]), "zone": "sea"},
		"law": {"kind": "law", "name": "Task Force HQ", "x": law[0], "y": law[1], "heading": face.call(law, [har.x, har.y]), "zone": "west"},
		"rival": {"kind": "rival", "name": "Los Cuervos compound", "x": rival[0], "y": rival[1],
			"heading": face.call(rival, rival_near), "zone": "sea"},
	}
