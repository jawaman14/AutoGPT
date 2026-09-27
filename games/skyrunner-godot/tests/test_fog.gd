extends TestCase
## Sea fog on calm nights (its own stream, seed + 137; live play asks for it):
## the crews' eyes shorten, the helicopters stay on the ground in thick fog,
## the radar doesn't care. And the town's side-street junctions get their
## traffic lights.


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func test_explicit_fog_blinds_the_crews_and_grounds_the_helis() -> void:
	var s := Session.new({"seed": 3})
	s.set_weather({"sky": "clear", "wind_kt": 4, "moon": 0.5})
	var clear_vis: float = s.police.visibility
	s.set_weather({"sky": "clear", "wind_kt": 4, "moon": 0.5, "fog": 0.9})
	check_near(s.police.visibility, clear_vis * (1.0 - 0.65 * 0.9), 1e-6, "eyes at 41% in thick fog")
	check(s.police.heli_grounded, "helis grounded above 75%")
	check_eq(s.police.launch("heli"), "Fog: the helicopters are grounded.")
	s.set_weather({"sky": "clear", "wind_kt": 4, "fog": 0.5})
	check(not s.police.heli_grounded, "a thin fog: they fly")
	s.set_weather({"sky": "clear", "wind_kt": 4})
	check_eq(float(s.weather["fog"]), 0.0, "no fog unless someone rolls it")
	check_near(s.police.visibility, clear_vis, 1e-6, "clear again")
	s.dispose()


func test_fog_is_opt_in_and_only_on_calm_dry_nights() -> void:
	var foggy := 0
	for seed in 40:
		var off := Session.new({"seed": seed})
		off.set_weather({"sky": "clear", "wind_kt": 4})
		check_eq(float(off.weather["fog"]), 0.0, "never without the option")
		off.dispose()
		var on := Session.new({"seed": seed, "fog": true})
		on.set_weather({"sky": "clear", "wind_kt": 4})
		var f := float(on.weather["fog"])
		if f > 0.0:
			foggy += 1
			check(f >= 0.4 and f <= 0.95, "density in range (%.2f)" % f)
		on.set_weather({"sky": "storm", "wind_kt": 30})
		check_eq(float(on.weather["fog"]), 0.0, "a storm blows it away")
		on.set_weather({"sky": "clear", "wind_kt": 18})
		check_eq(float(on.weather["fog"]), 0.0, "so does a breeze")
		on.dispose()
	check(foggy >= 4 and foggy <= 24, "about three calm nights in ten (%d/40)" % foggy)


func test_the_same_seed_brings_the_same_fog() -> void:
	var a := Session.new({"seed": 11, "fog": true})
	var b := Session.new({"seed": 11, "fog": true})
	for i in 10:
		a.set_weather({"sky": "clear", "wind_kt": 3})
		b.set_weather({"sky": "clear", "wind_kt": 3})
		check_eq(a.weather["fog"], b.weather["fog"])
	a.dispose()
	b.dispose()


func test_the_scene_closes_in() -> void:
	var s := Session.new({"seed": 1, "map_seed": MapCity.SEED, "location": "HAR"})
	var scene := WorldScene.new()
	_tree().root.add_child(scene)
	scene.setup(s.world, Quality.get_preset("low"))
	scene.set_weather({"sky": "clear", "wind_kt": 4, "fog": 0.8})
	check_eq(scene.env.fog_mode, Environment.FOG_MODE_EXPONENTIAL, "a wall, not haze")
	var vis := 3.0 / scene.env.fog_density
	check(vis > 500.0 and vis < 900.0, "you can see about 700 m (%d)" % int(vis))
	check(scene.env.fog_light_color.s < 0.25, "pale grey, not sky blue")
	scene.set_weather({"sky": "clear", "wind_kt": 4})
	check_eq(scene.env.fog_mode, Environment.FOG_MODE_DEPTH, "clear night: back to distance haze")
	scene.queue_free()
	s.dispose()


func test_side_street_junctions_have_lights() -> void:
	var s := Session.new({"seed": 1, "map_seed": MapCity.SEED, "location": "HAR"})
	var city := CityRender.build(s.world, Quality.get_preset("low"))
	var lights: MultiMeshInstance3D = city.get_node("street-props").get_node("trafficlight_A")
	check(lights.multimesh.instance_count >= 20, "lights at the arterials and every third side street (%d)" % lights.multimesh.instance_count)
	city.free()
	s.dispose()
