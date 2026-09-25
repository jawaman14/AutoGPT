// Trees and bushes (MultiMesh). Vertex colour: rgb = base colour (instance
// colour tints it), a = sway weight (0 at the root, 1 at leaf tips). The wind
// bends each instance on its own phase so the forest doesn't pulse in step.
shader_type spatial;
render_mode cull_disabled;

uniform float wind = 1.0;
uniform float sway = 0.35;
varying float leafy;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float ph = dot(origin.xz, vec2(0.013, 0.021));
	float w = COLOR.a;
	float s = sin(TIME * 1.4 * wind + ph) * 0.6 + sin(TIME * 2.9 * wind + ph * 1.7) * 0.25;
	VERTEX.x += s * sway * w * w;
	VERTEX.z += s * sway * 0.5 * w * w;
	leafy = w;
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = mix(0.95, 0.75, leafy);
	SPECULAR = 0.2;
	BACKLIGHT = vec3(0.25, 0.35, 0.1) * leafy;  // light through leaves (Forward+)
}
