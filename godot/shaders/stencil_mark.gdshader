shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, fog_disabled;
stencil_mode write, compare_always, 1;

// The pixels whose rays may meet a movable ball or cube (main.gd, _update_proxies): drawn first
// (render priority -2) over spheres around the shell and around this universe's toys, it sets the
// stencil to 1 there: the ray tracer with the flat universes' toys runs there (its stencil test:
// equal 1), and where stencil_toys_shell.gdshader then sets 2 the one with all of them; the plain
// one elsewhere (equal 0). Its colour is drawn over by one of them.
void fragment() {
	ALBEDO = vec3(0.0);
}
