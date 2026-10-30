// Full-screen ray tracer (and, with WH_MARK, the stencil marks' code: stencil_mark.gdshader and
// stencil_mark_all.gdshader define their own fragment(), WH_MARK_PROXY their own vertex() too).
// The script supplies the head's point on the manifold
// (head_l, head_n), the play-space axes parallel-transported to it (head_f, as (U_l, u))
// and the head's play-space position.
//
// Multiview (stereo) in Godot: VIEW_MATRIX / INV_VIEW_MATRIX are the camera between the
// eyes for BOTH views. Each eye's position and rotation relative to it are folded into that
// view's PROJECTION_MATRIX, and EYE_OFFSET is the eye's position in that shared view space.
// So the eye sits at EYE_OFFSET, and the ray of a pixel is the line from EYE_OFFSET through
// the pixel's unprojected point. The eye's manifold state is obtained by following the
// geodesic from the head to the eye. Without multiview EYE_OFFSET is zero.

// The uniforms wormhole_core.gdshaderinc's top says the including file declares, and the head's.
uniform float wh_rho0;
uniform float wh_h;
uniform float wh_fillet;
uniform vec4 wh_sph[6];
uniform vec4 wh_pil[4];
uniform vec4 wh_box[4];
uniform vec4 wh_ball[12];
uniform vec4 wh_ballCol[12];
uniform int wh_nBall = 0;
uniform float head_l = 10.0;
uniform vec3 head_n = vec3(1.0, 0.0, 0.0);
uniform vec4 head_f[3];
uniform vec3 head_pos;
uniform sampler2D wh_tab : filter_linear, repeat_disable;
uniform vec4 wh_tabLo;
uniform vec4 wh_tabInv;
uniform vec4 wh_tabReg;
#ifdef WH_GRAVITY
uniform vec4 grav_cyl;
uniform vec4 grav_g[2];
uniform vec4 grav_d[2];
#endif
#ifndef WH_NO_BALLS
#define WH_PIX
#else
#ifdef WH_ARROWS
#define WH_PIX
#endif
#endif
#ifdef WH_PIX
uniform float wh_pix = 0.0015;
#endif
#ifndef WH_NO_BALLS
uniform vec4 wh_cube[6];
uniform vec4 wh_cubeE[30];
uniform vec4 wh_cubeCol[6];
uniform int wh_nCube = 0;
uniform vec4 wh_bound[4];
uniform ivec4 wh_bIdx;
uniform ivec4 wh_cIdx;
uniform vec4 wh_fball[12];
#endif

#include "res://shaders/wormhole_core.gdshaderinc"

// The eye at play-space point eye: its point of the manifold (l, n) and the play axes moved there
// (f0, f1, f2), along the geodesic of its offset from the head.
void wh_viewEye(vec3 eye, out float l, out vec3 n, out vec4 f0, out vec4 f1, out vec4 f2) {
	l = head_l;
	n = head_n;
	f0 = head_f[0];
	f1 = head_f[1];
	f2 = head_f[2];
	vec3 off = eye - head_pos;                         // this eye relative to the head, play space
	float len = length(off);
	if (len > 1e-6) {
		vec4 dir = (off.x * f0 + off.y * f1 + off.z * f2) / len;
		wh_geodesic(l, n, dir, len, f0, f1, f2);
	}
}

#ifndef WH_NO_BALLS
// Whether the ray from the eye at n with its direction's part across w (the eye's tangent space)
// can meet a movable ball or cube anywhere along it: its whole path, curved part and straight ones,
// lies in R^4's subspace span(n, w, the w axis), so one whose centre is farther from it than its
// reach (a ball's radius, a cube's half diagonal: two half sizes) is never met (wh_curved's
// candidates, for every toy). The distance is the centre's xyz along the plane's normal. A ray
// along n has no plane: it may meet any. The reach a little grown: rounding.
bool wh_toysNear(vec3 n, vec3 w) {
	vec3 c = cross(n, w);
	float lc = length(c);
	if (lc < 1e-6 * length(w) + 1e-12) return true;
	c /= lc;
	for (int i = 0; i < wh_nBall; i++)
		if (abs(dot(wh_ball[i].xyz, c)) < 1.001 * wh_ballCol[i].w + 1e-4) return true;
	for (int i = 0; i < wh_nCube; i++)
		if (abs(dot(wh_cube[i].xyz, c)) < 2.002 * wh_cubeCol[i].w + 1e-4) return true;
	return false;
}
#endif

varying flat float v_l;
varying flat vec3 v_n;
varying flat vec4 v_f0;
varying flat vec4 v_f1;
varying flat vec4 v_f2;
varying flat vec2 v_eye;        // wh_eye(v_l): once per eye, not per pixel
varying vec4 v_ray;

#ifndef WH_MARK_PROXY
void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
	float l;
	vec3 n;
	vec4 f0;
	vec4 f1;
	vec4 f2;
	wh_viewEye((INV_VIEW_MATRIX * vec4(EYE_OFFSET, 1.0)).xyz, l, n, f0, f1, f2);
	v_l = l; v_n = n; v_f0 = f0; v_f1 = f1; v_f2 = f2;
	v_eye = wh_eye(l);
	// this corner's ray: the line from the eye, EYE_OFFSET, through the corner unprojected at two
	// depths (the far point, whatever the depth convention). Unnormalised, it is affine in the
	// screen position, so the interpolated value is each pixel's ray exactly.
	vec4 pa = INV_PROJECTION_MATRIX * vec4(VERTEX.xy, 0.001, 1.0);
	vec4 pb = INV_PROJECTION_MATRIX * vec4(VERTEX.xy, 0.999, 1.0);
	vec3 qa = pa.xyz / pa.w;
	vec3 qb = pb.xyz / pb.w;
	vec3 pd = mat3(INV_VIEW_MATRIX) * ((dot(qa, qa) > dot(qb, qb) ? qa : qb) - EYE_OFFSET);   // play space
	v_ray = pd.x * f0 + pd.y * f1 + pd.z * f2;
}
#endif

#ifndef WH_MARK
void fragment() {
	vec4 V = normalize(v_ray);
	vec4 dbg;
	ALBEDO = wh_renderE(v_l, v_n, V.x, V.yzw, v_eye, dbg);
}
#endif
