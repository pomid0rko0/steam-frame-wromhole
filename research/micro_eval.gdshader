shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
uniform sampler2DArray pt_path : filter_linear, repeat_disable;
uniform vec4 cb = vec4(1.0, 0.5, 0.2, 0.125);
uniform float perp2 = 0.01;
varying vec4 v_ray;
void vertex() { POSITION = vec4(VERTEX.xy, 1.0, 1.0); v_ray = vec4(VERTEX.xy, 0.3, 0.7); }
void fragment() {
	float rowv = v_ray.x * 0.5 + 0.5;
	float s = v_ray.y * 0.01;
	float layer = float(VIEW_INDEX);
	for (int k = 0; k < 9; k++) {
		float c = sqrt(clamp(s * 0.125, 0.0, 1.0));
		vec3 q = textureLod(pt_path, vec3(c * 0.99609375 + 0.001953125, rowv, layer), 0.0).xyz;
		vec3 a = q - cb.xyz;
		float d = sqrt(dot(a, a) + perp2) - cb.w;
		s += d;
	}
	ALBEDO = vec3(s);
}
