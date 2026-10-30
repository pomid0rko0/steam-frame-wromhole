shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, fog_disabled;
stencil_mode write, compare_always, 1;

// The pixels whose rays may meet a movable ball or cube: it sets the stencil there (how and why:
// tracer.gd, «The stencil split», set_head). Its colour is drawn over by one of the ray tracers.
void fragment() {
	ALBEDO = vec3(0.0);
}
