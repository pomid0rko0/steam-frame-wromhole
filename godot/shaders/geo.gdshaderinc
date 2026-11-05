// The space and its rays, for every shader that draws (floor.gdshader, body.gdshader and its
// variants): docs/geometry.md, «Как рисуется кадр». Plain GLSL apart from the uniforms, which the
// including shader declares (geo_uniforms.gdshaderinc; ref/test_gpu.py declares its own):
//   g_prof  = (rho0, R, Lc, L)          the throat (WormholeSpace)
//   g_prof2 = (Rout, u0, rmin, th0)     u0 = sin^2(th0 / 2): where the fillet starts
//   g_tabx  = (t0, 1 / (t1 - t0), nb, nv)   the table's axes (WormholeSpace.sweep_table)
//   g_tab   the table G(b, v): psi in .r, length in .g
//   g_lift  the throat's centre above the floor (WormholeSpace.lift)
// A point is (l, n), n a unit vector of the shared angular sphere; a tangent vector is
// vec4(U_l, u) with u . n = 0 (WormholeSpace's top). A ray lies in the plane through the centre
// spanned by n and its direction; b is its impact parameter, and on the way from |l| = a1 to a2
// (no turning point between) its position angle turns by psi and it covers length len:
// geo_between. On the fillet they are closed forms plus the table's small rest (ref/geo.py's top).
//
// Precision: float32. Where a ray starts or ends next to its turning point, r - b ("gap") goes in
// from what knows it exactly (the eye's from its angle), not from a difference of two lengths.

const float GEO_PI = 3.14159265358979;
// Godot writes a shader's numbers into the GLSL it compiles with 14 decimals: a smaller one would
// come out 0, so the tiny ones are products (ref/test_gpu.py checks every number of the shaders).
const float GEO_TINY = 1e-10 * 1e-10 * 1e-10;      // 1e-30
const float GEO_TINY20 = 1e-10 * 1e-10;            // 1e-20

// atan(y, x) in [-pi, pi]: a minimax polynomial in the octant's ratio (off by 4e-8 rad, 1.2e-7 in
// float32) and the octants. Mesa's own atan takes about three times the instructions on the
// headset (tools/adreno_stats.sh --paths), and a floor pixel takes up to five. asin and acos go
// through it: Mesa's are polynomials good to only ~1e-4 rad.
float geo_atan2(float y, float x) {
	float ax = abs(x), ay = abs(y);
	float a = min(ax, ay) / max(max(ax, ay), GEO_TINY);
	float s = a * a;
	float r = a * (0.999999336 + s * (-0.333298608 + s * (0.199465655 + s * (-0.139086284 + s * (0.0964219381
			+ s * (-0.0559122717 + s * (0.0218629158 + s * -0.00405455466)))))));
	if (ay > ax) r = 0.5 * GEO_PI - r;
	if (x < 0.0) r = GEO_PI - r;
	return y < 0.0 ? -r : r;
}
float geo_asin(float x) { return geo_atan2(x, sqrt(max((1.0 - x) * (1.0 + x), 0.0))); }
float geo_acos(float x) { return geo_atan2(sqrt(max((1.0 - x) * (1.0 + x), 0.0)), x); }

// (sin x, cos x), not the GPU's own: Turnip (the headset's driver) takes every sin and cos through
// 2 pi fract(x / 2 pi + 1/2) - pi, which puts x on a grid of 4e-7 rad, so a small angle keeps none of
// its digits (ref/test_gpu.py takes the shaders' every sin and cos the same way). Here x less its
// nearest multiple of pi/2 (pi/2 in three parts, each product with it exact), then Cephes'
// polynomials on [-pi/4, pi/4]: a float32 step of the result off, at any x up to thousands.
vec2 geo_sincos(float x) {
	float k = round(x * 0.636619772);
	float r = ((x - k * 1.5703125) - k * 4.83751297e-4) - k * 7.54978995e-8;
	float s = r * r;
	float sn = r + r * s * (-0.166666546 + s * (0.00833216087 + s * -0.000195152959));
	float cs = 1.0 - 0.5 * s + s * s * (0.0416666418 + s * (-0.00138873165 + s * 2.44331571e-5));
	int q = int(k) & 3;
	vec2 v = (q & 1) == 0 ? vec2(sn, cs) : vec2(cs, -sn);
	return q >= 2 ? -v : v;
}
float geo_sin(float x) { return geo_sincos(x).x; }
float geo_cos(float x) { return geo_sincos(x).y; }

// x is a number, not NaN or infinite, by its bits: GLSL leaves comparisons with NaN to the
// compiler (the PC's let x < 1e30 hold for NaN), and isnan may be folded away
bool geo_finite(float x) { return (floatBitsToUint(x) & 0x7f800000u) != 0x7f800000u; }

// r(|l|) - rho0, without the difference: near the cylinder's end r and rho0 share their first seven
// digits, and what a ray does there hangs on the rest (sigma below and every test against r_min)
float geo_dr(float al) {
	if (al >= g_prof.w) return al - g_prof.w + (g_prof2.x - g_prof.x);
	float th = g_prof2.w + (max(al, g_prof.z) - g_prof.z) / g_prof.y;
	float s = geo_sin(0.5 * th);
	return 2.0 * g_prof.y * s * s;
}

float geo_r(float al) { return g_prof.x + geo_dr(al); }

// dr/dl and dw/dl at l (dr odd, dw even): the embedded d/dl is (dr n, dw)
vec2 geo_drdw(float l) {
	float al = abs(l);
	if (al >= g_prof.w) return vec2(sign(l), 0.0);
	if (al <= g_prof.z) return vec2(0.0, 1.0);
	float th = g_prof2.w + (al - g_prof.z) / g_prof.y;
	vec2 sc = geo_sincos(th);
	return vec2(sign(l) * sc.x, sc.y);
}

// u = sin^2(theta / 2) on the fillet
float geo_u(float al) {
	float th = g_prof2.w + (clamp(al, g_prof.z, g_prof.w) - g_prof.z) / g_prof.y;
	float s = geo_sin(0.5 * th);
	return s * s;
}

// psi's and len's integrands on the fillet without the weight du / sqrt(u (u - sigma)), and their
// derivative in u (ref/geo.py's F, Fu)
vec2 geo_F(float b, float u) {
	float r = g_prof.x + 2.0 * g_prof.y * u;
	float c = sqrt(0.5 * g_prof.y) * inversesqrt((1.0 - u) * (r + b));
	return vec2(b / r, r) * c;
}

vec2 geo_Fu(float b, float u, vec2 f) {
	float r = g_prof.x + 2.0 * g_prof.y * u;
	float a = 0.5 / (1.0 - u) - g_prof.y / (r + b);
	float k = 2.0 * g_prof.y / r;
	return f * vec2(a - k, a + k);
}

// the table's rest G at impact b (sigma = (b - rho0) / 2R) and v = sqrt((u - u_lo) / (1/2 - u_lo))
vec2 geo_G(float sigma, float v) {
	float s = sigma - g_prof2.y;
	float t = sign(s) * sqrt(abs(s));
	float x = clamp((t - g_tabx.x) * g_tabx.y, 0.0, 1.0);
	vec2 uv = vec2((x * (g_tabx.z - 1.0) + 0.5) / g_tabx.z, (clamp(v, 0.0, 1.0) * (g_tabx.w - 1.0) + 0.5) / g_tabx.w);
	return textureLod(g_tab, uv, 0.0).rg;
}

// sigma = (b - rho0) / 2R from b - rho0, kept off the photon sphere's b = rho0 (h >= R), where the
// weight's integral diverges. Which side of r_min a ray is on is sigma's sign against u0: b itself
// can't tell b from rho0 within 2.4e-7 m, a ray's sigma knows it (geo_dr).
float geo_sigma(float gap_rho0) {
	float s = gap_rho0 / (2.0 * g_prof.y);
	return abs(s) < 1e-14 ? (s < 0.0 ? -1e-14 : 1e-14) : s;
}

// (psi, len) on the fillet from u1 to u2 (u_lo <= u1 <= u2 <= 1/2; d = u - sigma at each), lo: u1 is
// u_lo (no table there). The closed forms: F(u_lo) W + F_u(u_lo) int (u - u_lo) dW, W the weight's
// integral; the table the rest. whole: u2 = 1/2 (the table's last row).
vec2 geo_fillet(float b, float sigma, float u1, float d1, float u2, float d2, bool lo, bool whole) {
	float ul = max(sigma, g_prof2.y);
	float span = 0.5 - ul;
	if (span <= 0.0 || u2 <= u1) return vec2(0.0);
	vec2 f0 = geo_F(b, ul);
	vec2 f1 = geo_Fu(b, ul, f0);
	float s1 = sqrt(u1), e1 = sqrt(max(d1, 0.0));
	float s2 = sqrt(u2), e2 = sqrt(max(d2, 0.0));
	float w = 2.0 * log((s2 + e2) / (s1 + e1));
	vec2 out_ = f0 * w + f1 * (s2 * e2 - s1 * e1 + (0.5 * sigma - ul) * w);
	out_ += geo_G(sigma, whole ? 1.0 : sqrt(max(u2 - ul, 0.0) / span));
	if (!lo) out_ -= geo_G(sigma, sqrt(max(u1 - ul, 0.0) / span));
	return out_;
}

// (psi, len) from |l| = a1 to a2 >= a1 with no turning point between, gap = r - b at each end;
// origin: a1 is the ray's origin (its turning point, gap1 = 0, or l = 0). The cylinder, the fillet
// and the flat part each in closed form or by the table, as differences that keep their precision
// when a1 and a2 are close.
vec2 geo_between(float b, float sigma, float a1, float gap1, float a2, float gap2, bool origin) {
	vec2 out_ = vec2(0.0);
	float Lc = g_prof.z, L = g_prof.w, R2 = 2.0 * g_prof.y;
	if (a1 < Lc) {
		// b < rho0 here: sqrt(rho0^2 - b^2) from sigma, exact near the photon sphere
		float k = sqrt(max(-R2 * sigma * (g_prof.x + b), 0.0));
		out_ += vec2(b / g_prof.x, g_prof.x) * ((min(a2, Lc) - a1) / max(k, 1e-12));
	}
	if (a2 > Lc && a1 < L) {
		// u at either end: a ray that turns on the fillet (sigma >= u0) has u = sigma + gap / 2R
		// there (r - b = 2R (u - sigma)), exact by the gap; from |l| u keeps only |l|'s float32 digits,
		// which on a long throat (|l| tens of metres) are fewer than a point next to the turn needs
		float ul = max(sigma, g_prof2.y);
		bool turns = sigma >= g_prof2.y;
		bool lo = origin || a1 <= Lc;
		float d1 = lo ? ul - sigma : gap1 / R2;
		float u1 = lo ? ul : (turns ? sigma + d1 : geo_u(a1));
		bool whole = a2 >= L;
		float d2 = whole ? (g_prof2.x - b) / R2 : gap2 / R2;
		float u2 = whole ? 0.5 : (turns ? sigma + d2 : geo_u(a2));
		out_ += geo_fillet(b, sigma, u1, d1, u2, d2, lo, whole);
	}
	if (a2 > L) {
		// r2 - r1 as the difference of the gaps: near a turning point the radii's own difference
		// keeps none of its digits
		float g1 = a1 <= L ? g_prof2.x - b : gap1;
		float r1 = b + g1, r2 = b + gap2;
		float q1 = sqrt(max(g1 * (r1 + b), 0.0));
		float q2 = sqrt(max(gap2 * (r2 + b), 0.0));
		float dq = (gap2 - g1) * (r2 + r1) / max(q1 + q2, GEO_TINY20);
		out_ += vec2(geo_atan2(b * dq, b * b + q1 * q2), dq);
	}
	return out_;
}

// where a ray of impact b starts counting: |l| of its turning point (b >= rmin) or 0
float geo_origin(float b, float sigma) {
	if (b >= g_prof2.x) return b - g_prof2.x + g_prof.w;
	if (sigma < g_prof2.y) return 0.0;
	return g_prof.z + g_prof.y * (2.0 * geo_asin(sqrt(clamp(sigma, 0.0, 0.5))) - g_prof2.w);
}

// (psi, len) from the ray's origin to |l| = a (gap = r - b there)
vec2 geo_from_origin(float b, float sigma, float a, float gap) {
	return geo_between(b, sigma, geo_origin(b, sigma), 0.0, a, gap, true);
}

// ---------------------------------------------------------------- the eyes
// The eye of the current view: the head (head_l, head_n, its frame head_f = play x, y, z as
// tangent vectors) and its place in the room (head_pos), and the view's camera as Godot gives it.
// Under multiview INV_VIEW_MATRIX is one camera for both eyes, set back so that its frustum holds
// both; each eye sits at EYE_OFFSET in that camera's space (its own turn is in its projection). So:
// The ray from the eye seen at clip (x, y) by projection P, in the camera's space: to the point
// there that P puts at w = 1, so linear across the picture (a varying between corners is exact).
// Only P's rows x, y and w say it, whatever its depth row (near and far) is.
vec3 geo_view_ray(mat4 P, vec2 clip) {
	return inverse(mat3(P[0].xyw, P[1].xyw, P[2].xyw)) * vec3(clip, 1.0);
}

// the eye at inv_view * eye_offset, the camera's axes (right, up, back) carried there; a point's
// place in the camera's space is eye_offset plus its direction from the eye along those axes. The
// eye is the head moved by the play-space offset, to second order along the geodesic
// (|offset| ~ 5 cm: below 1e-4 rad at 20 cm), the frame carried to first order.
void geo_eye(mat4 inv_view, vec3 eye_offset, out float el, out vec3 en, out vec4 ex, out vec4 ey, out vec4 ez) {
	vec3 o = (inv_view * vec4(eye_offset, 1.0)).xyz - head_pos;
	vec4 O = o.x * head_f[0] + o.y * head_f[1] + o.z * head_f[2];
	float r = geo_r(abs(head_l));
	float k = geo_drdw(head_l).x / r;
	vec3 v = O.yzw;
	float vv = dot(v, v);
	el = head_l + O.x + 0.5 * k * vv;
	en = normalize(head_n + v / r - k * O.x * v / r - 0.5 * vv / (r * r) * head_n);
	vec4 f[3];
	for (int j = 0; j < 3; j++) {
		vec4 A = head_f[j];
		vec3 au = A.yzw;
		vec3 du = -k * A.x * v - (dot(au, v) / r) * head_n;
		vec3 nu = au + du;
		nu -= dot(nu, en) * en;
		f[j] = vec4(A.x + k * dot(v, au), nu);
	}
	ex = inv_view[0].x * f[0] + inv_view[0].y * f[1] + inv_view[0].z * f[2];
	ey = inv_view[1].x * f[0] + inv_view[1].y * f[1] + inv_view[1].z * f[2];
	ez = inv_view[2].x * f[0] + inv_view[2].y * f[1] + inv_view[2].z * f[2];
}

// ---------------------------------------------------------------- seeing a point
// The geodesics along which the eye at (el, en) sees the point (pl, pn). Every one lies in a plane
// through the centre, and in it turns from en to pn by alpha + 2 pi k on one side or 2 pi (k + 1) -
// alpha on the other (alpha the angle between en and pn, k = 0, 1...): on the plane's surface,
// whose curvature is nowhere positive, one geodesic for each, the images of the point
// (docs/geometry.md). geo_see_to finds the one that leaves the eye toward t (a unit vector
// orthogonal to en, in the plane) and turns by target to reach the point (pn = cos target en + sin
// target t). Returns the launch direction as a tangent vector at the eye (.xyzw) and the length
// (out len); arrive: the direction it comes in at the point, as a vector of R^4; fell: 1/2 where a
// ray of the search came out not finite (passed over), 1 where none was finite and the stand-in
// below took the search's place (ref/test_gpu.py: never either). straight: the turn is alpha the
// short way (the first image), which the straight line takes where it can.
// Taken at once where a closed form is the geodesic (geo_see_segment, geo_see_unrolled). Else the
// ray is found among those that reach |l| = |pl| (below): GEO_ITERS rays, the first the one between
// the two families, then false position with halving (Illinois) in the family that holds the point,
// until a ray turns to within GEO_TOL of the target (how many it takes: ref/test_gpu.py).
const int GEO_ITERS = 12;
const int GEO_SPARE = 8;
const float GEO_TOL = 1e-5;

// The straight line on the throat's cylinder unrolled from the eye (side, |l| = le, r = re) to the
// point (lp on the eye's side), turned by delta toward t (scd: its sine and cosine). Where both are
// in the cylinder, the space there is the product of l and a sphere of radius rho0 and this is the
// geodesic (geo_see_to's families can't take a point at about the eye's l there: their rays circle
// the cylinder, their sweep grows without bound as they turn tangent, and the length comes out of a
// division by their dl/ds). Elsewhere geo_see_to's stand-in.
vec4 geo_see_unrolled(float side, float le, float lp, float re, vec3 en, vec3 t, float delta, vec2 scd, out float len, out vec4 arrive) {
	float dl0 = lp - le, arc0 = re * delta;
	len = sqrt(dl0 * dl0 + arc0 * arc0);
	float cl0 = dl0 / max(len, GEO_TINY20), sl0 = arc0 / max(len, GEO_TINY20);
	arrive = vec4(sl0 * (scd.y * t - scd.x * en), side * cl0);
	return vec4(side * cl0, sl0 * t);
}

// The eye (side, r = re, direction en) and the point (r = rp, pn) in the same flat universe: the
// segment between them (in R^4's xyz there) if it stays out of the curved zone (its nearest point to
// the centre at least Rout from it), its direction at the eye, its length and the direction it comes
// in at (dir, len, arrive); else false.
bool geo_see_segment(float side, float re, vec3 en, float rp, vec3 pn, inout vec4 dir, inout float len, inout vec4 arrive) {
	vec3 xe = re * en;
	vec3 dv = rp * pn - xe;
	float d2 = max(dot(dv, dv), GEO_TINY20);
	vec3 m = xe + clamp(-dot(xe, dv) / d2, 0.0, 1.0) * dv;
	if (dot(m, m) < g_prof2.x * g_prof2.x) return false;
	len = sqrt(d2);
	vec3 u = dv / len;
	arrive = vec4(u, 0.0);
	float cu = dot(u, en);
	dir = vec4(side * cu, u - cu * en);
	return true;
}

vec4 geo_see_to(float el, vec3 en, float pl, vec3 pn, vec3 t, float target, bool straight, out float len, out vec4 arrive, out float fell) {
	// One way out, nothing skipped in the loop: what the wave's vertices do apart is only their
	// branches.
	float side = el < 0.0 ? -1.0 : 1.0;
	float le = abs(el);
	float lp = side * pl;           // the eye's side is +
	float alp = abs(lp);
	float dre = geo_dr(le), drp = geo_dr(alp);       // r - rho0 at each
	float re = g_prof.x + dre, rp = g_prof.x + drp;
	// Taken at once: with straight, both in the eye's flat universe and the segment between them
	// clear of the curved zone, the segment (geo_see_segment); both in the throat's cylinder, the line
	// on it unrolled (geo_see_unrolled, below).
	vec4 dir = vec4(0.0);
	len = 0.0;
	arrive = vec4(0.0);
	fell = 0.0;
	if (!(straight && le >= g_prof.w && lp >= g_prof.w && geo_see_segment(side, re, en, rp, pn, dir, len, arrive))) {
		float rmin = g_prof2.z;
		float dr0 = 2.0 * g_prof.y * g_prof2.y;             // r_min - rho0
		float delta = target;
		vec2 scd = geo_sincos(delta);
		bool found = false;
		if (le > g_prof.z || alp > g_prof.z) {
			// The rays that reach |l| = |lp|, by their launch angle from the radial direction
			// (outward for lp >= le, else inward): the first crossings, ang in [0, A1) (A1: the
			// tangent going out, else the ray grazing the point's sphere, or r_min for a point in
			// the cylinder or past l = 0), along which the turn psi grows from 0; then, where rays
			// turn back to the point, those that turn first, launched inward at a_min + e from e =
			// A1 - a_min down to the photon sphere's e = 0, along which it grows on without bound.
			// The ray between the two (eps = 0, e = cT) tells which holds the point. The first
			// crossings' psi goes as ang near 0, and near A1 (eps = A1 - ang) up to the ray
			// between's psi_t as eps, or without bound as a power of 1 / eps where that ray keeps
			// to the cylinder: searched in y = log(ang / eps) on log(psi / (psi_t - psi)) (log psi
			// without psi_t), near straight in y at both ends whichever. The turned ones' psi goes
			// as log 1 / e: searched in v = log(cT / e) on psi itself. Every angle near those ends
			// is carried as its complement, every b - rho0 as a product: float32 keeps them.
			bool outw = lp >= le;
			bool cross_ = (lp <= 0.0) || (drp <= dr0);
			float c1 = geo_atan2(sqrt(max((dre - dr0) * (re + rmin), 0.0)), rmin);   // pi/2 - asin(r_min / re)
			float a_min = 0.5 * GEO_PI - c1;
			float cA = 0.0, dA = dre;         // pi/2 - A1, and b - rho0 at A1
			if (!outw) {
				cA = cross_ ? c1 : geo_atan2(sqrt(max((dre - drp) * (re + rp), 0.0)), rp);
				dA = cross_ ? dr0 : drp;
			}
			float A1 = 0.5 * GEO_PI - cA;
			float cT = c1 - cA;               // the turned ones' span of e
			if (!outw && !cross_) {
				// asin(rp / re) - asin(rmin / re) without the difference of two angles near pi/2
				float cx = sqrt(max((dre - drp) * (re + rp), 0.0)) / re, cy = sqrt(max((dre - dr0) * (re + rmin), 0.0)) / re;
				cT = geo_asin((drp - dr0) * (rp + rmin) / (re * re) / max((rp * cy + rmin * cx) / re, GEO_TINY));
			}
			bool two = outw ? dre > dr0 : !cross_;
			const float WMAX = 24.0;          // the ends' distances down to 4e-11 of their span (the turned ones near r_min need 1e-7)
			int fam = two ? -1 : 0;           // -1: the ray between, 0: first crossings, 1: turned
			float lo = -WMAX, hi = WMAX, flo = 0.0, fhi = 0.0;
			bool have_lo = false, have_hi = false;
			float psit = 0.0, gt = 0.0;       // the ray between's psi, the target log(delta / (psi_t - delta))
			// the first crossings' first guess: the straight line on the cylinder unrolled
			float ang0 = clamp(geo_atan2(re * delta, abs(lp - le)), 1e-6 * A1, (1.0 - 1e-6) * A1);
			float x = log(ang0 / (A1 - ang0));
			int last = 0;
			float jeps = 0.0;                 // the ray between, or one beside it should it not be finite
			float best = 1e30;                // the kept ray's |val|
			int nbad = 0;                     // rays not finite: each buys one more, up to GEO_SPARE
			bool blind = false;               // the ray between not known: the family found by searching
			vec2 res = vec2(0.0);
			float dsa = 0.0, dca = 1.0;       // the found ray's launch direction: (along the outward radial, across)
			bool tlast = false;               // the found ray turned
			float b = 0.0, gp = 0.0;          // its impact and r - b at the point
			vec2 scA = geo_sincos(cA), sc1 = geo_sincos(c1);
			for (int i = 0; i < GEO_ITERS + GEO_SPARE; i++) {
				if (i >= GEO_ITERS + nbad) break;
				// the ray: sin and cos of its launch angle's complement, base + 2 g h (the first
				// crossings: cA + eps, the turned: c1 - e), from those of the base and of h (half
				// the step) by the sums; b - rho0 from the product
				bool turned = fam == 1;
				float ex = exp(-abs(x));
				float g = turned ? -1.0 : 1.0;
				float h = 0.5 * (turned ? cT * exp(-x) : (fam < 0 ? jeps : A1 * (x > 0.0 ? ex : 1.0) / (1.0 + ex)));
				vec2 sb = turned ? sc1 : scA;
				vec2 sh = geo_sincos(h);
				float sm = sb.x * sh.y + g * sb.y * sh.x;     // sin(base + g h)
				float cm = sb.y * sh.y - g * sb.x * sh.x;     // cos(base + g h)
				float ca = sm * sh.y + g * cm * sh.x;
				float sa = cm * sh.y - g * sm * sh.x;
				float bmr = (turned ? dr0 : dA) - g * 2.0 * re * sm * sh.x;
				float bp = re * sa;
				float sigma = geo_sigma(bmr);
				float gap_e = re * ca * ca / (1.0 + sa);     // re - b
				// rp - b: from the ray's own b - rho0 where the point is nearer the throat than the eye (next to
					// its turning point the difference of the eye's gaps keeps none of its digits)
					float gap_p = abs(drp) < abs(dre) ? drp - bmr : (drp - dre) + gap_e;
				// its sweep and length to the point: between the two |l| on one stretch, or from its
				// origin to each (turned, or through l = 0): one geo_between in the code, run once or twice
				bool twice = turned || (!outw && lp < 0.0);
				float org = twice ? geo_origin(bp, sigma) : 0.0;
				vec2 s = vec2(0.0);
				for (int k = 0; k < 2; k++) {
					if (k == 1 && !twice) break;
					bool to_p = twice ? k == 1 : outw;           // the stretch ends at the point
					s += geo_between(bp, sigma, twice ? org : (outw ? le : alp), twice ? 0.0 : (outw ? gap_e : gap_p),
							to_p ? alp : le, to_p ? gap_p : gap_e, twice);
				}
				float val = s.x - delta;
				if (fam == 0) val = log(max(s.x, GEO_TINY)) - (two ? log(max(psit - s.x, GEO_TINY)) + gt : log(max(delta, GEO_TINY)));
				// A ray whose numbers came out not finite tells nothing: the bracket stays, the next
				// ray is a quarter of the way from it to the bracket's far end (the ray between: one
				// a little beside it), and the ray kept is the finite one nearest the point.
				bool ok = geo_finite(s.x + s.y + val + ca + sa);
				if (!ok) { fell = 0.5; nbad++; }
				if (ok && (fam < 0 || abs(val) <= best)) {
					best = fam < 0 ? 1e30 : abs(val);
					res = s;
					dca = (outw && !turned) ? ca : -ca;
					dsa = sa;
					tlast = turned;
					gp = gap_p;
					b = bp;
				}
				if (fam < 0 && !ok && i < 2) {
					jeps = jeps > 0.0 ? 30.0 * jeps : 1e-5 * A1;
				} else if (fam < 0) {
					// the ray between: the point among the first crossings if this one has turned
					// past it (if neither it nor the ones beside it is finite, they are searched as
					// if no ray turned)
					psit = s.x;
					gt = log(max(delta, GEO_TINY) / max(psit - delta, GEO_TINY));
					fam = ok && s.x <= delta ? 1 : 0;
					blind = two && !ok;
					two = ok;
					if (fam == 1) { lo = 0.0; flo = s.x - delta; have_lo = true; x = 0.5 * WMAX; }
				} else if (!ok) {
					x += 0.25 * ((x > 0.5 * (lo + hi) ? lo : hi) - x);
				} else {
					// this ray turns to within GEO_TOL of the point's angle (a relative share of it
					// among the first crossings): it is the one
					if (abs(val) <= GEO_TOL) break;
					// Illinois: the end kept twice in a row has its value halved. Until a ray each
					// side of the point is known, halve the bracket: neither end's value is
					// bounded.
					if (val > 0.0) { hi = x; fhi = val; if (last > 0) flo *= 0.5; last = 1; have_hi = true; }
					else { lo = x; flo = val; if (last < 0) fhi *= 0.5; last = -1; have_lo = true; }
					x = (have_lo && have_hi) ? (lo * fhi - hi * flo) / (fhi - flo) : 0.5 * (lo + hi);
					if (blind && fam == 0 && !have_hi && lo > 0.5 * WMAX) {
						// all the first crossings fall short of the point: it is among the turned
						fam = 1; lo = 0.0; hi = WMAX; have_lo = false; last = 0; x = 0.5 * WMAX;
					}
				}
			}
			// arriving: in the plane, (dl/ds, b / rp) in (radial, toward growing angle)
			float vr = sqrt(max(gp * (rp + b), 0.0)) / rp;
			bool arrive_out = outw || tlast;          // moving to growing |l| at the point (eye's side +)
			float dl = (arrive_out ? 1.0 : -1.0) * vr;
			vec2 dd = geo_drdw(pl);
			float dls = side * dl;                    // dl/ds in the true l
			vec3 tau = -scd.x * en + scd.y * t;       // toward growing angle at pn
			vec4 arr = vec4(dls * dd.x * pn + (b / rp) * tau, dls * dd.y);
			// the search's ray if any was finite. Its length with the turns it falls short of: a point
			// a hair from the cylinder's end many turns round is reached by a ray closer to r_min than
			// float32 tells (its direction that of r_min's to the last digit), and a turn more there is
			// r_min^2 / b of length, r_min
			float lens = res.y + (delta - res.x) * rmin;
			found = geo_finite(lens + dca + dsa + arr.x + arr.y + arr.z + arr.w) && lens > 0.0 && lens < 1e7;
			len = lens;
			arrive = arr;
			dir = vec4(side * dca, dsa * t);
			if (!found) fell = 1.0;
		}
		if (!found) {
			// both in the cylinder, or no ray of the search came out finite (which a GPU's
			// arithmetic must never make a hole of)
			dir = geo_see_unrolled(side, le, lp, re, en, t, delta, scd, len, arrive);
		}
	}
	return dir;
}

// The first image: the geodesic that turns by the angle between en and pn the short way.
vec4 geo_see(float el, vec3 en, float pl, vec3 pn, out float len, out vec4 arrive, out float fell) {
	float c = dot(en, pn);
	vec3 cr = cross(en, pn);
	float sd = length(cr);
	vec3 t = sd > 1e-9 ? (pn - c * en) / sd : (abs(en.z) < 0.9 ? normalize(cross(en, vec3(0.0, 0.0, 1.0))) : normalize(cross(en, vec3(1.0, 0.0, 0.0))));
	return geo_see_to(el, en, pl, pn, t, geo_atan2(sd, c), true, len, arrive, fell);
}

// Image j of the point (j = 0 the first; then by the turn: 2 pi - alpha, 2 pi + alpha, 4 pi -
// alpha...), the plane's direction t from en toward pn and alpha the angle between them.
vec4 geo_see_image(float el, vec3 en, float pl, vec3 pn, vec3 t, float alpha, int j, out float len, out vec4 arrive, out float fell) {
	float k = float(j / 2);
	bool far = (j & 1) == 1;
	float target = far ? 2.0 * GEO_PI * (k + 1.0) - alpha : alpha + 2.0 * GEO_PI * k;
	return geo_see_to(el, en, pl, pn, far ? -t : t, target, j == 0, len, arrive, fell);
}

// ---------------------------------------------------------------- a ray's way out of the zone
// Outside the curved zone a ray is straight, and a straight ray that leaves the zone's ball never
// comes back; the floor and the sky are out there. So a ray goes straight from an eye outside until
// the ball (or for ever), turns in its plane through the centre across the zone, and leaves it
// straight into universe A or B (into the other one only with b < r_min): all its turns round the
// throat are in between, however many.
// The ray D of the eye (as geo_exit): the cosine and sine of its angle off the outward radial (ca,
// sa), its unit direction across it (t), its impact b, r - b at the eye (gap: exact for rays along
// the sphere of the eye) and sigma (geo_sigma); false if it never enters the zone (the eye outside).
bool geo_exit_ray(float el, vec3 eye, vec3 en, vec4 D, out float ca, out float sa, out vec3 t, out float b, out float gap, out float sigma) {
	float side = el < 0.0 ? -1.0 : 1.0;
	float re = eye.x;
	ca = side * D.x;                    // along the outward radial direction
	sa = length(D.yzw);
	t = sa > 1e-7 ? D.yzw / sa : normalize(cross(en, abs(en.z) < 0.9 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0)));
	float nrm = inversesqrt(ca * ca + sa * sa);
	ca *= nrm;
	sa *= nrm;
	b = re * sa;
	gap = re * (ca * ca / (1.0 + sa));  // 1 - sin: exact for rays along the sphere of the eye
	sigma = geo_sigma(eye.z - gap);
	return !(abs(el) >= g_prof.w && (ca >= 0.0 || b >= g_prof2.x));
}

// A ray's turn and length per metre of l along the throat's cylinder: those of a ray that passes
// the throat (b < r_min) where there is a cylinder (h > R), next to r_min many turns a metre; else 0.
vec2 geo_exit_cyl(float b, float sigma) {
	float k = sqrt(max(-2.0 * g_prof.y * sigma * (g_prof.x + b), 0.0));
	return sigma < g_prof2.y ? vec2(b / g_prof.x, g_prof.x) / max(k, 1e-12) : vec2(0.0);
}

// The metres of the cylinder that a ray from the eye at |l| = le crosses on its way out, if it
// passes the throat: outward to the cylinder's end, inward through l = 0 to its other end.
float geo_exit_mc(float le, bool outward) {
	float Lc = g_prof.z;
	return outward ? max(Lc - le, 0.0) : Lc + min(le, Lc);
}

// A ray's way across the zone besides its way along the cylinder (geo_exit_way), from the eye at
// |l| = le (eye as geo_exit has it) by its impact b, sigma and gap (geo_exit_ray) and whether it
// starts outward: its turn in its plane and its length.
vec2 geo_exit_rest(float le, vec3 eye, float b, float sigma, float gap_e, bool outward) {
	float re = eye.x;
	float L = g_prof.w, Rout = g_prof2.x;
	float R2 = 2.0 * g_prof.y;
	// the fillet's closed forms
	float ul = max(sigma, g_prof2.y);
	float span = 0.5 - ul;
	vec2 f0 = geo_F(b, ul);
	vec2 f1 = geo_Fu(b, ul, f0);
	float s0 = sqrt(ul), e0 = sqrt(ul - sigma);
	float Dw = s0 + e0, P0 = s0 * e0;
	float sL = sqrt(max(0.5 - sigma, 0.0));
	float wL = 2.0 * log((0.70710678 + sL) / Dw);
	// on the fillet from the ray's origin (its turning point, or the cylinder's end) to the zone's edge
	vec2 SLf = f0 * wL + f1 * (0.70710678 * sL - P0 + (0.5 * sigma - ul) * wL) + geo_G(sigma, 1.0);
	float Lc = g_prof.z;
	vec2 rest;
	if (le >= L) {
		// from the edge in to the origin and out again, and straight from the eye to the edge
		float qR = sqrt(max((Rout - b) * (Rout + b), 0.0));
		float q2 = sqrt(max(gap_e * (re + b), 0.0));
		float dq = (re - Rout) * (re + Rout) / max(qR + q2, GEO_TINY20);
		rest = 2.0 * SLf + vec2(geo_atan2(b * dq, b * b + qR * q2), dq);
	} else if (le > Lc) {
		// on the fillet from the origin to the eye
		float su = eye.y, eu = sqrt(gap_e / R2);
		float ue = su * su;
		float w = 2.0 * log((su + eu) / Dw);
		vec2 sef = f0 * w + f1 * (su * eu - P0 + (0.5 * sigma - ul) * w) + geo_G(sigma, sqrt(max(ue - ul, 0.0) / span));
		// outward from the eye to the edge; inward to the origin and out to the edge
		rest = outward ? SLf - sef : SLf + sef;
	} else {
		rest = SLf;
	}
	return rest;
}

// A ray's way across the zone, as geo_exit_rest takes it: (its turn in its plane, its length, 1 if
// it goes on into the other universe, else 0). Out along its way from the eye: outward straight to
// the edge; inward through the origin (to the other universe if it passes the throat).
vec3 geo_exit_way(float le, vec3 eye, float b, float sigma, float gap_e, bool outward) {
	return vec3(geo_exit_rest(le, eye, b, sigma, gap_e, outward) + geo_exit_mc(le, outward) * geo_exit_cyl(b, sigma),
			!outward && sigma < g_prof2.y ? 1.0 : 0.0);
}

// Where the ray of impact b, across direction t of the eye at en, leaves the zone having turned by
// turn in its plane: the point (|pos| = Rout) and its direction there, in R^4's xyz.
void geo_exit_at(vec3 en, vec3 t, float b, float turn, out vec3 pos, out vec3 dir) {
	float Rout = g_prof2.x;
	float qR = sqrt(max((Rout - b) * (Rout + b), 0.0));
	vec2 sc = geo_sincos(turn);
	vec3 nx = sc.y * en + sc.x * t;
	vec3 tx = sc.y * t - sc.x * en;
	pos = Rout * nx;
	dir = (qR * nx + b * tx) / Rout;    // b = Rout sin of its angle off the outward radial
}

// The ray D (a tangent vector at the eye, any length) of the eye at (el, en), eye = (r, the root of
// u, r - rho0) there (geo_r, geo_u, geo_dr, worked out once per eye). False for a ray that never
// enters the zone (the eye outside): then pos is the eye's place, dir the ray's direction, sheet the
// eye's universe (+1 A, -1 B), all in R^4's xyz. Else true: pos is where it leaves the zone (|pos| =
// Rout), dir its direction there, sheet the universe it goes on in, way the length up to there.
// In the three steps above, which our own foveation's floor shares (geo_xt below): the ray
// (geo_exit_ray), its way across the zone (geo_exit_way), where it leaves (geo_exit_at).
bool geo_exit(float el, vec3 eye, vec3 en, vec4 D, out vec3 pos, out vec3 dir, out float sheet, out float way) {
	float ca, sa, b, gap, sigma;
	vec3 t;
	bool in_ = geo_exit_ray(el, eye, en, D, ca, sa, t, b, gap, sigma);
	sheet = el < 0.0 ? -1.0 : 1.0;
	way = 0.0;
	pos = eye.x * en;
	dir = ca * en + sa * t;
	if (!in_) return false;
	vec3 w = geo_exit_way(abs(el), eye, b, sigma, gap, ca >= 0.0);
	if (w.z > 0.5) sheet = -sheet;
	geo_exit_at(en, t, b, w.x, pos, dir);
	way = w.y;
	return true;
}

// ---------------------------------------------------------------- the way out by a table
// Foveation's floor (foveation.gdshaderinc) works the way out of the zone out for every
// texel of its picture, and from inside the zone every one goes through it. For one eye a ray's way
// across hangs only on its sigma and whether it starts outward (geo_exit_way): so each frame a row
// per eye and start (outward, inward) holds it (besides its way along the cylinder, which a texel
// adds: geo_exit_cyl, cheap, and next to r_min many turns) at GEO_XN rays from b = 0 to b = b_max
// (r of an eye in the zone, Rout of one outside), evenly in
//   x = sign(d) ln(1 + |d| / GEO_XA) - ln(1 + g / GEO_XB),   d = sigma - u0,  g = (b_max - b) / 2R:
// crowded next to d = 0 (b = r_min: the photon sphere, or the crease), where the turn grows as
// ln |d|, a straight line in x, and next to b_max (a ray along the sphere of the eye, or grazing the
// zone's ball), where it bends as the root of g. A texel takes the way between its row's two nodes
// about it, linearly in x, where the cell between them is good (geo_xt_good: the ray half way
// between is off that line by at most GEO_XTOL, a few times the way's own error in float32, which
// alone then fails no cell: ref/test_gpu.py); elsewhere
// (next to d = 0 within what x resolves, a turn of many thousands) it takes geo_exit_way itself.
// ref/test_gpu.py checks the texels' ways out as geo_exit's.
const int GEO_XN = 4096;
const float GEO_XA = 1e-8;
const float GEO_XB = 1e-7;
const float GEO_XTOL = 3e-5;           // radians of turn
const float GEO_XTOL_WAY = 1e-4;       // metres, and as a share of the length

float geo_xt_s(float d) { return sign(d) * log(1.0 + abs(d) / GEO_XA); }

// a ray's place along its eye's row, by its d and g
float geo_xt_x(float d, float g) { return geo_xt_s(d) - log(1.0 + g / GEO_XB); }

// a ray's g from its b and gap (geo_exit_ray), for the eye at |l| = le
float geo_xt_g(float le, float b, float gap) { return (le >= g_prof.w ? g_prof2.x - b : gap) / (2.0 * g_prof.y); }

// the eye's rows' ends: x at b = 0 and at b = b_max
vec2 geo_xt_range(float le, vec3 eye) {
	float R2 = 2.0 * g_prof.y;
	bool out_ = le >= g_prof.w;
	return vec2(geo_xt_x(-g_prof.x / R2 - g_prof2.y, (out_ ? g_prof2.x : eye.x) / R2),
			geo_xt_x((out_ ? g_prof2.x - g_prof.x : eye.z) / R2 - g_prof2.y, 0.0));
}

// the ray at place x of the eye's row: its sigma, gap and b as geo_exit_ray would give them. Newton
// in x's first term s = sign(d) ln(1 + |d| / GEO_XA), kept within its bracket; where that leaves g
// small, again in its second, t = ln(1 + g / GEO_XB): next to b_max s in float32 no longer tells g
// from 0 (its step there is 2e-6), t does.
void geo_xt_ray(float le, vec3 eye, float x, out float sigma, out float gap, out float b) {
	float R2 = 2.0 * g_prof.y, u0 = g_prof2.y;
	bool out_ = le >= g_prof.w;
	float lo = geo_xt_s(-g_prof.x / R2 - u0), hi = geo_xt_s((out_ ? g_prof2.x - g_prof.x : eye.z) / R2 - u0);
	float s = clamp(x, lo, hi);         // x <= s
	float g = 0.0;
	for (int i = 0; i < 30; i++) {
		float d = sign(s) * GEO_XA * (exp(abs(s)) - 1.0);
		sigma = u0 + d;
		sigma = abs(sigma) < 1e-14 ? (sigma < 0.0 ? -1e-14 : 1e-14) : sigma;   // as geo_sigma
		gap = max(eye.z - R2 * sigma, 0.0);
		b = eye.x - gap;
		g = geo_xt_g(le, b, gap);
		float F = s - log(1.0 + g / GEO_XB) - x;
		if (abs(F) < 1e-6) break;
		if (F > 0.0) hi = s; else lo = s;
		float sn = s - F / (1.0 + (GEO_XA + abs(d)) / (GEO_XB + g));
		s = sn > lo && sn < hi ? sn : 0.5 * (lo + hi);
	}
	if (g >= 1e-3) return;
	// the ray by its g: gap from it in the zone, b from it outside, sigma from gap (geo_exit_ray)
	float tlo = 0.0, thi = log(1.0 + 1e-2 / GEO_XB);
	float t = clamp(log(1.0 + g / GEO_XB), tlo, thi);
	for (int i = 0; i < 30; i++) {
		g = GEO_XB * (exp(t) - 1.0);
		if (out_) {
			b = g_prof2.x - R2 * g;
			gap = eye.x - b;
		} else {
			gap = R2 * g;
			b = eye.x - gap;
		}
		sigma = geo_sigma(eye.z - gap);
		float d = sigma - u0;
		float F = geo_xt_s(d) - t - x;
		if (abs(F) < 1e-6) break;
		if (F < 0.0) thi = t; else tlo = t;
		float tn = t + F / (1.0 + GEO_XB * exp(t) / (GEO_XA + abs(d)));
		t = tn > tlo && tn < thi ? tn : 0.5 * (tlo + thi);
	}
}

// the node at place k (0 .. GEO_XN - 1, a half for the ray between two) of the eye's row: its way
// across besides the cylinder's (geo_exit_rest), and its own x
vec3 geo_xt_node(float le, vec3 eye, bool outward, vec2 xr, float k) {
	float sigma, gap, b;
	geo_xt_ray(le, eye, mix(xr.x, xr.y, k / float(GEO_XN - 1)), sigma, gap, b);
	return vec3(geo_exit_rest(le, eye, b, sigma, gap, outward), geo_xt_x(sigma - g_prof2.y, geo_xt_g(le, b, gap)));
}

// whether a ray between nodes a and c of a row may take the line between them, m the node between
bool geo_xt_good(vec3 a, vec3 m, vec3 c) {
	vec2 line = mix(a.xy, c.xy, (m.z - a.z) / (c.z - a.z));
	return geo_finite(a.x + a.y + m.x + m.y + c.x + c.y + line.x + line.y) && c.z > a.z
			&& abs(m.x - line.x) <= GEO_XTOL && abs(m.y - line.y) <= GEO_XTOL_WAY * (1.0 + abs(m.y));
}

// texel k of the eye's row (the table's pass writes them): node k (geo_xt_node), and 1 if the cell
// from it to node k + 1 is good, else 0
vec4 geo_xt_texel(float le, vec3 eye, bool outward, vec2 xr, int k) {
	vec3 a = geo_xt_node(le, eye, outward, xr, float(k));
	if (k >= GEO_XN - 1) return vec4(a, 0.0);
	vec3 m = geo_xt_node(le, eye, outward, xr, float(k) + 0.5);
	vec3 c = geo_xt_node(le, eye, outward, xr, float(k + 1));
	return vec4(a, geo_xt_good(a, m, c) ? 1.0 : 0.0);
}

// a ray's place in its eye's row (b, gap and sigma from geo_exit_ray, xr from geo_xt_range): its x,
// and the node k at or before it
float geo_xt_place(float le, float b, float gap, float sigma, vec2 xr, out int k) {
	float x = geo_xt_x(sigma - g_prof2.y, geo_xt_g(le, b, gap));
	k = clamp(int((x - xr.x) / (xr.y - xr.x) * float(GEO_XN - 1)), 0, GEO_XN - 2);
	return x;
}

// a ray's way across (as geo_exit_way gives it) from its row's texels k and k + 1 and its x
// (geo_xt_place); the rest as geo_exit_way takes it, for a cell that is not good
vec3 geo_xt_way(vec4 a, vec4 c, float x, float le, vec3 eye, float b, float sigma, float gap, bool outward) {
	if (a.w < 0.5) return geo_exit_way(le, eye, b, sigma, gap, outward);
	return vec3(mix(a.xy, c.xy, (x - a.z) / (c.z - a.z)) + geo_exit_mc(le, outward) * geo_exit_cyl(b, sigma),
			!outward && sigma < g_prof2.y ? 1.0 : 0.0);
}

// ---------------------------------------------------------------- points of R^4
// The space as the hypersurface (r(l) n, w(l)) of R^4 (docs/geometry.md): its profile curve in the
// quarter plane (rho = |xyz|, a = |w|) is the tube rho = rho0, the fillet's arc round
// K = (Rout, Lc - R sin th0) and the sheet a = h. The signed distance to it (positive between the
// sheets and outside the tube) and its gradient (d/drho, d/dw).
vec3 geo_sdf(float rho, float w) {
	float a = abs(w);
	float sw = w < 0.0 ? -1.0 : 1.0;
	float R = g_prof.y;
	float Kr = g_prof2.x, Ka = g_prof.z - R * geo_sin(g_prof2.w);
	float dr = rho - Kr, da = a - Ka;
	if (dr <= 0.0 && da <= 0.0) return vec3(rho - g_prof.x, 1.0, 0.0);
	if (dr >= 0.0 && da >= 0.0) return vec3(Ka + R - a, 0.0, -sw);
	if (dr < 0.0) {
		float q = length(vec2(dr, da));
		return vec3(R - q, -dr / q, -da / q * sw);
	}
	float d1 = rho - g_prof.x, d2 = Ka + R - a;
	return d1 < d2 ? vec3(d1, 1.0, 0.0) : vec3(d2, 0.0, -sw);
}

// the unit normal of the space at its point P (WormholeSpace.normal4 up to sign)
vec4 geo_normal(vec4 P) {
	float rho = length(P.xyz);
	vec3 s = geo_sdf(rho, P.w);
	return normalize(vec4(s.y * P.xyz / rho, s.z));
}

// the point of the space on the line Q0 + c N nearest c = 0 (N about normal there): Newton on c
vec4 geo_onto(vec4 Q0, vec4 N) {
	float c = 0.0;
	for (int i = 0; i < 4; i++) {
		vec4 Q = Q0 + c * N;
		float rho = length(Q.xyz);
		vec3 s = geo_sdf(rho, Q.w);
		c -= s.x / (s.y * dot(Q.xyz, N.xyz) / rho + s.z * N.w);
	}
	return Q0 + c * N;
}

// (l, n) of the space's point P
float geo_l_of(vec4 P, out vec3 n) {
	float rho = length(P.xyz);
	n = P.xyz / rho;
	float a = abs(P.w);
	float sw = P.w < 0.0 ? -1.0 : 1.0;
	float R = g_prof.y;
	float Kr = g_prof2.x, Ka = g_prof.z - R * geo_sin(g_prof2.w);
	if (rho >= Kr) return sw * (g_prof.w + rho - Kr);
	if (a <= Ka) return P.w;
	return sw * (g_prof.z + R * (geo_atan2(a - Ka, Kr - rho) - g_prof2.w));
}

// the vector of R^4 orthogonal to a, b and c (their 4D cross product)
vec4 geo_cross4(vec4 a, vec4 b, vec4 c) {
	return vec4(
		dot(a.yzw, cross(b.yzw, c.yzw)),
		-dot(a.xzw, cross(b.xzw, c.xzw)),
		dot(a.xyw, cross(b.xyw, c.xyw)),
		-dot(a.xyz, cross(b.xyz, c.xyz)));
}
