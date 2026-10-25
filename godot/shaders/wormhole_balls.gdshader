shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
// only where a movable ball or cube may be seen (stencil_mark.gdshader)
stencil_mode read, compare_equal, 1;

// The ray tracer with movable balls (wh_ball, wh_ballCol, wh_nBall) and cubes (wh_cube, wh_cubeE,
// wh_cubeCol, wh_nCube).
// The fillet polynomials from a table (main.gd sets it), as the plain ray tracer
#define WH_TABLE
#include "res://shaders/wormhole_view.gdshaderinc"
