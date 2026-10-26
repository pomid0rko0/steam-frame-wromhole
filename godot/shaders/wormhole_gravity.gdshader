shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
// where no movable ball or cube can be seen (stencil 0: main.gd, _update_proxies)
stencil_mode read, compare_equal, 0;

// The gravity view's floor (main.set_gravity_view 1): the plain ray tracer (no movable balls, the
// fillet table) with the floor coloured by the strength of gravity. A shader of its own, as is the
// one with the arrows (wormhole_arrows.gdshader): code needs registers even where no pixel runs
// it, and the GPU then runs fewer pixels at once.
#define WH_NO_BALLS
#define WH_TABLE
#define WH_GRAVITY
#include "res://shaders/wormhole_view.gdshaderinc"
