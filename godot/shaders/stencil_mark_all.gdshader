shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
stencil_mode write, compare_always, 1;

// stencil_mark.gdshader over the whole view (the head in the curved region, where no chart maps
// the proxies to the room): the pixels whose ray can reach a toy (wh_toysNear); mark_near off
// (the split turned off): every pixel.
#define WH_MARK
uniform bool mark_near = true;
#include "res://shaders/wormhole_view.gdshaderinc"

void fragment() {
	if (mark_near && !wh_toysNear(v_n, v_ray.yzw)) discard;
	ALBEDO = vec3(0.0);
}
