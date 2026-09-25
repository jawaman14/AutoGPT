// Sea. Three travelling waves displace a camera-following grid (normals from
// their analytic derivatives), depth comes from the island's heightmap so the
// water turns turquoise over sand, shows the reef edge and foams at the
// shoreline, plus Fresnel sky reflection and a sun glint. Works in Forward+
// and in the compatibility renderer (no depth-buffer reads).
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, specular_schlick_ggx;

uniform sampler2D heightmap : filter_linear;
uniform sampler2D noise_pack : filter_linear_mipmap, repeat_enable;
uniform float map_size = 32000.0;
uniform float amp = 1.0;
uniform float anim = 1.0;
uniform vec3 deep : source_color = vec3(0.02, 0.12, 0.24);
uniform vec3 mid : source_color = vec3(0.03, 0.30, 0.42);
uniform vec3 shallow : source_color = vec3(0.14, 0.62, 0.62);
uniform vec3 sky_tint : source_color = vec3(0.55, 0.72, 0.9);

varying vec3 wpos;
varying float depth;

vec3 wave(vec2 p, vec2 dir, float len, float a, float speed, float t, inout vec3 dn) {
	float k = 6.2831 / len;
	float ph = k * dot(dir, p) - speed * k * t;
	dn.x += dir.x * k * a * cos(ph);
	dn.z += dir.y * k * a * cos(ph);
	return vec3(0.0, a * sin(ph), 0.0);
}

float terrain_h(vec2 xz) {
	vec2 uv = (vec2(xz.x, xz.y) + map_size * 0.5) / map_size;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return -60.0;
	return texture(heightmap, uv).r;
}

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float t = TIME * anim;
	depth = max(0.0, -terrain_h(w.xz));
	// waves die on the beach, and fade with distance so the camera-following sheet meets the far sea seamlessly
	float cam_d = length(w.xz - CAMERA_POSITION_WORLD.xz);
	float a = amp * smoothstep(0.0, 6.0, depth) * (1.0 - smoothstep(1200.0, 2700.0, cam_d));
	vec3 dn = vec3(0.0);
	vec3 d = wave(w.xz, normalize(vec2(1.0, 0.3)), 38.0, 0.45 * a, 5.0, t, dn);
	d += wave(w.xz, normalize(vec2(-0.4, 1.0)), 17.0, 0.22 * a, 3.2, t, dn);
	d += wave(w.xz, normalize(vec2(0.8, -0.7)), 7.0, 0.08 * a, 2.1, t, dn);
	VERTEX.y += d.y;
	NORMAL = normalize(vec3(-dn.x, 1.0, -dn.z));
	wpos = w + d;
}

void fragment() {
	float t = TIME * anim;
	vec2 p = wpos.xz;
	vec4 n1 = texture(noise_pack, p * 0.012 + vec2(t * 0.004, t * 0.002));
	vec4 n2 = texture(noise_pack, p * 0.05 - vec2(t * 0.01, -t * 0.006));
	vec3 ripple = normalize(vec3((n1.r - 0.5) * 0.35 + (n2.b - 0.5) * 0.25, 1.0, (n1.b - 0.5) * 0.35 + (n2.r - 0.5) * 0.25));
	NORMAL = normalize((VIEW_MATRIX * vec4(normalize(ripple + vec3(0.0, 0.0, 0.0)), 0.0)).xyz * 0.5 + NORMAL * 0.5);
	vec3 col = mix(shallow, mid, smoothstep(0.5, 8.0, depth));
	col = mix(col, deep, smoothstep(8.0, 45.0, depth));
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	col = mix(col, sky_tint, fres * 0.45);
	// shoreline and reef-edge foam, broken up by the cellular noise
	float foam_line = 1.0 - smoothstep(0.0, 1.6, depth);
	float breaker = sin(depth * 2.5 - t * 1.6) * 0.5 + 0.5;
	float foam = foam_line * smoothstep(0.35, 0.8, n2.g + breaker * 0.35) * step(0.02, depth);
	col = mix(col, vec3(0.95, 0.97, 1.0), foam);
	ALBEDO = col;
	// far away the sub-pixel waves average out: rougher, dimmer mirror (no white band at the horizon)
	float far = smoothstep(400.0, 6000.0, length(wpos.xz - CAMERA_POSITION_WORLD.xz));
	ROUGHNESS = mix(mix(0.05, 0.6, foam), 0.32, far);
	METALLIC = 0.0;
	SPECULAR = mix(0.6, 0.3, far);
	ALPHA = clamp(mix(0.78, 1.0, smoothstep(0.3, 4.0, depth)) + foam * 0.2, 0.0, 1.0);  // opaque when deep: no double-blend seam with the far sea
}
