class_name WorldScene
extends Node3D
## The static world shared by the pilot's view and the remote 3D seats: sky,
## sun, fog, terrain, water, trees and airfields at a quality preset (port of
## render/scene.py), plus the graphics overhaul: a day/night cycle driving the
## sun, sky and fog colours, runway/nav lights that come on at dusk, SSAO,
## volumetric fog and glow on the presets that can afford them.

const BOUNCE := Color(0.56, 0.52, 0.45)  ## sunlit ground's bounce light
const DAY_SKY := Color(0.55, 0.72, 0.9)
const NIGHT_SKY := Color(0.04, 0.02, 0.08)  ## violet: the fog and the low preset's sky at night
const DUSK_SKY := Color(0.95, 0.45, 0.5)  ## the pink of a coastal sunset

var quality: Quality
var world: World
var env: Environment
var sun: DirectionalLight3D
var moon: DirectionalLight3D
var sky_mat: ProceduralSkyMaterial
var water: Ocean
var sky_shader: ShaderMaterial
var field_lights: Array = []  ## emissive runway light meshes
## Hour of day, 0-24. Advanced by `time_scale` game-seconds per real second
## (60 = one game hour per real minute); 0 freezes it.
var hour := 14.0
var time_scale := 0.0
var night := 0.0  ## 0 day .. 1 full night, for other nodes (aircraft lights)
var fx: WeatherFX  ## rain, lightning, cloud deck, moon phase (Session.weather)
var ambient_base := 0.7  ## ambient energy before lightning


func setup(world_: World, q: Quality) -> WorldScene:
	world = world_
	quality = q
	name = "WorldScene"
	_build_environment()
	add_child(TerrainMesh.build(world, q))
	water = Ocean.new().setup(world, q)
	add_child(water)
	add_child(Vegetation.build(world, q))
	add_child(CityRender.build(world, q))
	for af in world.airfields:
		var n := Models.build_airfield(world, af, q)
		add_child(n)
		field_lights.append(n.get_node("lights"))
		add_child(Buildings.airfield_site(world, af))
	for k in world.map.hqs:
		add_child(Buildings.hq(world, world.map.hqs[k]))
	if not world.map.foreign.is_empty():
		var isl := IslandRender.build(world, q)  # Isla Soberana, over the horizon
		add_child(isl)
		for af in world.map.foreign:
			var lights = isl.find_child("lights", true, false)
			if lights != null:
				field_lights.append(lights)
	fx = WeatherFX.new().setup(self)
	add_child(fx)
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
		sky_shader = ShaderMaterial.new()
		sky_shader.shader = load("res://shaders/sky.gdshader")
		sky_shader.set_shader_parameter("noise_pack", TexGen.noise_pack())
		var sky := Sky.new()
		sky.sky_material = sky_shader
		sky.radiance_size = Sky.RADIANCE_SIZE_128
		env.background_mode = Environment.BG_SKY
		env.sky = sky
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		# no GI in the compatibility renderer: half the ambient is a warm ground
		# bounce, so shade and interiors aren't tinted pure sky-blue
		env.ambient_light_sky_contribution = 0.5
		env.ambient_light_color = BOUNCE
		env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	else:
		env.background_mode = Environment.BG_COLOR
		env.background_color = DAY_SKY
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.42, 0.45, 0.52)
		env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_ACES if quality.shaded else Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.15 if quality.shaded else 1.0
	env.tonemap_white = 4.0 if quality.shaded else 1.0  # ACES headroom: sunlit walls keep their colour
	if quality.ssao:
		env.ssil_enabled = true  # Forward+: bounce light off the ground and walls
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_depth_begin = quality.fog_far * 0.2
	env.fog_depth_end = quality.fog_far
	env.fog_light_color = DAY_SKY
	env.fog_sky_affect = 0.35
	env.fog_aerial_perspective = 0.5 if quality.sky else 0.0
	if quality.glow:
		env.glow_enabled = true
		env.glow_intensity = 0.75  # neon wants to bleed a little
		env.glow_bloom = 0.08
		env.glow_hdr_threshold = 1.1
	# the grade: a touch more colour and punch (the 1980s-coast look)
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.15
	env.adjustment_contrast = 1.05
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
	var ls := fx.light_scale() if fx != null else 1.0
	var moon_k := (0.15 + 0.85 * fx.moon_illum) if fx != null else 1.0
	sun.light_energy = 1.0 * day * ls
	# the sun stays on (at zero energy) so it is always LIGHT0 for the sky shader:
	# hiding it made the moon LIGHT0 and the night sky rendered as day
	sun.shadow_enabled = quality.shadows and day > 0.01
	sun.light_color = Color(1.0, 0.96, 0.88).lerp(Color(1.0, 0.6, 0.35), dusk)
	moon.light_energy = 0.3 * night * moon_k * ls
	var sky_col := NIGHT_SKY.lerp(DAY_SKY, day).lerp(DUSK_SKY, dusk * 0.45)
	if fx != null:
		sky_col = sky_col.lerp(Color(0.3, 0.33, 0.36) * (0.15 + 0.85 * day), fx.overcast * 0.7)
	env.fog_light_color = sky_col
	if sky_shader != null:
		ambient_base = lerpf(0.4, 0.7, day) * (1.0 - 0.3 * (fx.overcast if fx != null else 0.0))
		env.ambient_light_energy = ambient_base
		env.ambient_light_color = Color(0.1, 0.11, 0.16).lerp(BOUNCE, day)
	else:
		env.background_color = sky_col
		env.ambient_light_color = Color(0.42, 0.45, 0.52).lerp(Color(0.12, 0.14, 0.22), night)
	var lights_on := el < 4.0
	for l in field_lights:
		l.visible = lights_on
	if water != null:
		water.set_sky(sky_col)
	Buildings.set_night(night)
	CityRender.set_night(night)


## Tonight's weather (Session.weather).
func set_weather(w: Dictionary) -> void:
	if fx != null and not w.is_empty():
		fx.apply(w)


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
