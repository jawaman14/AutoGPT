// City blocks (MultiMesh of unit boxes). Instance COLOR: rgb = wall colour,
// a = 1 for buildings with windows (0: warehouses, sheds). Windows are a grid
// in world space (3.4 m floors, 3.8 m bays) with a pseudo-random share lit at
// night; roofs are darker and flat.
//
// The 1980s-coast deco: every building gets a trim colour (white, turquoise
// or flamingo pink, picked from its position) for a band along the roofline
// and, on half the windowed ones, thin "speed line" bands every third floor;
// a third of them carry a neon strip under the roof that glows pink or cyan
// after dark.
shader_type spatial;
render_mode cull_back;

uniform float night = 0.0;
uniform float neon = 1.0;  // 0 turns the neon and the deco trim off
uniform sampler2D noise_pack : source_color, filter_linear_mipmap, repeat_enable;

varying vec3 wpos;
varying vec3 wnrm;
varying vec4 icol;
varying float base_y;
varying float top_y;
varying float bhash;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	icol = COLOR;
	base_y = (MODEL_MATRIX * vec4(0.0, -0.5, 0.0, 1.0)).y;
	top_y = (MODEL_MATRIX * vec4(0.0, 0.5, 0.0, 1.0)).y;
	bhash = hash(MODEL_MATRIX[3].xz * 0.013);
}

void fragment() {
	float wall = 1.0 - step(0.5, abs(wnrm.y));
	float along = abs(wnrm.x) > 0.5 ? wpos.z : wpos.x;
	float up = wpos.y - base_y;
	float below_top = top_y - wpos.y;
	vec2 cell = vec2(floor(along / 3.8), floor(up / 3.4));
	float fx = fract(along / 3.8);
	float fy = fract(up / 3.4);
	float win = wall * icol.a * step(0.28, fy) * step(fy, 0.78) * step(0.18, fx) * step(fx, 0.78) * step(3.0, up) * step(1.2, below_top);
	float lit = step(0.7, hash(cell + floor(wpos.xz / 37.0)));
	// far away the grid is smaller than a pixel: blend to its average (no sparkle)
	float fade = smoothstep(0.25, 0.6, max(fwidth(along / 3.8), fwidth(up / 3.4)));
	float win_avg = wall * icol.a * 0.3 * step(3.0, up);
	win = mix(win, win_avg, fade);
	lit = mix(lit, 0.3, fade);
	vec4 n = texture(noise_pack, wpos.xz * 0.05 + wpos.y * 0.03);
	vec3 base = icol.rgb * (0.9 + 0.2 * n.b);
	vec3 roof = icol.rgb * 0.45 + vec3(0.05);
	vec3 col = mix(roof, base, wall);
	// deco trim: the roofline band, and speed lines every third floor
	float h1 = fract(bhash * 7.13);
	float h2 = fract(bhash * 13.7);
	vec3 trim = h1 < 0.4 ? vec3(0.97, 0.96, 0.93) : (h1 < 0.7 ? vec3(0.3, 0.78, 0.8) : vec3(0.95, 0.42, 0.62));
	float band = wall * step(below_top, 1.1) * step(3.0, up);
	float lines = wall * icol.a * step(h2, 0.5) * step(mod(floor(up / 3.4), 3.0), 0.5) * step(fy, 0.1) * step(3.0, up) * (1.0 - fade);
	col = mix(col, trim, clamp(band + lines, 0.0, 1.0) * neon);
	col = mix(col, vec3(0.07, 0.09, 0.12), win * 0.9);
	col *= mix(1.0, 0.8, step(up, 3.2) * wall);  // a darker ground-floor band
	// the neon strip under the roof
	float has_neon = icol.a * step(0.62, h2) * neon;
	float strip = wall * has_neon * step(1.3, below_top) * step(below_top, 1.62);
	vec3 neon_col = h1 < 0.5 ? vec3(1.0, 0.2, 0.62) : vec3(0.2, 0.9, 1.0);
	col = mix(col, neon_col * 0.7, strip);
	ALBEDO = col;
	ROUGHNESS = mix(0.85, 0.15, win);
	METALLIC = 0.0;
	EMISSION = win * lit * night * vec3(1.0, 0.78, 0.48) * mix(2.2, 1.4, fade) + strip * neon_col * (0.3 + 4.5 * night);
}
