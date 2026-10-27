shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
// where a ray may meet one of the shell's toys, but none near the eye (stencil 2: main.gd,
// _update_proxies; its material leaves those out of wh_candMask), or the whole view (main.TOYS_WHOLE)
stencil_mode read, compare_equal, 2;

// The ray tracer with movable balls and cubes (wormhole_balls.gdshader) and the floor coloured by gravity (main.set_gravity_view 1).
#define WH_GRAVITY
// The fillet polynomials from a table (main.gd sets it), as the plain ray tracer
#define WH_TABLE
#include "res://shaders/wormhole_view.gdshaderinc"
