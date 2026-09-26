class_name Ocean
extends Node3D
## The sea: a finely subdivided sheet that follows the camera (snapped to its
## own grid spacing so the waves don't swim) plus a coarse far plane out to
## the horizon, both using shaders/ocean.gdshader.

const NEAR_SIZE := 6000.0
const NEAR_SUB := 300
var near: MeshInstance3D
var far: MeshInstance3D
var mat: ShaderMaterial
var cam: Camera3D


func setup(world: World, q: Quality) -> Ocean:
	name = "ocean"
	mat = ShaderMaterial.new()
	mat.shader = load("res://shaders/ocean.gdshader")
	mat.set_shader_parameter("heightmap", TexGen.heightmap(world))
	mat.set_shader_parameter("noise_pack", TexGen.noise_pack())
	mat.set_shader_parameter("anim", 1.0 if q.water_anim else 0.0)
	near = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(NEAR_SIZE, NEAR_SIZE)
	pm.subdivide_width = NEAR_SUB
	pm.subdivide_depth = NEAR_SUB
	near.mesh = pm
	near.material_override = mat
	near.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(near)
	# the far sea: a ring made of a big plane with the near sheet's square cut out is
	# overkill - a slightly lower plane under the near one never shows through it
	far = MeshInstance3D.new()
	var fm := PlaneMesh.new()
	fm.size = Vector2(120000, 120000)
	fm.subdivide_width = 60
	fm.subdivide_depth = 60
	far.mesh = fm
	var fmat: ShaderMaterial = mat.duplicate()
	fmat.set_shader_parameter("amp", 0.0)
	far.material_override = fmat
	far.position.y = -0.35
	far.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(far)
	return self


func set_sky(col: Color) -> void:
	mat.set_shader_parameter("sky_tint", col)
	far.material_override.set_shader_parameter("sky_tint", col)


func _process(_dt: float) -> void:
	var c := get_viewport().get_camera_3d()
	if c == null:
		return
	var step := NEAR_SIZE / NEAR_SUB
	near.global_position = Vector3(snappedf(c.global_position.x, step), 0.0, snappedf(c.global_position.z, step))
	far.global_position = Vector3(snappedf(c.global_position.x, 200.0), -0.35, snappedf(c.global_position.z, 200.0))
