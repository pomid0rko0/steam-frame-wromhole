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
// form, tail_slab). On the cylinder the copies n whose l there is within the slab are a run of whole
// numbers in closed form (a cube's narrowed to its box's l at the window's angles), however many turns
// on; next to the limit, where l moves by a hair a copy, the run is long, and the copies the ray goes
// into are a run within it: tried at TAIL_COPIES copies spread over it, then halving back from the
// first it goes into to the first of all (tail_copy). On the far fillet the few there by psi at the
// slab's ends. A copy's window of y is its |x| <=
// dmax, and in it the ray goes into the body where it enters every one of its convex parts (a ball's
// chord ball, a cube's four slabs of its 4D box): each part's Newton step from the side the ray comes
// from never passes that part's own way in, so the furthest of them, taken again and again, lands on
// the way into the body, or finds a part the ray leaves before it is in the others (tail_enter).
// Only ways in at a turn psi >= psi_min count (a point at psi is in image floor(psi / pi)): those
// before are the meshes' images, drawn already, and a ray already in a body at psi_min went in through
// one of them. The renderer takes psi_min (ZONE_IMAGES - 1) pi: the meshes' last image is drawn by
// both (the same points, at the same depth), else where it meets the next in a ring round the eye's
// axis the mesh's edge and the tail's first way in would leave pinholes between them.
//   Precision: float32. psi grows without bound next to the limit; a copy's angle is therefore
// carried as its offset x from psi_c, and the l at which a copy passes psi_c straight from n
// (tail_copy_y). Their phase is off by about psi times float32's step (1e-3 rad at psi 1e4, ten
// thousand turns: images far thinner than a pixel, a pixel or less from the limit).

const float TAIL_PI2 = 6.28318530717959;
const int TAIL_COPIES = 4;        // copies tried a body and stretch (from the first that can be met)
const int TAIL_STEPS = 12;        // Newton's rounds into a body
const float TAIL_TOL = 2e-6;      // m: a point this near a body's surface is on it (on the far fillet:)
const float TAIL_TOL_FILLET = 1e-5;
const int TAIL_CUTS = 9;          // angles a cube's l on the cylinder is taken at across a window

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

TailBody tail_body(bool cube, vec4 C, vec4 E1, vec4 E2, float size) {
	TailBody q;
	q.C = C;
	q.cube = cube;
	q.size = size;
	vec4 N = geo_normal(C);
	q.E[0] = E1;
	q.E[1] = E2;
	q.E[2] = -geo_cross4(E1, E2, N);
	q.E[3] = N;
	// the 4D box [-s, s]^4 lies within 2 s of its centre
	q.reach = cube ? 2.0 * size : size;
	return q;
}

// The ray D (as geo_exit takes it) of the eye at (el, en), eye = (r, the root of u, r - rho0): true
// if it goes through the throat's cylinder (from the eye in it, or inward through it) and turns by
// psi_min at least before it leaves the zone (a hair less: the straight way on adds less than pi).
bool tail_ray(float el, vec3 eye, vec3 en, vec4 D, float psi_min, out TailRay z) {
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

// From xa (where the ray is out of the body, its angle within dmax of the copy's) to xb: where it
// goes in (true), by Newton's steps on each part it is out of, the furthest taken; false if it
// leaves a part (or never reaches one) before it is in all. Along the copy by x: on the cylinder
// its angle off psi_c (there l = lc + lam x, the point a closed form: x keeps its digits however
// fast the ray winds), on the far fillet y (the angle base + the fillet's sweep, base: at1's psi
// less 2 pi n). Done within TAIL_TOL of the body, or where a step moves the point by less: on the
// fillet the sweep's table (its filter's weights in 256ths) leaves the point that much uncertain.
bool tail_enter(TailRay z, TailBody q, bool fillet, float lc, float lam, float psi_c, float base, float xa, float xb, out float x) {
	x = xa;
	float near = fillet ? TAIL_TOL_FILLET : TAIL_TOL;
	float tol = q.cube ? near : 2.0 * near * q.size;
	for (int i = 0; i < TAIL_STEPS; i++) {
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
		float step = 0.0;
		bool in_ = true;
		for (int k = 0; k < 4; k++) {
			if (g[k] <= tol) continue;
			in_ = false;
			if (dg[k] >= 0.0) return false;
			step = max(step, -g[k] / dg[k]);
		}
		// in at the window's start: it went in before (the meshes' images, or a copy before)
		if (in_) return i > 0;
		float xn = x + step;
		if (!(xn <= xb)) return false;
		bool done = xn == x || step * length(dP) < near;
		x = xn;
		if (done) return true;
	}
	return false;
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
	float x;
	if (!(xa <= xb && tail_enter(z, q, false, tail_l(z, yc), lam, psi_c, 0.0, xa, xb, x))) return false;
	at = vec3(yc + x / z.cyl.x, psi_c + x, TAIL_PI2 * n + psi_c + x);
	return at.z >= psi_min;
}

// The first way into the body at a turn of psi_min or more: true, its y, angle in the plane, turn
// (psi) and the stretch it is on (0 the cylinder, 1 the far fillet, 2 out past the zone)
bool tail_meet(TailRay z, TailBody q, float psi_min, out float y, out float ang, out float psi, out int on) {
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
	float nmin = ceil((psi_min - psi_c - dmax) / TAIL_PI2);
	// the cylinder: the copies whose l at psi_c is within the slab, a run of whole numbers (l moves by
	// 2 pi lambda a copy); a cube's narrowed to its box's l at psi_c where it has one (its slabs
	// across l at that angle)
	if (sl.x <= sl.y && z.cyl.x > 0.0) {
		float lam = z.dl / z.cyl.x;       // dl / dpsi
		float D0 = tail_l(z, tail_copy_y(z, psi_c, 0.0)) - q.C.w;
		float lo = tail_l(z, sl.x) - q.C.w, hi = tail_l(z, sl.y) - q.C.w;
		if (lo > hi) { float s = lo; lo = hi; hi = s; }
		if (q.cube) {
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
		float n0 = max(ceil((z.at0.x - psi_c - dmax) / TAIL_PI2), nmin);
		float n1 = floor((z.at1.x - psi_c + dmax) / TAIL_PI2);
		float s2 = TAIL_PI2 * lam;
		if (abs(s2) > GEO_TINY20) {
			float na = (lo - D0) / s2, nb = (hi - D0) / s2;
			n0 = max(n0, ceil(min(na, nb)) - 1.0);
			n1 = min(n1, floor(max(na, nb)) + 1.0);
		} else if (D0 < lo || D0 > hi) {
			n1 = n0 - 1.0;
		}
		// the first copy the ray goes into: each of a short run, else TAIL_COPIES spread over it
		// and halving back from the first of them it goes into
		vec3 at;
		bool met = false;
		float span = n1 - n0;
		float prev = n0 - 1.0;
		for (int c = 0; c < TAIL_COPIES; c++) {
			float n = span < float(TAIL_COPIES) ? n0 + float(c) : n0 + floor(span * float(c) / float(TAIL_COPIES - 1) + 0.5);
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
		float n1 = floor((ps1 - psi_c + dmax) / TAIL_PI2);
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
			if (tail_enter(z, q, true, 0.0, 0.0, psi_c, base, ya, sl.w, y)) {
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

// The view's directions in which body q's tail can be met from the eye at el (eye as geo_exit takes
// it): (the least and greatest angle off the inward radial direction; least past greatest: none).
// Its rays pass the throat through the cylinder (from the eye in it, either way along it, or inward
// from outside) and reach the body's far end along that way (its centre's l and the reach a hair
// stretched: the profile's arc is a little longer than its chord) having turned by psi_min - 2 pi at
// least: from the launch whose ray does (halving) to r_min's. Round the axis it is seen within its
// two sectors: tail_sector.
vec2 tail_band(float el, vec3 eye, TailBody q, float psi_min) {
	float le = abs(el), re = eye.x, side = el < 0.0 ? -1.0 : 1.0;
	float Lc = g_prof.z, L = g_prof.w, R2 = 2.0 * g_prof.y;
	vec2 band = vec2(GEO_PI, 0.0);
	if (Lc <= 0.0) return band;
	vec3 cn;
	float lc = geo_l_of(q.C, cn);
	float rl = 1.05 * q.reach + 0.01;
	float lim = geo_asin(min(g_prof2.z / re, 1.0));
	for (int w = 0; w < 2; w++) {
		bool outward = w == 1;
		if (outward && le >= Lc) break;
		float dl = outward ? side : -side;
		float y0 = max(le - Lc, 0.0), y1 = outward ? Lc - le : Lc + le;
		// the body's far end along this way, in metres of l from the eye: nothing of it past the
		// cylinder's start, none (on the near fillet its images close in at once)
		float yf = (lc - el) * dl + rl;
		if (yf <= y0) continue;
		float lo = 0.0, hi = lim;
		for (int i = 0; i < 24; i++) {
			float m = 0.5 * (lo + hi);
			vec2 sc = geo_sincos(m);
			float b = re * sc.x;
			float gap = re * (sc.y * sc.y / (1.0 + sc.x));
			float sigma = geo_sigma(eye.z - gap);
			float turn = 0.0;
			if (sigma < g_prof2.y) {
				float gc = -R2 * sigma;
				float near = le > Lc ? geo_between(b, sigma, Lc, gc, le, gap, false).x : 0.0;
				float cyl = geo_exit_cyl(b, sigma).x;
				turn = near + (min(yf, y1) - y0) * cyl;
				if (yf > y1) {
					float a = min(Lc + (yf - y1), L);
					turn += geo_between(b, sigma, Lc, gc, a, geo_dr(a) + gc, false).x;
				}
			}
			if (turn >= psi_min - TAIL_PI2) hi = m; else lo = m;
		}
		band = outward ? vec2(min(band.x, GEO_PI - lim), max(band.y, GEO_PI - lo)) : vec2(min(band.x, lo), max(band.y, lim));
	}
	return band;
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
