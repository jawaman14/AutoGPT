// City blocks (MultiMesh of unit boxes). Instance COLOR: rgb = wall colour,
// a = 1 for buildings with windows (0: warehouses, sheds). Windows are a grid
// in world space (3.4 m floors, 3.8 m bays) with a pseudo-random share lit at
// night; roofs are darker and flat.
shader_type spatial;
render_mode cull_back;

uniform float night = 0.0;
uniform sampler2D noise_pack : source_color, filter_linear_mipmap, repeat_enable;

varying vec3 wpos;
varying vec3 wnrm;
varying vec4 icol;
varying float base_y;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	icol = COLOR;
	base_y = (MODEL_MATRIX * vec4(0.0, -0.5, 0.0, 1.0)).y;
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	float wall = 1.0 - step(0.5, abs(wnrm.y));
	float along = abs(wnrm.x) > 0.5 ? wpos.z : wpos.x;
	float up = wpos.y - base_y;
	vec2 cell = vec2(floor(along / 3.8), floor(up / 3.4));
	float fx = fract(along / 3.8);
	float fy = fract(up / 3.4);
	float win = wall * icol.a * step(0.28, fy) * step(fy, 0.78) * step(0.18, fx) * step(fx, 0.78) * step(3.0, up);
	float lit = step(0.7, hash(cell + floor(wpos.xz / 37.0)));
	// far away the grid is smaller than a pixel: blend to its average (no sparkle)
	float fade = smoothstep(0.25, 0.6, max(fwidth(along / 3.8), fwidth(up / 3.4)));
	float win_avg = wall * icol.a * 0.3 * step(3.0, up);
	win = mix(win, win_avg, fade);
	lit = mix(lit, 0.3, fade);
	vec4 n = texture(noise_pack, wpos.xz * 0.05 + wpos.y * 0.03);
	vec3 base = icol.rgb * (0.88 + 0.24 * n.b);
	vec3 roof = icol.rgb * 0.45 + vec3(0.05);
	vec3 col = mix(roof, base, wall);
	col = mix(col, vec3(0.07, 0.09, 0.12), win * 0.9);
	col *= mix(1.0, 0.8, step(up, 3.2) * wall);  // a darker ground-floor band
	ALBEDO = col;
	ROUGHNESS = mix(0.85, 0.15, win);
	METALLIC = 0.0;
	EMISSION = win * lit * night * vec3(1.0, 0.78, 0.48) * mix(2.2, 1.4, fade);
}
