shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
stencil_mode write, compare_always, 2;

// The whole view for the ray tracer with all the toys (main.TOYS_WHOLE: the speed check times it
// so, to see what the split saves).
void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	ALBEDO = vec3(0.0);
}
