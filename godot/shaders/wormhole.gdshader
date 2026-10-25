shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
// where no movable ball or cube can be seen (stencil_mark.gdshader)
stencil_mode read, compare_not_equal, 1;

// The ray tracer for scenes without movable balls (wh_nBall = 0): the balls' code is left out.
// It needs registers even where no ray runs it, and the GPU then runs fewer pixels at once.
#define WH_NO_BALLS
// The fillet polynomials from a table (main.gd sets it), not worked out per ray.
#define WH_TABLE
#include "res://shaders/wormhole_view.gdshaderinc"
