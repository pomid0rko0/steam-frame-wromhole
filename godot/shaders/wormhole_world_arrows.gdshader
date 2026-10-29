shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
// marks the pixels it draws; the rest goes to the ray tracer with the toys (tracer.gd, «The split»)
stencil_mode write, compare_always, 1;

// wormhole_world.gdshader with the floor coloured by gravity and the arrows of its field (the gravity
// view "floor and arrows": Tracer.GRAVITY_VIEWS).
#define WH_WORLD
#define WH_GRAVITY
#define WH_ARROWS
#include "res://shaders/wormhole_view.gdshaderinc"
