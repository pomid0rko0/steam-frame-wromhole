shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
stencil_mode write, compare_always, 1;

// stencil_mark.gdshader over the whole view: the ray tracer with the toys everywhere (the split
// turned off: the speed check's comparison, Tracer.WHOLE).
void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	ALBEDO = vec3(0.0);
}
