shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
// where a ray may meet one of the shell's toys near the eye (stencil 3: main.gd, _update_proxies): the
// same ray tracer, its material looking for all of them (wh_candMask)
stencil_mode read, compare_equal, 3;

// The ray tracer with movable balls (wh_ball, wh_ballCol, wh_nBall) and cubes (wh_cube, wh_cubeE,
// wh_cubeCol, wh_nCube).
// The fillet polynomials from a table (main.gd sets it), as the plain ray tracer
#define WH_TABLE
// each ray leaves out the near toys whose cone or box it misses (main._update_near)
#define WH_NEAR_CULL
#include "res://shaders/wormhole_view.gdshaderinc"
