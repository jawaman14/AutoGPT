// Sky: gradient driven by the sun's height (day blue, dusk gold, night navy),
// sun disc and halo, two drifting cloud layers from the noise pack lit by the
// sun (warm at dusk, grey at night), stars and a moon once the sun is down.
shader_type sky;
render_mode use_debanding;

uniform sampler2D noise_pack : filter_linear_mipmap, repeat_enable;
uniform float coverage = 0.45;
uniform float wind = 1.0;
uniform vec3 moon_dir = vec3(-0.4, 0.5, 0.75);

float stars(vec3 d) {
	vec3 p = floor(d * 400.0);
	float h = fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
	return step(0.9975, h) * (0.5 + 0.5 * fract(h * 97.0));
}

void sky() {
	vec3 d = EYEDIR;
	vec3 sun = normalize(LIGHT0_DIRECTION);
	float sun_h = sun.y;
	float day = smoothstep(-0.18, 0.12, sun_h);
	float dusk = clamp(1.0 - abs(sun_h - 0.02) / 0.22, 0.0, 1.0);
	float up = clamp(d.y, 0.0, 1.0);
	vec3 zen = mix(vec3(0.01, 0.015, 0.05), vec3(0.16, 0.36, 0.72), day);
	vec3 hor = mix(vec3(0.03, 0.05, 0.1), vec3(0.62, 0.76, 0.92), day);
	float toward_sun = pow(max(dot(normalize(vec3(d.x, 0.0, d.z)), normalize(vec3(sun.x, 0.0, sun.z))), 0.0), 3.0);
	hor = mix(hor, vec3(1.0, 0.52, 0.25), dusk * (0.45 + 0.55 * toward_sun));
	vec3 col = mix(hor, zen, pow(up, 0.55));
	if (d.y < 0.0) {
		col = mix(hor, vec3(0.08, 0.12, 0.16) * (0.2 + day), clamp(-d.y * 4.0, 0.0, 1.0));
	}
	// sun
	float sd = dot(d, sun);
	col += LIGHT0_COLOR * (pow(max(sd, 0.0), 900.0) * 30.0 + pow(max(sd, 0.0), 12.0) * 0.35 * (0.3 + dusk)) * step(-0.05, sun_h);
	// night: stars and the moon
	float night = 1.0 - day;
	col += vec3(stars(d)) * night * smoothstep(0.02, 0.2, d.y);
	float md = dot(d, normalize(moon_dir));
	col += vec3(0.9, 0.92, 1.0) * smoothstep(0.9993, 0.9996, md) * night;
	// clouds on a flattened dome
	if (d.y > 0.01) {
		vec2 uv = d.xz / (d.y + 0.12);
		float t = TIME * 0.004 * wind;
		float c1 = texture(noise_pack, uv * 0.08 + vec2(t, t * 0.4)).b;
		float c2 = texture(noise_pack, uv * 0.25 - vec2(t * 1.7, t)).r;
		float dens = smoothstep(1.0 - coverage, 1.0 - coverage + 0.35, c1 * 0.75 + c2 * 0.35);
		vec3 lit = mix(vec3(0.25, 0.27, 0.32), vec3(1.0), day);
		lit = mix(lit, vec3(1.0, 0.62, 0.42), dusk * 0.7);
		float shade = 0.72 + 0.28 * smoothstep(0.3, 0.9, c2);
		col = mix(col, lit * shade, dens * smoothstep(0.01, 0.12, d.y) * 0.9);
	}
	COLOR = col;
}
