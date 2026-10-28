shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, fog_disabled;
stencil_mode write, compare_always, 1;

// The pixels whose rays may meet a movable ball or cube (tracer.gd, set_head): drawn first
// (render priority -1) over spheres around the shell and around this universe's toys, it sets the
// stencil there. The ray tracer with the toys then runs only there (its stencil test: equal 1),
// the plain one elsewhere (not equal 1). Its colour is drawn over by one of the two.
void fragment() {
	ALBEDO = vec3(0.0);
}
