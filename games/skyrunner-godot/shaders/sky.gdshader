// Sky: gradient driven by the sun's height (day blue, dusk gold, night navy),
// sun disc and halo, two drifting cloud layers from the noise pack lit by the
// sun (warm at dusk, grey at night), stars and a moon once the sun is down.
shader_type sky;
render_mode use_debanding;

uniform sampler2D noise_pack : filter_linear_mipmap, repeat_enable;
uniform float coverage = 0.45;
uniform float wind = 1.0;
uniform vec3 moon_dir = vec3(-0.4, 0.5, 0.75);
uniform float overcast = 0.0;  // 0 clear .. 1 storm deck
uniform float moon_illum = 0.5;  // 0 new .. 1 full
uniform float flash = 0.0;  // lightning
uniform float vice = 1.0;  // the 1980s-coast grade: saturated blue days, pink-and-violet dusks, violet nights

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
	// the sun parks at -10 deg all night (WorldScene clamps it): the wide vice dusk must end above that
	dusk = mix(dusk, smoothstep(-0.15, -0.03, sun_h) * (1.0 - smoothstep(0.12, 0.32, sun_h)), vice);
	float up = clamp(d.y, 0.0, 1.0);
	vec3 zen = mix(vec3(0.01, 0.015, 0.05), vec3(0.16, 0.36, 0.72), day);
	vec3 hor = mix(vec3(0.03, 0.05, 0.1), vec3(0.62, 0.76, 0.92), day);
	zen = mix(zen, mix(vec3(0.035, 0.01, 0.075), vec3(0.08, 0.4, 0.8), day), vice);  // violet nights, deep-blue days
	hor = mix(hor, mix(vec3(0.07, 0.03, 0.1), vec3(0.6, 0.82, 0.94), day), vice);
	float toward_sun = pow(max(dot(normalize(vec3(d.x, 0.0, d.z)), normalize(vec3(sun.x, 0.0, sun.z))), 0.0), 3.0);
	hor = mix(hor, vec3(1.0, 0.52, 0.25), dusk * (0.45 + 0.55 * toward_sun));
	vec3 col = mix(hor, zen, pow(up, 0.55));
	// the sunset: orange at the sea, magenta above it, violet overhead
	vec3 band = mix(vec3(1.0, 0.45, 0.16), vec3(0.95, 0.22, 0.55), smoothstep(0.0, 0.22, up));
	band = mix(band, vec3(0.32, 0.1, 0.48), smoothstep(0.2, 0.65, up));
	col = mix(col, band, dusk * vice * (0.55 + 0.4 * toward_sun));
	if (d.y < 0.0) {
		col = mix(hor, vec3(0.08, 0.12, 0.16) * (0.2 + day), clamp(-d.y * 4.0, 0.0, 1.0));
	}
	// sun
	float sd = dot(d, sun);
	col += LIGHT0_COLOR * (pow(max(sd, 0.0), 900.0) * 30.0 + pow(max(sd, 0.0), 12.0) * 0.35 * (0.3 + dusk)) * step(-0.05, sun_h);
	// night: stars and the moon
	float night = 1.0 - day;
	col += vec3(stars(d)) * night * smoothstep(0.02, 0.2, d.y);
	vec3 mdir = normalize(moon_dir);
	float md = dot(d, mdir);
	// the phase: the lit disc minus a second disc slid sideways by (1 - illumination)
	vec3 side = normalize(cross(mdir, vec3(0.0, 1.0, 0.0)));
	float shadow = smoothstep(0.9993, 0.9996, dot(d, normalize(mdir + side * 0.03 * (1.0 - moon_illum) * 2.0)));
	float disc = smoothstep(0.9993, 0.9996, md) * (1.0 - shadow * step(moon_illum, 0.97));
	col += vec3(0.9, 0.92, 1.0) * disc * night * (0.25 + 0.75 * moon_illum);
	col += vec3(0.5, 0.55, 0.7) * pow(max(md, 0.0), 60.0) * 0.12 * moon_illum * night;  // moon glow
	// clouds on a flattened dome
	if (d.y > 0.01) {
		vec2 uv = d.xz / (d.y + 0.12);
		float t = TIME * 0.004 * wind;
		float c1 = texture(noise_pack, uv * 0.08 + vec2(t, t * 0.4)).b;
		float c2 = texture(noise_pack, uv * 0.25 - vec2(t * 1.7, t)).r;
		float dens = smoothstep(1.0 - coverage, 1.0 - coverage + 0.35, c1 * 0.75 + c2 * 0.35);
		vec3 lit = mix(vec3(0.25, 0.27, 0.32), vec3(1.0), day) * (1.0 - 0.6 * overcast);
		lit = mix(lit, mix(vec3(1.0, 0.62, 0.42), vec3(1.0, 0.45, 0.62), vice), dusk * 0.8);
		float shade = 0.72 + 0.28 * smoothstep(0.3, 0.9, c2);
		col = mix(col, lit * shade, dens * smoothstep(0.01, 0.12, d.y) * 0.9);
	}
	// the city's glow on the night haze, pink over the sea
	col += vec3(0.28, 0.05, 0.22) * night * vice * pow(1.0 - up, 7.0) * 0.7;
	// under a storm deck the whole sky goes slate grey
	vec3 slate = mix(vec3(0.02, 0.025, 0.03), vec3(0.34, 0.37, 0.4), day);
	col = mix(col, slate, overcast * 0.75);
	col += vec3(0.75, 0.8, 1.0) * flash;
	COLOR = col;
}
