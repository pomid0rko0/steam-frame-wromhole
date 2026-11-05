// Bodies in the curved zone drawn round the eye's axis (body.gdshaderinc, ZONE): a mesh's vertex
// (a ball's: zone_ball_vertex; a cube's: zone_cube.gdshaderinc, after this) as a point of a body's
// section by a half-surface of the space through that axis, worked out once a frame per eye by
// zone_sections.gdshaderinc's compute shader; and the paths a body's vertices take to the eye, by a
// table. Plain GLSL after geo.gdshaderinc (ref/test_gpu.py takes it too).

// w(l), the embedding's fourth coordinate (WormholeSpace.w)
float zone_w(float l) {
	float al = abs(l);
	float sg = l < 0.0 ? -1.0 : 1.0;
	float Ka = g_prof.z - g_prof.y * geo_sin(g_prof2.w);
	if (al >= g_prof.w) return sg * (Ka + g_prof.y);
	if (al <= g_prof.z) return l;
	return sg * (Ka + g_prof.y * geo_sin(g_prof2.w + (al - g_prof.z) / g_prof.y));
}

// the space's point (l, alpha) of the half-surface toward t (R^4), and its rate along (dl, dalpha)
vec4 zone_point(float l, float al, vec3 en, vec3 t) {
	vec2 sc = geo_sincos(al);
	return vec4(geo_r(abs(l)) * (sc.y * en + sc.x * t), zone_w(l));
}

vec4 zone_rate(float l, float al, vec3 en, vec3 t, float dl, float dal) {
	vec2 sc = geo_sincos(al);
	vec2 dd = geo_drdw(l);
	vec3 n = sc.y * en + sc.x * t;
	vec3 dn = sc.y * t - sc.x * en;
	return vec4(dd.x * dl * n + geo_r(abs(l)) * dal * dn, dd.y * dl);
}

// The angle alpha of the half-surface toward t of the direction x (R^4's xyz) from en, in (-pi / 2,
// 3 pi / 2]: a body's section is within [0, pi] up to its curve's hair across the axis, where the
// angles of its corners must go on past 0 or pi, not wrap round.
float zone_alpha(vec3 x, vec3 t, vec3 en) {
	float a = geo_atan2(dot(x, t), dot(x, en));
	return a < -0.5 * GEO_PI ? a + 2.0 * GEO_PI : a;
}

// From the inner point (l0, al0) along the straight line of (l, r alpha) whose (dl, dalpha) per
// metre is (dl, dal): where it meets the ball's surface (zone_edge_ball) or the cube's
// (zone_edge_cube), (l, alpha); the inner point if it is not inside.
vec2 zone_edge_ball(float l0, float al0, float dl, float dal, vec3 en, vec3 t, vec4 C, float size) {
	vec4 X0 = zone_point(l0, al0, en, t);
	vec4 T0 = zone_rate(l0, al0, en, t, dl, dal);
	vec4 q = X0 - C;
	// the chord's square along the line: a quadratic to first order, then Newton on the exact one
	float c0 = dot(q, q) - size * size;
	if (c0 >= 0.0) return vec2(l0, al0);
	float bq = dot(q, T0), tt = max(dot(T0, T0), 1e-12);
	// Newton kept within what is known: inside at lo, out at hi (at first the ball's diameter on);
	// a step out of that the middle instead (a line out near the section's tip, where the
	// half-surface grazes the ball, leaves along it)
	float lo = 0.0, hi = 2.0 * size / sqrt(tt);
	float rho = clamp((-bq + sqrt(max(bq * bq - tt * c0, 0.0))) / tt, lo, hi);
	for (int i = 0; i < 3; i++) {
		vec4 X = zone_point(l0 + rho * dl, al0 + rho * dal, en, t);
		vec4 T = zone_rate(l0 + rho * dl, al0 + rho * dal, en, t, dl, dal);
		vec4 qq = X - C;
		float f = dot(qq, qq) - size * size, dv = 2.0 * dot(qq, T);
		if (f < 0.0) lo = rho; else hi = rho;
		float nr = dv > 1e-9 ? rho - f / dv : hi;
		rho = nr >= lo && nr <= hi ? nr : 0.5 * (lo + hi);
	}
	return vec2(l0 + rho * dl, al0 + rho * dal);
}

vec2 zone_edge_cube(float l0, float al0, float dl, float dal, vec3 en, vec3 t, vec4 C, vec4 E1, vec4 E2, vec4 E3, float size) {
	vec4 q = zone_point(l0, al0, en, t) - C;
	vec3 s0 = vec3(dot(q, E1), dot(q, E2), dot(q, E3));
	if (max(max(abs(s0.x), abs(s0.y)), abs(s0.z)) >= size) return vec2(l0, al0);
	// from the slabs to first order the nearest one's crossing; then Newton on the largest slab less
	// the half size (along a line from inside it crosses 0 once, where the line leaves), kept within
	// what is known: inside at lo, out at hi; a step out of that the middle, or further on while no
	// point out is known
	vec4 T0 = zone_rate(l0, al0, en, t, dl, dal);
	vec3 ds = vec3(dot(T0, E1), dot(T0, E2), dot(T0, E3));
	vec3 r1 = (size - sign(ds) * s0) / max(abs(ds), vec3(1e-9));
	float rho = min(min(r1.x, r1.y), r1.z);
	float lo = 0.0, hi = -1.0;
	for (int i = 0; i < 8; i++) {
		vec4 X = zone_point(l0 + rho * dl, al0 + rho * dal, en, t);
		vec4 T = zone_rate(l0 + rho * dl, al0 + rho * dal, en, t, dl, dal);
		vec4 qq = X - C;
		vec3 sv = vec3(dot(qq, E1), dot(qq, E2), dot(qq, E3));
		vec3 av = abs(sv);
		int k = av.x >= av.y && av.x >= av.z ? 0 : (av.y >= av.z ? 1 : 2);
		float g = av[k] - size;
		if (abs(g) < 1e-7) break;
		if (g < 0.0) lo = rho; else hi = rho;
		float dg = sign(sv[k]) * dot(T, k == 0 ? E1 : (k == 1 ? E2 : E3));
		float nr = dg > 1e-9 ? rho - g / dg : -1.0;
		if (!(nr > lo && (hi < 0.0 || nr < hi))) nr = hi >= 0.0 ? 0.5 * (lo + hi) : 2.0 * lo + 0.1 * size;
		rho = nr;
	}
	return vec2(l0 + rho * dl, al0 + rho * dal);
}

// The point of the half-surface toward azimuth th (t: its direction) nearest a ball's centre C, as
// (l, alpha): C's place in the half-surface's hyperplane, its direction there and the l of the
// profile's point nearest it (the half-surface is round the w axis in that hyperplane).
vec2 zone_ball_inner(vec4 C, vec3 en, float th, vec3 a1, vec3 a2, out vec3 t) {
	vec2 sc = geo_sincos(th);
	t = sc.y * a1 + sc.x * a2;
	vec3 m = sc.y * a2 - sc.x * a1;
	vec3 cq = C.xyz - dot(C.xyz, m) * m;
	vec3 nn;
	return vec2(geo_l_of(vec4(cq, C.w), nn), geo_atan2(dot(cq, t), dot(cq, en)));
}

// How far either way of its centre's azimuth a ball's azimuths reach round the axis (d: the centre's
// distance from it): to where the half-surface's point nearest the centre (zone_ball_inner) is the
// radius away. At an azimuth delta off the centre's that is, with s = sin^2 delta, d^2 s from the
// hyperplane and the distance D of the centre's place in it, at sqrt(|C.xyz|^2 - d^2 s) from the w
// axis, from the profile: d^2 s + D^2 = radius^2, by false position in s (the 4D ball's asin(radius /
// d) reaches past it: the space cuts the ball narrower).
float zone_ball_reach(vec4 C, float d, float size) {
	float rc2 = dot(C.xyz, C.xyz), d2 = d * d;
	float lo = 0.0, hi = min(size * size / d2, 1.0), flo = -size * size, fhi = 0.0;
	int last = 0;
	vec3 nn;
	for (int i = 0; i < 6; i++) {
		// first the 4D ball's reach, then false position, the end kept twice in a row halved
		// (Illinois); the reach the last s inside
		float sv = i == 0 ? hi : (lo * fhi - hi * flo) / (fhi - flo);
		float rho = sqrt(max(rc2 - d2 * sv, 0.0));
		float l = geo_l_of(vec4(rho, 0.0, 0.0, C.w), nn);
		float dr = rho - geo_r(abs(l)), dw = C.w - zone_w(l);
		float f = d2 * sv + dr * dr + dw * dw - size * size;
		if (i == 0) {
			if (f <= 0.0) return hi < 1.0 ? geo_asin(sqrt(hi)) : GEO_PI;
			fhi = f;
		} else if (f > 0.0) {
			hi = sv; fhi = f;
			if (last > 0) flo *= 0.5;
			last = 1;
		} else {
			lo = sv; flo = f;
			if (last < 0) fhi *= 0.5;
			last = -1;
		}
	}
	return geo_asin(sqrt(lo));
}

// The axis's point deepest in a cube (the least of its largest slab): the axis is (l, al0), and
// along it each slab to first order a line; the least of the three lines' largest absolute value, at
// one's zero or where two cross, and again from there. (l, the largest slab less the half size
// there: below 0 inside.) The axis can go through a cube by a corner while its point nearest the
// centre is out.
vec2 zone_cube_axis(float l0, float al0, vec3 en, vec3 a1, vec4 C, vec4 E1, vec4 E2, vec4 E3, float size) {
	float l = l0, out_ = 0.0;
	for (int it = 0; it < 3; it++) {
		vec4 q = zone_point(l, al0, en, a1) - C;
		vec4 T = zone_rate(l, al0, en, a1, 1.0, 0.0);
		vec3 v = vec3(dot(q, E1), dot(q, E2), dot(q, E3));
		vec3 g = vec3(dot(T, E1), dot(T, E2), dot(T, E3));
		out_ = max(max(abs(v.x), abs(v.y)), abs(v.z)) - size;
		if (it == 2) break;
		float bx = 0.0, bm = out_ + size;
		for (int c = 0; c < 9; c++) {
			float x;
			if (c < 3) {
				x = abs(g[c]) > 1e-9 ? -v[c] / g[c] : 0.0;
			} else {
				int pr = (c - 3) / 2;                                // pairs (0, 1), (0, 2), (1, 2), each sign
				int i = pr == 2 ? 1 : 0, j = pr == 0 ? 1 : 2;
				float sg = ((c - 3) & 1) == 0 ? 1.0 : -1.0;
				float den = g[i] - sg * g[j];
				x = abs(den) > 1e-9 ? (sg * v[j] - v[i]) / den : 0.0;
			}
			x = clamp(x, -4.0 * size, 4.0 * size);
			vec3 w = abs(v + g * x);
			float mm = max(max(w.x, w.y), w.z);
			if (mm < bm) { bm = mm; bx = x; }
		}
		l += bx;
	}
	return vec2(l, out_);
}

// A ball's vertex in the curved zone (body.gdshaderinc, ZONE; a cube's: zone_cube.gdshaderinc) for
// the eye whose direction from the centre is en: column u of the mesh (strips across the azimuths)
// and row v (round the section): (l, alpha) of its point on the ball (centre C, radius size), and t,
// its half-surface's direction (across en). Round the axis where the axis's point nearest the centre
// is inside the ball (every azimuth, each section from where the axis enters it round to where it
// leaves, into the half-surface), else off it (the azimuths its reach spans, each section round the
// half-surface's point nearest the centre).
vec2 zone_ball_vertex(vec2 uv, vec3 en, vec4 C, float size, out vec3 t) {
	// the axis's frame: a1, a2 across it; the centre's offset across it, and the axis's point nearest
	// the centre, inside the ball or not
	vec3 a1 = normalize(cross(en, abs(en.z) < 0.9 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0)));
	vec3 a2 = cross(en, a1);
	vec2 cp = vec2(dot(C.xyz, a1), dot(C.xyz, a2));
	float d = length(cp);
	float ce = dot(C.xyz, en);
	vec3 nn;
	vec2 ax = vec2(geo_l_of(vec4(ce * en, C.w), nn), ce >= 0.0 ? 0.0 : GEO_PI);
	vec4 q = zone_point(ax.x, ax.y, en, a1) - C;
	bool round_axis = d < size && dot(q, q) < size * size;
	float dsg = round_axis && ce < 0.0 ? -1.0 : 1.0;
	float th = 2.0 * GEO_PI * uv.x;
	if (!round_axis) th = geo_atan2(cp.y, cp.x) + (2.0 * uv.x - 1.0) * zone_ball_reach(C, d, size);
	// the inner point: the centre's place in the half-surface's hyperplane, its direction there and
	// the l of the profile's point nearest it
	vec2 i0 = zone_ball_inner(C, en, th, a1, a2, t);
	if (round_axis) i0 = ax;
	vec2 sp = geo_sincos((round_axis ? GEO_PI : 2.0 * GEO_PI) * uv.y);
	return zone_edge_ball(i0.x, i0.y, sp.y, dsg * sp.x / geo_r(abs(i0.x)), en, t, C, size);
}

// ---------------------------------------------------------------- the paths by a table
// A vertex of a body's image j takes its geodesic from a table worked out once a frame for each eye
// and body (zone_sections.gdshaderinc, PATHS), not by geo_see_to's search. The space is spherically
// symmetric, so the way from the eye to a point hangs only on the point's l and on the turn psi
// (alpha + 2 pi k or 2 pi (k + 1) - alpha) its image takes in its plane through the centre: in that
// plane, (X, Y) = len (cos a, sin a), a the launch angle from the eye's outward radial toward the
// turn. That map is smooth everywhere, the eye too (the inverse of the exponential map at the eye:
// on the plane's surface, whose curvature is nowhere positive, one geodesic a class), and close to
// linear once the rays wind round the photon sphere; but where the profile joins its parts (the
// cylinder's ends, the zone's edge: a step in a derivative of r(l)) only once or twice differentiable
// across the join J, and beside it from an eye a few centimetres off it it goes as |l - J|^(3/2)
// (rays that graze the join). A body's table: ZONE_PL nodes along l over its reach and a margin each
// way, ZONE_PQ along q = asinh psi, from one node below psi = 0 (the turn the other way: (X, -Y)) to
// past the images' last turn, evenly in each; where the body's l reaches a join, evenly in u =
// sign(l - J) sqrt(|l - J|) instead, a node on J: in u that power is a cubic, and the nodes crowd
// to the join. A node holds (X, Y, len dl/ds at the point as the eye's side counts l, fell:
// geo_see_to's): dl/ds itself is the ray's direction near the eye, a jump there that a cubic can't
// follow, len dl/ds is smooth (close to X there). A vertex takes only its sign: its size is the
// ray's own, by b = r_eye sin a, which the ray keeps. A vertex takes the cubic through 4 x 4 nodes about it, both ways (Lagrange's: its
// error goes as the 4th power of the steps), along l from its side of the join only. The steps set
// against the error: ref/test_gpu.py. Where geo_see_to takes a closed form (the segment, the
// cylinder unrolled), the vertex takes that.
const int ZONE_PL = 16;
const int ZONE_PQ = 100;

// A body's table's frame (C its centre, reach the chord its points are within, psi_max the turn of
// its images' last): (a, the step along l or u, the step along q, the node on the join or -1). Node
// (i, k) is at q = (k - 1) .z, and at l = a + (i - 1) .y (no join: a the l of node 1), or at u = (i -
// on) .y (a the join, on its node). Nodes 1 to ZONE_PL - 2 hold the body's l, one step to spare (u's
// nodes move by less than one to put one on the join), and 1 to ZONE_PQ - 2 the turns from 0 to
// psi_max.
vec4 zone_path_frame(vec4 C, float reach, float psi_max) {
	vec3 n;
	float lc = geo_l_of(C, n);
	float rl = 1.1 * reach + 0.01;     // a point's l within its geodesic distance of C's, a hair more than the chord
	float h = 2.0 * rl / float(ZONE_PL - 4);
	// the profile's join nearest the body's centre, if within a step of the body's l
	vec4 joins = vec4(-g_prof.w, -g_prof.z, g_prof.z, g_prof.w);
	float jl = 0.0;
	bool join = false;
	for (int k = 0; k < 4; k++) {
		if (abs(joins[k] - lc) <= rl + h && (!join || abs(joins[k] - lc) < abs(jl - lc))) {
			join = true;
			jl = joins[k];
		}
	}
	float hq = log(psi_max + sqrt(psi_max * psi_max + 1.0)) / float(ZONE_PQ - 3);
	if (!join) return vec4(lc - rl, h, hq, -1.0);
	float ua = sqrt(max(jl - (lc - rl), 0.0)), ub = sqrt(max(lc + rl - jl, 0.0));
	float hu = (ua + ub) / float(ZONE_PL - 4);
	return vec4(jl, hu, hq, ceil(ua / hu) + 1.0);
}

// node (i, k)'s place in the table of frame f (zone_path_frame): (l, psi)
vec2 zone_path_at(vec4 f, int i, int k) {
	float q = float(k - 1) * f.z;
	float u = float(i) - f.w;
	float l = f.w < 0.0 ? f.x + float(i - 1) * f.y : f.x + sign(u) * u * u * f.y * f.y;
	return vec2(l, 0.5 * (exp(q) - exp(-q)));
}

// The node at l and turn psi (negative: the other way) for the eye at (el, en): (X, Y, len dl/ds at
// the point on the eye's side, fell) as the table's top has them, by geo_see_to; at psi = 0 the
// radial line, through the throat too: l along it goes as the length.
vec4 zone_path_node(float el, vec3 en, float l, float psi) {
	float side = el < 0.0 ? -1.0 : 1.0;
	float dl = side * l - abs(el);
	if (psi == 0.0) return vec4(dl, 0.0, dl, 0.0);
	vec3 t = normalize(cross(en, abs(en.z) < 0.9 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0)));
	float ap = abs(psi);
	vec2 sc = geo_sincos(ap);
	vec3 pn = sc.y * en + sc.x * t;
	float len, fell;
	vec4 arr;
	vec4 d = geo_see_to(el, en, l, pn, t, ap, ap <= GEO_PI, len, arr, fell);
	vec2 dd = geo_drdw(l);
	// dl/ds at the point: arrive's part along d/dl there, (dd.x pn, dd.y) (the rest is across it)
	float dls = dot(arr, vec4(dd.x * pn, dd.y));
	return vec4(len * side * d.x, (psi < 0.0 ? -len : len) * dot(d.yzw, t), len * side * dls, fell);
}

// Lagrange's weights of the nodes at -1, 0, 1, 2 at x (between 0 and 1 in the middle of them, 1 and
// 2 or -1 and 0 beside a join)
vec4 zone_lagrange(float x) {
	float a = x + 1.0, b = x - 1.0, c = x - 2.0;
	return vec4(-x * b * c, 3.0 * a * b * c, -3.0 * a * x * c, a * x * b) / 6.0;
}

// Image j of the point (pl, pn), alpha off the eye's axis toward t, as geo_see_image gives it (the
// launch direction, len, arrive; fell: the most of its nodes'), by geo_see_to's closed forms or else
// the body's table: tab's rows from row0 (its slot's), layer (the eye's), and at column ZONE_PQ of row0 its frame
// (zone_path_frame).
vec4 zone_path_see(sampler2DArray tab, int row0, int layer, float el, vec3 en, float pl, vec3 pn, vec3 t, float alpha, int j, out float len, out vec4 arrive, out float fell) {
	float k = float(j / 2);
	bool far = (j & 1) == 1;
	float target = far ? 2.0 * GEO_PI * (k + 1.0) - alpha : alpha + 2.0 * GEO_PI * k;
	vec3 tt = far ? -t : t;
	vec4 dir = vec4(0.0);
	len = 0.0;
	arrive = vec4(0.0);
	fell = 0.0;
	// what geo_see_to takes at once: the segment, the line on the cylinder unrolled
	float side = el < 0.0 ? -1.0 : 1.0;
	float le = abs(el), lp = side * pl;
	float re = geo_r(le);
	if (j == 0 && le >= g_prof.w && lp >= g_prof.w && geo_see_segment(side, re, en, geo_r(lp), pn, dir, len, arrive)) return dir;
	vec2 scd = geo_sincos(target);
	if (le <= g_prof.z && abs(lp) <= g_prof.z) return geo_see_unrolled(side, le, lp, re, en, tt, target, scd, len, arrive);
	vec4 f = texelFetch(tab, ivec3(ZONE_PQ, row0, layer), 0);
	// the point's place along l in steps from node 1, and the nodes from its side of the join only
	// (the join's node on: fl = on - 1)
	float d = pl - f.x;
	int on = int(f.w);
	float fl = on < 0 ? d / f.y : float(on - 1) + sign(d) * sqrt(abs(d)) / f.y;
	int i = int(floor(fl));
	if (on >= 0) i = fl < float(on - 1) ? min(i, on - 3) : max(i, on);
	i = clamp(i, 0, ZONE_PL - 4);
	float fq = log(target + sqrt(target * target + 1.0)) / f.z;
	int c = clamp(int(floor(fq)), 0, ZONE_PQ - 4);
	vec4 wl = zone_lagrange(fl - float(i)), wq = zone_lagrange(fq - float(c));
	vec3 s = vec3(0.0);
	for (int a = 0; a < 4; a++) {
		vec3 row = vec3(0.0);
		for (int b = 0; b < 4; b++) {
			vec4 v = texelFetch(tab, ivec3(c + b, row0 + i + a, layer), 0);
			row += wq[b] * v.xyz;
			fell = max(fell, v.w);
		}
		s += wl[a] * row;
	}
	len = length(s.xy);
	vec2 cs = s.xy / max(len, GEO_TINY20);
	// arriving (geo_see_to's arrive): toward growing angle b / r there, b = r_eye sin a; along d/dl
	// the rest, its sign the table's
	float bp = min(re * cs.y / geo_r(abs(pl)), 1.0);
	float dls = side * (s.z < 0.0 ? -1.0 : 1.0) * sqrt(max((1.0 - bp) * (1.0 + bp), 0.0));
	vec2 dd = geo_drdw(pl);
	arrive = vec4(dls * dd.x * pn + bp * (scd.y * tt - scd.x * en), dls * dd.y);
	return vec4(side * cs.x, cs.y * tt);
}
