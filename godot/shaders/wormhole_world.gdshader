shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
// marks the pixels it draws; the rest goes to the ray tracer with the toys (tracer.gd, «The split»)
stencil_mode write, compare_always, 1;

// The ray tracer of a scene with movable balls and cubes, all but their search in the curved region
// (wormhole_core.gdshaderinc, WH_WORLD): where that search could find one, it leaves the pixel to
// wormhole_balls.gdshader.
#define WH_WORLD
#include "res://shaders/wormhole_view.gdshaderinc"
