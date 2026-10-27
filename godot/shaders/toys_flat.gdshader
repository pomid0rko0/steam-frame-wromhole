shader_type spatial;
// back faces (toys_view.gdshaderinc); the depth of the hit, tested against the other toys
render_mode unshaded, cull_front, depth_draw_always, skip_vertex_transform, fog_disabled;

// A flat universe's toys seen straight from an eye there (wormhole_toys.gdshaderinc, wht_flat).
#define WHT_FLAT
#define WH_TABLE
#include "res://shaders/toys_view.gdshaderinc"
