shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, fog_disabled;
stencil_mode write, compare_always, 3;

// stencil_toys_near.gdshader drawn over the sphere round the shell, the head in a flat universe.
#define WH_MARK
#define WH_MARK_MESH
#define WH_MARK_NEAR
#include "res://shaders/wormhole_view.gdshaderinc"
