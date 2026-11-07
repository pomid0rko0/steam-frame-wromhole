// The tail of the images of the bodies in the curved zone, per pixel (zone_tail.gdshader; the first
// Renderer.ZONE_IMAGES images of each body are meshes, body.gdshaderinc). Plain GLSL after
// geo.gdshaderinc and zone.gdshaderinc (ref/test_gpu.py takes it too). docs/geometry.md, «Как
// рисуется кадр», 6.
//
// A body's images close in on the limit of the rays that wind round the throat's cylinder (b next to
// r_min = rho0): seen from inside the cylinder the k-th turn is only about 1 / k of a turn off it,
// from outside 1 / k^2, and on a long throat the band between the meshes' last image and the limit
// is many pixels wide, image after image (issue #141). Each ray of that band passes the throat (b <
// r_min) through the cylinder, where its way is a closed form: it goes along l evenly and round the
// throat evenly, psi growing by cyl = (b, rho0^2) / (rho0 k) per metre of l, k = sqrt(rho0^2 - b^2)
// (geo_exit_cyl); past it on the far fillet psi grows by the fillet's sweep (geo_between) and past the
// zone it goes straight. Along the ray l is monotone: y, the metres of l from the eye along it, is
// its parameter, and a point of it is (l(y), psi(y)) in the ray's plane through the centre.
//   Seen in the ray's plane, a body at angle psi_c (its centre's projection) is met only where the
// ray's angle is psi_c + 2 pi n + x with |x| <= dmax (the angle the body's bounding ball spans from
// the axis) and l within the ball's slab: the profile (r(l), w(l)) within its chord of the ball's
// centre seen at psi_c (the cylinder a line, the fillet an arc, the flat part a line: each in closed
// form, tail_slab). On the cylinder the copies n whose window reaches into the slab are a run of whole
// numbers in closed form (a ball's exactly those it goes into: tail_meet; a cube's narrowed to its
// box's l at the window's angles), however many turns on; next to the limit, where l moves by a hair
// a copy, a cube's run is long, and the copies the ray goes into are a run within it: tried at
// TAIL_COPIES copies spread over it, then halving back from the first it goes into to the first of
// all (tail_copy). On the far fillet the few there by psi at the slab's ends. A copy's window of y is
// its |x| <= dmax, and in it the ray goes into the body where it enters every one of its convex
// parts (a ball's chord ball, a cube's four slabs of its 4D box): each part's Newton step from the
// side the ray comes from never passes that part's own way in, so the furthest of them, taken again
// and again, lands on the way into the body, or finds a part the ray leaves before it is in the
// others (tail_enter); a ball's on the cylinder from just before the way in, by a parabola its
// function is no less than (tail_ball_start), and none where that has no root.
// Only ways in at a turn psi >= psi_min count (a point at psi is in image floor(psi / pi)): those
// before are the meshes' images, drawn already, and a ray already in a body at psi_min went in through
// one of them. The renderer takes psi_min (ZONE_IMAGES - 1) pi: the meshes' last image is drawn by
// both (the same points, at the same depth), else where it meets the next in a ring round the eye's
// axis the mesh's edge and the tail's first way in would leave pinholes between them.
//   Drawn where it can be (zone_tail.gdshader per pixel; under foveation foveation.gdshaderinc's TAIL
// per texel, by the same tests): per body and side of the eye's axis its sector of
// azimuths (tail_sector) and, off the inward radial, a strip of launch angles per copy (tail_strip):
// copy n is met only by rays whose turn reaches its least at the body's far end and not yet its
// greatest at the near end, as far as the copies' strips stay apart (on a long throat, a body tens of
// metres along the cylinder, its first dozens of copies past the meshes' leave most of the view
// between them empty); past them one band to the limit (tail_band, from that copy on). A strip's
// pixel looks into its copy only, the band's into the copies from there on (tail_meet's n_lo, n_hi):
// where two meet the ray, the depth test keeps the nearer, the first way in.
//   Precision: float32. psi grows without bound next to the limit; a copy's angle is therefore
// carried as its offset x from psi_c, and the l at which a copy passes psi_c straight from n
// (tail_copy_y). Their phase is off by about psi times float32's step (1e-3 rad at psi 1e4, ten
// thousand turns: images far thinner than a pixel, a pixel or less from the limit).

const float TAIL_PI2 = 6.28318530717959;
const int TAIL_COPIES = 4;        // copies tried a body and stretch (from the first that can be met)
const int TAIL_STEPS = 12;        // Newton's rounds into a body
const int TAIL_HALVE = 12;        // steps back to the way in (Newton's, or halving), a step past it
const float TAIL_TOL = 2e-6;      // m: a point this near a body's surface is on it (on the far fillet:)
const float TAIL_TOL_FILLET = 1e-5;
const int TAIL_CUTS = 9;          // angles a cube's l on the cylinder is taken at across a window
const float TAIL_EPS = 1.2e-7;    // float32's unit in the last place over the number (2^-23)
const float TAIL_REACH = 1.02;    // a ball's bounding ball over its radius (tail_body)
const int TAIL_OVER = 4;          // looks into a step that may have gone over a cube (tail_enter)
const float TAIL_AHEAD = 2e-5;    // rad: a ball's Newton starts this far before its parabola's root (tail_ball_enter)
const int TAIL_STRIPS = 8;        // strips a side at most before the band (tail_strip; ZoneSections.TAIL_STRIPS)
const float TAIL_SEGMENTS = 32.0; // quads across a sector of the view (Renderer.TAIL_SEGMENTS: zone_tail.gdshader)

struct TailRay {
	float el;        // the eye's l
	float dl;        // the sign of dl/ds along the ray
	float b;
	float sigma;
	vec3 en;
	vec3 t;
	float gap_c;     // rho0 - b, r - b on the cylinder
	float y0;        // y where the cylinder starts (0: the eye in it), ends, the far fillet ends
	float y1;
	float y2;
	vec2 at0;        // (psi, len) from the eye at y0, y1, y2
	vec2 at1;
	vec2 at2;
	vec2 cyl;        // their rates per metre of l on the cylinder
};

// a body as the tail takes it: its centre C, its 4D box's axes E[0..3] (E[3] the space's normal at C),
// its size (a ball's radius, a cube's half size), the bounding ball's chord reach, cube or ball
struct TailBody {
	vec4 C;
	vec4 E[4];
	float size;
	float reach;
	bool cube;
};

// a body as tail_body has it from its axes all four: E3 = -E1 x E2 x N, N the space's normal at C
TailBody tail_body_of(bool cube, vec4 C, vec4 E1, vec4 E2, vec4 E3, vec4 N, float size) {
	TailBody q;
	q.C = C;
	q.cube = cube;
	q.size = size;
	q.E[0] = E1;
	q.E[1] = E2;
	q.E[2] = E3;
	q.E[3] = N;
	// the 4D box [-s, s]^4 lies within 2 s of its centre; a ball's bounding ball a hair wider than
	// itself, so that a window's edge (tail_meet: where the ray's circle leaves the bounding ball) is
	// never on its surface, where float32 would put the window's start inside it (tail_enter: no way
	// in there)
	q.reach = cube ? 2.0 * size : TAIL_REACH * size;
	return q;
}

TailBody tail_body(bool cube, vec4 C, vec4 E1, vec4 E2, float size) {
	vec4 N = geo_normal(C);
	return tail_body_of(cube, C, E1, E2, -geo_cross4(E1, E2, N), N, size);
}

// The ray D (as geo_exit takes it) of the eye at (el, en), eye = (r, the root of u, r - rho0): true
// if it goes through the throat's cylinder (from the eye in it, or inward through it) and, with far
// (the way out past the zone wanted: tail_meet's far), turns by psi_min at least before it leaves the
// zone (a hair less: the straight way on adds less than pi); without far at2 is at1, not worked out.
bool tail_ray(float el, vec3 eye, vec3 en, vec4 D, float psi_min, bool far, out TailRay z) {
	float ca, sa, b, gap, sigma;
	vec3 t;
	bool in_ = geo_exit_ray(el, eye, en, D, ca, sa, t, b, gap, sigma);
	float Lc = g_prof.z, L = g_prof.w;
	float side = el < 0.0 ? -1.0 : 1.0;
	float le = abs(el);
	bool outward = ca >= 0.0;
	z.el = el;
	z.b = b;
	z.sigma = sigma;
	z.en = en;
	z.t = t;
	z.dl = outward ? side : -side;
	z.gap_c = -2.0 * g_prof.y * sigma;
	z.cyl = geo_exit_cyl(b, sigma);
	z.y0 = max(le - Lc, 0.0);
	z.y1 = outward ? Lc - le : Lc + le;
	z.y2 = z.y1 + (L - Lc);
	z.at0 = vec2(0.0);
	z.at1 = vec2(0.0);
	z.at2 = vec2(0.0);
	if (!in_ || Lc <= 0.0 || sigma >= g_prof2.y || (outward && le >= Lc)) return false;
	if (le > Lc) z.at0 = geo_between(b, sigma, Lc, z.gap_c, le, gap, false);
	z.at1 = z.at0 + (z.y1 - z.y0) * z.cyl;
	if (!far) {
		z.at2 = z.at1;
		return geo_finite(z.at1.x + z.at1.y);
	}
	z.at2 = z.at1 + geo_between(b, sigma, Lc, z.gap_c, L, g_prof2.x - b, false);
	return geo_finite(z.at2.x + z.at2.y) && z.at2.x + GEO_PI >= psi_min;
}

// l at y, and |l| on the far fillet
float tail_l(TailRay z, float y) { return z.el + z.dl * y; }

// the far fillet's (psi, len) from the cylinder's end to y (> y1)
vec2 tail_fillet(TailRay z, float y) {
	float a = g_prof.z + (y - z.y1);
	return geo_between(z.b, z.sigma, g_prof.z, z.gap_c, a, geo_dr(a) + z.gap_c, false);
}

// (dpsi/dy, dlen/dy) at y on the far fillet: (b / r, r) / sqrt(r^2 - b^2)
vec2 tail_rate(TailRay z, float y) {
	float a = g_prof.z + (y - z.y1);
	float r = geo_r(a);
	float q = sqrt(max((geo_dr(a) + z.gap_c) * (r + z.b), GEO_TINY20));
	return vec2(z.b / r, r) / q;
}

// the ray's point at y and angle ang in its plane (from en toward t), and its rate along y (R^4)
void tail_point(TailRay z, float y, float ang, float dpsi, out vec4 P, out vec4 dP) {
	float l = tail_l(z, y);
	float r = geo_r(abs(l));
	vec2 dd = geo_drdw(l);
	vec2 sc = geo_sincos(ang);
	vec3 n = sc.y * z.en + sc.x * z.t;
	vec3 nt = sc.y * z.t - sc.x * z.en;
	P = vec4(r * n, zone_w(l));
	dP = vec4(dd.x * z.dl * n + r * dpsi * nt, dd.y * z.dl);
}

// The y-range where the ray, at the body's angle, is within its bounding ball: the profile point
// (r(l), w(l)) within q of (A, Cw) (A the centre's distance from the axis in the ray's plane, q^2
// the reach's square less the centre's distance from that plane's square). On the cylinder (out
// .xy) l within sqrt(q^2 - (rho0 - A)^2) of Cw; on the far fillet (.zw) the arc of radius R round
// (rho0 + R, its side's Lc) within q of it: theta within acos of the cosine rule of the angle to it.
// An empty range has its start past its end.
vec4 tail_slab(TailRay z, float A, float Cw, float q2) {
	vec4 out_ = vec4(1.0, 0.0, 1.0, 0.0);
	float rho0 = g_prof.x, R = g_prof.y, Lc = g_prof.z;
	float c2 = q2 - (rho0 - A) * (rho0 - A);
	if (c2 > 0.0) {
		float hw = sqrt(c2);
		float ya = (Cw - hw - z.el) * z.dl, yb = (Cw + hw - z.el) * z.dl;
		out_.xy = vec2(max(min(ya, yb), z.y0), min(max(ya, yb), z.y1));
	}
	float sf = z.dl;                    // the far fillet's side
	float dx = A - (rho0 + R), dw = Cw - sf * Lc;
	float d = sqrt(dx * dx + dw * dw);
	float c0 = (R * R + d * d - q2) / max(2.0 * R * d, GEO_TINY20);
	if (c0 < 1.0) {
		float lo = 0.0, hi = 0.5 * GEO_PI;
		if (c0 > -1.0) {
			float thd = geo_atan2(sf * dw, -dx), al = geo_acos(c0);
			lo = 1e9;
			hi = -1e9;
			for (int k = -1; k <= 1; k++) {
				float a1 = max(thd - al + TAIL_PI2 * float(k), 0.0), a2 = min(thd + al + TAIL_PI2 * float(k), 0.5 * GEO_PI);
				if (a1 <= a2) {
					lo = min(lo, a1);
					hi = max(hi, a2);
				}
			}
		}
		if (lo <= hi) out_.zw = vec2(z.y1 + R * lo, z.y1 + R * hi);
	}
	return out_;
}

// how far the point P (rate dP along y) is out of the body: per part (a ball's one, a cube's four
// slabs) the value (> 0 out) and its rate; parts past the body's count 0, 0
void tail_parts(TailBody q, vec4 P, vec4 dP, out vec4 g, out vec4 dg) {
	vec4 d = P - q.C;
	if (!q.cube) {
		g = vec4(dot(d, d) - q.size * q.size, -1.0, -1.0, -1.0);
		dg = vec4(2.0 * dot(d, dP), 0.0, 0.0, 0.0);
		return;
	}
	for (int i = 0; i < 4; i++) {
		float v = dot(d, q.E[i]), dv = dot(dP, q.E[i]);
		g[i] = abs(v) - q.size;
		dg[i] = v < 0.0 ? -dv : dv;
	}
}

// how far the ray's point at x along copy n is out of the body (> 0 out, its parts' most), and the
// Newton step that takes each part it is out of to its way in, the furthest (a part it leaves: -1).
// Along the copy by x: on the cylinder its angle off psi_c (there l = lc + lam x, the point a closed
// form: x keeps its digits however fast the ray winds), on the far fillet y (the angle base + the
// fillet's sweep, base: at1's psi less 2 pi n).
vec4 tail_out(TailRay z, TailBody q, bool fillet, float lc, float lam, float psi_c, float base, float x, float tol) {
	vec4 P, dP;
	if (fillet) {
		tail_point(z, x, base + tail_fillet(z, x).x, tail_rate(z, x).x, P, dP);
	} else {
		vec2 sc = geo_sincos(psi_c + x);
		P = vec4(g_prof.x * (sc.y * z.en + sc.x * z.t), lc + lam * x);
		dP = vec4(g_prof.x * (sc.y * z.t - sc.x * z.en), lam);
	}
	vec4 g, dg;
	tail_parts(q, P, dP, g, dg);
	float worst = -1e30, rate = 0.0, step = 0.0;
	bool leaves = false;
	for (int k = 0; k < 4; k++) {
		if (g[k] > worst) {
			worst = g[k];
			rate = dg[k];
		}
		if (g[k] <= tol) continue;
		if (dg[k] >= 0.0) leaves = true;
		else step = max(step, -g[k] / dg[k]);
	}
	return vec4(worst, leaves ? -1.0 : step, length(dP), rate);
}

// A cube's four slab coordinates over its size at x (in it where all are within [-1, 1])
vec4 tail_box(TailRay z, TailBody q, bool fillet, float lc, float lam, float psi_c, float base, float x) {
	vec4 P, dP;
	if (fillet) {
		tail_point(z, x, base + tail_fillet(z, x).x, tail_rate(z, x).x, P, dP);
	} else {
		vec2 sc = geo_sincos(psi_c + x);
		P = vec4(g_prof.x * (sc.y * z.en + sc.x * z.t), lc + lam * x);
	}
	vec4 d = P - q.C;
	return vec4(dot(d, q.E[0]), dot(d, q.E[1]), dot(d, q.E[2]), dot(d, q.E[3])) / q.size;
}

// Whether a step from xa to xb (both out of the cube) may have gone over it: the slabs' coordinates
// taken as linear between them are all within the cube somewhere; u the middle of where
bool tail_over(TailRay z, TailBody q, bool fillet, float lc, float lam, float psi_c, float base, float xa, float xb, out float u) {
	u = xa;
	vec4 ma = tail_box(z, q, fillet, lc, lam, psi_c, base, xa);
	vec4 d = tail_box(z, q, fillet, lc, lam, psi_c, base, xb) - ma;
	float lo = 0.0, hi = 1.0;
	for (int k = 0; k < 4; k++) {
		if (abs(d[k]) < 1e-12) {
			if (abs(ma[k]) > 1.0) return false;
			continue;
		}
		float t1 = (-1.0 - ma[k]) / d[k], t2 = (1.0 - ma[k]) / d[k];
		lo = max(lo, min(t1, t2));
		hi = min(hi, max(t1, t2));
	}
	if (lo > hi) return false;
	u = mix(xa, xb, 0.5 * (lo + hi));
	return true;
}

// From xa (where the ray is out of the body, its angle within dmax of the copy's) to xb: where it
// goes in (true), by Newton's steps on each part it is out of, the furthest taken; false if it
// leaves a part (or never reaches one) before it is in all. A part's step from outside never passes
// its own way in where the part bends away from the ray, so a step that lands within TAIL_TOL of
// the body going in (a ball's always) lands where the ray goes in. But a cube's slab can bend toward
// the ray along the helix and the step overshoot into the body: the way in is then looked for back
// between the last point out of it and the first in (TAIL_HALVE steps at most), by Newton's steps
// on the part a point in is in by least (the face the ray came in through), and halving where such
// a step would leave that stretch or after a point out. A step can even go over a cube (a thin way
// through a corner of it) and leave it behind: where the ray then leaves a part, the step's stretch
// is looked into (tail_over, TAIL_OVER times, each time on the half its slabs say the cube is in),
// and a point in the cube found there is the first in. Done within TAIL_TOL of the body (on its
// surface, going in), or where a step moves the point by less: on the fillet the sweep's table (its
// filter's weights in 256ths) leaves the point that much uncertain.
bool tail_enter(TailRay z, TailBody q, bool fillet, float lc, float lam, float psi_c, float base, float xa, float xs, float xb, out float x) {
	x = xs;
	float near = fillet ? TAIL_TOL_FILLET : TAIL_TOL;
	float tol = q.cube ? near : 2.0 * near * q.size;
	float xo = xa;          // the last point out of the body (the window's start is)
	bool in_ = false;
	for (int i = 0; i < TAIL_STEPS; i++) {
		vec4 o = tail_out(z, q, fillet, lc, lam, psi_c, base, x, tol);
		if (o.x <= tol) {
			// in at the window's start: it went in before (the meshes' images, or a copy before);
			// in where the steps start ahead of it: on it going in, or float32 put the start past
			// the way in (then looked for back from the window's start)
			if (i == 0 && x <= xo) return false;
			if (o.x >= -tol && o.w <= 0.0) return true;
			in_ = true;
			break;
		}
		if (o.y < 0.0) {
			// leaving a part: over the cube with the last step? (xo out, x out)
			if (!q.cube || i == 0) return false;
			float a = xo, c = x, u;
			for (int r = 0; r < TAIL_OVER && !in_; r++) {
				if (!tail_over(z, q, fillet, lc, lam, psi_c, base, a, c, u)) break;
				if (tail_out(z, q, fillet, lc, lam, psi_c, base, u, tol).x <= tol) {
					x = u;
					xo = a;
					in_ = true;
				} else {
					// out at u: on the half the slabs, linear on it, say the cube may be in
					float v;
					if (tail_over(z, q, fillet, lc, lam, psi_c, base, a, u, v)) c = u; else a = u;
				}
			}
			if (in_) break;
			return false;
		}
		xo = x;
		float xn = x + o.y;
		if (!(xn <= xb)) return false;
		// a step float32 can't take at x is done too: so asked, not as xn == x, which a compiler
		// may take for o.y == 0 (deep in the tail, a fillet's y is tens of metres: its last digit
		// some micrometres)
		bool done = o.y <= TAIL_EPS * abs(x) || o.y * o.z < near;
		x = xn;
		if (done) return true;
	}
	if (!in_) return false;
	// x in, xo out; o at the last point worked out, its rate 0 if that was out (then halving). The
	// point in is worked out again rather than kept from the steps: kept, its numbers would hold
	// registers all through them (tools/adreno_stats.sh: 48 instead of 32, 4 waves instead of 6)
	vec4 o = tail_out(z, q, fillet, lc, lam, psi_c, base, x, tol);
	for (int i = 0; i < TAIL_HALVE; i++) {
		if (o.x >= -tol && o.x <= tol && o.w <= 0.0) break;
		float m = 0.5 * (xo + x);
		if (o.w < 0.0) {
			float xn = x - o.x / o.w;
			if (xn > xo && xn < x) m = xn;
		}
		if (m == xo || m == x) break;
		o = tail_out(z, q, fillet, lc, lam, psi_c, base, m, tol);
		if (o.x <= tol) {
			x = m;
		} else {
			xo = m;
			o.w = 0.0;
		}
	}
	return true;
}

// Where to look for a ball's way in along copy n's line on the cylinder, l = lc + lam x at x off
// psi_c, within the window [xa, xb]: there |P - C|^2 - s^2 is g(x) = k (1 - cos x) + (d + lam x)^2 -
// e (d = lc - Cw; e and k as tail_meet has them, worked out again: kept, they would hold registers
// all through the search, tools/adreno_stats.sh), and 1 - cos x >= x^2 / 2 - x^4 / 24 >= (1 - X^2
// / 12) x^2 / 2 for |x| <= X, so g is no less than that parabola: where it has no root in the
// window, the ray misses (false); else xs is its first root a hair before (TAIL_AHEAD), a point
// before the way in from which tail_enter's steps land on it in a step or two, or xa where the
// parabola can't tell (the window may start in the ball, or is wider than the bound holds).
bool tail_ball_start(TailRay z, TailBody q, float lc, float lam, float xa, float xb, out float xs) {
	xs = xa;
	float X = max(abs(xa), abs(xb));
	float ae = dot(q.C.xyz, z.en), at = dot(q.C.xyz, z.t), h = dot(q.C.xyz, cross(z.en, z.t));
	float A = sqrt(ae * ae + at * at);
	float e = q.size * q.size - h * h - (A - g_prof.x) * (A - g_prof.x);
	float c = g_prof.x * A * (1.0 - X * X / 12.0) + lam * lam;
	if (X > 1.0 || c <= 0.0) return true;
	float d = lc - q.C.w;
	float bq = d * lam, cq = d * d - e;
	float disc = bq * bq - c * cq;
	if (disc < 0.0) return false;
	// the roots without cancelling digits: r1 r2 = cq / c
	float m = -(bq + (bq < 0.0 ? -1.0 : 1.0) * sqrt(disc));
	float ra = m / c, rb = abs(m) > GEO_TINY20 ? cq / m : ra;
	float r1 = min(ra, rb), r2 = max(ra, rb);
	if (r2 < xa || r1 > xb) return false;
	xs = max(r1 - TAIL_AHEAD * (1.0 + abs(r1)), xa);
	return true;
}

// where copy n passes the body's angle psi_c on the cylinder (y)
float tail_copy_y(TailRay z, float psi_c, float n) {
	return z.y0 + (TAIL_PI2 * n + (psi_c - z.at0.x)) / z.cyl.x;
}

// copy n on the cylinder (sl: the slab's y on it): true if the ray goes into the body there at a turn
// psi_min or more, and where (y, the angle, psi)
bool tail_copy(TailRay z, TailBody q, float n, float psi_c, float dmax, vec2 sl, float lam, float psi_min, out vec3 at) {
	at = vec3(0.0);
	float yc = tail_copy_y(z, psi_c, n);
	// the window in the angle off psi_c: dmax, and the slab's and the cylinder's ends
	float xa = max(-dmax, (max(sl.x, z.y0) - yc) * z.cyl.x), xb = min(dmax, (min(sl.y, z.y1) - yc) * z.cyl.x);
	if (!(xa <= xb)) return false;
	float lc = tail_l(z, yc);
	float xs = xa, x;
	if (!q.cube && !tail_ball_start(z, q, lc, lam, xa, xb, xs)) return false;
	if (!tail_enter(z, q, false, lc, lam, psi_c, 0.0, xa, xs, xb, x)) return false;
	at = vec3(yc + x / z.cyl.x, psi_c + x, TAIL_PI2 * n + psi_c + x);
	return at.z >= psi_min;
}

// The first way into the body at a turn of psi_min or more, among copies n_lo to n_hi (a strip's
// one, the band's from its first on: tail_strip) and, with far, out past the zone: true, its y, angle
// in the plane, turn (psi) and the stretch it is on (0 the cylinder, 1 the far fillet, 2 out past the
// zone)
bool tail_meet(TailRay z, TailBody q, float psi_min, float n_lo, float n_hi, bool far, out float y, out float ang, out float psi, out int on) {
	y = 0.0;
	ang = 0.0;
	psi = 0.0;
	on = 0;
	vec4 Cx = q.C;
	float ae = dot(Cx.xyz, z.en), at = dot(Cx.xyz, z.t);
	float A = sqrt(ae * ae + at * at);
	float q2 = q.reach * q.reach - max(dot(Cx.xyz, Cx.xyz) - A * A, 0.0);
	if (q2 <= 0.0) return false;
	float psi_c = geo_atan2(at, ae);
	// the angle the bounding ball spans from the axis: 1 - cos dmax = q^2 / (2 r A), r >= rho0
	float cd = 1.0 - q2 / max(2.0 * g_prof.x * A, GEO_TINY20);
	float dmax = cd > -1.0 ? geo_acos(cd) : GEO_PI;
	vec4 sl = tail_slab(z, A, q.C.w, q2);
	float nmin = max(ceil((psi_min - psi_c - dmax) / TAIL_PI2), n_lo);
	// the cylinder: the copies whose window (tail_copy's: the ray goes along l by lambda dmax across
	// it) reaches into the slab (on the cylinder: a copy past its end at psi_c can go in before), a
	// run of whole numbers (l moves by 2 pi lambda a copy); a cube's narrowed to its box's l at angles
	// across the window where it has one (its slabs across l there), but only where the run is longer
	// than TAIL_COPIES tries one by one (it spans (hi - lo) / |2 pi lambda| + 1 at most): off the
	// limit it is a copy or two, and a copy the ray misses costs less than the narrowing; a ball's to
	// those whose line meets its section of the cylinder
	if (sl.x <= sl.y && z.cyl.x > 0.0) {
		float lam = z.dl / z.cyl.x;       // dl / dpsi
		float s2 = TAIL_PI2 * lam;
		float D0 = tail_l(z, tail_copy_y(z, psi_c, 0.0)) - q.C.w;
		float lo = tail_l(z, sl.x) - q.C.w, hi = tail_l(z, sl.y) - q.C.w;
		if (lo > hi) { float s = lo; lo = hi; hi = s; }
		lo -= abs(lam) * dmax;
		hi += abs(lam) * dmax;
		if (q.cube && hi - lo > float(TAIL_COPIES - 1) * abs(s2)) {
			// its box's l on the cylinder at angles across the window (TAIL_CUTS of them), each the
			// slabs across l there; the ray goes along l by lambda dmax across the window, and the
			// box's l between two angles by up to a step's worth more
			float clo = 1e9, chi = -1e9;
			for (int j = 0; j < TAIL_CUTS; j++) {
				vec2 scc = geo_sincos(psi_c + dmax * (2.0 * float(j) / float(TAIL_CUTS - 1) - 1.0));
				vec4 Pc = vec4(g_prof.x * (scc.y * z.en + scc.x * z.t), q.C.w) - q.C;
				float a1 = -1e9, a2 = 1e9;
				for (int i = 0; i < 4; i++) {
					float m = dot(Pc, q.E[i]), e = q.E[i].w;
					if (abs(e) > 1e-6) {
						float u1 = (-q.size - m) / e, u2 = (q.size - m) / e;
						a1 = max(a1, min(u1, u2));
						a2 = min(a2, max(u1, u2));
					} else if (abs(m) > q.size) {
						a1 = 1e9;
					}
				}
				if (a1 <= a2) {
					clo = min(clo, a1);
					chi = max(chi, a2);
				}
			}
			float mg = abs(lam) * dmax + 0.25 * q.size / float(TAIL_CUTS - 1);
			if (clo <= chi) {
				lo = max(lo, clo - mg);
				hi = min(hi, chi + mg);
			}
		}
		if (!q.cube) {
			// a ball's copies the ray goes into, exactly: copy n's line in the window, l = Cw + d + lam
			// x (d its l at psi_c off the centre's), is in the ball's section of the cylinder where
			// rho0^2 + |C|^2 - s^2 - k cos x + (d + lam x)^2 <= 0 (k = 2 rho0 A), which it meets where
			// |d| <= the most of sqrt(k cos x + e - k) + |lam x| over x (e = s^2 - h^2 - (A - rho0)^2,
			// h: C off the ray's plane), at cos x = 1 - delta; a hair wider than float32 works it out
			float h = dot(Cx.xyz, cross(z.en, z.t));
			float e = q.size * q.size - h * h - (A - g_prof.x) * (A - g_prof.x);
			float k = 2.0 * g_prof.x * A, l2 = lam * lam;
			float B = 2.0 * k * k + 4.0 * l2 * k;
			float del = 8.0 * l2 * max(e, 0.0) / max(B + sqrt(max(B * B - 16.0 * k * k * l2 * max(e, 0.0), 0.0)), GEO_TINY20);
			float ds = e > 0.0 ? (sqrt(max(e - k * del, 0.0)) + 2.0 * abs(lam) * geo_asin(sqrt(0.5 * del))) * 1.001 + 1e-6 : -1.0;
			lo = max(lo, -ds);
			hi = min(hi, ds);
		}
		float n0 = max(ceil((z.at0.x - psi_c - dmax) / TAIL_PI2), nmin);
		float n1 = min(floor((z.at1.x - psi_c + dmax) / TAIL_PI2), n_hi);
		if (abs(s2) > GEO_TINY20) {
			// a hair wider than float32 works out where copy n passes psi_c (tail_copy: from y, l to
			// some 120 m)
			float na = (lo - D0) / s2, nb = (hi - D0) / s2;
			float tol = 1e-3 + 1e-6 * (abs(z.el) + z.y1 + abs(q.C.w) + 1.0) / abs(s2);
			n0 = max(n0, ceil(min(na, nb) - tol));
			n1 = min(n1, floor(max(na, nb) + tol));
		} else if (D0 < lo || D0 > hi) {
			n1 = n0 - 1.0;
		}
		if (lo > hi) n1 = n0 - 1.0;
		// the first copy the ray goes into: each of a short run, else TAIL_COPIES spread over it
		// (a ball's run is exact: its first ones, then its last) and halving back from the first
		// of them it goes into
		vec3 at;
		bool met = false;
		float span = n1 - n0;
		float prev = n0 - 1.0;
		for (int c = 0; c < TAIL_COPIES; c++) {
			float n = span < float(TAIL_COPIES) || (!q.cube && c < TAIL_COPIES - 1) ? n0 + float(c) : n0 + floor(span * float(c) / float(TAIL_COPIES - 1) + 0.5);
			if (n > n1) break;
			if (tail_copy(z, q, n, psi_c, dmax, sl.xy, lam, psi_min, at)) {
				met = true;
				for (int k = 0; k < 16; k++) {
					if (n - prev <= 1.0) break;
					float mid = floor(0.5 * (prev + n));
					vec3 am;
					if (tail_copy(z, q, mid, psi_c, dmax, sl.xy, lam, psi_min, am)) {
						n = mid;
						at = am;
					} else {
						prev = mid;
					}
				}
				break;
			}
			prev = n;
		}
		if (met) {
			y = at.x;
			ang = at.y;
			psi = at.z;
			return true;
		}
	}
	// the far fillet: the copies psi there reaches, each window's start by Newton on the sweep
	// (growing and concave: from below it never passes the root)
	if (sl.z <= sl.w) {
		float ps0 = z.at1.x + tail_fillet(z, sl.z).x, ps1 = z.at1.x + tail_fillet(z, sl.w).x;
		float n0 = max(ceil((ps0 - psi_c - dmax) / TAIL_PI2), nmin);
		float n1 = min(floor((ps1 - psi_c + dmax) / TAIL_PI2), n_hi);
		float ya = sl.z;
		for (int c = 0; c < TAIL_COPIES; c++) {
			float n = n0 + float(c);
			if (n > n1) break;
			float base = z.at1.x - TAIL_PI2 * n;
			for (int i = 0; i < 6; i++) {
				float h = base + tail_fillet(z, ya).x - (psi_c - dmax);
				if (h >= -1e-6) break;
				ya = min(ya - h / tail_rate(z, ya).x, sl.w);
			}
			if (tail_enter(z, q, true, 0.0, 0.0, psi_c, base, ya, ya, sl.w, y)) {
				ang = base + tail_fillet(z, y).x;
				psi = TAIL_PI2 * n + ang;
				if (psi >= psi_min) {
					on = 1;
					return true;
				}
			}
		}
	}
	// past the zone: straight from where the ray leaves it, in the far universe (a body reaching
	// across the zone's edge)
	if (!far) return false;
	vec3 pos, dir;
	geo_exit_at(z.en, z.t, z.b, z.at2.x, pos, dir);
	vec4 o = vec4(pos, z.dl * (g_prof.z + g_prof.y * (1.0 - geo_sin(g_prof2.w)))) - q.C;
	vec4 dv = vec4(dir, 0.0);
	float t0 = 0.0, t1 = 1e9;
	if (!q.cube) {
		float bb = dot(o, dv), cc = dot(o, o) - q.size * q.size;
		float disc = bb * bb - cc;
		if (disc < 0.0) return false;
		t0 = -bb - sqrt(disc);
		t1 = -bb + sqrt(disc);
	} else {
		t0 = -1e9;
		for (int i = 0; i < 4; i++) {
			float m = dot(o, q.E[i]), e = dot(dv, q.E[i]);
			if (abs(e) < GEO_TINY20) {
				if (abs(m) > q.size) return false;
				continue;
			}
			float u1 = (-q.size - m) / e, u2 = (q.size - m) / e;
			t0 = max(t0, min(u1, u2));
			t1 = min(t1, max(u1, u2));
		}
	}
	// in it already where the ray leaves the zone: it went in before
	if (t0 > t1 || t0 <= 0.0) return false;
	vec3 hp = pos + t0 * dir;
	// below the floor: hidden
	if (hp.z + g_lift < 0.0) return false;
	ang = z.at2.x + geo_atan2(length(cross(pos, hp)), dot(pos, hp));
	psi = ang;
	y = z.y2 + (length(hp) - g_prof2.x);
	on = 2;
	return psi >= psi_min;
}

// The point the ray meets at y (stretch on, angle ang): the point (R^4), the light's way in there
// (R^4, unit) and the length of its way from the eye
void tail_hit(TailRay z, float y, float ang, int on, out vec4 P, out vec4 arrive, out float len) {
	if (on == 2) {
		vec3 pos, dir;
		geo_exit_at(z.en, z.t, z.b, z.at2.x, pos, dir);
		vec3 hp = vec3(0.0);
		// the point at its distance from the centre along the straight way out
		float rr = y - z.y2 + g_prof2.x;
		float pd = dot(pos, dir);
		float s = -pd + sqrt(max(pd * pd - dot(pos, pos) + rr * rr, 0.0));
		hp = pos + s * dir;
		P = vec4(hp, z.dl * (g_prof.z + g_prof.y * (1.0 - geo_sin(g_prof2.w))));
		arrive = vec4(dir, 0.0);
		len = z.at2.y + s;
		return;
	}
	vec2 rate = on == 0 ? z.cyl : tail_rate(z, y);
	vec4 dP;
	tail_point(z, y, ang, rate.x, P, dP);
	arrive = dP / max(length(dP), GEO_TINY20);
	len = on == 0 ? z.at0.y + (y - z.y0) * z.cyl.y : z.at1.y + tail_fillet(z, y).y;
}

// The turn by y (metres of l from the eye along the way it goes) of the ray launched m off the radial
// along that way from the eye at le (eye as geo_exit takes it), the cylinder's start and end on that
// way at y0 and y1: from the eye (its near fillet, the cylinder, the far fillet up to the zone's
// edge); nought for a ray that doesn't pass the throat. Growing with m (toward the limit) and y.
float tail_turn(float le, vec3 eye, float y0, float y1, float y, float m) {
	float Lc = g_prof.z, L = g_prof.w, R2 = 2.0 * g_prof.y;
	vec2 sc = geo_sincos(m);
	float b = eye.x * sc.x;
	float gap = eye.x * (sc.y * sc.y / (1.0 + sc.x));
	float sigma = geo_sigma(eye.z - gap);
	if (sigma >= g_prof2.y) return 0.0;
	float gc = -R2 * sigma;
	float turn = le > Lc ? geo_between(b, sigma, Lc, gc, le, gap, false).x : 0.0;
	turn += (min(y, y1) - y0) * geo_exit_cyl(b, sigma).x;
	if (y > y1) {
		float a = min(Lc + (y - y1), L);
		turn += geo_between(b, sigma, Lc, gc, a, geo_dr(a) + gc, false).x;
	}
	return turn;
}

// The launch off the radial (within [0, lim]) where tail_turn at y reaches target, by halving: (the
// last short of it, the first that reaches it)
vec2 tail_launch(float le, vec3 eye, float y0, float y1, float y, float target, float lim) {
	float lo = 0.0, hi = lim;
	for (int i = 0; i < 24; i++) {
		float m = 0.5 * (lo + hi);
		if (tail_turn(le, eye, y0, y1, y, m) >= target) hi = m; else lo = m;
	}
	return vec2(lo, hi);
}

// The view's directions in which body q's tail can be met from the eye at el (eye as geo_exit takes
// it): (the least and greatest angle off the inward radial direction; least past greatest: none).
// Its rays pass the throat through the cylinder (from the eye in it, either way along it, or inward
// from outside) and reach the body's far end along that way (its centre's l and the reach a hair
// stretched: the profile's arc is a little longer than its chord) having turned by psi_min - 2 pi at
// least: from the launch whose ray does (halving) to r_min's. Round the axis it is seen within its
// two sectors: tail_sector.
vec2 tail_band(float el, vec3 eye, TailBody q, float psi_min) {
	float le = abs(el), side = el < 0.0 ? -1.0 : 1.0;
	float Lc = g_prof.z;
	vec2 band = vec2(GEO_PI, 0.0);
	if (Lc <= 0.0) return band;
	vec3 cn;
	float lc = geo_l_of(q.C, cn);
	float rl = 1.05 * q.reach + 0.01;
	float lim = geo_asin(min(g_prof2.z / eye.x, 1.0));
	for (int w = 0; w < 2; w++) {
		bool outward = w == 1;
		if (outward && le >= Lc) break;
		float dl = outward ? side : -side;
		float y0 = max(le - Lc, 0.0), y1 = outward ? Lc - le : Lc + le;
		// the body's far end along this way, in metres of l from the eye: nothing of it past the
		// cylinder's start, none (on the near fillet its images close in at once)
		float yf = (lc - el) * dl + rl;
		if (yf <= y0) continue;
		float lo = tail_launch(le, eye, y0, y1, yf, psi_min - TAIL_PI2, lim).x;
		band = outward ? vec2(min(band.x, GEO_PI - lim), max(band.y, GEO_PI - lo)) : vec2(min(band.x, lo), max(band.y, lim));
	}
	return band;
}

// The tail's strips of body q from the eye at el (eye as geo_exit takes it), its sector's half width
// half_w round u (tail_sector), psi_min as tail_meet's. Strips only where every way into the body
// past psi_min is a copy on the cylinder or the far fillet along one way from the eye: the body
// within the zone, all of it past the cylinder's start along that way (past the eye, from in the
// cylinder; a body round the axis on its far side, whose angle in the planes wraps round pi, none).
// Seen in a ray's plane of side s (s 0: its sector round u; 1: round -u) the body's centre is at
// psi_c within c[2 s], c[2 s + 1] (the plane's tangent within the sector's half width of u's way:
// psi_c = atan2(its distance across the axis times the cosine of that, its distance along it)) and
// its bounding ball spans dmax <= dm of it (tail_meet's, with the ball's least distance from the
// axis), so copy n's turns are within 2 pi n + [c[2 s] - dm, c[2 s + 1] + dm]; the first copy that
// can be past psi_min is n0[s].
struct TailStrips {
	bool on;
	bool outward;
	float le;
	float y0;
	float y1;
	float yn;
	float yf;
	float lim;
	vec2 n0;
	vec4 c;
	float dm;
};

TailStrips tail_strips(float el, vec3 eye, vec3 en, TailBody q, float half_w, float psi_min) {
	TailStrips t;
	float Lc = g_prof.z, L = g_prof.w;
	float le = abs(el), side = el < 0.0 ? -1.0 : 1.0;
	vec3 cn;
	float lc = geo_l_of(q.C, cn);
	float rl = 1.05 * q.reach + 0.01;
	t.on = false;
	t.outward = false;
	t.le = le;
	t.y0 = max(le - Lc, 0.0);
	t.y1 = Lc + le;
	t.yn = 0.0;
	t.yf = 0.0;
	t.lim = geo_asin(min(g_prof2.z / eye.x, 1.0));
	t.n0 = vec2(0.0);
	t.c = vec4(0.0);
	t.dm = GEO_PI;
	if (Lc <= 0.0 || abs(lc) + rl >= L) return t;
	// the way the body is along: inward (toward the throat's middle) or, from in the cylinder, outward
	float din = (lc - el) * -side;
	bool outward = le < Lc && din < 0.0;
	float dl = outward ? side : -side;
	t.outward = outward;
	t.y1 = outward ? Lc - le : Lc + le;
	t.yn = (lc - el) * dl - rl;
	t.yf = t.yn + 2.0 * rl;
	if (t.yn <= t.y0) return t;
	vec3 C3 = q.C.xyz;
	float ce = dot(C3, en);
	float cp = length(C3 - ce * en);
	// a body round the axis on the far side: its angle in the planes wraps round pi
	if (half_w >= GEO_PI && ce < 0.0) return t;
	float a0 = geo_atan2(cp, ce), a1 = geo_atan2(cp * geo_sincos(min(half_w, GEO_PI)).y, ce);
	float lo = min(a0, a1), hi = max(a0, a1);
	t.c = vec4(lo - 1e-4, hi + 1e-4, -hi - 1e-4, -lo + 1e-4);
	float r2 = q.reach * q.reach;
	float cd = 1.0 - r2 / max(2.0 * g_prof.x * sqrt(max(dot(C3, C3) - r2, 0.0)), GEO_TINY20);
	t.dm = cd > -1.0 ? geo_acos(cd) : GEO_PI;
	float wide = max(t.c.y - t.c.x, t.c.w - t.c.z) + 2.0 * t.dm;
	if (wide >= 0.5 * TAIL_PI2) return t;
	t.n0 = vec2(ceil((psi_min - t.c.y - t.dm) / TAIL_PI2), ceil((psi_min - t.c.w - t.dm) / TAIL_PI2));
	t.on = true;
	return t;
}

// The margins zone_tail.gdshader draws a sector of half width half_w with: (round the axis, off the
// inward radial where the body has no strips). Its edges off the radial are chords of circles round
// it; round the axis the sector a hair wider still.
vec2 tail_margins(float half_w) {
	float step = 2.0 * min(half_w, GEO_PI) / TAIL_SEGMENTS;
	float sag = 0.125 * step * step;
	return vec2(2e-3 + sag, 2e-3 + sag);
}

// The margin past a strip's edge at angle chi off the radial: half a pixel, and as far as the chords
// between the edge's vertices (a step apart round the axis, as zone_tail.gdshader puts them) dip off
// its circle away from the equator (chi pi/2) at their middle: tan chi' = tan chi cos(step / 2), so
// by up to sin(2 chi) sin^2(step / 4).
float tail_margin(float chi, float half_w) {
	float step = 2.0 * min(min(half_w, GEO_PI) + tail_margins(half_w).x, GEO_PI) / TAIL_SEGMENTS;
	float h = geo_sincos(0.25 * step).x;
	return 5e-4 + abs(geo_sincos(2.0 * chi).x) * h * h * 1.05;
}

// How many of a side's strips are drawn (st: strip k's least and greatest angle at st[k], k to
// TAIL_STRIPS, of a sector of half width half_w): those up to the first that comes within the
// margins of the next, the band from it.
int tail_apart(vec2 st[TAIL_STRIPS + 1], float half_w) {
	int K = 0;
	while (K < TAIL_STRIPS) {
		float gap = max(st[K].x, st[K + 1].x) - min(st[K].y, st[K + 1].y);
		float mg = tail_margin(st[K].x, half_w) + tail_margin(st[K].y, half_w) + tail_margin(st[K + 1].x, half_w) + tail_margin(st[K + 1].y, half_w);
		if (gap <= mg) break;
		K++;
	}
	return K;
}

// Strip k (copy n0 + k) of side s: its launches' angles off the inward radial (least, greatest):
// from the one whose turn at the body's far end reaches the copy's least to the one whose turn at its
// near end reaches its greatest, each by halving to the side that keeps every ray of the copy in.
vec2 tail_strip(TailStrips t, vec3 eye, int s, float k) {
	float n = (s == 0 ? t.n0.x : t.n0.y) + k;
	float clo = s == 0 ? t.c.x : t.c.z, chi = s == 0 ? t.c.y : t.c.w;
	float a = tail_launch(t.le, eye, t.y0, t.y1, t.yf, TAIL_PI2 * n + clo - t.dm, t.lim).x;
	float b = tail_launch(t.le, eye, t.y0, t.y1, t.yn, TAIL_PI2 * n + chi + t.dm, t.lim).y;
	return t.outward ? vec2(GEO_PI - b, GEO_PI - a) : vec2(a, b);
}

// Body q's azimuths round the eye's axis whose rays' planes pass within its reach of its centre:
// two sectors, round u (out: C's direction across en, unit, in the eye's tangent space) and round -u,
// each the half width returned (pi: all of them, a body round the axis).
float tail_sector(vec3 en, TailBody q, out vec3 u) {
	vec3 c = q.C.xyz - dot(q.C.xyz, en) * en;
	float rc = length(c);
	u = rc > 1e-9 ? c / rc : normalize(cross(en, abs(en.z) < 0.9 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0)));
	return q.reach >= rc ? GEO_PI : geo_asin(q.reach / rc);
}
