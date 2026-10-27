shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;

// The gravity view with arrows (main.set_gravity_view 2): wormhole_gravity.gdshader and arrows of
// the field on the vertical surface through the wormhole that faces the start (x = 0).
#define WH_TABLE
#define WH_GRAVITY
#define WH_ARROWS
#include "res://shaders/wormhole_view.gdshaderinc"
