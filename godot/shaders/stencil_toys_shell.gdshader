shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, fog_disabled;
stencil_mode write, compare_always, 2;

// stencil_toys.gdshader drawn over the sphere round the shell, the head in a flat universe
// (main.gd, _update_proxies; after stencil_mark.gdshader): of the pixels whose rays go into the
// shell, those that may meet one of its toys (but those near the eye).
#define WH_MARK
#define WH_MARK_MESH
#include "res://shaders/wormhole_view.gdshaderinc"
