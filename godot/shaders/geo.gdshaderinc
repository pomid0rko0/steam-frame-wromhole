// The space and its rays, for every shader that draws (floor.gdshader, body.gdshader and its
// variants): docs/geometry.md, «Как рисуется кадр». Plain GLSL apart from the uniforms, which the
// including shader declares (geo_uniforms.gdshaderinc; ref/test_gpu.py declares its own):
//   g_prof  = (rho0, R, Lc, L)          the throat (WormholeSpace)
//   g_prof2 = (Rout, u0, rmin, th0)     u0 = sin^2(th0 / 2): where the fillet starts
//   g_tabx  = (t0, 1 / (t1 - t0), nb, nv)   the table's axes (WormholeSpace.sweep_table)
//   g_tab   the table G(b, v): psi in .r, length in .g
//   g_poly[9]  G(b, 1/2) as Chebyshev series (geo_poly)
// A point is (l, n), n a unit vector of the shared angular sphere; a tangent vector is
// vec4(U_l, u) with u . n = 0 (WormholeSpace's top). A ray lies in the plane through the centre
// spanned by n and its direction; b is its impact parameter, and on the way from |l| = a1 to a2
// (no turning point between) its position angle turns by psi and it covers length len:
// geo_between. On the fillet they are closed forms plus the table's small rest (ref/geo.py's top).
//
// Precision: float32. Where a ray starts or ends next to its turning point, r - b ("gap") goes in
// from what knows it exactly (the eye's from its angle), not from a difference of two lengths.

const float GEO_PI = 3.14159265358979;

// atan(y, x) in [-pi, pi]: a minimax polynomial in the octant's ratio (off by 4e-8 rad, 1.2e-7 in
// float32) and the octants. Mesa's own atan takes about three times the instructions on the
// headset (tools/adreno_stats.sh --paths), and a floor pixel takes up to five. asin and acos go
// through it: Mesa's are polynomials good to only ~1e-4 rad.
float geo_atan2(float y, float x) {
	float ax = abs(x), ay = abs(y);
	float a = min(ax, ay) / max(max(ax, ay), 1e-30);
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

// the rest over the whole fillet, G(b, 1/2), without the table: Chebyshev series in t on each side
// of b = r_min (g_poly[k] = psi's and len's coefficients below, then above; WormholeSpace.sweep_table)
vec2 geo_poly(float sigma) {
	float s = sigma - g_prof2.y;
	float t = sign(s) * sqrt(abs(s));
	bool hi = s >= 0.0;
	float t1 = g_tabx.x + 1.0 / g_tabx.y;
	float x = hi ? 2.0 * t / t1 - 1.0 : 1.0 - 2.0 * t / g_tabx.x;
	vec2 b1 = vec2(0.0), b2 = vec2(0.0);
	for (int k = 8; k >= 1; k--) {
		vec2 c = hi ? g_poly[k].zw : g_poly[k].xy;
		vec2 b0 = c + 2.0 * x * b1 - b2;
		b2 = b1;
		b1 = b0;
	}
	return (hi ? g_poly[0].zw : g_poly[0].xy) + x * b1 - b2;
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
// integral; the table the rest. whole: u2 = 1/2, the rest there from geo_poly.
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
	out_ += whole ? geo_poly(sigma) : geo_G(sigma, sqrt(max(u2 - ul, 0.0) / span));
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
		float ul = max(sigma, g_prof2.y);
		bool lo = origin || a1 <= Lc;
		float u1 = lo ? ul : geo_u(a1);
		float d1 = lo ? ul - sigma : gap1 / R2;
		bool whole = a2 >= L;
		float u2 = whole ? 0.5 : geo_u(a2);
		float d2 = whole ? (g_prof2.x - b) / R2 : gap2 / R2;
		out_ += geo_fillet(b, sigma, u1, d1, u2, d2, lo, whole);
	}
	if (a2 > L) {
		// r2 - r1 as the difference of the gaps: near a turning point the radii's own difference
		// keeps none of its digits
		float g1 = a1 <= L ? g_prof2.x - b : gap1;
		float r1 = b + g1, r2 = b + gap2;
		float q1 = sqrt(max(g1 * (r1 + b), 0.0));
		float q2 = sqrt(max(gap2 * (r2 + b), 0.0));
		float dq = (gap2 - g1) * (r2 + r1) / max(q1 + q2, 1e-20);
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

// psi from the origin to infinity
float geo_psi_inf(float b, float sigma) {
	if (b >= g_prof2.x) return 0.5 * GEO_PI;
	return geo_from_origin(b, sigma, g_prof.w, g_prof2.x - b).x + geo_asin(b / g_prof2.x);
}

// On the fillet, the u where the sweep from u_lo is psi (0 <= psi <= the whole fillet's): the
// weight's part inverted exactly, a Newton step on the closed forms, one on the whole (with the
// table). Returns (u, the length from u_lo).
vec2 geo_fillet_at(float b, float sigma, float psi) {
	float ul = max(sigma, g_prof2.y);
	float span = 0.5 - ul;
	vec2 f0 = geo_F(b, ul);
	vec2 f1 = geo_Fu(b, ul, f0);
	float dl0 = ul - sigma;
	float s0 = sqrt(ul), e0 = sqrt(dl0);
	float D = s0 + e0;
	float X = D * exp(min(psi / max(2.0 * f0.x, 1e-20), 40.0));
	float du;               // u - u_lo
	if (sigma > g_prof2.y) { float y = 0.5 * (X - sigma / X); du = y * y; }
	else { float y = 0.5 * (X + sigma / X); du = y * y - ul; }
	float v = clamp(sqrt(max(du, 0.0) / span), 0.0, 1.0);
	vec2 val = vec2(0.0);
	for (int i = 0; i < 2; i++) {
		float u = ul + span * v * v;
		float s = sqrt(u), e = sqrt(u - ul + dl0);
		float w = 2.0 * log((s + e) / D);
		val = f0 * w + f1 * (s * e - s0 * e0 + (0.5 * sigma - ul) * w);
		if (i == 1) val += geo_G(sigma, v);
		float der = geo_F(b, u).x * 2.0 * span * v / (s * e);
		if (der > 0.0) v = clamp(v - (val.x - psi) / der, 0.0, 1.0);
	}
	return vec2(ul + span * v * v, val.y);
}

// |l| where the sweep from the origin is psi (>= 0), or -1 if only at infinity
float geo_l_at(float b, float sigma, float psi) {
	float Lc = g_prof.z, L = g_prof.w, Rout = g_prof2.x;
	if (b >= Rout) return psi < 0.5 * GEO_PI ? b / geo_cos(psi) - Rout + L : -1.0;
	float pc = 0.0;
	if (sigma < g_prof2.y && Lc > 0.0) {
		float k = sqrt(max(-2.0 * g_prof.y * sigma * (g_prof.x + b), 0.0));
		pc = b * Lc / (g_prof.x * max(k, 1e-12));
		if (psi <= pc) return psi * g_prof.x * k / max(b, 1e-20);
	}
	float ul = max(sigma, g_prof2.y);
	float whole = 0.5 - ul > 0.0 ? geo_fillet(b, sigma, ul, ul - sigma, 0.5, 0.5 - sigma, true, true).x : 0.0;
	if (psi > pc + whole) {
		float a = psi - pc - whole + geo_acos(clamp(b / Rout, 0.0, 1.0));
		return a < 0.5 * GEO_PI ? b / geo_cos(a) - Rout + L : -1.0;
	}
	float u = geo_fillet_at(b, sigma, psi - pc).x;
	return Lc + g_prof.y * (2.0 * geo_asin(sqrt(u)) - g_prof2.w);
}

// ---------------------------------------------------------------- the eyes
// The eye of the current view: the head (head_l, head_n, its frame head_f = play x, y, z as
// tangent vectors) and its place in the room (head_pos), and the view's camera as Godot gives it.
// Under multiview INV_VIEW_MATRIX is one camera for both eyes, set back so that its frustum holds
// both; each eye sits at EYE_OFFSET in that camera's space (its own turn is in its projection). So:
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
// The geodesic along which the eye at (el, en) sees the point (pl, pn): the only one whose position
// angle turns by the angle between en and pn (less than pi; any other crosses the floor first:
// docs/geometry.md). Returns the launch direction as a tangent vector at the eye (.xyzw) and the
// length (out len); arrive: the direction it comes in at the point, as a vector of R^4; fell: 1 where
// the search came out not finite and the stand-in below took its place (ref/test_gpu.py: never).
// Taken at once: where the eye and the point are in the same flat universe and the segment between
// them stays out of the curved zone, the segment (most of a scene seen not through the throat);
// where both are in the throat's cylinder, the straight line on it unrolled. Else the ray is found
// among those that reach |l| = |pl| (below): GEO_ITERS rays, the first the one between the two
// families, then false position with halving (Illinois) in the family that holds the point.
const int GEO_ITERS = 12;

vec4 geo_see(float el, vec3 en, float pl, vec3 pn, out float len, out vec4 arrive, out float fell) {
	float side = el < 0.0 ? -1.0 : 1.0;
	float le = abs(el);
	float lp = side * pl;           // the eye's side is +
	float alp = abs(lp);
	float dre = geo_dr(le), drp = geo_dr(alp);       // r - rho0 at each
	float re = g_prof.x + dre, rp = g_prof.x + drp;
	// One way out, nothing skipped in the loop: what the wave's vertices do apart is only their
	// branches. Both in the eye's flat universe and the segment between them clear of the curved
	// zone (its nearest point to the centre at least Rout from it): the segment itself, in R^4's
	// xyz there.
	vec4 dir = vec4(0.0);
	len = 0.0;
	arrive = vec4(0.0);
	fell = 0.0;
	bool seg = false;
	if (le >= g_prof.w && lp >= g_prof.w) {
		vec3 xe = re * en;
		vec3 dv = rp * pn - xe;
		float d2 = max(dot(dv, dv), 1e-20);
		vec3 m = xe + clamp(-dot(xe, dv) / d2, 0.0, 1.0) * dv;
		if (dot(m, m) >= g_prof2.x * g_prof2.x) {
			seg = true;
			len = sqrt(d2);
			vec3 u = dv / len;
			arrive = vec4(u, 0.0);
			float cu = dot(u, en);
			dir = vec4(side * cu, u - cu * en);
		}
	}
	if (!seg) {
		float rmin = g_prof2.z;
		float dr0 = 2.0 * g_prof.y * g_prof2.y;             // r_min - rho0
		float c = dot(en, pn);
		vec3 cr = cross(en, pn);
		float sd = length(cr);
		float delta = geo_atan2(sd, c);
		vec3 t = sd > 1e-9 ? (pn - c * en) / sd : (abs(en.z) < 0.9 ? normalize(cross(en, vec3(0.0, 0.0, 1.0))) : normalize(cross(en, vec3(1.0, 0.0, 0.0))));
		// the straight line on the cylinder unrolled. Where both are in the throat's cylinder, the
		// space there is the product of l and a sphere of radius rho0 and that is the geodesic (the
		// family below can't take a point at about the eye's l there: its rays circle the cylinder,
		// their sweep grows without bound as they turn tangent, and the length comes out of a
		// division by their dl/ds). Elsewhere it stands should the search come out not finite,
		// which a GPU's arithmetic must never make a hole of; fell says so.
		float dl0 = lp - le, arc0 = re * delta;
		len = sqrt(dl0 * dl0 + arc0 * arc0);
		float cl0 = dl0 / max(len, 1e-20), sl0 = arc0 / max(len, 1e-20);
		arrive = vec4(sl0 * (c * t - sd * en), side * cl0);
		dir = vec4(side * cl0, sl0 * t);
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
			bool two = outw ? dre > dr0 : !cross_;
			const float WMAX = 16.0;          // the ends' distances down to 1e-7 of their span: float32's step
			int fam = two ? -1 : 0;           // -1: the ray between, 0: first crossings, 1: turned
			float lo = -WMAX, hi = WMAX, flo = 0.0, fhi = 0.0;
			bool have_lo = false, have_hi = false;
			float psit = 0.0, gt = 0.0;       // the ray between's psi, the target log(delta / (psi_t - delta))
			// the first crossings' first guess: the straight line on the cylinder unrolled
			float ang0 = clamp(geo_atan2(re * delta, abs(lp - le)), 1e-6 * A1, (1.0 - 1e-6) * A1);
			float x = log(ang0 / (A1 - ang0));
			int last = 0;
			vec2 res = vec2(0.0);
			float dsa = 0.0, dca = 1.0;       // the found ray's launch direction: (along the outward radial, across)
			bool tlast = false;               // the found ray turned
			float b = 0.0, gp = 0.0;          // its impact and r - b at the point
			for (int i = 0; i < GEO_ITERS; i++) {
				// the ray: sin and cos of its launch angle, b - rho0
				float sa, ca, bmr;
				bool turned = fam == 1;
				if (fam == 1) {
					float e = cT * exp(-x);
					vec2 sc = geo_sincos(c1 - e);
					sa = sc.y;
					ca = sc.x;
					bmr = dr0 + 2.0 * re * geo_sin(c1 - 0.5 * e) * geo_sin(0.5 * e);
				} else {
					float ex = exp(-abs(x));
					float eps = fam < 0 ? 0.0 : A1 * (x > 0.0 ? ex : 1.0) / (1.0 + ex);
					vec2 sc = geo_sincos(cA + eps);
					sa = sc.y;
					ca = sc.x;
					bmr = dA - 2.0 * re * geo_sin(cA + 0.5 * eps) * geo_sin(0.5 * eps);
				}
				b = re * sa;
				float sigma = geo_sigma(bmr);
				float gap_e = re * ca * ca / (1.0 + sa);     // re - b
				float gap_p = (drp - dre) + gap_e;           // rp - b
				vec2 s;
				if (outw && !turned) {
					s = geo_between(b, sigma, le, gap_e, alp, gap_p, false);
				} else if (!outw && !turned && lp >= 0.0) {
					s = geo_between(b, sigma, alp, gap_p, le, gap_e, false);
				} else {
					s = geo_from_origin(b, sigma, le, gap_e) + geo_from_origin(b, sigma, alp, gap_p);
				}
				res = s;
				dca = (outw && !turned) ? ca : -ca;
				dsa = sa;
				tlast = turned;
				gp = gap_p;
				if (fam < 0) {
					// the ray between: the point among the first crossings if this one has turned
					// past it
					psit = s.x;
					gt = log(max(delta, 1e-30) / max(psit - delta, 1e-30));
					fam = s.x > delta ? 0 : 1;
					if (fam == 1) { lo = 0.0; flo = s.x - delta; have_lo = true; x = 0.5 * WMAX; }
				} else {
					float val = s.x - delta;
					if (fam == 0) val = log(max(s.x, 1e-30)) - (two ? log(max(psit - s.x, 1e-30)) + gt : log(max(delta, 1e-30)));
					// Illinois: the end kept twice in a row has its value halved. Until a ray each
					// side of the point is known, halve the bracket: neither end's value is
					// bounded.
					if (val > 0.0) { hi = x; fhi = val; if (last > 0) flo *= 0.5; last = 1; have_hi = true; }
					else { lo = x; flo = val; if (last < 0) fhi *= 0.5; last = -1; have_lo = true; }
					x = (have_lo && have_hi) ? (lo * fhi - hi * flo) / (fhi - flo) : 0.5 * (lo + hi);
				}
			}
			// arriving: in the plane, (dl/ds, b / rp) in (radial, toward growing angle)
			float vr = sqrt(max(gp * (rp + b), 0.0)) / rp;
			bool arrive_out = outw || tlast;          // moving to growing |l| at the point (eye's side +)
			float dl = (arrive_out ? 1.0 : -1.0) * vr;
			vec2 dd = geo_drdw(pl);
			float dls = side * dl;                    // dl/ds in the true l
			vec3 tau = -sd * en + c * t;              // toward growing angle at pn
			vec4 arr = vec4(dls * dd.x * pn + (b / rp) * tau, dls * dd.y);
			// the search's ray where it is finite (NaN fails every comparison)
			float lens = res.y;
			if (lens > 0.0 && lens < 1e7 && abs(dca) <= 1.5 && abs(dsa) <= 1.5 && abs(arr.w) <= 2.0) {
				len = lens;
				arrive = arr;
				dir = vec4(side * dca, dsa * t);
			} else {
				fell = 1.0;
			}
		}
	}
	return dir;
}


// ---------------------------------------------------------------- the floor and the sky
// Where the ray D (a tangent vector at the eye, any length) of the eye at (el, en) ends: true if on
// the floor, at lh (its l), nh (its n's x and y, any length) after way metres; else in the sky of
// universe skys (+1 A, -1 B), toward skyd (its chart direction, any length). eye = (r, the root of
// u, r - rho0) there (geo_r, geo_u, geo_dr), worked out once per eye.
// The ray's plane and impact b, where in that plane the floor is (the angle phif from the eye), and
// from the sweep where the ray turns that far, or that it reaches the sky first. Rays of an eye in a
// flat universe that never come near the throat go straight; rays of an eye in the throat's cylinder
// that meet the floor before they leave it go straight on the cylinder unrolled.
bool geo_floor(float el, vec3 eye, vec3 en, vec4 D, out float lh, out vec2 nh, out float way, out vec3 skyd, out float skys) {
	float side = el < 0.0 ? -1.0 : 1.0;
	float le = abs(el);
	float re = eye.x;
	float L = g_prof.w, Rout = g_prof2.x;
	float ca = side * D.x;                  // along the outward radial direction
	float sa = length(D.yzw);
	vec3 t = sa > 1e-7 ? D.yzw / sa : normalize(cross(en, vec3(0.0, 1.0, 0.0)));
	float nrm = 1.0 / sqrt(ca * ca + sa * sa);
	ca *= nrm;
	sa *= nrm;
	float b = re * sa;
	// where the floor is in the ray's plane: the angle from the eye (0, pi), the eye above it
	float phif = geo_atan2(en.z, -t.z);
	bool hit = false;
	lh = 0.0;
	nh = vec2(1.0, 0.0);
	way = 0.0;
	skyd = vec3(0.0, 0.0, 1.0);
	skys = side;
	// in the throat's cylinder the ray is straight on it unrolled: where it gets to the floor's angle
	float isa = 1.0 / max(sa, 1e-20);
	float lf = le + re * phif * ca * isa;
	if (le >= L && (ca >= 0.0 || b >= Rout)) {
		// straight: in the eye's sheet (R^4's xyz there)
		vec3 xe = re * en;
		vec3 dc = ca * en + sa * t;
		if (dc.z < 0.0) {
			way = -xe.z / dc.z;
			vec2 p = xe.xy + way * dc.xy;
			float rp = length(p);
			hit = true;
			lh = side * (L + rp - Rout);
			nh = p;
		} else {
			skyd = dc;
		}
	} else if (max(le, abs(lf)) <= g_prof.z) {
		// the eye in the cylinder and the floor met before the ray leaves it (the sweep's rates below
		// divide by the ray's dl/ds, nothing for a ray round the cylinder)
		hit = true;
		lh = side * lf;
		vec2 scf = geo_sincos(phif);
		nh = (scf.y * en + scf.x * t).xy;
		way = re * phif * isa;
	} else {
		// what the ray's sweeps share: its impact, the cylinder's rates, the fillet's closed forms
		float oms = ca * ca / (1.0 + sa);   // 1 - sin: exact for rays along the sphere of the eye
		float gap_e = re * oms;
		float sigma = geo_sigma(eye.z - gap_e);
		float R2 = 2.0 * g_prof.y;
		float Lc = g_prof.z;
		bool pass = sigma < g_prof2.y;      // b < r_min, known from sigma (geo_sigma)
		float k = sqrt(max(-R2 * sigma * (g_prof.x + b), 0.0));
		vec2 cyl = pass ? vec2(b / g_prof.x, g_prof.x) / max(k, 1e-12) : vec2(0.0);   // per metre of l
		vec2 cylL = cyl * Lc;
		float ul = max(sigma, g_prof2.y);
		float span = 0.5 - ul;
		vec2 f0 = geo_F(b, ul);
		vec2 f1 = geo_Fu(b, ul, f0);
		float s0 = sqrt(ul), e0 = sqrt(ul - sigma);
		float Dw = s0 + e0, P0 = s0 * e0;
		float sL = sqrt(max(0.5 - sigma, 0.0));
		float wL = 2.0 * log((0.70710678 + sL) / Dw);
		// from the ray's origin to the curved zone's edge, and to the eye
		vec2 SL = cylL + f0 * wL + f1 * (0.70710678 * sL - P0 + (0.5 * sigma - ul) * wL) + geo_poly(sigma);
		float qR = sqrt(max((Rout - b) * (Rout + b), 0.0));
		vec2 se;
		if (le >= L) {
			float q2 = sqrt(max(gap_e * (re + b), 0.0));
			float dq = (re - Rout) * (re + Rout) / max(qR + q2, 1e-20);
			se = SL + vec2(geo_atan2(b * dq, b * b + qR * q2), dq);
		} else if (le > Lc) {
			float su = eye.y, eu = sqrt(gap_e / R2);
			float ue = su * su;
			float w = 2.0 * log((su + eu) / Dw);
			se = cylL + f0 * w + f1 * (su * eu - P0 + (0.5 * sigma - ul) * w) + geo_G(sigma, sqrt(max(ue - ul, 0.0) / span));
		} else {
			se = cyl * le;
		}
		float ab = geo_asin(b / Rout);
		float pinf = SL.x + ab;             // to infinity
		float target = 0.0;                 // the sweep from the ray's origin to the floor point
		float far = 1.0;                    // +1: the point's |l| on the eye's side, -1 the other
		float sgnw = 1.0;                   // the way: se.y + sgnw * (length from the origin)
		float tot = 0.0;
		if (ca >= 0.0) {
			tot = pinf - se.x;
			target = se.x + phif;
		} else {
			tot = se.x + pinf;
			target = abs(se.x - phif);
			sgnw = phif <= se.x ? -1.0 : 1.0;
			if (pass) {
				// through the throat
				far = phif <= se.x ? 1.0 : -1.0;
				sgnw = -far;
				skys = -side;
			}
		}
		// t is done with before the fillet's inversion (it costs registers there): where it ends, the
		// sky's direction, and the floor point's
		hit = phif < tot;
		vec2 sct = geo_sincos(tot);
		if (!hit) {
			skyd = sct.y * en + sct.x * t;
		} else {
			vec2 scf = geo_sincos(phif);
			nh = (scf.y * en + scf.x * t).xy;
			vec2 at;                        // (|l|, length from the origin)
			if (target >= SL.x) {
				// beyond the curved zone: straight
				float a = target - SL.x + 0.5 * GEO_PI - ab;
				hit = a < 0.5 * GEO_PI;
				if (!hit) skyd = sct.y * en + sct.x * t;
				float r = b / geo_cos(a);
				at = vec2(L + r - Rout, SL.y + sqrt(max((r - b) * (r + b), 0.0)) - qR);
			} else if (pass && target <= cylL.x) {
				at = vec2(target / max(cyl.x, 1e-20), 0.0);
				at.y = cyl.y * at.x;
			} else {
				// the fillet: the weight inverted exactly, a Newton step on the closed forms, one with the table
				float pf = target - cylL.x;
				float X = Dw * exp(min(pf / max(2.0 * f0.x, 1e-20), 40.0));
				float du;
				if (sigma > g_prof2.y) { float y = 0.5 * (X - sigma / X); du = y * y; }
				else { float y = 0.5 * (X + sigma / X); du = y * y - ul; }
				float v = clamp(sqrt(max(du, 0.0) / span), 0.0, 1.0);
				vec2 val = vec2(0.0);
				for (int i = 0; i < 2; i++) {
					float u = ul + span * v * v;
					float su = sqrt(u), eu = sqrt(u - ul + e0 * e0);
					float w = 2.0 * log((su + eu) / Dw);
					val = f0 * w + f1 * (su * eu - P0 + (0.5 * sigma - ul) * w);
					if (i == 1) val += geo_G(sigma, v);
					float der = geo_F(b, u).x * 2.0 * span * v / (su * eu);
					if (der > 0.0) v = clamp(v - (val.x - pf) / der, 0.0, 1.0);
				}
				float u = ul + span * v * v;
				at = vec2(Lc + g_prof.y * (2.0 * geo_asin(sqrt(u)) - g_prof2.w), cylL.y + val.y);
			}
			lh = side * far * at.x;
			way = ca >= 0.0 ? at.y - se.y : se.y + sgnw * at.y;
		}
	}
	return hit;
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
