shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
// where no movable ball or cube can be seen (stencil_mark.gdshader)
stencil_mode read, compare_not_equal, 1;

// The gravity view "floor and arrows" (Tracer.GRAVITY_VIEWS): wormhole_gravity.gdshader and arrows of
// the field (wormhole_core.gdshaderinc, WH_ARROWS).
#define WH_NO_BALLS
#define WH_GRAVITY
#define WH_ARROWS
#include "res://shaders/frag/wormhole_view.gdshaderinc"
