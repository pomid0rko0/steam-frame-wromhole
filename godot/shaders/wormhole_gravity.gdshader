shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;

// The gravity view "floor" (Tracer.GRAVITY_VIEWS): the ray tracer without movable balls and cubes,
// the floor coloured by the strength of gravity (tracer.gd: a shader per combination).
#define WH_NO_BALLS
#define WH_GRAVITY
#include "res://shaders/wormhole_view.gdshaderinc"
