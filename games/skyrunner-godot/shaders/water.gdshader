// Sea. Two scrolling noise normal layers, Fresnel towards the sky colour, a
// sun glint, and a lighter band in the shallows around the island (distance
// from the island centre stands in for depth, which the compatibility renderer
// can't read from the depth buffer).
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque;

uniform vec3 deep : source_color = vec3(0.05, 0.22, 0.38);
uniform vec3 shallow : source_color = vec3(0.12, 0.45, 0.52);
uniform vec3 sky_tint : source_color = vec3(0.55, 0.72, 0.9);
uniform float anim = 1.0;
uniform float island_r = 15500.0;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float height(vec2 p, float t) {
	return vnoise(p * 0.02 + vec2(t * 0.04, t * 0.025)) * 0.6 + vnoise(p * 0.07 - vec2(t * 0.09, -t * 0.05)) * 0.4;
}

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float t = TIME * anim;
	vec2 p = wpos.xz;
	float e = 1.5;
	float h0 = height(p, t);
	vec3 n_world = normalize(vec3(h0 - height(p + vec2(e, 0.0), t), 1.2, h0 - height(p + vec2(0.0, e), t)));
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);
	float r = length(p);
	float shelf = 1.0 - smoothstep(island_r * 0.9, island_r * 1.35, r);
	vec3 col = mix(deep, shallow, shelf * 0.7);
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	ALBEDO = mix(col, sky_tint, fres * 0.55);
	ROUGHNESS = 0.08;
	METALLIC = 0.0;
	SPECULAR = 0.6;
	ALPHA = 0.9;
}
