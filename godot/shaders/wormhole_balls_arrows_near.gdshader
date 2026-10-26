shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
// where a ray may meet one of the shell's toys near the eye (stencil 3: main.gd, _update_proxies): the
// same ray tracer, its material looking for all of them (wh_candMask)
stencil_mode read, compare_equal, 3;

// The ray tracer with movable balls and cubes (wormhole_balls.gdshader) and the floor coloured by gravity and the arrows of its field (main.set_gravity_view 2).
#define WH_GRAVITY
#define WH_ARROWS
// The fillet polynomials from a table (main.gd sets it), as the plain ray tracer
#define WH_TABLE
#include "res://shaders/wormhole_view.gdshaderinc"
