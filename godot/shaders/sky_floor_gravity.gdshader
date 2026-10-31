shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
// The floor and the sky, the floor coloured by gravity (the gravity views: Renderer.set_gravity_view).
#define LK_GRAVITY
#include "res://shaders/sky_floor_view.gdshaderinc"
