shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
// only where the world's ray tracer left the pixel (tracer.gd, «The split»)
stencil_mode read, compare_not_equal, 1;

// The ray tracer with movable balls and cubes (wormhole_balls.gdshader) and the floor coloured by
// gravity (the gravity view "floor": Tracer.GRAVITY_VIEWS).
#define WH_GRAVITY
#include "res://shaders/wormhole_view.gdshaderinc"
