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
#endif
#endif
#ifdef WH_MARK
// The toys this mark looks for (main._update_near: the shell's but those near the eye, or with
// WH_MARK_NEAR those near it), four to a vec4, wh_mkGroups of them: their centres' x, y, z in R^4,
// (reach + 1 cm)^2, and the range of l where each can be met (lo, hi: a path point within its reach
// has a profile point (r, w) within it, so an l within its reach along the profile, bent at most
// 1 / R). An empty slot: reach^2 -1, the range at 1e9.
uniform vec4 wh_mkX[5];
uniform vec4 wh_mkY[5];
uniform vec4 wh_mkZ[5];
uniform vec4 wh_mkR2[5];
uniform vec4 wh_mkLo[5];
uniform vec4 wh_mkHi[5];
uniform int wh_mkGroups = 0;
#endif
#ifdef WH_MARK
// The near toys, four slots (WH_MARK_NEAR's packed toys are the same four), seen from the head
// (main._update_near): where the head's geodesic to each centre ends when unrolled into the room
// (play space), and its reach (with the margins; 0: none)
uniform vec4 wh_near[4];
#endif
#ifdef WH_MARK_NEAR
// and a near cube's box in the room (main._near_box): per slot its three body axes there, the first
// with its half size grown by what the flat picture may be off by (0: not a cube, no box)
uniform vec4 wh_nearBox[12];
#endif
#ifdef WH_NEAR_CULL
// The ray tracer of stencil 3 leaves each near toy out of a ray that misses its cone or its box
// (wormhole_core.gdshaderinc, wh_curved): the same four slots from the head (slot k; main._near_cull): a cube's three axes in the room as
// vectors of the head's frame (wh_nearA[3 k + j]), the cone's axis the same way (wh_nearQ[k]), the
// head against the box along those axes and the cone's cos (wh_nearO[k]); the boxes' grown half
// sizes (0: none); each slot's candidate bit (wormhole_core.gdshaderinc, wh_curved; -1: none)
uniform vec4 wh_nearA[12];
uniform vec4 wh_nearQ[4];
uniform vec4 wh_nearO[4];
uniform vec4 wh_nearH;
uniform ivec4 wh_nearBit = ivec4(-1);
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
#ifdef WH_MARK_NEAR
// the eye against each near cube's box (slot k: component k), along its three axes; the ray in
// the room
varying flat vec4 v_box0;
varying flat vec4 v_box1;
varying flat vec4 v_box2;
#ifndef WH_MARK_MESH
varying vec3 v_pd;
#endif
#endif
#endif

#ifdef WH_MARK_NEAR
// Per near slot, 1 if the ray from the eye along pd (the room's; unnormalised) passes its box
// (main._near_box: the ray from the eye a straight line there, the box grown by what that is off
// by), or the slot has none; slabs. b0, b1, b2: v_box0, v_box1, v_box2.
vec4 wh_nearBoxes(vec3 pd, vec4 b0, vec4 b1, vec4 b2) {
	vec4 ok;
	for (int k = 0; k < 4; k++) {
		float H = wh_nearBox[3 * k].w;
		vec3 rd = vec3(dot(pd, wh_nearBox[3 * k].xyz), dot(pd, wh_nearBox[3 * k + 1].xyz), dot(pd, wh_nearBox[3 * k + 2].xyz));
		vec3 ro = vec3(b0[k], b1[k], b2[k]);
		vec3 ta = (-H - ro) / rd;
		vec3 tb = (H - ro) / rd;
		vec3 tn = min(ta, tb);
		vec3 tf = max(ta, tb);
		float t0 = max(max(tn.x, tn.y), max(tn.z, 0.0));
		float t1 = min(min(tf.x, tf.y), tf.z);
		ok[k] = H <= 0.0 || t1 >= t0 ? 1.0 : 0.0;
	}
	return ok;
}
#endif

void vertex() {
	vec2 corner = VERTEX.xy;        // where this corner of the quad over the view goes, in NDC
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
#ifdef WH_MARK
	// the near toys' cones from this eye: each centre's direction in its frame, as v_ray
	vec4 Q[4];
	vec4 cs;
#ifdef WH_MARK_NEAR
#ifndef WH_MARK_MESH
	// the quad over the cones only: the bounding box, in this eye's view, of an octagon round each
	// cone's circle at a unit distance along its axis (it holds the circle, and projected from the
	// eye the projected circle: the cone's pixels). The whole view if one is wide or reaches
	// behind the eye.
	vec2 lo = vec2(1.0);
	vec2 hi = vec2(-1.0);
	bool whole = false;
#endif
#endif
	for (int k = 0; k < 4; k++) {
		vec3 q = wh_near[k].xyz - eye;
		cs[k] = wh_near[k].w > 0.0 ? wh_nearCone(q, wh_near[k].w) : 2.0;     // none: no direction
		q = q / max(length(q), 1e-6);
		Q[k] = q.x * f0 + q.y * f1 + q.z * f2;
#ifdef WH_MARK_NEAR
#ifndef WH_MARK_MESH
		if (cs[k] > 1.5)
			continue;
		if (cs[k] < 0.2) {
			whole = true;
			continue;
		}
		vec3 qv = normalize(mat3(VIEW_MATRIX) * q);
		float t = sqrt(1.0 - cs[k] * cs[k]) / cs[k] / 0.92387953;     // tan of the angle / cos(pi / 8)
		vec3 a1 = normalize(cross(qv, abs(qv.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
		vec3 a2 = cross(qv, a1);
		for (int j = 0; j < 8; j++) {
			float ang = float(j) * 0.78539816;
			vec4 cp = PROJECTION_MATRIX * vec4(EYE_OFFSET + qv + t * (cos(ang) * a1 + sin(ang) * a2), 1.0);
			if (cp.w < 1e-3) {
				whole = true;
				break;
			}
			lo = min(lo, cp.xy / cp.w);
			hi = max(hi, cp.xy / cp.w);
		}
#endif
#endif
	}
	v_near0 = Q[0]; v_near1 = Q[1]; v_near2 = Q[2]; v_near3 = Q[3];
	v_nearCos = cs;
#ifdef WH_MARK_NEAR
	for (int k = 0; k < 4; k++) {
		vec3 o = eye - wh_near[k].xyz;
		v_box0[k] = dot(o, wh_nearBox[3 * k].xyz);
		v_box1[k] = dot(o, wh_nearBox[3 * k + 1].xyz);
		v_box2[k] = dot(o, wh_nearBox[3 * k + 2].xyz);
	}
#endif
#ifdef WH_MARK_NEAR
#ifndef WH_MARK_MESH
	if (!whole)      // none at all: every corner at one point off the view, nothing drawn
		corner = lo.x > hi.x ? vec2(2.0) : mix(clamp(lo, -1.0, 1.0), clamp(hi, -1.0, 1.0), VERTEX.xy * 0.5 + 0.5);
#endif
#endif
#endif
#ifndef WH_MARK_MESH
	POSITION = vec4(corner, 1.0, 1.0);
	// this corner's ray: the line from the eye, EYE_OFFSET, through the corner unprojected at two
	// depths (the far point, whatever the depth convention). Unnormalised, it is affine in the
	// screen position, so the interpolated value is each pixel's ray exactly.
	vec4 pa = INV_PROJECTION_MATRIX * vec4(corner, 0.001, 1.0);
	vec4 pb = INV_PROJECTION_MATRIX * vec4(corner, 0.999, 1.0);
	vec3 qa = pa.xyz / pa.w;
	vec3 qb = pb.xyz / pb.w;
	vec3 pd = mat3(INV_VIEW_MATRIX) * ((dot(qa, qa) > dot(qb, qb) ? qa : qb) - EYE_OFFSET);   // play space
	v_ray = pd.x * f0 + pd.y * f1 + pd.z * f2;
#ifdef WH_MARK_NEAR
	v_pd = pd;
#endif
#endif
}

#ifdef WH_MARK
// Where a ray tracer with the shell's toys must run (stencil 2, or with WH_MARK_NEAR 3): a ray can
// meet one of them only if it is within reach of the ray's plane through the centre (the whole ray
// lies in span(n, w) of R^4's xyz: the search's candidates, wh_curved), only within the range of l
// its path can pass, and one near the eye only if the ray points into its cone (wh_nearCone). A
// centimetre more than the ray tracer's test, and the cones a little wider: the marks must cover
// every pixel where it could find one. Four toys at a time, from uniforms main packs for each mark
// (no indexing per toy): over the whole view this runs on every pixel.
void fragment() {
#ifdef WH_MARK_MESH
	// drawn over a mesh (the sphere round the shell, stencil_toys_shell.gdshader): the pixel's ray
	// from the eye through the point drawn
	vec3 pd = mat3(INV_VIEW_MATRIX) * (VERTEX - EYE_OFFSET);
	vec4 V = normalize(pd.x * v_f0 + pd.y * v_f1 + pd.z * v_f2);
#else
	vec4 V = normalize(v_ray);
#ifdef WH_MARK_NEAR
	vec3 pd = v_pd;
#endif
#endif
	float hit = 0.0;
#ifdef WH_MARK_NEAR
	// the near toys' cones first: most pixels are in none, and their waves skip the rest (a loop of
	// at most one pass, its bound one the compiler cannot see: an if would become selects, and every
	// pixel would pay for all of it)
	vec4 inCone = vec4(greaterThanEqual(vec4(dot(V, v_near0), dot(V, v_near1), dot(V, v_near2), dot(V, v_near3)),
			v_nearCos - 1e-4));
	for (int once = 0; once < (dot(inCone, vec4(1.0)) > 0.5 ? 1 : 0) + min(wh_mkGroups, 0); once++) {
	// a near cube's ray must also pass its box
	inCone *= wh_nearBoxes(pd, v_box0, v_box1, v_box2);
#endif
	vec3 e3 = cross(v_n, V.yzw);              // the plane's normal, |w| long
	// along the radius (e3 = 0) the ray is in every plane through it: the 1e-12 lets it pass
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
	// as l itself
	float llo = sd > 0.0 ? xlo : -xhi;
	float lhi = sd > 0.0 ? xhi : -xlo;
	for (int g = 0; g < wh_mkGroups; g++) {
		vec4 d = wh_mkX[g] * e3.x + wh_mkY[g] * e3.y + wh_mkZ[g] * e3.z;
		vec4 m = vec4(lessThan(d * d, wh_mkR2[g] * s2 + 1e-12)) * vec4(lessThanEqual(wh_mkLo[g], vec4(lhi)))
				* vec4(greaterThanEqual(wh_mkHi[g], vec4(llo)));
#ifdef WH_MARK_NEAR
		m *= inCone;                          // one group: the four near slots
#endif
		hit += dot(m, vec4(1.0));
	}
#ifdef WH_MARK_NEAR
	}
#endif
	if (hit < 0.5) discard;
	ALBEDO = vec3(0.0);
}
#else
void fragment() {
	vec4 V = normalize(v_ray);
	vec4 dbg;
	ALBEDO = wh_renderE(v_l, v_n, V.x, V.yzw, v_eye, dbg);
}
#endif
