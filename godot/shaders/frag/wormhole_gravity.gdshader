shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
// where no movable ball or cube can be seen (stencil_mark.gdshader)
stencil_mode read, compare_not_equal, 1;

// The gravity view "floor" (Tracer.GRAVITY_VIEWS): the plain ray tracer with the floor coloured
// by the strength of gravity (tracer.gd: a shader per combination).
#define WH_NO_BALLS
#define WH_GRAVITY
#include "res://shaders/frag/wormhole_view.gdshaderinc"
