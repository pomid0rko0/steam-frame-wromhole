shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;

// The ray tracer with movable balls and cubes (wormhole_balls.gdshader) and the floor coloured by gravity and the arrows of its field (main.set_gravity_view 2).
#define WH_GRAVITY
#define WH_ARROWS
#include "res://shaders/wormhole_view.gdshaderinc"
