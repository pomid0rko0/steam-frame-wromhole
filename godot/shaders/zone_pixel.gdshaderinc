// Balls in the curved zone found per pixel along its ray (zone_pixel.gdshader, drawn while
// Renderer.zone_pixel is on), instead of a mesh per image: every image of a ball comes out of one
// pixel's ray, however many times it goes round the throat. Plain GLSL after geo.gdshaderinc,
// zone.gdshaderinc and look.gdshaderinc; the includer declares
//   zone_ball[2 ZONE_PIXEL_MAX]: per ball its centre C (a point of R^4) and (colour, radius)
//   zone_balls: how many.
//
// The ray lies in its plane through the centre, spanned by the eye's en and its direction t across
// (geo_exit_ray), and turns in it by psi from en toward t. Along it |l| = a_o + q^2 with a_o its
// origin (geo_origin: its turning point, or l = 0 for a ray through the throat) and q from the eye's
// (negative on the way in) on: psi is smooth in q through the turning point, where it is not in l.
// A ball (the points within chord distance radius of C) is met only where the ray's l is within
// its slab, |l - l_C| below the profile's arc over the radius (the fillet's arc of radius R being the
// most curved). On each stretch of the ray across the slab psi is worked out at both ends
// (geo_between: no steps) with its rate in q there (closed form), and between them a cubic in q
// stands in for it. In the ray's plane the ball's copies stand every 2 pi of psi, the ball seen
// from the centre within dmax = asin(radius / A) of its own angle phi (A its centre's distance from
// the centre in the plane): only copies with phi + 2 pi k - dmax .. + dmax within the stretch's
// psi can be met, the first of them first. Within such a copy's window of psi the chord distance's
// least is found on the cubic, the ray's way in by halving, then psi itself is worked out there
// and the place set right by Newton's steps with it.

#define ZONE_PIXEL_MAX 12

// the ray as the search takes it
struct ZoneRay {
	float side;      // the eye's universe (+1 A, -1 B)
	float s2;        // the universe of the way out (past the origin)
	float le;        // the eye's |l|
	float b;
	float sigma;
	float gap_e;     // r - b at the eye
	float bmr;       // b - rho0
	float ao;        // the origin's |l|
	float qe;        // the eye's q
	bool outward;
	vec3 eye;        // (r, the root of u, r - rho0) at the eye
	vec3 en;
	vec3 t;
};

// r - b at |l| = a, from what keeps its digits (geo_see_to's way)
float zone_px_gap(ZoneRay z, float a) {
	float dra = geo_dr(a);
	return abs(dra) < abs(z.eye.z) ? dra - z.bmr : (dra - z.eye.z) + z.gap_e;
}

// the ray's turn and length from the eye to |l| = a, on the way in (before the origin) or after
// it; ple: those from the origin to the eye (the way in's, worked out once)
vec2 zone_px_way(ZoneRay z, float a, bool in_, vec2 ple) {
	float ga = zone_px_gap(z, a);
	if (in_) return geo_between(z.b, z.sigma, a, ga, z.le, z.gap_e, false);
	if (z.outward) return geo_between(z.b, z.sigma, z.le, z.gap_e, a, ga, false);
	return ple + geo_from_origin(z.b, z.sigma, a, ga);
}

// dpsi / dq at q (|l| = a): 2 |q| b / (r sqrt(r^2 - b^2)); next to a turning point r - b goes as r' q^2
float zone_px_rate(ZoneRay z, float a, float q) {
	float r = geo_r(a);
	float ga = zone_px_gap(z, a);
	if (z.ao > 0.0) ga = max(ga, abs(geo_drdw(a).x) * q * q);
	return 2.0 * abs(q) * z.b / (r * sqrt(max(ga * (r + z.b), GEO_TINY)));
}

// the cubic on [q1, q2] with values p1, p2 and rates d1, d2 at its ends
float zone_px_cubic(float q, vec2 qs, vec2 ps, vec2 ds) {
	float H = qs.y - qs.x;
	float x = clamp((q - qs.x) / max(H, GEO_TINY20), 0.0, 1.0);
	float x2 = x * x, x3 = x2 * x;
	return (2.0 * x3 - 3.0 * x2 + 1.0) * ps.x + (x3 - 2.0 * x2 + x) * H * ds.x
			+ (3.0 * x2 - 2.0 * x3) * ps.y + (x3 - x2) * H * ds.y;
}

// the q in [q1, q2] where the cubic reaches psi (it grows along the ray)
float zone_px_at(float psi, vec2 qs, vec2 ps, vec2 ds) {
	float lo = qs.x, hi = qs.y;
	if (psi <= ps.x) return lo;
	if (psi >= ps.y) return hi;
	for (int i = 0; i < 14; i++) {
		float m = 0.5 * (lo + hi);
		if (zone_px_cubic(m, qs, ps, ds) < psi) lo = m; else hi = m;
	}
	return 0.5 * (lo + hi);
}

// the ray's point at q with turn psi (R^4), and its l
vec4 zone_px_point(ZoneRay z, float q, float psi, out float l) {
	float a = z.ao + q * q;
	l = (q < 0.0 ? z.side : z.s2) * a;
	vec2 sc = geo_sincos(psi);
	return vec4(geo_r(a) * (sc.y * z.en + sc.x * z.t), zone_w(l));
}

// the chord's square less the radius's at q, turn psi
float zone_px_out(ZoneRay z, float q, float psi, vec4 C, float rr) {
	float l;
	vec4 d = zone_px_point(z, q, psi, l) - C;
	return dot(d, d) - rr;
}

// The first ball this pixel's ray meets (D: the ray as geo_exit takes it): true, its colour and the
// length of the light's way there.
bool zone_pixel_trace(float el, vec3 eye, vec3 en, vec4 D, out vec3 colour, out float way) {
	colour = vec3(0.0);
	way = 0.0;
	ZoneRay z;
	float ca, sa, b0, gap0, sigma0;
	vec3 t;
	geo_exit_ray(el, eye, en, D, ca, sa, t, b0, gap0, sigma0);
	z.b = b0;
	z.gap_e = gap0;
	z.sigma = sigma0;
	z.side = el < 0.0 ? -1.0 : 1.0;
	z.le = abs(el);
	z.eye = eye;
	z.en = en;
	z.t = t;
	z.outward = ca >= 0.0;
	z.bmr = eye.z - z.gap_e;
	z.ao = min(geo_origin(z.b, z.sigma), z.le);
	bool through = z.sigma < g_prof2.y;
	z.s2 = (!z.outward && through) ? -z.side : z.side;
	float qe = sqrt(max(z.le - z.ao, 0.0));
	z.qe = z.outward ? qe : -qe;
	float R = g_prof.y;
	vec2 ple = vec2(0.0);
	bool have_ple = false;
	float best = 1e30;          // the q of the nearest met so far
	vec4 bestP = vec4(0.0), bestC = vec4(0.0);
	float best_psi = 0.0, best_l = 0.0, best_len = 0.0;
	vec3 best_col = vec3(0.0);
	for (int i = 0; i < ZONE_PIXEL_MAX; i++) {
		if (i >= zone_balls) break;
		vec4 C = zone_ball[2 * i];
		vec4 cr = zone_ball[2 * i + 1];
		float rad = cr.w;
		// the ray's plane passes the ball no nearer than C's distance from it
		float ac = dot(C.xyz, en), cc = dot(C.xyz, t);
		float A2 = ac * ac + cc * cc;
		float perp2 = max(dot(C.xyz, C.xyz) - A2, 0.0);
		if (perp2 >= rad * rad) continue;
		float A = sqrt(A2);
		float phi = geo_atan2(cc, ac);
		float dmax = A > rad ? geo_asin(rad / A) : GEO_PI;
		vec3 cn;
		float lc = geo_l_of(C, cn);
		float slab = 2.0 * R * geo_asin(min(0.5 * rad / R, 1.0)) + 1e-3;
		// the stretches: the way in (q < 0, the eye's universe), the way out (q > 0)
		for (int k = 0; k < 2; k++) {
			bool in_ = k == 0;
			if (in_ && z.outward) continue;
			float sg = in_ ? z.side : z.s2;
			float alo = max(sg * lc - slab, z.ao);
			float ahi = sg * lc + slab;
			if (in_) ahi = min(ahi, z.le);
			else if (z.outward) alo = max(alo, z.le);
			if (ahi <= alo) continue;
			float qa = sqrt(max(alo - z.ao, 0.0)), qb = sqrt(max(ahi - z.ao, 0.0));
			vec2 qs = in_ ? vec2(-qb, -qa) : vec2(qa, qb);
			if (qs.x >= best) continue;
			if (!in_ && !z.outward && !have_ple) {
				ple = geo_from_origin(z.b, z.sigma, z.le, z.gap_e);
				have_ple = true;
			}
			float a1 = z.ao + qs.x * qs.x, a2 = z.ao + qs.y * qs.y;
			vec2 ps = vec2(zone_px_way(z, a1, in_, ple).x, zone_px_way(z, a2, in_, ple).x);
			vec2 ds = vec2(zone_px_rate(z, a1, qs.x), zone_px_rate(z, a2, qs.y));
			if (!geo_finite(ps.x + ps.y + ds.x + ds.y)) continue;
			// the copies whose window of psi the stretch reaches, the first one first
			float kmin = ceil((ps.x - phi - dmax) / (2.0 * GEO_PI));
			float kmax = floor((ps.y - phi + dmax) / (2.0 * GEO_PI));
			for (int j = 0; j < 4; j++) {
				float kk = kmin + float(j);
				if (kk > kmax) break;
				float mid = phi + 2.0 * GEO_PI * kk;
				float w1 = zone_px_at(mid - dmax, qs, ps, ds);
				float w2 = zone_px_at(mid + dmax, qs, ps, ds);
				if (w2 <= w1) continue;
				// the chord's least over the window on the cubic
				float rr = rad * rad;
				float qmin = w1, fmin = 1e30, prev_q = w1;
				float fprev = zone_px_out(z, w1, zone_px_cubic(w1, qs, ps, ds), C, rr);
				float q_out = w1;
				bool inside0 = fprev < 0.0;
				for (int m = 1; m <= 8; m++) {
					float q = mix(w1, w2, float(m) / 8.0);
					float f = zone_px_out(z, q, zone_px_cubic(q, qs, ps, ds), C, rr);
					if (f < fmin) { fmin = f; qmin = q; }
				}
				if (fprev < fmin) { fmin = fprev; qmin = w1; }
				// a grazing ray: the least between the samples about the least (a parabola)
				float h = (w2 - w1) / 8.0;
				if (fmin >= 0.0) {
					float qa_ = max(qmin - h, w1), qb_ = min(qmin + h, w2);
					float fa = zone_px_out(z, qa_, zone_px_cubic(qa_, qs, ps, ds), C, rr);
					float fb = zone_px_out(z, qb_, zone_px_cubic(qb_, qs, ps, ds), C, rr);
					float den = fa - 2.0 * fmin + fb;
					if (den > 0.0) {
						float qp = clamp(qmin + 0.5 * h * (fa - fb) / den, w1, w2);
						float fp = zone_px_out(z, qp, zone_px_cubic(qp, qs, ps, ds), C, rr);
						if (fp < fmin) { fmin = fp; qmin = qp; }
					}
				}
				if (fmin >= 0.0) continue;
				// the way in: halving between the window's start (outside) and the least (inside)
				float lo = w1, hi = qmin;
				if (!inside0) {
					for (int m = 0; m < 10; m++) {
						float q = 0.5 * (lo + hi);
						if (zone_px_out(z, q, zone_px_cubic(q, qs, ps, ds), C, rr) < 0.0) hi = q; else lo = q;
					}
				}
				float qh = inside0 ? w1 : hi;
				// psi itself there, and the place set right along the ray with it (Newton, the
				// rate taken across the bracket)
				float ah = z.ao + qh * qh;
				vec2 wh = zone_px_way(z, ah, qh < 0.0, ple);
				float e = wh.x - zone_px_cubic(qh, qs, ps, ds);
				if (!geo_finite(e + wh.y)) continue;
				float qh0 = qh;
				bool ok = true;
				if (!inside0) {
					float dq = max(hi - lo, 1e-7);
					for (int m = 0; m < 3; m++) {
						float f0 = zone_px_out(z, qh, zone_px_cubic(qh, qs, ps, ds) + e, C, rr);
						float f1 = zone_px_out(z, qh + dq, zone_px_cubic(qh + dq, qs, ps, ds) + e, C, rr);
						float sl = (f1 - f0) / dq;
						if (abs(sl) < GEO_TINY20) break;
						qh = clamp(qh - f0 / sl, w1, w2);
					}
					ok = zone_px_out(z, qh, zone_px_cubic(qh, qs, ps, ds) + e, C, rr) < 1e-3 * rr;
				}
				if (!ok || qh >= best) continue;
				float psi = zone_px_cubic(qh, qs, ps, ds) + e;
				float l;
				vec4 P = zone_px_point(z, qh, psi, l);
				if (P.z + g_lift < 0.0) continue;     // under the floor: hidden
				// the length there: the one worked out, on by ds/dq = 2 |q| r / sqrt(r^2 - b^2)
				float am = z.ao + 0.25 * (qh + qh0) * (qh + qh0);
				float rm = geo_r(am);
				float gm = max(zone_px_gap(z, am), 0.0);
				if (z.ao > 0.0) gm = max(gm, abs(geo_drdw(am).x) * 0.25 * (qh + qh0) * (qh + qh0));
				best_len = wh.y + (qh - qh0) * abs(qh + qh0) * rm / sqrt(max(gm * (rm + z.b), GEO_TINY));
				best = qh;
				bestP = P;
				bestC = C;
				best_psi = psi;
				best_l = l;
				best_col = cr.rgb;
				break;
			}
		}
	}
	if (best >= 1e29) return false;
	// lit as body.gdshaderinc lights a ball in the zone: its normal, the sun and up, all tangent at
	// the point, and the ray's direction there
	float a = z.ao + best * best;
	float r = geo_r(a);
	float ga = max(zone_px_gap(z, a), 0.0);
	float dls = (best < 0.0 ? -z.side : z.s2) * sqrt(ga * (r + z.b)) / r;
	vec2 dd = geo_drdw(best_l);
	vec2 sc = geo_sincos(best_psi);
	vec3 nx = sc.y * en + sc.x * t;
	vec3 tau = sc.y * t - sc.x * en;
	vec4 arrive = dls * vec4(dd.x * nx, dd.y) + (z.b / r) * vec4(tau, 0.0);
	vec4 Np = geo_normal(bestP);
	vec4 nrm = bestP - bestC;
	nrm -= dot(nrm, Np) * Np;
	vec4 s4 = look_sun4(best_l);
	vec4 sun = s4 - dot(s4, Np) * Np;
	vec4 up4 = vec4(0.0, 0.0, 1.0, 0.0) - Np.z * Np;
	vec4 n = nrm * inversesqrt(max(dot(nrm, nrm), GEO_TINY20));
	float nl = dot(n, sun) * inversesqrt(max(dot(sun, sun), GEO_TINY20));
	float up = dot(n, up4) * inversesqrt(max(dot(up4, up4), GEO_TINY20));
	float nv = -dot(n, arrive) * inversesqrt(max(dot(arrive, arrive), GEO_TINY20));
	colour = look_body(best_col, nl, up, nv, best_l);
	way = best_len;
	return geo_finite(colour.r + colour.g + colour.b + way);
}
