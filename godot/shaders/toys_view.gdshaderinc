// The toys' passes (wormhole_toys.gdshaderinc): the world's uniforms (wormhole_uniforms) and the
// toys', the core and the toys' code, and the vertex and fragment parts of the two passes:
//  - WHT_FLAT (toys_flat*.gdshader): over the proxies of the toys of the head's flat universe, a
//    sphere around each in the room (main.gd, a MultiMesh; the toy's bit in INSTANCE_CUSTOM.x);
//  - else (toys_shell*.gdshader): over the cells of each eye's view where a toy can be met (main.gd,
//    _cell_mesh; wht_cellDir below): the rest of the view is not drawn at all.
// The flat pass is drawn as back faces (cull_front): one fragment per pixel, and an eye inside a
// proxy still sees it. Each fragment writes the depth of its hit, as if its path length lay straight
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
uniform vec4 wht_cx[5];         // the pass's toys in groups of four (wht_near, main.set_objects)
uniform vec4 wht_cy[5];
uniform vec4 wht_cz[5];
uniform vec4 wht_r2[5];
uniform vec4 wht_lo[5];
uniform vec4 wht_hi[5];
uniform vec4 wht_fs[5];
uniform ivec4 wht_bit[5];
uniform vec3 wht_t1;            // the bins of the list's toys (wht_near, main._update_bins)
uniform vec3 wht_t2;
uniform ivec4 wht_phiBin[8];
uniform ivec4 wht_bBin[16];
uniform float wht_bStep = 1.0;
uniform ivec4 wht_coneIdx = ivec4(-1);   // the near toys' places in the list (-1: none), whose cones
                                         // eye_data.gd works out (main._update_cones)
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
varying flat vec4 v_cone[5];    // the near toys' cones (wh_coneAt) at this eye: 0-3 their axes, 4 the
                                // cos of their half angles (-2: none)

const float WHT_CELL_NA = 4.0;  // the chords along a cell's azimuths (main.CELL_NA)

// The max of V . U over the directions V of a cell (wht_cellDir): V = (sig cos th, sin th w(a)), w(a) =
// sin a e1 - cos a e2, th in [th0, th1] within [0, pi / 2], a in [a0, a1]; U = (U_l, u).
float wht_cellMax(float sig, float th0, float th1, float a0, float a1, vec3 e1, vec3 e2, vec4 U) {
    // w(a) . u = |u_t| cos(a - pi / 2 - au): its max over the azimuths, then over th
    vec2 ut = vec2(dot(U.yzw, e1), dot(U.yzw, e2));
    float au = atan(ut.y, ut.x) + 0.5 * WH_PI;
    float d0 = au - a0;
    d0 -= 2.0 * WH_PI * floor(d0 / (2.0 * WH_PI));
    float ca = d0 <= a1 - a0 ? 1.0 : max(cos(d0), cos(d0 - (a1 - a0)));
    float A = sig * U.x;
    float B = length(ut) * ca;
    float ts = atan(B, A);
    if (ts >= th0 && ts <= th1) return sqrt(A * A + B * B);
    return max(A * cos(th0) + B * sin(th0), A * cos(th1) + B * sin(th1));
}

// A vertex of a cell of an eye's view (main.gd, _cell_mesh): cell (pb, bb) holds the rays whose
// plane's normal N = n x w has its azimuth in bin pb round the head's radial axis (wht_t1, wht_t2)
// and whose impact parameter b = rho |w| (rho = r of the eye, or its chart radius outside the
// shell) is in bin bb & 31, moving toward +l for bb < 32, toward -l for the rest: wht_near's bins.
// The cell is drawn only if a toy is in both bins, and no near toy among them has a cone that misses
// the whole cell. Its edges of one azimuth are halves of great circles through the radial axis,
// straight on the screen; its b edges are circles round the axis, drawn as chords: the outer ones
// pushed out to circumscribe them (fa: the vertex's place along the azimuths, ring 0 inner, 1
// outer). V: the vertex's direction (vl, w), unit; false: the cell is not drawn.
bool wht_cellDir(float l, vec3 n, float rho, int pb, int bb, float fa, float ring, vec4 cu[4], vec4 cc,
                 out vec4 V) {
    V = vec4(0.0);
    int cand = wht_phiBin[pb >> 2][pb & 3] & wht_bBin[bb >> 2][bb & 3];
    if (cand == 0) return false;
    float sig = bb < 32 ? 1.0 : -1.0;
    float side = l > 0.0 ? 1.0 : -1.0;
    bool outside = abs(l) >= wh_Lsh();
    if (outside && sig == side) return false;      // from outside the shell only inward rays meet it
    float q = float(bb & 31);
    float w0 = q * wht_bStep / rho;
    if (w0 >= 1.0) return false;
    float w1 = min((q + 1.0) * wht_bStep / rho, 1.0);
    if (outside) w1 = min(w1, wh_Rout() / rho);
    float th0 = asin(w0);
    float th1 = asin(w1);
    // the eye's frame round its radial axis; the angle a of N = cos a e1 + sin a e2 whose azimuth in
    // (wht_t1, wht_t2) is the bin's edge: (N.t1, N.t2) = M (cos a, sin a)
    vec3 e1 = normalize(wht_t1 - dot(wht_t1, n) * n);
    vec3 e2 = cross(n, e1);
    mat2 Mi = inverse(mat2(vec2(dot(e1, wht_t1), dot(e1, wht_t2)), vec2(dot(e2, wht_t1), dot(e2, wht_t2))));
    float p0 = float(pb) * (WH_PI / 16.0) - WH_PI;
    vec2 q0 = Mi * vec2(cos(p0), sin(p0));
    vec2 q1 = Mi * vec2(cos(p0 + WH_PI / 16.0), sin(p0 + WH_PI / 16.0));
    float a0 = atan(q0.y, q0.x);
    float a1 = atan(q1.y, q1.x);
    a1 += a1 < a0 ? 2.0 * WH_PI : 0.0;
    // the near toys whose cone misses the whole cell
    for (int j = 0; j < 4; j++) {
        int k = wht_coneIdx[j];
        if (k >= 0 && cc[j] > -1.5 && ((cand >> k) & 1) != 0
                && wht_cellMax(sig, th0, th1, a0, a1, e1, e2, cu[j]) < cc[j] - 1e-3)
            cand &= ~(1 << k);
    }
    if (cand == 0) return false;
    float a = mix(a0, a1, fa);
    // the outer chord (a segment of the vertex's cell is (a1 - a0) / WHT_CELL_NA wide) circumscribes
    // its circle: in the plane tangent at the axis the circle has radius tan th1, its polygon's
    // vertices tan th1 / cos of half a segment
    float th = th0;
    if (ring > 0.5) th = w1 >= 1.0 ? 0.5 * WH_PI : atan(tan(th1) / cos(0.5 * (a1 - a0) / WHT_CELL_NA));
    V = vec4(sig * cos(th), sin(th) * (sin(a) * e1 - cos(a) * e2));
    return true;
}
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
	int view = int(VIEW_INDEX);
	float l; vec3 n; vec4 f0; vec4 f1; vec4 f2; vec2 eye;
	wh_eyeOf(view, l, n, f0, f1, f2, eye);
	v_l = l; v_n = n; v_f0 = f0; v_f1 = f1; v_f2 = f2;
	v_eye = eye;
	// the near toys' cones at this eye (eye_data.gd)
	vec4 cu[4];
	vec4 cc;
	for (int j = 0; j < 4; j++) {
		cu[j] = texelFetch(wh_eyes, ivec2(5 + 2 * j, view), 0);
		cc[j] = texelFetch(wh_eyes, ivec2(6 + 2 * j, view), 0).x;
		v_cone[j] = cu[j];
	}
	v_cone[4] = cc;
	// this vertex of its cell (UV: the cell's bins, UV2: its place in the cell), or nothing drawn
	vec4 V;
	if (wht_cellDir(l, n, eye.x, int(UV.x), int(UV.y), UV2.x, UV2.y, cu, cc, V)) {
		vec3 vv = mat3(VIEW_MATRIX) * vec3(dot(V, f0), dot(V, f1), dot(V, f2));    // view space
		POSITION = PROJECTION_MATRIX * vec4(EYE_OFFSET + vv, 1.0);
		v_view = vv;
		v_ray = V;
	} else {
		POSITION = vec4(0.0, 0.0, 0.0, 1.0);
		v_view = vec3(0.0, 0.0, -1.0);
		v_ray = vec4(1.0, 0.0, 0.0, 0.0);
	}
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
