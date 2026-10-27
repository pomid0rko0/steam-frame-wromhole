shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
stencil_mode write, compare_always, 3;

// stencil_toys.gdshader for the shell's toys near the eye (render priority -1, after it): the
// pixels whose rays point into one's cone and whose plane passes within its reach. The ray tracer
// that looks for all the toys runs there.
#define WH_MARK
#define WH_MARK_NEAR
#include "res://shaders/wormhole_view.gdshaderinc"
