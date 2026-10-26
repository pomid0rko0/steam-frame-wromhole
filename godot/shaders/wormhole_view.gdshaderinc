// Full-screen ray tracer. The script supplies the head's point on the manifold
// (head_l, head_n), the play-space axes parallel-transported to it (head_f, as (U_l, u))
// and the head's play-space position.
//
// Multiview (stereo) in Godot: VIEW_MATRIX / INV_VIEW_MATRIX are the camera between the
// eyes for BOTH views. Each eye's position and rotation relative to it are folded into that
// view's PROJECTION_MATRIX, and EYE_OFFSET is the eye's position in that shared view space.
// So the eye sits at EYE_OFFSET, and the ray of a pixel is the line from EYE_OFFSET through
// the pixel's unprojected point. The eye's manifold state is obtained by following the
// geodesic from the head to the eye. Without multiview EYE_OFFSET is zero.
//
// With movable toys the frame is split by the stencil (main.gd, _update_proxies), and each part
// gets the cheapest ray tracer that sees everything there: 0 none of them (WH_NO_BALLS), 1 only
// those of the flat universes (WH_FLAT_TOYS), 2 also the shell's but those near the eye (their
// bits out of wh_candMask), 3 all of them. With WH_MARK this is instead a pass that marks where
// 2 or 3 must run (stencil_toys*.gdshader): no colour, discarded elsewhere.

uniform float wh_rho0 = 3.0;
uniform float wh_h = 5.0;
uniform float wh_fillet = 1.0;
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
#ifdef WH_TABLE
uniform sampler2D wh_tab : filter_linear, repeat_disable;
uniform vec4 wh_tabLo;
uniform vec4 wh_tabInv;
uniform vec4 wh_tabReg;
#endif
#ifdef WH_GRAVITY
uniform vec4 grav_cyl;
uniform vec4 grav_g[2];
uniform vec4 grav_d[2];
#endif
// a pixel's angle: the arrows' soft edges, the cubes' edge lines
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
// balls' and cubes' bounding spheres (R^4 xyz of the centre, radius; < 0: none) in universe A, B
// (main.set_objects): a ray of a flat universe that misses one tests none of them
uniform vec4 wh_bound[4];
// where in the sorted lists the balls and cubes of universe A, of the shell and of universe B are
uniform ivec4 wh_bIdx;
uniform ivec4 wh_cIdx;
// each ball's sphere in the flat universe whose sheet cuts it, in its chart (centre, radius^2)
uniform vec4 wh_fball[12];
#endif
#ifndef WH_NO_BALLS
#ifndef WH_FLAT_TOYS
// the shell's toys this ray tracer looks for in the curved region, as candidate bits (ball i: i,
// cube i: 16 + i): all, or all but those near the eye (main._update_near)
uniform int wh_candMask = -1;
#define WH_CAND_MASK wh_candMask
#ifdef WH_MARK
// up to four of the shell's toys near the head (main._update_near): where the head's geodesic to
// each centre ends when unrolled into the room (play space), and its reach (with the margins; 0:
// none); their bits
uniform vec4 wh_near[4];
uniform ivec4 wh_nearBit;
// the range of l where each of the shell's toys can be met (ball i: i, cube i: 12 + i; xy): a path
// point within its reach has a profile point (r, w) within it, so an l within its reach along the
// profile (bent at most 1 / R)
uniform vec4 wh_toyL[18];
#endif
#endif
#endif

#include "res://shaders/wormhole_core.gdshaderinc"

varying flat float v_l;
varying flat vec3 v_n;
varying flat vec4 v_f0;
varying flat vec4 v_f1;
varying flat vec4 v_f2;
varying flat vec2 v_eye;        // wh_eye(v_l): once per eye, not per pixel
varying vec4 v_ray;
#ifdef WH_MARK
// each near toy's centre seen from this eye (unit, as v_ray) and its cone's cos (wh_nearCone)
varying flat vec4 v_near0;
varying flat vec4 v_near1;
varying flat vec4 v_near2;
varying flat vec4 v_near3;
varying flat vec4 v_nearCos;
#endif

void vertex() {
#ifndef WH_MARK_MESH
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
#endif
	float l = head_l;
	vec3 n = head_n;
	vec4 f0 = head_f[0];
	vec4 f1 = head_f[1];
	vec4 f2 = head_f[2];
	vec3 eye = (INV_VIEW_MATRIX * vec4(EYE_OFFSET, 1.0)).xyz;
	vec3 off = eye - head_pos;                         // this eye relative to the head, play space
	float len = length(off);
	if (len > 1e-6) {
		vec4 dir = (off.x * f0 + off.y * f1 + off.z * f2) / len;
		wh_geodesic(l, n, dir, len, f0, f1, f2);
	}
	v_l = l; v_n = n; v_f0 = f0; v_f1 = f1; v_f2 = f2;
	v_eye = wh_eye(l);
#ifndef WH_MARK_MESH
	// this corner's ray: the line from the eye, EYE_OFFSET, through the corner unprojected at two
	// depths (the far point, whatever the depth convention). Unnormalised, it is affine in the
	// screen position, so the interpolated value is each pixel's ray exactly.
	vec4 pa = INV_PROJECTION_MATRIX * vec4(VERTEX.xy, 0.001, 1.0);
	vec4 pb = INV_PROJECTION_MATRIX * vec4(VERTEX.xy, 0.999, 1.0);
	vec3 qa = pa.xyz / pa.w;
	vec3 qb = pb.xyz / pb.w;
	vec3 pd = mat3(INV_VIEW_MATRIX) * ((dot(qa, qa) > dot(qb, qb) ? qa : qb) - EYE_OFFSET);   // play space
	v_ray = pd.x * f0 + pd.y * f1 + pd.z * f2;
#endif
#ifdef WH_MARK
	// the near toys' cones from this eye: each centre's direction in its frame, as v_ray
	vec4 Q[4];
	vec4 cs;
	for (int k = 0; k < 4; k++) {
		vec3 q = wh_near[k].xyz - eye;
		cs[k] = wh_nearCone(q, wh_near[k].w);
		q = q / max(length(q), 1e-6);
		Q[k] = q.x * f0 + q.y * f1 + q.z * f2;
	}
	v_near0 = Q[0]; v_near1 = Q[1]; v_near2 = Q[2]; v_near3 = Q[3];
	v_nearCos = cs;
#endif
}

#ifdef WH_MARK
// Where a ray tracer with the shell's toys must run (stencil 2, or with WH_MARK_NEAR 3): a ray can
// meet one of them only if it is within reach of the ray's plane through the centre (the whole ray
// lies in span(n, w) of R^4's xyz: the search's candidates, wh_curved), and one near the eye only
// if the ray points into its cone (wh_nearCone). A centimetre more than the ray tracer's test, and
// the cones a little wider: the marks must cover every pixel where it could find one. Without
// WH_MARK_NEAR those near the eye are left out (the ray tracer of stencil 2 leaves them out), with
// it only they are looked at.
void fragment() {
#ifdef WH_MARK_MESH
	// drawn over a mesh (the sphere round the shell, stencil_toys_shell.gdshader): the pixel's ray
	// from the eye through the point drawn
	vec3 pd = mat3(INV_VIEW_MATRIX) * (VERTEX - EYE_OFFSET);
	vec4 V = normalize(pd.x * v_f0 + pd.y * v_f1 + pd.z * v_f2);
#else
	vec4 V = normalize(v_ray);
#endif
	vec3 e3 = cross(v_n, V.yzw);              // the plane's normal, |w| long
	float s2 = dot(e3, e3);
	// the range of l the path passes in the shell, as x = side l (this side x > 0): inward, a ray
	// that passes the throat goes on to the far edge, one that turns does so where r = b, at
	// |l| >= Lc + R (sqrt(2 (b - rho0) / R) - th0) (1 - cos th <= th^2 / 2), and not beyond where
	// it is; outward, it only goes out. An eye outside enters at the edge, inward. On the cylinder
	// no ray turns (b <= r = rho0): one that goes round it has b = rho0, rounded either way.
	float sd = v_l >= 0.0 ? 1.0 : -1.0;
	bool outside = abs(v_l) >= wh_Lsh();
	float x0 = outside ? wh_Lsh() : abs(v_l);
	float b = (outside ? wh_Rout() : v_eye.x) * length(V.yzw);
	bool inward = outside || V.x * sd < 0.0;
	float th0 = wh_th0();
	float s0 = sin(0.5 * th0);
	bool turn = b > wh_rho0 + 2.0 * wh_fillet * s0 * s0 && x0 > wh_Lc();
	float lt = max(wh_Lc() + wh_fillet * (sqrt(max(2.0 * (b - wh_rho0) / wh_fillet, 0.0)) - th0), wh_Lc());
	float xlo = inward ? (turn ? min(lt, x0) : -wh_Lsh()) : x0;
	float xhi = inward && !turn ? x0 : wh_Lsh();
	int near = 0;                             // the near toys this ray points at
	if (dot(V, v_near0) >= v_nearCos.x - 1e-4) near |= 1 << wh_nearBit.x;
	if (dot(V, v_near1) >= v_nearCos.y - 1e-4) near |= 1 << wh_nearBit.y;
	if (dot(V, v_near2) >= v_nearCos.z - 1e-4) near |= 1 << wh_nearBit.z;
	if (dot(V, v_near3) >= v_nearCos.w - 1e-4) near |= 1 << wh_nearBit.w;
#ifdef WH_MARK_NEAR
	int want = near;                          // the near ones it points at
#else
	int want = wh_candMask;                   // the others (main sets the near ones' bits off)
#endif
	bool any = s2 < 1e-12 && want != 0;       // along the radius: in every plane through it
	for (int i = wh_bIdx.x; i < wh_bIdx.w; i++) {
		float d = dot(wh_ball[i].xyz, e3);
		float rr = wh_ballCol[i].w + 0.01;
		vec2 wl = sd * wh_toyL[i].xy;
		any = any || (d * d < rr * rr * s2 && (want & (1 << i)) != 0 && xhi >= min(wl.x, wl.y) && xlo <= max(wl.x, wl.y));
	}
	for (int i = wh_cIdx.x; i < wh_cIdx.w; i++) {
		float d = dot(wh_cube[i].xyz, e3);
		float rr = 2.0 * wh_cubeCol[i].w + 0.01;
		vec2 wl = sd * wh_toyL[12 + i].xy;
		any = any || (d * d < rr * rr * s2 && (want & (1 << (16 + i))) != 0 && xhi >= min(wl.x, wl.y) && xlo <= max(wl.x, wl.y));
	}
	if (!any) discard;
	ALBEDO = vec3(0.0);
}
#else
void fragment() {
	vec4 V = normalize(v_ray);
	vec4 dbg;
	ALBEDO = wh_renderE(v_l, v_n, V.x, V.yzw, v_eye, dbg);
}
#endif
