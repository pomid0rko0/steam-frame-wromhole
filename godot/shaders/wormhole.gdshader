shader_type spatial;
// the depth test on: the GPU skips it where a movable object's pass has drawn (wormhole_view)
render_mode unshaded, cull_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;

// The ray tracer of the world: the space, the floor and the static objects. The movable balls and
// cubes are drawn before it by passes of their own (toys_flat.gdshader, toys_shell.gdshader).
// The fillet polynomials from a table (main.gd sets it), not worked out per ray.
#define WH_TABLE
#include "res://shaders/wormhole_view.gdshaderinc"
