class_name TerrainMesh
extends RefCounted
## The island as 8 x 8 mesh chunks: frustum-culled, with automatic LODs
## (ImporterMesh.generate_lods) and skirts so chunk edges never open cracks at
## different LODs. Each vertex carries biome weights in COLOR for the splat
## shader (dry grass / rock / shore sand / forest floor).

const CHUNKS := 8


static func _weights(world: World, step: int) -> PackedColorArray:
	var h := world.terrain.get_heights()
	var G := World.GRID
	# forest density on a 128 x 128 grid from the tree list
	var fg := 128
	var dens := PackedFloat32Array()
	dens.resize(fg * fg)
	var trees := world.terrain.get_trees()
	for k in trees.size() / 4:
		var i := clampi(int((trees[k * 4] + World.HALF) / World.SIZE_M * fg), 0, fg - 1)
		var j := clampi(int((trees[k * 4 + 1] + World.HALF) / World.SIZE_M * fg), 0, fg - 1)
		dens[j * fg + i] += 1.0
	var out := PackedColorArray()
	for j in range(0, G, step):
		for i in range(0, G, step):
			var z: float = h[j * G + i]
			var gx: float = (h[j * G + mini(i + 1, G - 1)] - h[j * G + maxi(i - 1, 0)]) / (2 * World.CELL)
			var gy: float = (h[mini(j + 1, G - 1) * G + i] - h[maxi(j - 1, 0) * G + i]) / (2 * World.CELL)
			var slope := sqrt(gx * gx + gy * gy)
			var dry := clampf((z - 380) / 500, 0, 1)
			var rock := maxf(clampf((slope - 0.45) / 0.35, 0, 1), clampf((z - 900) / 250, 0, 1))
			var shore := clampf((5.0 - z) / 4.0, 0, 1)
			# bilinear density, so forest edges are soft rather than 250 m squares
			var fx := clampf(float(i) / G * fg - 0.5, 0, fg - 1.001)
			var fy := clampf(float(j) / G * fg - 0.5, 0, fg - 1.001)
			var i0 := int(fx)
			var j0 := int(fy)
			var tx := fx - i0
			var ty := fy - j0
			var i1 := mini(i0 + 1, fg - 1)
			var j1 := mini(j0 + 1, fg - 1)
			var dv: float = lerpf(lerpf(dens[j0 * fg + i0], dens[j0 * fg + i1], tx), lerpf(dens[j1 * fg + i0], dens[j1 * fg + i1], tx), ty)
			var forest := clampf(dv / 6.0, 0, 1)
			out.append(Color(dry, rock, shore, forest))
	return out


## MapCity's land use as an RGBA texture (one texel per terrain cell) for the splat shader.
static func landuse_texture(world: World) -> ImageTexture:
	var G := World.GRID
	var lu := world.map.land_use
	var img := Image.create(G, G, false, Image.FORMAT_RGBA8)
	for j in G:
		for i in G:
			var c: int = lu[j * G + i]
			img.set_pixel(i, j, Color(1.0 if c in [MapCity.URBAN, MapCity.PORT] else 0.0, 1.0 if c == MapCity.FARM else 0.0,
				1.0 if c in [MapCity.MANGROVE, MapCity.SWAMP] else 0.0, 1.0 if c == MapCity.JUNGLE else 0.0))
	return ImageTexture.create_from_image(img)


static func build(world: World, q: Quality) -> Node3D:
	var root := Node3D.new()
	root.name = "terrain"
	var step := q.terrain_step
	var G := World.GRID
	var h := world.terrain.get_heights()
	var n := (G - 1) / step + 1  # vertices per side
	var cols := _weights(world, step) if q.shaded else Models.terrain_colors(world, step)
	var mat: Material
	if q.shaded:
		var sm := ShaderMaterial.new()
		sm.shader = load("res://shaders/terrain_splat.gdshader")
		sm.set_shader_parameter("noise_pack", TexGen.noise_pack())
		sm.set_shader_parameter("normal_pack", TexGen.normal_pack())
		if not world.map.land_use.is_empty():
			sm.set_shader_parameter("landuse", landuse_texture(world))
			sm.set_shader_parameter("has_landuse", 1.0)
			sm.set_shader_parameter("grid_origin", MapCity.CITY_C - MapCity.CITY_R)
		mat = sm
	else:
		mat = Models.vertex_material()
	var per := (n - 1) / CHUNKS  # cells per chunk side
	var cell := World.CELL * step
	for cj in CHUNKS:
		for ci in CHUNKS:
			var verts := PackedVector3Array()
			var nrms := PackedVector3Array()
			var vcol := PackedColorArray()
			var idx := PackedInt32Array()
			var m := per + 1
			for jj in m:
				for ii in m:
					var gi := ci * per + ii
					var gj := cj * per + jj
					var i := gi * step
					var j := gj * step
					var z: float = h[j * G + i]
					verts.append(Vector3(-World.HALF + i * World.CELL, z, -(-World.HALF + j * World.CELL)))
					var zl: float = h[j * G + maxi(i - step, 0)]
					var zr: float = h[j * G + mini(i + step, G - 1)]
					var zd: float = h[maxi(j - step, 0) * G + i]
					var zu: float = h[mini(j + step, G - 1) * G + i]
					nrms.append(Vector3(-(zr - zl) / (2 * cell), 1.0, (zu - zd) / (2 * cell)).normalized())
					vcol.append(cols[gj * n + gi])
			for jj in per:
				for ii in per:
					var a := jj * m + ii
					idx.append_array([a, a + m + 1, a + 1, a, a + m, a + m + 1])
			# skirts: a 25 m curtain under each edge hides LOD cracks between chunks
			var edges := [[], [], [], []]
			for k in m:
				edges[0].append(k)  # south row
				edges[1].append((m - 1) * m + (m - 1 - k))  # north row, reversed
				edges[2].append((m - 1 - k) * m)  # west column, reversed
				edges[3].append(k * m + (m - 1))  # east column
			for e in edges:
				var base := verts.size()
				for vi in e:
					verts.append(verts[vi] - Vector3(0, 25, 0))
					nrms.append(nrms[vi])
					vcol.append(vcol[vi])
				for k in e.size() - 1:
					var t0: int = e[k]
					var t1: int = e[k + 1]
					var b0: int = base + k
					var b1: int = base + k + 1
					idx.append_array([t0, b0, t1, t1, b0, b1, t0, t1, b0, t1, b1, b0])  # both faces
			var arr := []
			arr.resize(Mesh.ARRAY_MAX)
			arr[Mesh.ARRAY_VERTEX] = verts
			arr[Mesh.ARRAY_NORMAL] = nrms
			arr[Mesh.ARRAY_COLOR] = vcol
			arr[Mesh.ARRAY_INDEX] = idx
			var im := ImporterMesh.new()
			im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arr)
			if q.shaded:
				im.generate_lods(25.0, 60.0, [])
			var mi := MeshInstance3D.new()
			mi.name = "chunk_%d_%d" % [ci, cj]
			mi.mesh = im.get_mesh()
			mi.material_override = mat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if q.shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(mi)
	return root
