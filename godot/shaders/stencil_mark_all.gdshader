shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
stencil_mode write, compare_always, 1;

// stencil_mark.gdshader over the whole view: the head in the curved region, where no chart maps it
// to the room (stencil_toys.gdshader then marks where the full ray tracer runs), or another
// source's ray tracer timed over the whole view (main.TOYS_BARE: stencil 1 is what those test for).
void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	ALBEDO = vec3(0.0);
}
