shader_type spatial;
// Stereo check, drawn by Godot's standard renderer: green lines along the edges of a cube that
// the ray tracer draws as a solid magenta one, with dark edges, at the same place.
render_mode unshaded, cull_back, depth_test_disabled, depth_draw_never, fog_disabled, shadows_disabled;

uniform float half = 0.3;      // the cube's half size (the mesh is 2 half wide)

varying vec3 v_local;

void vertex() {
	v_local = VERTEX;
}

void fragment() {
	// on a face one coordinate is +-half; the distance to its nearest edge is half minus the
	// larger of the other two
	vec3 a = abs(v_local);
	float mid = a.x + a.y + a.z - max(max(a.x, a.y), a.z) - min(min(a.x, a.y), a.z);
	float d = half - mid;
	float fw = max(fwidth(d), 1e-5);
	float k = 1.0 - clamp(d / fw - 1.5, 0.0, 1.0);
	if (k < 0.02) discard;
	ALBEDO = vec3(0.0, 1.0, 0.25);
	ALPHA = k;
}
