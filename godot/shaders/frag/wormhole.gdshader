shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
// where no movable ball or cube can be seen (stencil_mark.gdshader)
stencil_mode read, compare_not_equal, 1;

// The ray tracer without movable balls and cubes: the normal scene where none can be seen, and
// scenes without any (Tracer). Their code is left out (tracer.gd: a shader per combination).
#define WH_NO_BALLS
#include "res://shaders/frag/wormhole_view.gdshaderinc"
