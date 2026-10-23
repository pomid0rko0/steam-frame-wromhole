shader_type spatial;
// Stereo check, drawn by Godot's standard renderer: a green latitude/longitude grid on the
// surface of a ball that the ray tracer draws as a solid red ball at the same place.
render_mode unshaded, cull_back, depth_test_disabled, depth_draw_never, fog_disabled, shadows_disabled;

void fragment() {
	vec2 q = vec2(UV.x * 24.0, UV.y * 12.0);
	vec2 fw = max(fwidth(q), vec2(1e-4));
	vec2 gf = abs(fract(q + 0.5) - 0.5) / fw;
	float a = 1.0 - clamp(min(gf.x, gf.y) - 0.75, 0.0, 1.0);
	if (a < 0.02) discard;
	ALBEDO = vec3(0.0, 1.0, 0.25);
	ALPHA = a;
}
