class_name MeshBuilder
extends RefCounted
## Flat-shaded triangle soup in *game* coordinates (x east, y north, z up),
## emitted as one Godot ArrayMesh (x, z, -y). Port of render/models.py MeshBuilder.
##
## Game models follow the Python convention: +Y forward, +Z up. Godot's forward
## is -Z, so a model built here faces Node3D.forward with rotation 0.

var v := PackedVector3Array()
var n := PackedVector3Array()
var c := PackedColorArray()


static func to_godot(p) -> Vector3:
	return Vector3(p[0], p[2], -p[1])


func tri(a, b, cc, color) -> void:
	var A := to_godot(a)
	var B := to_godot(b)
	var C := to_godot(cc)
	# The axis swap is a proper rotation (det +1), so the Python models' counter-
	# clockwise faces stay counter-clockwise; Godot's front faces are clockwise,
	# hence A, C, B below. The outward normal is unchanged: (B - A) x (C - A).
	var nrm := (B - A).cross(C - A)
	nrm = nrm.normalized() if nrm.length() > 1e-9 else Vector3.UP
	var col := Color(color[0], color[1], color[2], color[3] if color.size() > 3 else 1.0)
	for p in [A, C, B]:
		v.append(p)
		n.append(nrm)
		c.append(col)


func quad(a, b, cc, d, color) -> void:
	tri(a, b, cc, color)
	tri(a, cc, d, color)


## 8 corners: bottom (-x-y, +x-y, +x+y, -x+y) then top in the same order.
func hexa(p: Array, color) -> void:
	quad(p[0], p[3], p[2], p[1], color)
	quad(p[4], p[5], p[6], p[7], color)
	quad(p[0], p[1], p[5], p[4], color)
	quad(p[1], p[2], p[6], p[5], color)
	quad(p[2], p[3], p[7], p[6], color)
	quad(p[3], p[0], p[4], p[7], color)


func box(cx: float, cy: float, cz: float, sx: float, sy: float, sz: float, color) -> void:
	frustum(cy - sy / 2, cy + sy / 2, [cx, cz, sx / 2, sz / 2], [cx, cz, sx / 2, sz / 2], color)


## Box-like section along Y from y0 to y1; each section = [cx, cz, half_w, half_h].
func frustum(y0: float, y1: float, s0: Array, s1: Array, color) -> void:
	var x0: float = s0[0]; var z0: float = s0[1]; var w0: float = s0[2]; var h0: float = s0[3]
	var x1: float = s1[0]; var z1: float = s1[1]; var w1: float = s1[2]; var h1: float = s1[3]
	hexa([[x0 - w0, y0, z0 - h0], [x0 + w0, y0, z0 - h0], [x1 + w1, y1, z1 - h1], [x1 - w1, y1, z1 - h1],
		[x0 - w0, y0, z0 + h0], [x0 + w0, y0, z0 + h0], [x1 + w1, y1, z1 + h1], [x1 - w1, y1, z1 + h1]], color)


func cone(x: float, y: float, z0: float, radius: float, height: float, color, segments := 6) -> void:
	var top := [x, y, z0 + height]
	for k in segments:
		var a0 := TAU * k / segments
		var a1 := TAU * (k + 1) / segments
		tri([x + radius * cos(a0), y + radius * sin(a0), z0], [x + radius * cos(a1), y + radius * sin(a1), z0], top, color)


func cylinder(x: float, y: float, z0: float, radius: float, height: float, color, segments := 10) -> void:
	for k in segments:
		var a0 := TAU * k / segments
		var a1 := TAU * (k + 1) / segments
		var p0 := [x + radius * cos(a0), y + radius * sin(a0)]
		var p1 := [x + radius * cos(a1), y + radius * sin(a1)]
		quad([p0[0], p0[1], z0], [p1[0], p1[1], z0], [p1[0], p1[1], z0 + height], [p0[0], p0[1], z0 + height], color)


func is_empty() -> bool:
	return v.is_empty()


func mesh() -> ArrayMesh:
	var am := ArrayMesh.new()
	if v.is_empty():
		return am
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = n
	arr[Mesh.ARRAY_COLOR] = c
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am


## A MeshInstance3D with a vertex-colour material.
func node(name := "mesh", material: Material = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = mesh()
	mi.material_override = material if material != null else Models.vertex_material()
	return mi
