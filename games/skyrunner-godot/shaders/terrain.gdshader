// Island terrain, medium/high presets. The vertex colours carry the
// height/slope splat baked by Models.terrain_colors (grass -> dry grass ->
// rock -> sand -> seabed); this adds what a 62 m vertex grid can't: per-pixel
// rock on steep faces, two octaves of detail noise, macro colour variation and
// a wet band at the shoreline.
shader_type spatial;
render_mode cull_back;

uniform float detail_scale = 0.045;   // 1 / (detail tile metres)
uniform float macro_scale = 0.0011;
uniform vec3 rock_color : source_color = vec3(0.45, 0.42, 0.40);
uniform vec3 wet_sand : source_color = vec3(0.58, 0.52, 0.36);

varying vec3 wpos;
varying vec3 wnrm;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 base = COLOR.rgb;
	float slope = 1.0 - clamp(wnrm.y, 0.0, 1.0);
	float d1 = vnoise(wpos.xz * detail_scale);
	float d2 = vnoise(wpos.xz * detail_scale * 4.3 + 17.0);
	float macro = vnoise(wpos.xz * macro_scale);
	float rock = smoothstep(0.30, 0.55, slope + (d1 - 0.5) * 0.15);
	vec3 col = mix(base, rock_color * (0.85 + 0.3 * d2), rock * step(0.0, wpos.y));
	col *= 0.86 + 0.18 * d1 + 0.08 * d2;
	col *= 0.93 + 0.14 * macro;
	float wet = 1.0 - smoothstep(0.0, 1.8, wpos.y);
	col = mix(col, wet_sand, wet * step(-2.0, wpos.y) * 0.6);
	ALBEDO = col;
	ROUGHNESS = mix(0.95, 0.7, rock) - wet * 0.35;
	SPECULAR = 0.25;
}
