extends SceneTree
## Build the city map once and print its layout, timings and land-use census.
func _init():
	var t0 := Time.get_ticks_msec()
	World.use_map(MapCity.SEED)
	var t1 := Time.get_ticks_msec()
	var w := World.new()
	var t2 := Time.get_ticks_msec()
	print("layout %d ms, world %d ms" % [t1 - t0, t2 - t1])
	print(w.map.describe())
	var census := {}
	for c in w.map.land_use:
		census[MapCity.CLASS_NAMES[c]] = census.get(MapCity.CLASS_NAMES[c], 0) + 1
	print("land use: ", census)
	print("trees+obstacles %d, buildings %d" % [w.tree_count(), w.map.buildings.size()])
	for af in w.airfields:
		print("%s elev %.1f approach %s" % [af.code, w.airfield_elev(af), MapGen._clear_approach(w.terrain, af.x, af.y, af.ux, af.uy, af.length, w.airfield_elev(af))])
	for st in w.map.stashes:
		var af := World.airfield(st.strip)
		print("stash %-10s ground %.1f  %s  %.1f km from %s" % [st.id, w.ground(st.x, st.y), MapCity.CLASS_NAMES[MapCity.at(w.map.land_use, st.x, st.y)], PyMath.hypot(st.x - af.x, st.y - af.y) / 1000, st.strip])
	for k in w.map.hqs:
		print(k, " ground %.1f" % w.ground(w.map.hqs[k].x, w.map.hqs[k].y))
	var out := OS.get_environment("CITY_PNG")
	if out != "":
		Models.minimap_image(w, 1024).save_png(out)
		print("saved ", out)
	quit()
