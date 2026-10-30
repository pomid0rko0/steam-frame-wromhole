shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
stencil_mode write, compare_always, 1;

// The pixels whose rays may meet a movable ball or cube (wh_mayMeetToy): it sets the stencil there,
// and only there the ray tracer with them runs (tracer.gd, «The stencil split»). Its colour is drawn
// over by one of the ray tracers.
#define WH_MARK
#include "res://shaders/wormhole_view.gdshaderinc"
