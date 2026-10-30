shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
// only where a movable ball or cube may be seen (stencil_mark.gdshader)
stencil_mode read, compare_equal, 1;

// The ray tracer with movable balls and cubes (their uniforms: wormhole_core.gdshaderinc's top).
#include "res://shaders/frag/wormhole_view.gdshaderinc"
