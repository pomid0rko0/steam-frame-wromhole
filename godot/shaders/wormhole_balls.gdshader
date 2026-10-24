shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;

// The ray tracer with movable balls (wh_ball, wh_ballCol, wh_nBall).
#include "res://shaders/wormhole_view.gdshaderinc"
