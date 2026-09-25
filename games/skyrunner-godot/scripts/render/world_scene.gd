class_name WorldScene
extends Node3D
## The static world shared by the pilot's view and the remote 3D seats: sky,
## sun, fog, terrain, water, trees and airfields at a quality preset (port of
## render/scene.py), plus the graphics overhaul: a day/night cycle driving the
## sun, sky and fog colours, runway/nav lights that come on at dusk, SSAO,
## volumetric fog and glow on the presets that can afford them.

const DAY_SKY := Color(0.55, 0.72, 0.9)
const NIGHT_SKY := Color(0.02, 0.03, 0.07)
const DUSK_SKY := Color(0.85, 0.5, 0.35)

var quality: Quality
var world: World
var env: Environment
var sun: DirectionalLight3D
var moon: DirectionalLight3D
var sky_mat: ProceduralSkyMaterial
var water: MeshInstance3D
var field_lights: Array = []  ## emissive runway light meshes
## Hour of day, 0-24. Advanced by `time_scale` game-seconds per real second
## (60 = one game hour per real minute); 0 freezes it.
var hour := 14.0
var time_scale := 0.0
var night := 0.0  ## 0 day .. 1 full night, for other nodes (aircraft lights)


func setup(world_: World, q: Quality) -> WorldScene:
	world = world_
	quality = q
	name = "WorldScene"
	_build_environment()
	add_child(Models.build_terrain(world, q))
	water = Models.build_water(q)
	add_child(water)
	add_child(Models.build_trees(world, q))
	for af in world.airfields:
		var n := Models.build_airfield(world, af, q)
		add_child(n)
		field_lights.append(n.get_node("lights"))
	var aer := Models.build_aerostat()
	aer.name = "aerostat"
	aer.position = MeshBuilder.to_godot([SensorNet.AEROSTAT_POS[0], SensorNet.AEROSTAT_POS[1], 2500.0])
	aer.visible = false
	add_child(aer)
	set_hour(hour)
	return self


func _build_environment() -> void:
	env = Environment.new()
	if quality.sky:
		sky_mat = ProceduralSkyMaterial.new()
		sky_mat.sky_curve = 0.12
		sky_mat.ground_curve = 0.05
		var sky := Sky.new()
		sky.sky_material = sky_mat
		env.background_mode = Environment.BG_SKY
		env.sky = sky
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_sky_contribution = 0.7
		env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	else:
		env.background_mode = Environment.BG_COLOR
		env.background_color = DAY_SKY
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.42, 0.45, 0.52)
		env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC if quality.shaded else Environment.TONE_MAPPER_LINEAR
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_depth_begin = quality.fog_far * 0.2
	env.fog_depth_end = quality.fog_far
	env.fog_light_color = DAY_SKY
	env.fog_sky_affect = 0.35
	env.fog_aerial_perspective = 0.5 if quality.sky else 0.0
	if quality.glow:
		env.glow_enabled = true
		env.glow_intensity = 0.6
		env.glow_bloom = 0.05
		env.glow_hdr_threshold = 1.2
	if quality.ssao:  # Forward+ only; ignored by the compatibility renderer
		env.ssao_enabled = true
		env.ssao_radius = 2.0
		env.ssao_intensity = 1.5
	if quality.volumetric_fog:
		env.volumetric_fog_enabled = true
		env.volumetric_fog_density = 0.00012
		env.volumetric_fog_length = 3000.0
		env.volumetric_fog_albedo = Color(0.9, 0.93, 1.0)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.name = "sun"
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.shadow_enabled = quality.shadows
	if quality.shadows:
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		sun.directional_shadow_max_distance = 1500.0
	add_child(sun)
	moon = DirectionalLight3D.new()
	moon.name = "moon"
	moon.light_color = Color(0.55, 0.65, 0.9)
	moon.light_energy = 0.0
	moon.rotation_degrees = Vector3(-40, 150, 0)
	add_child(moon)


## Sun elevation from the hour: a simple tropical day (6:00 sunrise, 18:00 sunset).
static func sun_elevation(h: float) -> float:
	return 75.0 * sin((h - 6.0) / 12.0 * PI)


func set_hour(h: float) -> void:
	hour = fposmod(h, 24.0)
	var el := sun_elevation(hour)
	var az := 90.0 + (hour - 6.0) / 12.0 * 180.0  # east in the morning, west at dusk
	# Godot: rotation.x negative tilts the light down; y is compass (north = -Z)
	sun.rotation_degrees = Vector3(-maxf(el, -10.0), -az + 180.0, 0)
	var day := smoothstep(-10.0, 8.0, el)  # through civil twilight to full day
	var dusk := clampf(1.0 - absf(el - 2.0) / 9.0, 0.0, 1.0)
	night = 1.0 - day
	sun.light_energy = 1.1 * day
	sun.visible = day > 0.01
	sun.light_color = Color(1.0, 0.96, 0.88).lerp(Color(1.0, 0.6, 0.35), dusk)
	moon.light_energy = 0.3 * night
	var sky_col := NIGHT_SKY.lerp(DAY_SKY, day).lerp(DUSK_SKY, dusk * 0.45)
	env.fog_light_color = sky_col
	if sky_mat != null:
		sky_mat.sky_top_color = Color(0.18, 0.36, 0.7).lerp(Color(0.01, 0.015, 0.04), night)
		sky_mat.sky_horizon_color = sky_col
		sky_mat.ground_horizon_color = sky_col.darkened(0.2)
		sky_mat.ground_bottom_color = Color(0.1, 0.14, 0.18).lerp(Color(0.01, 0.01, 0.02), night)
		sky_mat.sun_angle_max = 30.0
		env.ambient_light_energy = lerpf(0.45, 1.0, day)
	else:
		env.background_color = sky_col
		env.ambient_light_color = Color(0.42, 0.45, 0.52).lerp(Color(0.12, 0.14, 0.22), night)
	var lights_on := el < 4.0
	for l in field_lights:
		l.visible = lights_on
	if water != null and water.material_override is ShaderMaterial:
		water.material_override.set_shader_parameter("sky_tint", sky_col)


func _process(dt: float) -> void:
	if time_scale > 0.0:
		set_hour(hour + dt * time_scale / 3600.0)


func show_aerostat(up: bool) -> void:
	get_node("aerostat").visible = up


# ---------------------------------------------------------------- effects
## Dust kicked up by the wheels on unpaved strips (attach to the aircraft, set
## `emitting` from the ground roll speed).
static func make_dust() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "dust"
	p.amount = 64
	p.lifetime = 1.6
	p.emitting = false
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 0.4, 1)
	pm.spread = 35.0
	pm.initial_velocity_min = 2.0
	pm.initial_velocity_max = 6.0
	pm.gravity = Vector3(0, 0.3, 0)
	pm.scale_min = 1.0
	pm.scale_max = 3.0
	pm.color = Color(0.65, 0.55, 0.4, 0.35)
	p.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(1.5, 1.5)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	q.material = m
	p.draw_pass_1 = q
	return p


## White water behind a boat.
static func make_wake() -> GPUParticles3D:
	var p := make_dust()
	p.name = "wake"
	p.amount = 96
	p.lifetime = 3.0
	var pm: ParticleProcessMaterial = p.process_material
	pm.direction = Vector3(0, 0.1, 1)
	pm.spread = 20.0
	pm.gravity = Vector3(0, -0.5, 0)
	pm.color = Color(0.95, 0.97, 1.0, 0.5)
	return p
