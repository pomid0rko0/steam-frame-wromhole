shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
// only where a movable ball or cube may be seen (stencil_mark.gdshader)
stencil_mode read, compare_equal, 1;

// The ray tracer with movable balls and cubes (wormhole_balls.gdshader) and the floor coloured by
// gravity (main.set_gravity_view 1).
#define WH_GRAVITY
#include "res://shaders/wormhole_view.gdshaderinc"
