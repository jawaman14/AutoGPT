class_name WeatherFX
extends Node3D
## Tonight's weather on screen (Session.weather): cloud cover and a storm deck
## in the sky shader, the moon's phase, rain streaks that follow the camera and
## lean with the wind, lightning, bigger seas, fog closing in under the storm.
## WorldScene owns it and folds `overcast` / `moon_illum` into its lighting.

var scene: WorldScene
var rain: GPUParticles3D
var sky := "clear"
var wind_kt := 8.0
var wind_dir := 250.0
var overcast := 0.0  ## 0 clear .. 1 storm deck (dims the sun, greys the fog)
var moon_illum := 0.5
var _flash := 0.0
var _next_flash := 8.0
var _rng := RandomNumberGenerator.new()


func setup(scene_: WorldScene) -> WeatherFX:
	scene = scene_
	name = "weather"
	_rng.seed = 7
	rain = GPUParticles3D.new()
	rain.name = "rain"
	rain.amount = 5000 if scene.quality.shaded else 1500
	rain.lifetime = 1.4
	rain.preprocess = 1.4
	rain.visibility_aabb = AABB(Vector3(-60, -60, -60), Vector3(120, 120, 120))
	rain.local_coords = false
	rain.emitting = false
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(45, 1, 45)
	pm.direction = Vector3(0, -1, 0)
	pm.spread = 2.0
	pm.initial_velocity_min = 24.0
	pm.initial_velocity_max = 30.0
	pm.gravity = Vector3.ZERO
	rain.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.025, 0.9)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.75, 0.8, 0.88, 0.35)
	m.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	m.billboard_keep_scale = true
	q.material = m
	rain.draw_pass_1 = q
	add_child(rain)
	return self


func apply(w: Dictionary) -> void:
	sky = w.get("sky", "clear")
	wind_kt = float(w.get("wind_kt", 8))
	wind_dir = float(w.get("wind_dir", 250))
	moon_illum = float(w.get("moon", 0.5))
	overcast = {"clear": 0.0, "cloud": 0.45, "storm": 1.0}.get(sky, 0.0)
	rain.emitting = sky == "storm"
	var pm: ParticleProcessMaterial = rain.process_material
	# rain leans downwind: the wind blows *from* wind_dir
	var toward := deg_to_rad(wind_dir + 180.0)
	var wv := Vector3(sin(toward), 0, -cos(toward)) * wind_kt * 0.514
	pm.direction = (Vector3(0, -27, 0) + wv).normalized()
	var sh := scene.sky_shader
	if sh != null:
		sh.set_shader_parameter("coverage", {"clear": 0.35, "cloud": 0.68, "storm": 0.97}.get(sky, 0.35))
		sh.set_shader_parameter("overcast", overcast)
		sh.set_shader_parameter("wind", 0.6 + wind_kt / 12.0)
		sh.set_shader_parameter("moon_illum", moon_illum)
	if scene.water != null:
		var amp := 0.6 + wind_kt / 18.0
		scene.water.mat.set_shader_parameter("amp", amp)
	var env := scene.env
	var far: float = scene.quality.fog_far
	env.fog_depth_end = far * (1.0 - 0.8 * overcast)
	env.fog_depth_begin = env.fog_depth_end * (0.2 - 0.15 * overcast)
	scene.set_hour(scene.hour)


func light_scale() -> float:
	return 1.0 - 0.6 * overcast


func _process(dt: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam != null and rain.emitting:
		rain.global_position = cam.global_position + Vector3(0, 22, 0)
	if sky != "storm":
		return
	# lightning: a sheet flash every so often, brighter at night
	_next_flash -= dt
	if _next_flash <= 0.0:
		_flash = 1.0
		_next_flash = _rng.randf_range(5.0, 18.0)
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - dt * 6.0)
		var f := _flash * (0.6 + 0.4 * sin(_flash * 40.0))
		if scene.sky_shader != null:
			scene.sky_shader.set_shader_parameter("flash", f)
		scene.env.ambient_light_energy = scene.ambient_base + f * 1.5
