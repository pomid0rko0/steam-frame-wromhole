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

// asin and acos through atan: Mesa's (the headset's driver) are polynomials good to only ~1e-4 rad
float geo_asin(float x) { return atan(x, sqrt(max((1.0 - x) * (1.0 + x), 0.0))); }
float geo_acos(float x) { return atan(sqrt(max((1.0 - x) * (1.0 + x), 0.0)), x); }

float geo_r(float al) {
	if (al >= g_prof.w) return al - g_prof.w + g_prof2.x;
	float th = g_prof2.w + (max(al, g_prof.z) - g_prof.z) / g_prof.y;
	float s = sin(0.5 * th);
	return g_prof.x + 2.0 * g_prof.y * s * s;
}

// dr/dl and dw/dl at l (dr odd, dw even): the embedded d/dl is (dr n, dw)
vec2 geo_drdw(float l) {
	float al = abs(l);
	if (al >= g_prof.w) return vec2(sign(l), 0.0);
	if (al <= g_prof.z) return vec2(0.0, 1.0);
	float th = g_prof2.w + (al - g_prof.z) / g_prof.y;
	return vec2(sign(l) * sin(th), cos(th));
}

// u = sin^2(theta / 2) on the fillet
float geo_u(float al) {
	float th = g_prof2.w + (clamp(al, g_prof.z, g_prof.w) - g_prof.z) / g_prof.y;
	float s = sin(0.5 * th);
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

// sigma kept off the photon sphere's b = rho0 (h >= R), where the weight's integral diverges
float geo_sigma(float gap_rho0) {
	// gap_rho0 = b - rho0
	float s = gap_rho0 / (2.0 * g_prof.y);
	return abs(s) < 1e-7 ? (s < 0.0 ? -1e-7 : 1e-7) : s;
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
		float r1, q1;
		if (a1 <= L) { r1 = g_prof2.x; q1 = sqrt(max((g_prof2.x - b) * (g_prof2.x + b), 0.0)); }
		else { r1 = geo_r(a1); q1 = sqrt(max(gap1 * (r1 + b), 0.0)); }
		float r2 = geo_r(a2);
		float q2 = sqrt(max(gap2 * (r2 + b), 0.0));
		float dq = (r2 - r1) * (r2 + r1) / max(q1 + q2, 1e-20);
		out_ += vec2(atan(b * dq, b * b + q1 * q2), dq);
	}
	return out_;
}

// where a ray of impact b starts counting: |l| of its turning point (b >= rmin) or 0
float geo_origin(float b, float sigma) {
	if (b >= g_prof2.x) return b - g_prof2.x + g_prof.w;
	if (b < g_prof2.z) return 0.0;
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
	if (b >= Rout) return psi < 0.5 * GEO_PI ? b / cos(psi) - Rout + L : -1.0;
	float pc = 0.0;
	if (b < g_prof2.z && Lc > 0.0) {
		float k = sqrt(max(-2.0 * g_prof.y * sigma * (g_prof.x + b), 0.0));
		pc = b * Lc / (g_prof.x * max(k, 1e-12));
		if (psi <= pc) return psi * g_prof.x * k / max(b, 1e-20);
	}
	float ul = max(sigma, g_prof2.y);
	float whole = 0.5 - ul > 0.0 ? geo_fillet(b, sigma, ul, ul - sigma, 0.5, 0.5 - sigma, true, true).x : 0.0;
	if (psi > pc + whole) {
		float a = psi - pc - whole + geo_acos(clamp(b / Rout, 0.0, 1.0));
		return a < 0.5 * GEO_PI ? b / cos(a) - Rout + L : -1.0;
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
// length (out len); arrive: the direction it comes in at the point, as a vector of R^4.
// The rays that reach |l| = |pl| form one family along which that turn grows from 0 without bound,
// parametrised by the launch angle (q below): bisection with false position steps.
const int GEO_ITERS = 12;

vec4 geo_see(float el, vec3 en, float pl, vec3 pn, out float len, out vec4 arrive) {
	float side = el < 0.0 ? -1.0 : 1.0;
	float le = abs(el);
	float lp = side * pl;           // the eye's side is +
	float alp = abs(lp);
	float re = geo_r(le), rp = geo_r(alp);
	float rmin = g_prof2.z;
	float c = dot(en, pn);
	vec3 cr = cross(en, pn);
	float sd = length(cr);
	float delta = atan(sd, c);
	vec3 t = sd > 1e-9 ? (pn - c * en) / sd : (abs(en.z) < 0.9 ? normalize(cross(en, vec3(0.0, 0.0, 1.0))) : normalize(cross(en, vec3(1.0, 0.0, 0.0))));
	// the family: alpha = launch angle from the outward radial direction
	// lp >= le: alpha in [0, amax), amax = pi - asin(rmin / re) (the turned rays down to rmin)
	// lp <  le: beta = pi - alpha; first crossing beta in [0, b1], b1 = asin(bmax / re), then (if
	//           the point lies where rays turn back) the second crossing back from b1 to asin(rmin / re)
	bool outw = lp >= le;
	bool cross_ = (lp <= 0.0) || (rp <= rmin * 1.000001);
	float bmax = cross_ ? rmin : rp;
	float a_min = geo_asin(min(rmin / re, 1.0));
	float qmax, b1;
	if (outw) { qmax = re > rmin * 1.000001 ? 2.0 : 1.0; b1 = 0.5 * GEO_PI; }
	else { qmax = cross_ ? 1.0 : 2.0; b1 = geo_asin(min(bmax / re, 1.0)); }
	float lo = 0.0, hi = qmax, flo = -delta, fhi = 0.0;
	bool have_hi = false;
	float q = 0.5 * qmax;
	int last = 0;
	vec2 res = vec2(0.0);
	float alpha = 0.0;
	float b = 0.0;
	for (int i = 0; i < GEO_ITERS; i++) {
		// the ray at q
		float ang;          // launch angle from the radial direction: outward for outw q <= 1, else inward
		bool turned;        // q > 1: the second crossing
		if (outw) {
			turned = q > 1.0;
			ang = turned ? (0.5 * GEO_PI + (q - 1.0) * (0.5 * GEO_PI - a_min)) : q * 0.5 * GEO_PI;
		} else {
			turned = q > 1.0;
			ang = turned ? (b1 - (q - 1.0) * (b1 - a_min)) : q * b1;
		}
		float sa = sin(ang), ca = cos(ang);
		// outw, not turned: alpha = ang; outw turned: alpha = ang (in (pi/2, pi)); inward: alpha = pi - ang
		b = re * sa;
		float one_m_s = ca * ca / (1.0 + sa);          // 1 - sin, exact near the tangent
		float gap_e = re * one_m_s;
		float sigma = geo_sigma((re - g_prof.x) - re * one_m_s);
		float gap_p = rp - b;
		vec2 s;
		if (outw && !turned) {
			s = geo_between(b, sigma, le, gap_e, alp, gap_p, false);
		} else if (outw) {
			s = geo_from_origin(b, sigma, le, gap_e) + geo_from_origin(b, sigma, alp, gap_p);
		} else if (!turned) {
			if (lp >= 0.0) s = geo_between(b, sigma, alp, gap_p, le, gap_e, false);
			else s = geo_from_origin(b, sigma, le, gap_e) + geo_from_origin(b, sigma, alp, gap_p);
		} else {
			s = geo_from_origin(b, sigma, le, gap_e) + geo_from_origin(b, sigma, alp, gap_p);
		}
		res = s;
		alpha = (outw && !turned) ? ang : (outw ? ang : GEO_PI - ang);
		float val = s.x - delta;
		// Illinois: the end kept twice in a row has its value halved
		// (until a ray goes past the point, hi is where the turn has no bound: halve the bracket)
		if (val > 0.0) { hi = q; fhi = val; if (last > 0) flo *= 0.5; last = 1; have_hi = true; }
		else { lo = q; flo = val; if (last < 0) fhi *= 0.5; last = -1; }
		q = have_hi ? (lo * fhi - hi * flo) / (fhi - flo) : 0.5 * (lo + hi);
	}
	len = res.y;
	float sa = sin(alpha), ca = cos(alpha);
	// arriving: in the plane, (dl/ds, b / rp) in (radial, toward growing angle)
	float vr = sqrt(max(1.0 - (b / rp) * (b / rp), 0.0));
	bool arrive_out = outw || (q > 1.0);      // moving to growing |l| at the point (eye's side +)
	float dl = (arrive_out ? 1.0 : -1.0) * vr;
	if (!outw && q <= 1.0 && lp < 0.0) dl = -vr;   // through the throat: falling l
	vec2 dd = geo_drdw(pl);
	float dls = side * dl;                    // dl/ds in the true l
	vec3 tau = -sd * en + c * t;              // toward growing angle at pn
	arrive = vec4(dls * dd.x * pn + (b / rp) * tau, dls * dd.y);
	return vec4(side * ca, sa * t);
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
	float Kr = g_prof2.x, Ka = g_prof.z - R * sin(g_prof2.w);
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
	float Kr = g_prof2.x, Ka = g_prof.z - R * sin(g_prof2.w);
	if (rho >= Kr) return sw * (g_prof.w + rho - Kr);
	if (a <= Ka) return P.w;
	return sw * (g_prof.z + R * (atan(a - Ka, Kr - rho) - g_prof2.w));
}

// the vector of R^4 orthogonal to a, b and c (their 4D cross product)
vec4 geo_cross4(vec4 a, vec4 b, vec4 c) {
	return vec4(
		dot(a.yzw, cross(b.yzw, c.yzw)),
		-dot(a.xzw, cross(b.xzw, c.xzw)),
		dot(a.xyw, cross(b.xyw, c.xyw)),
		-dot(a.xyz, cross(b.xyz, c.xyz)));
}
