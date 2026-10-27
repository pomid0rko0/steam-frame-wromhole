// The toys' passes (wormhole_toys.gdshaderinc): the world's uniforms (wormhole_uniforms) and the
// toys', the core and the toys' code, and the vertex and fragment parts of the two passes:
//  - WHT_FLAT (toys_flat*.gdshader): over the proxies of the toys of the head's flat universe, a
//    sphere around each in the room (main.gd, a MultiMesh; the toy's bit in INSTANCE_CUSTOM.x);
//  - else (toys_shell*.gdshader): over a sphere around the shell in the room, or, with the head in
//    the curved region (wht_full), the whole view.
// Both are drawn as back faces (cull_front): one fragment per pixel, and an eye inside a proxy
// still sees it. Each fragment writes the depth of its hit, as if its path length lay straight
// along the pixel's ray (monotone along it: the passes and the toys order by it), or is discarded.
#define WH_TOYS
#include "res://shaders/wormhole_uniforms.gdshaderinc"
uniform vec4 wh_ball[12];
uniform vec4 wh_ballCol[12];
uniform int wh_nBall = 0;
uniform vec4 wh_fball[12];
uniform vec4 wh_cube[6];
uniform vec4 wh_cubeE[30];
uniform vec4 wh_cubeCol[6];
uniform int wh_nCube = 0;
#ifdef WHT_FLAT
uniform mat4 wht_toChart;       // play space -> the chart of the head's universe (main.gd)
uniform float wht_side = 1.0;   // that universe
#else
uniform bool wht_full = false;  // the whole view (the head in the curved region), not the shell's proxy
uniform vec4 wht_toy[18];       // the pass's toys (wht_near, main.set_objects)
uniform vec4 wht_win[18];
uniform int wht_nToy = 0;
uniform vec4 wht_cone[4];       // toys near the head (main._update_toy_draws): their centre's (n, l),
uniform vec4 wht_coneR;         // chord radius,
uniform ivec4 wht_coneIdx = ivec4(-1);   // index in wht_toy (-1: none)
#endif

#include "res://shaders/wormhole_core.gdshaderinc"
#include "res://shaders/wormhole_toys.gdshaderinc"

varying vec3 v_view;            // the pixel's ray in view space, unnormalised
#ifdef WHT_FLAT
varying flat int v_toy;         // the toy's bit
varying flat vec3 v_x;          // the eye in the chart
varying vec3 v_d;               // the ray in the chart, unnormalised
#else
varying flat float v_l;
varying flat vec3 v_n;
varying flat vec4 v_f0;
varying flat vec4 v_f1;
varying flat vec4 v_f2;
varying flat vec2 v_eye;
varying vec4 v_ray;
varying flat vec4 v_cone[5];    // the near toys' cones (wht_coneAt) at this eye: 0-3 their axes, 4 the
                                // cos of their half angles (-2: none)
#endif

void vertex() {
#ifdef WHT_FLAT
	vec4 pv = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POSITION = PROJECTION_MATRIX * pv;
	v_toy = int(INSTANCE_CUSTOM.x + 0.5);
	mat4 M = wht_toChart * INV_VIEW_MATRIX;
	v_x = (M * vec4(EYE_OFFSET, 1.0)).xyz;
	v_view = pv.xyz - EYE_OFFSET;
	v_d = mat3(M) * v_view;
#else
	if (wht_full) {
		POSITION = vec4(VERTEX.xy, 1e-6, 1.0);
		v_view = wh_cornerRay(VERTEX.xy, INV_PROJECTION_MATRIX, EYE_OFFSET);
	} else {
		vec4 pv = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
		POSITION = PROJECTION_MATRIX * pv;
		v_view = pv.xyz - EYE_OFFSET;
	}
	float l; vec3 n; vec4 f0; vec4 f1; vec4 f2;
	wh_eyeAt((INV_VIEW_MATRIX * vec4(EYE_OFFSET, 1.0)).xyz, l, n, f0, f1, f2);
	v_l = l; v_n = n; v_f0 = f0; v_f1 = f1; v_f2 = f2;
	v_eye = wh_eye(l);
	// the near toys' cones at this eye: the same at every vertex (the full view has four)
	vec4 cc = vec4(-2.0);
	for (int j = 0; j < 4; j++) {
		vec4 cu = vec4(0.0);
		if (wht_coneIdx[j] >= 0) {
			float ct;
			cu = wht_coneAt(l, n, wht_cone[j].w, wht_cone[j].xyz, wht_coneR[j], ct);
			cc[j] = ct;
		}
		v_cone[j] = cu;
	}
	v_cone[4] = cc;
	vec3 pd = mat3(INV_VIEW_MATRIX) * v_view;          // play space
	v_ray = pd.x * f0 + pd.y * f1 + pd.z * f2;
#endif
}

void fragment() {
	vec4 dbg;
#ifdef WHT_FLAT
	vec4 r = wht_flat(v_toy, wht_side, v_x, normalize(v_d), dbg);
#else
	vec4 V = normalize(v_ray);
	// the near toys whose cone this ray is outside: not met
	int skip = 0;
	for (int j = 0; j < 4; j++) {
		if (dot(V, v_cone[j]) < v_cone[4][j]) skip |= 1 << wht_coneIdx[j];
	}
	vec4 r = wht_shell(v_l, v_n, V.x, V.yzw, v_eye, skip, dbg);
#endif
	if (r.w < 0.0) discard;
	ALBEDO = r.rgb;
	vec4 c = PROJECTION_MATRIX * vec4(EYE_OFFSET + r.w * normalize(v_view), 1.0);
	DEPTH = c.z / c.w;
}
