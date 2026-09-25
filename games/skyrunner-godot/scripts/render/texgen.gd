class_name TexGen
extends RefCounted
## Procedural textures, built once at start-up from FastNoiseLite (C++), so the
## game still needs no art files.
##
##   noise_pack()   RGBA seamless noise: R fine Perlin, G cellular (stones,
##                  cracks), B medium Perlin, A value-cubic grain. Shaders turn
##                  channels into grass, rock, sand, asphalt... with colour ramps.
##   normal_pack()  a tangent-space normal map from the same noise (bump -> normal)
##   heightmap()    the island's heights as a float texture, so the water shader
##                  knows the depth (shallows, shoreline foam) in any renderer

const SIZE := 256

static var _cache := {}


static func _noise(kind: int, freq: float, seed: int, fractal := FastNoiseLite.FRACTAL_FBM, octaves := 4) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = kind
	n.frequency = freq
	n.seed = seed
	n.fractal_type = fractal
	n.fractal_octaves = octaves
	return n


static func noise_pack() -> ImageTexture:
	if _cache.has("noise"):
		return _cache["noise"]
	var chans := [
		_noise(FastNoiseLite.TYPE_PERLIN, 0.06, 11).get_seamless_image(SIZE, SIZE),
		_cellular().get_seamless_image(SIZE, SIZE),
		_noise(FastNoiseLite.TYPE_PERLIN, 0.015, 23).get_seamless_image(SIZE, SIZE),
		_noise(FastNoiseLite.TYPE_VALUE_CUBIC, 0.25, 31, FastNoiseLite.FRACTAL_NONE).get_seamless_image(SIZE, SIZE),
	]
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	for y in SIZE:
		for x in SIZE:
			img.set_pixel(x, y, Color(chans[0].get_pixel(x, y).r, chans[1].get_pixel(x, y).r,
				chans[2].get_pixel(x, y).r, chans[3].get_pixel(x, y).r))
	img.generate_mipmaps()
	var t := ImageTexture.create_from_image(img)
	_cache["noise"] = t
	return t


static func _cellular() -> FastNoiseLite:
	var n := _noise(FastNoiseLite.TYPE_CELLULAR, 0.05, 17, FastNoiseLite.FRACTAL_NONE)
	n.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
	return n


static func normal_pack() -> ImageTexture:
	if _cache.has("normal"):
		return _cache["normal"]
	var bump := _noise(FastNoiseLite.TYPE_PERLIN, 0.06, 11).get_seamless_image(SIZE, SIZE)
	var cell := _cellular().get_seamless_image(SIZE, SIZE)
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	for y in SIZE:
		for x in SIZE:
			var v: float = bump.get_pixel(x, y).r * 0.6 + cell.get_pixel(x, y).r * 0.4
			img.set_pixel(x, y, Color(v, v, v))
	img.bump_map_to_normal_map(3.0)
	img.generate_mipmaps()
	var t := ImageTexture.create_from_image(img)
	_cache["normal"] = t
	return t


## Heights (m) as a half-float texture over the whole map, x east -> u, y north -> v up.
static func heightmap(world: World) -> ImageTexture:
	var key := "h/%s" % world.map.id
	if _cache.has(key):
		return _cache[key]
	var h := world.terrain.get_heights()
	var G := World.GRID
	var img := Image.create(G, G, false, Image.FORMAT_RH)  # half float: linear filtering works in GLES3 too
	for j in G:
		for i in G:
			img.set_pixel(i, G - 1 - j, Color(h[j * G + i], 0, 0))
	var t := ImageTexture.create_from_image(img)
	_cache[key] = t
	return t
