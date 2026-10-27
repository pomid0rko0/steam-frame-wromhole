shader_type spatial;
// the cells of the view where a toy can be met (toys_view.gdshaderinc), either winding; the depth
// of the hit, tested against the other toys
render_mode unshaded, cull_disabled, depth_draw_always, skip_vertex_transform, fog_disabled;

// The toys a ray meets in and beyond the shell (wormhole_toys.gdshaderinc, wht_shell).
// With the gravity view's arrows over them (main.set_gravity_view 2).
#define WH_TABLE
#define WH_GRAVITY
#define WH_ARROWS
#include "res://shaders/toys_view.gdshaderinc"
