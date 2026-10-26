shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
// where a ray may meet a flat universe's toy but none of the shell's (stencil 1: main.gd, _update_proxies)
stencil_mode read, compare_equal, 1;

// wormhole_balls_gravity.gdshader with the toys of the flat universes only (wormhole_balls_flat.gdshader).
#define WH_FLAT_TOYS
#define WH_GRAVITY
#define WH_TABLE
#include "res://shaders/wormhole_view.gdshaderinc"
