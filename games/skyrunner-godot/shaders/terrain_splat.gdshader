// Island terrain (medium/high). Vertex colours carry the biome weights baked
// per vertex by TerrainMesh: r = dry grass (altitude), g = rock (slope/peaks),
// b = shore sand, a = forest floor. Materials are drawn from one tileable
// noise pack (R fine, G cellular, B medium, A grain) with colour ramps, rock is
// triplanar so cliffs don't smear, and a normal pack adds surface relief.
shader_type spatial;
render_mode cull_back;

uniform sampler2D noise_pack : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_pack : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float tile = 0.075;       // 1 / metres per tile
uniform float macro_tile = 0.0012;
uniform vec3 grass_a : source_color = vec3(0.18, 0.30, 0.10);
uniform vec3 grass_b : source_color = vec3(0.33, 0.42, 0.17);
uniform vec3 forest : source_color = vec3(0.11, 0.21, 0.08);
uniform vec3 dry_a : source_color = vec3(0.42, 0.40, 0.22);
uniform vec3 dry_b : source_color = vec3(0.52, 0.47, 0.28);
uniform vec3 rock_a : source_color = vec3(0.34, 0.30, 0.26);
uniform vec3 rock_b : source_color = vec3(0.50, 0.44, 0.37);
uniform vec3 sand_a : source_color = vec3(0.66, 0.58, 0.42);
uniform vec3 sand_b : source_color = vec3(0.76, 0.68, 0.50);
uniform vec3 seabed : source_color = vec3(0.45, 0.47, 0.36);

varying vec3 wpos;
varying vec3 wnrm;
varying vec4 biome;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	biome = COLOR;
	// tangent frame for the normal map (terrain is a height field: x/z axes)
	TANGENT = normalize(cross(NORMAL, vec3(0.0, 0.0, 1.0)));
	BINORMAL = normalize(cross(TANGENT, NORMAL));
}

vec4 tri(vec3 p, vec3 n, float s) {
	vec3 w = pow(abs(n), vec3(4.0));
	w /= (w.x + w.y + w.z);
	return texture(noise_pack, p.zy * s) * w.x + texture(noise_pack, p.xz * s) * w.y + texture(noise_pack, p.xy * s) * w.z;
}

void fragment() {
	vec2 uv = wpos.xz * tile;
	vec4 n = texture(noise_pack, uv);
	vec4 m = texture(noise_pack, wpos.xz * macro_tile);
	vec4 g = texture(noise_pack, wpos.xz * tile * 6.0);
	float dist = length(VERTEX);
	float detail_fade = 1.0 - smoothstep(600.0, 3500.0, dist);

	vec3 grass = mix(grass_a, grass_b, n.r * 0.7 + m.b * 0.6) * (0.85 + 0.25 * g.a * detail_fade);
	grass = mix(grass, forest, clamp(biome.a * 1.2, 0.0, 1.0));
	vec3 dry = mix(dry_a, dry_b, n.b + (g.a - 0.5) * 0.3);
	vec4 tr = tri(wpos, wnrm, tile * 0.6);
	float strata = 0.5 + 0.5 * sin(wpos.y * 0.07 + tr.b * 4.0);
	vec3 rock = mix(rock_a, rock_b, tr.g * 0.7 + strata * 0.2);
	vec3 sand = mix(sand_a, sand_b, n.a * 0.6 + m.r * 0.4);

	// height-blended weights: the noise decides which material wins at a boundary
	float slope = 1.0 - clamp(wnrm.y, 0.0, 1.0);
	float w_rock = clamp(max(biome.g, smoothstep(0.32, 0.55, slope + (n.g - 0.5) * 0.25)), 0.0, 1.0);
	float w_dry = smoothstep(0.3, 0.7, biome.r + (n.b - 0.5) * 0.5);
	float w_sand = smoothstep(0.35, 0.65, biome.b + (n.a - 0.5) * 0.4);
	vec3 col = mix(grass, dry, w_dry);
	col = mix(col, rock, w_rock);
	col = mix(col, sand, w_sand * (1.0 - w_rock));
	float wet = 1.0 - smoothstep(-0.2, 1.4, wpos.y);
	col = mix(col, col * 0.62, wet * step(-1.5, wpos.y));
	col = mix(col, seabed * (0.8 + 0.3 * n.r), step(wpos.y, -1.5));
	col *= 0.82 + 0.3 * m.a;  // macro patches: the island isn't one shade of green
	col = mix(col, col * vec3(1.05, 0.97, 0.85), smoothstep(0.55, 0.8, m.r) * (1.0 - w_rock));

	ALBEDO = col;
	ROUGHNESS = mix(mix(0.92, 0.85, w_rock), 0.3, wet);
	SPECULAR = 0.3;
	NORMAL_MAP = texture(normal_pack, uv * (w_rock > 0.5 ? 0.6 : 1.0)).rgb;
	NORMAL_MAP_DEPTH = mix(0.6, 1.4, w_rock) * detail_fade;
}
