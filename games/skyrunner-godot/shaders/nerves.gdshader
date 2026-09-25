// Stress on screen: the edges darken and drain of colour (tunnel vision under
// adrenaline), pulsing with the heartbeat. Reads the screen, so it works in
// both renderers.
shader_type canvas_item;

uniform sampler2D screen : hint_screen_texture, filter_linear_mipmap;
uniform float stress = 0.0;  // 0 .. 1
uniform float pulse = 0.0;  // 0 .. 1, spikes on each beat

void fragment() {
	vec4 c = texture(screen, SCREEN_UV);
	vec2 p = (SCREEN_UV - 0.5) * vec2(1.6, 1.0);
	float r = length(p);
	float tunnel = smoothstep(0.35, 0.95, r + 0.12 * pulse) * smoothstep(0.35, 1.0, stress);
	float grey = dot(c.rgb, vec3(0.3, 0.59, 0.11));
	vec3 col = mix(c.rgb, vec3(grey), tunnel * 0.85);
	col *= 1.0 - tunnel * 0.75;
	col = mix(col, col * vec3(1.08, 0.94, 0.94), stress * pulse * 0.3);  // blood in the ears
	COLOR = vec4(col, 1.0);
}
