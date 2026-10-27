shader_type spatial;
// back faces (toys_view.gdshaderinc); the depth of the hit, tested against the other toys
render_mode unshaded, cull_front, depth_draw_always, skip_vertex_transform, fog_disabled;

// A flat universe's toys seen straight from an eye there (wormhole_toys.gdshaderinc, wht_flat).
// With the gravity view's arrows over them (main.set_gravity_view 2).
#define WHT_FLAT
#define WH_TABLE
#define WH_GRAVITY
#define WH_ARROWS
#include "res://shaders/toys_view.gdshaderinc"
