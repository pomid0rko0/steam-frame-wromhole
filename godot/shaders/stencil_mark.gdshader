shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, fog_disabled;
stencil_mode write, compare_always, 1;

// The pixels whose rays may meet a movable ball or cube: it sets the stencil there (how and why:
// tracer.gd, «The stencil split», set_head), drawn over the proxies, and of those pixels only the
// ones whose ray's plane passes within reach of a toy (wh_toysNear; mark_near off: all). Its
// colour is drawn over by one of the ray tracers.
#define WH_MARK
#define WH_MARK_PROXY
uniform bool mark_near = true;
#include "res://shaders/wormhole_view.gdshaderinc"

void vertex() {
	float l;
	vec3 n;
	vec4 f0;
	vec4 f1;
	vec4 f2;
	wh_viewEye((INV_VIEW_MATRIX * vec4(EYE_OFFSET, 1.0)).xyz, l, n, f0, f1, f2);
	v_n = n; v_f0 = f0; v_f1 = f1; v_f2 = f2;
}

void fragment() {
	// the ray from the eye (EYE_OFFSET) through this point of the proxy, on the eye's axes
	vec3 pd = mat3(INV_VIEW_MATRIX) * (VERTEX - EYE_OFFSET);
	vec4 V = pd.x * v_f0 + pd.y * v_f1 + pd.z * v_f2;
	if (mark_near && !wh_toysNear(v_n, V.yzw)) discard;
	ALBEDO = vec3(0.0);
}
