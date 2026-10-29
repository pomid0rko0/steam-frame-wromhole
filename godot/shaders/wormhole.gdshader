shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;

// The ray tracer without movable balls and cubes, for scenes without any (Tracer). Their code is
// left out (tracer.gd: a shader per combination).
#define WH_NO_BALLS
#include "res://shaders/wormhole_view.gdshaderinc"
