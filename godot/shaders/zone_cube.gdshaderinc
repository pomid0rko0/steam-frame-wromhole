// A cube in the curved zone, its mesh round the eye's axis (body.gdshaderinc, ZONE, draws it; the
// nodes are worked out by zone_sections.gdshaderinc's CUBE_* passes, a frame and an eye at a time).
// Plain GLSL 450 after geo.gdshaderinc and zone.gdshaderinc, compute shaders only (ref/test_gpu.py
// takes it too). docs/geometry.md, «Как рисуется кадр», 6.
//
// The mesh: columns on half-surfaces of azimuths theta round the axis, a node's point on the cube's
// section by its column's half-surface (l, alpha); a triangle joins two columns and two rows. So that
// none lies across an edge or leaves a gap, a row stays on the same corner of the sections all through
// a span of azimuths, a corner being where a section meets an edge, and the sections between rows on
// the face two corners share. The cube in its box coordinates (x, the offsets from C along E1, E2, E3
// over the half size) is an exact cube [-1, 1]^3, and the half-surfaces round the axis there are a
// book of nearly flat sheets: a section is nearly a convex polygon, but not quite, and near the axis
// what is not quite matters.
//   An edge's azimuth along it (geo_onto of the box's edge): dtheta/du = g / rho^2, g = (P x P') . en,
// smooth even where the edge passes through the axis (rho 0). Where g is 0 the edge turns back round
// the axis (a fold: it passes the axis nearer than the space's curve bends it), and a half-surface cuts
// it twice there; so an edge is split at its folds into pieces along which the azimuth only grows or
// only falls (zc_edge_near, zc_pieces), each also at its point nearest the axis (h = 0: there it can
// go round by up to a half turn), so that the half-surface it is cut by is bracketed. The azimuths of
// the pieces' ends (the corners and the folds) are the knots: between two the same pieces are cut,
// a span; the columns stand on the knots (zc_column: two on each, one a span's, the strip between
// them has no width, as in the picture a half-surface is a line; zc_side tells them) and share out
// the rest by angle.
//   A section's corners (zc_sequence, at the span's middle): where the half-surface cuts each piece
// whose azimuths hold it (zc_cut: the root of P(u) . m on its bracket, no atan near the axis), and
// round the axis where it enters and leaves the cube. On each face, its corners lie along one curve,
// the face's plane in the half-surface: sorted along it, two neighbours are joined across the face if
// the curve between them is inside the cube's other bounds. Then from corner to corner, across each
// corner's edge onto its other face: the section's parts (a fold turned the right way makes a part of
// its own, Morse's saddle or a new extremum), each a list of corners with the face to the next. Round
// the axis the first part runs from the entry to the exit; else each closes on its first corner.
//   A column's nodes (zc_items, zc_node): its corners at its own azimuth (the span's list), each on a
// row (rows shared out by corners in the span, the same row all through it), the rows between two on
// their face (zc_between: across the chord in the face's own square, onto the half-surface). Between
// two parts, two rows that are no part of the surface (the node's kill flag: body.gdshaderinc drops
// them): the strip between a part's end and the next one's start there, the rows on either side at
// their part's own points.
//   A corner or an edge within ZC_PUSH of the eye's axis has no azimuth float32 can tell, and the
// edges through a point on the axis turn round it there at once: the mesh is then built round an axis
// turned off that point to ZC_PUSH (zc_axis; the mesh turned so about the centre, at most ZC_PUSH),
// where the steps above hold.

const float ZC_PUSH = 1e-4;          // m: no corner or edge nearer the mesh's axis
const float ZC_ON = 4e-6;            // m: a point this near a half-surface's hyperplane is on it (float32)
const int ZC_PIECES = 4;             // an edge's pieces at most
const int ZC_ITEMS = 16;             // a section's corners (and its parts' ends again) at most
const int ZC_PARTS = 3;              // a section's parts at most
const int ZC_SPANS = 32;             // spans at most (knots: 2 a piece at most, 96)
const int ZC_KNOTS = 2 * ZC_PIECES * 12;
const int ZC_IN = 48, ZC_OUT = 49;   // the items besides the cuts (piece 4 e + k): the axis's entry, exit

struct ZCube {
	vec4 C;
	vec4 E[3];
	vec4 N;
	float s;
	vec3 en;
	vec3 a1;
	vec3 a2;
};

// the axis the mesh is built round (zc_axis) and where it meets the cube: round it (rnd) its entry (the
// larger l, row 0) and exit along it, at alpha aax
struct ZAxis {
	vec3 en;
	bool rnd;
	float l_in;
	float l_out;
	float aax;
};

// each edge's pieces: n, and per piece three places along it (its ends and its bracket's middle) and
// the azimuth there, continuous along the piece
struct ZPieces {
	int n[12];
	vec3 u[12 * ZC_PIECES];
	vec3 t[12 * ZC_PIECES];
};

// a span's section: its parts, n[i] entries each (a closed part's last is its first again), each an
// item and the face to the next (-1 for none)
struct ZSeq {
	int k;
	int n[ZC_PARTS];
	int id[ZC_ITEMS];
	int face[ZC_ITEMS];
};

ZCube zc_cube(vec4 C, vec4 E1, vec4 E2, vec4 E3, vec4 N, float s, vec3 en) {
	ZCube q;
	q.C = C;
	q.E[0] = E1;
	q.E[1] = E2;
	q.E[2] = E3;
	q.N = N;
	q.s = s;
	q.en = en;
	q.a1 = normalize(cross(en, abs(en.z) < 0.9 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0)));
	q.a2 = cross(en, q.a1);
	return q;
}

float zc_wrap(float a) { return a - 2.0 * GEO_PI * floor(a / (2.0 * GEO_PI) + 0.5); }

// the cube's point at box coordinates x, on the space
vec4 zc_point(ZCube q, vec3 x) { return geo_onto(q.C + q.s * (x.x * q.E[0] + x.y * q.E[1] + x.z * q.E[2]), q.N); }

// edge e (along axis e / 4, at the other two's bounds by its two lowest bits, as zone_edge_cut had
// them) at u in [-1, 1]
vec3 zc_x(int e, float u) {
	int a = e / 4, b = (a + 1) % 3, g = (a + 2) % 3;
	vec3 x = vec3(0.0);
	x[a] = u;
	x[b] = (e & 1) == 0 ? -1.0 : 1.0;
	x[g] = (e & 2) == 0 ? -1.0 : 1.0;
	return x;
}

// edge e's two faces as a bit mask (face 2 axis + (1 if at +1))
int zc_edge_faces(int e) {
	int a = e / 4, b = (a + 1) % 3, g = (a + 2) % 3;
	return (1 << (2 * b + (e & 1))) | (1 << (2 * g + ((e >> 1) & 1)));
}

// corner v's (bit i: + along axis i) three faces as a mask, and its box coordinates
int zc_corner_faces(int v) { return (1 << (v & 1)) | (1 << (2 + ((v >> 1) & 1))) | (1 << (4 + ((v >> 2) & 1))); }
vec3 zc_corner_x(int v) { return vec3((v & 1) == 0 ? -1.0 : 1.0, (v & 2) == 0 ? -1.0 : 1.0, (v & 4) == 0 ? -1.0 : 1.0); }

// the rate of P (the cube's point) along the box direction d, on the space
vec4 zc_rate(ZCube q, vec4 P, vec3 d) {
	vec4 n = geo_normal(P);
	vec4 Q = q.s * (d.x * q.E[0] + d.y * q.E[1] + d.z * q.E[2]);
	return Q - (dot(n, Q) / dot(n, q.N)) * q.N;
}

// along edge e at u: (g, h), g = (P x P') . en (the azimuth's rate times rho^2), h = P_perp . P'_perp
// (half rho^2's rate), P_perp across the axis; and P
vec2 zc_gh(ZCube q, int e, float u, out vec4 P) {
	P = zc_point(q, zc_x(e, u));
	vec3 d = vec3(0.0);
	d[e / 4] = 1.0;
	vec4 Pu = zc_rate(q, P, d);
	vec3 pp = P.xyz - dot(P.xyz, q.en) * q.en, qq = Pu.xyz - dot(Pu.xyz, q.en) * q.en;
	return vec2(dot(cross(P.xyz, Pu.xyz), q.en), dot(pp, qq));
}

float zc_rho(ZCube q, vec4 P) { return length(P.xyz - dot(P.xyz, q.en) * q.en); }

// g (which 0) or h (1) along edge e: its zero between lo and hi (its values flo, fhi of opposite
// signs), by false position halving the end kept twice (Illinois)
float zc_root(ZCube q, int e, int which, float lo, float hi, float flo, float fhi) {
	int side = 0;
	float c = 0.5 * (lo + hi);
	vec4 P;
	for (int i = 0; i < 12; i++) {
		c = (lo * fhi - hi * flo) / (fhi - flo);
		if (!(c > lo && c < hi)) c = 0.5 * (lo + hi);
		// no component by a number not known while compiling: the headset's compiler (ir3) has none
		vec2 gh = zc_gh(q, e, c, P);
		float fc = which == 0 ? gh.x : gh.y;
		if (fc * fhi > 0.0) {
			hi = c;
			fhi = fc;
			if (side == -1) flo *= 0.5;
			side = -1;
		} else {
			lo = c;
			flo = fc;
			if (side == 1) fhi *= 0.5;
			side = 1;
		}
		if (hi - lo < 1e-6) break;
	}
	return c;
}

// Edge e near the axis: (its point nearest the axis u*, or -9 if at an end; rho there; its folds' u,
// -9 for none), and in ends (rho at u = -1, 1). Each from where g, h change sign at 9 points along it.
vec4 zc_edge_near(ZCube q, int e, out vec2 ends) {
	vec2 gh[9];
	float rh[9];
	for (int i = 0; i < 9; i++) {
		vec4 P;
		gh[i] = zc_gh(q, e, -1.0 + 0.25 * float(i), P);
		rh[i] = zc_rho(q, P);
	}
	ends = vec2(rh[0], rh[8]);
	vec4 out_ = vec4(-9.0, min(rh[0], rh[8]), -9.0, -9.0);
	int nf = 0;
	for (int i = 0; i < 8; i++) {
		float lo = -1.0 + 0.25 * float(i), hi = lo + 0.25;
		if (gh[i].x * gh[i + 1].x < 0.0 && nf < 2) {
			out_[2 + nf] = zc_root(q, e, 0, lo, hi, gh[i].x, gh[i + 1].x);
			nf++;
		}
		if (gh[i].y < 0.0 && gh[i + 1].y >= 0.0 && out_.x < -2.0) {
			float u = gh[i + 1].y == 0.0 ? hi : zc_root(q, e, 1, lo, hi, gh[i].y, gh[i + 1].y);
			if (u < 1.0) {
				out_.x = u;
				out_.y = zc_rho(q, zc_point(q, zc_x(e, u)));
			}
		}
	}
	return out_;
}

// The axis the cube's mesh is built round (near, ends: zc_edge_near's of each edge round the eye's axis
// q.en): the eye's, but where a corner or an edge's point nearest it is within ZC_PUSH of it, turned
// off that point to ZC_PUSH (away from it, or on it away from the cube's centre; the caller's ZCube
// from en, every pass the same); and where it meets the cube (zone_cube_axis: round it if its deepest
// point is inside; its entry and exit from there along it, zone_edge_cube).
ZAxis zc_axis(ZCube q, vec4 near[12], vec2 ends[12]) {
	float best = 1e9;
	vec3 x = vec3(0.0);
	for (int e = 0; e < 12; e++) {
		for (int k = 0; k < 2; k++) {
			if (ends[e][k] < best) {
				best = ends[e][k];
				x = zc_x(e, k == 0 ? -1.0 : 1.0);
			}
		}
		if (near[e].x > -2.0 && near[e].y < best) {
			best = near[e].y;
			x = zc_x(e, near[e].x);
		}
	}
	ZAxis ax;
	ax.en = q.en;
	if (best < ZC_PUSH) {
		vec3 P = zc_point(q, x).xyz;
		float pe = dot(P, q.en);
		vec3 v = P - pe * q.en, c = q.C.xyz - dot(q.C.xyz, q.en) * q.en;
		float lv = length(v);
		vec3 dir = lv > 0.1 * ZC_PUSH ? v / lv : (length(c) > 1e-9 ? normalize(c) : q.a1);
		ax.en = normalize(pe * q.en - (ZC_PUSH - lv) * dir) * (pe >= 0.0 ? 1.0 : -1.0);
	}
	ZCube r = zc_cube(q.C, q.E[0], q.E[1], q.E[2], q.N, q.s, ax.en);
	vec3 nn;
	float ce = dot(r.C.xyz, r.en);
	ax.aax = ce >= 0.0 ? 0.0 : GEO_PI;
	vec2 cp = vec2(dot(r.C.xyz, r.a1), dot(r.C.xyz, r.a2));
	vec2 deep = zone_cube_axis(geo_l_of(vec4(ce * r.en, r.C.w), nn), ax.aax, r.en, r.a1, r.C, r.E[0], r.E[1], r.E[2], r.s);
	ax.rnd = length(cp) < 1.8 * r.s && deep.y < 0.0;
	ax.l_in = deep.x;
	ax.l_out = deep.x;
	if (ax.rnd) {
		ax.l_in = zone_edge_cube(deep.x, ax.aax, 1.0, 0.0, r.en, r.a1, r.C, r.E[0], r.E[1], r.E[2], r.s).x;
		ax.l_out = zone_edge_cube(deep.x, ax.aax, -1.0, 0.0, r.en, r.a1, r.C, r.E[0], r.E[1], r.E[2], r.s).x;
	}
	return ax;
}

// Edge e's pieces (zc_edge_near's near for it, round q's axis): split at its folds; per piece its
// ends and its middle (its point nearest the axis if in it), and the azimuths there, each the point's
// own and a whole number of turns (a corner's the same to the bit from each of its edges: one knot)
int zc_pieces(ZCube q, int e, vec4 near, out vec3 pu[ZC_PIECES], out vec3 pt[ZC_PIECES]) {
	float bp[4];
	int nb = 0;
	bp[nb++] = -1.0;
	for (int f = 0; f < 2; f++) {
		if (near[2 + f] > -1.0 && near[2 + f] < 1.0) bp[nb++] = near[2 + f];
	}
	if (nb == 3 && bp[2] < bp[1]) {
		float v = bp[1];
		bp[1] = bp[2];
		bp[2] = v;
	}
	bp[nb++] = 1.0;
	int n = 0;
	for (int i = 0; i < 3; i++) {
		if (i + 1 >= nb) break;
		if (bp[i + 1] - bp[i] < 1e-7) continue;
		float u0 = bp[i], u2 = bp[i + 1];
		float u1 = near.x > u0 && near.x < u2 ? near.x : 0.5 * (u0 + u2);
		vec4 P0 = zc_point(q, zc_x(e, u0)), P1 = zc_point(q, zc_x(e, u1)), P2 = zc_point(q, zc_x(e, u2));
		float t0 = geo_atan2(dot(P0.xyz, q.a2), dot(P0.xyz, q.a1));
		float a1 = geo_atan2(dot(P1.xyz, q.a2), dot(P1.xyz, q.a1)), a2 = geo_atan2(dot(P2.xyz, q.a2), dot(P2.xyz, q.a1));
		float t1 = a1 + 2.0 * GEO_PI * floor((t0 - a1) / (2.0 * GEO_PI) + 0.5);
		float t2 = a2 + 2.0 * GEO_PI * floor((t1 - a2) / (2.0 * GEO_PI) + 0.5);
		pu[n] = vec3(u0, u1, u2);
		pt[n] = vec3(t0, t1, t2);
		n++;
	}
	return n;
}

// whether a piece's azimuths (ts: monotone) hold th (to a whole turn)
bool zc_has(vec3 ts, float th) {
	float lo = min(ts.x, ts.z), hi = max(ts.x, ts.z);
	th += 2.0 * GEO_PI * floor((0.5 * (lo + hi) - th) / (2.0 * GEO_PI) + 0.5);
	return th >= lo && th <= hi;
}

// Where the half-surface at azimuth th (m: its hyperplane's normal) cuts the piece (us, ts) of edge e:
// on the half of the piece its azimuth is in, the root of P(u) . m (nearly linear: no atan near the
// axis), by false position (Illinois) in that bracket; the nearer end if it holds none (to rounding).
float zc_cut(ZCube q, int e, vec3 us, vec3 ts, float th, vec3 m) {
	float lt = min(ts.x, ts.z), ht = max(ts.x, ts.z);
	th += 2.0 * GEO_PI * floor((0.5 * (lt + ht) - th) / (2.0 * GEO_PI) + 0.5);
	// past the piece's ends (a knot's azimuth, to rounding): that end
	if (th <= lt || th >= ht) return (th <= lt) == (ts.x <= ts.z) ? us.x : us.z;
	bool first = (th - ts.x) * (th - ts.y) <= 0.0;
	float lo = first ? us.x : us.y, hi = first ? us.y : us.z;
	// P . m is the point's distance from the half-surface's hyperplane: within ZC_ON of it, on it (its
	// sign there is float32's noise, which would lead false position astray)
	float flo = dot(zc_point(q, zc_x(e, lo)).xyz, m), fhi = dot(zc_point(q, zc_x(e, hi)).xyz, m);
	if (abs(flo) <= ZC_ON || abs(fhi) <= ZC_ON || flo * fhi > 0.0) return abs(flo) <= abs(fhi) ? lo : hi;
	int side = 0;
	float c = 0.5 * (lo + hi);
	for (int i = 0; i < 10; i++) {
		c = (lo * fhi - hi * flo) / (fhi - flo);
		if (!(c > lo && c < hi)) c = 0.5 * (lo + hi);
		float fc = dot(zc_point(q, zc_x(e, c)).xyz, m);
		if (abs(fc) <= ZC_ON) break;
		if (fc * fhi > 0.0) {
			hi = c;
			fhi = fc;
			if (side == -1) flo *= 0.5;
			side = -1;
		} else {
			lo = c;
			flo = fc;
			if (side == 1) fhi *= 0.5;
			side = 1;
		}
		if (hi - lo < 2e-7) break;
	}
	return c;
}

// the half-surface toward azimuth th: t, and its hyperplane's normal m
vec3 zc_t(ZCube q, float th, out vec3 m) {
	vec2 sc = geo_sincos(th);
	m = sc.y * q.a2 - sc.x * q.a1;
	return sc.y * q.a1 + sc.x * q.a2;
}

// (l, alpha) of the space's point P on the half-surface toward t
vec2 zc_la(ZCube q, vec4 P, vec3 t) {
	vec3 nn;
	return vec2(geo_l_of(P, nn), zone_alpha(P.xyz, t, q.en));
}

// the axis's entry (it ZC_IN) or exit (ZC_OUT) round it, as (l, alpha) on the half-surface toward t,
// and its face (the one of its largest slab: ZC_PUSH from any other) as a mask in faces
vec2 zc_axis_item(ZCube q, ZAxis ax, int it, vec3 t, out int faces) {
	vec2 p = vec2(it == ZC_IN ? ax.l_in : ax.l_out, ax.aax);
	vec4 X = zone_point(p.x, p.y, q.en, t) - q.C;
	vec3 sv = vec3(dot(X, q.E[0]), dot(X, q.E[1]), dot(X, q.E[2]));
	vec3 av = abs(sv);
	int a = av.x >= av.y && av.x >= av.z ? 0 : (av.y >= av.z ? 1 : 2);
	faces = 1 << (2 * a + (sv[a] > 0.0 ? 1 : 0));
	return p;
}

// The section's item it at azimuth th (t, m): a piece's cut (it = 4 e + k) or a point of the axis
vec2 zc_item(ZCube q, ZPieces pcs, ZAxis ax, int it, float th, vec3 t, vec3 m) {
	if (it >= ZC_IN) {
		int f;
		return zc_axis_item(q, ax, it, t, f);
	}
	int e = it / ZC_PIECES, k = it % ZC_PIECES;
	float u = zc_cut(q, e, pcs.u[it], pcs.t[it], th, m);
	return zc_la(q, zc_point(q, zc_x(e, u)), t);
}

// The point a share f of the way from pa to pb ((l, alpha) on the half-surface toward t, its
// hyperplane's normal m) on the cube's face (-1: none, the chord's in (l, alpha)): on the face in its
// own coordinates, where it is an exact square and the chord between two of its points on it, from the
// chord's point across the chord, on the face, to where it is on the half-surface (the root of P . m,
// as zc_cut's; the end nearer it where the face has none: a face next to in the half-surface there).
vec2 zc_between(ZCube q, vec2 pa, vec2 pb, float f, int face, vec3 t, vec3 m) {
	if (f <= 0.0) return pa;
	if (f >= 1.0) return pb;
	if (face < 0) return mix(pa, pb, f);
	int a = face / 2;
	float sg = (face & 1) == 0 ? -1.0 : 1.0;
	vec4 XA = zone_point(pa.x, pa.y, q.en, t) - q.C, XB = zone_point(pb.x, pb.y, q.en, t) - q.C;
	vec3 xa = vec3(dot(XA, q.E[0]), dot(XA, q.E[1]), dot(XA, q.E[2])) / q.s;
	vec3 xb = vec3(dot(XB, q.E[0]), dot(XB, q.E[1]), dot(XB, q.E[2])) / q.s;
	vec3 x0 = mix(xa, xb, f);
	x0[a] = sg;
	vec3 ch = xb - xa;
	ch[a] = 0.0;
	vec3 na = vec3(0.0);
	na[a] = 1.0;
	vec3 d = cross(na, ch);
	float dl = length(d);
	// a chord this short is on the face and on the half-surface to its length squared times the curve
	if (!(dl * q.s > 1e-4)) return zc_la(q, zc_point(q, x0), t);
	d /= dl;
	// across it, within the square
	float lo = -1e9, hi = 1e9;
	for (int k = 0; k < 3; k++) {
		if (k == a || abs(d[k]) < 1e-9) continue;
		float r1 = (-1.0 - x0[k]) / d[k], r2 = (1.0 - x0[k]) / d[k];
		lo = max(lo, min(r1, r2));
		hi = min(hi, max(r1, r2));
	}
	vec4 P0 = zc_point(q, x0);
	float g0 = dot(P0.xyz, m);
	if (abs(g0) <= ZC_ON || !(hi > lo)) return zc_la(q, P0, t);
	float glo = dot(zc_point(q, x0 + lo * d).xyz, m), ghi = dot(zc_point(q, x0 + hi * d).xyz, m);
	// the bracket the root is in: [lo, 0] or [0, hi]; none: the nearest of the three
	float a0, a1, f0, f1;
	if (g0 * glo <= 0.0) {
		a0 = lo; a1 = 0.0; f0 = glo; f1 = g0;
	} else if (g0 * ghi <= 0.0) {
		a0 = 0.0; a1 = hi; f0 = g0; f1 = ghi;
	} else {
		float lam = abs(glo) < abs(g0) ? (abs(glo) < abs(ghi) ? lo : hi) : (abs(ghi) < abs(g0) ? hi : 0.0);
		return zc_la(q, zc_point(q, x0 + lam * d), t);
	}
	int side = 0;
	float c = 0.5 * (a0 + a1);
	for (int i = 0; i < 10; i++) {
		c = (a0 * f1 - a1 * f0) / (f1 - f0);
		if (!(c > a0 && c < a1)) c = 0.5 * (a0 + a1);
		float fc = dot(zc_point(q, x0 + c * d).xyz, m);
		if (abs(fc) <= ZC_ON) break;
		if (fc * f1 > 0.0) {
			a1 = c;
			f1 = fc;
			if (side == -1) f0 *= 0.5;
			side = -1;
		} else {
			a0 = c;
			f0 = fc;
			if (side == 1) f1 *= 0.5;
			side = 1;
		}
		if (a1 - a0 < 1e-6) break;
	}
	return zc_la(q, zc_point(q, x0 + c * d), t);
}

// How far the middle of the face's curve in the half-surface toward t between pa and pb is within
// the cube's other bounds (below 0 outside): its point on the face's plane by Newton from the chord's
// middle along the plane's gradient in (l, r alpha), unbounded.
float zc_margin(ZCube q, vec2 pa, vec2 pb, int face, vec3 t) {
	vec2 p = 0.5 * (pa + pb);
	vec4 Ef = q.E[face / 2];
	float goal = (face & 1) == 0 ? -q.s : q.s;
	float rc = geo_r(abs(p.x));
	// no break out of the steps, nor out of the walk back in zc_sequence: with them the headset's
	// compiler (ir3) crashes on CUBE_SPANS; a step stands still instead
	for (int i = 0; i < 4; i++) {
		float g = dot(zone_point(p.x, p.y, q.en, t) - q.C, Ef) - goal;
		vec2 gr = vec2(dot(zone_rate(p.x, p.y, q.en, t, 1.0, 0.0), Ef), dot(zone_rate(p.x, p.y, q.en, t, 0.0, 1.0 / rc), Ef));
		float gg = dot(gr, gr);
		vec2 step = abs(g) > ZC_ON && gg > 1e-18 ? (g / gg) * gr : vec2(0.0);
		p -= vec2(step.x, step.y / rc);
	}
	vec4 X = zone_point(p.x, p.y, q.en, t) - q.C;
	vec3 o = abs(vec3(dot(X, q.E[0]), dot(X, q.E[1]), dot(X, q.E[2]))) - q.s;
	o[face / 2] = -q.s;
	return -max(max(o.x, o.y), o.z);
}

// The section at azimuth th (a span's middle) as its parts (ZSeq): its items (the cuts of the pieces
// whose azimuths hold th, the axis's points on the cube), on each face sorted along its plane's curve
// in the half-surface and joined in turn (zc_margin); then the walk from item to
// item, across each item's edge onto its other face: round the axis first from the entry (to the
// exit), then from the lowest cut left, round to it again (or, where it stops, the other way too).
ZSeq zc_sequence(ZCube q, ZPieces pcs, ZAxis ax, float th) {
	vec3 m;
	vec3 t = zc_t(q, th, m);
	int ids[ZC_ITEMS];
	int fm[ZC_ITEMS];       // faces mask
	vec2 pos[ZC_ITEMS];
	int ni = 0;
	for (int e = 0; e < 12; e++) {
		for (int k = 0; k < ZC_PIECES; k++) {
			if (k >= pcs.n[e] || ni >= ZC_ITEMS - 2) break;
			int it = e * ZC_PIECES + k;
			if (!zc_has(pcs.t[it], th)) continue;
			ids[ni] = it;
			fm[ni] = zc_edge_faces(e);
			pos[ni] = zc_item(q, pcs, ax, it, th, t, m);
			ni++;
		}
	}
	int first = ni;
	if (ax.rnd) {
		for (int i = 0; i < 2; i++) {
			ids[ni] = ZC_IN + i;
			pos[ni] = zc_axis_item(q, ax, ZC_IN + i, t, fm[ni]);
			ni++;
		}
	}
	// on each face its items, sorted along its plane's curve in the half-surface (across its plane's
	// gradient in (l, r alpha))
	int onf[6 * ZC_ITEMS];
	int nof[6];
	for (int f = 0; f < 6; f++) {
		float key[ZC_ITEMS];
		int no = 0;
		vec2 ref = vec2(0.0);
		for (int i = 0; i < ZC_ITEMS; i++) {
			if (i >= ni) break;
			if ((fm[i] & (1 << f)) != 0) {
				onf[f * ZC_ITEMS + no] = i;
				ref += pos[i];
				no++;
			}
		}
		nof[f] = no;
		if (no < 2) continue;
		ref /= float(no);
		float rc = geo_r(abs(ref.x));
		vec4 Ef = q.E[f / 2];
		float gl = dot(zone_rate(ref.x, ref.y, q.en, t, 1.0, 0.0), Ef);
		float ga = dot(zone_rate(ref.x, ref.y, q.en, t, 0.0, 1.0 / rc), Ef);
		for (int j = 0; j < ZC_ITEMS; j++) {
			if (j >= no) break;
			vec2 p = pos[onf[f * ZC_ITEMS + j]];
			key[j] = -ga * p.x + gl * rc * p.y;
		}
		for (int j = 1; j < ZC_ITEMS; j++) {
			if (j >= no) break;
			int oi = onf[f * ZC_ITEMS + j];
			float kv = key[j];
			int h = j - 1;
			while (h >= 0 && key[h] > kv) {
				onf[f * ZC_ITEMS + h + 1] = onf[f * ZC_ITEMS + h];
				key[h + 1] = key[h];
				h--;
			}
			onf[f * ZC_ITEMS + h + 1] = oi;
			key[h + 1] = kv;
		}
	}
	// along a face's curve the cube's bounds are crossed at each item, so its stretches between them
	// are in and out in turn: of the two ways round, the one with the more margin inside (each's at
	// its middle: how far within the other bounds), against float32's noise in any one
	int pair[ZC_ITEMS * 6];
	for (int i = 0; i < ZC_ITEMS * 6; i++) pair[i] = -1;
	for (int f = 0; f < 6; f++) {
		int no = nof[f];
		float score = 0.0;
		for (int j = 0; j < ZC_ITEMS - 1; j++) {
			if (j >= no - 1) break;
			score += ((j & 1) == 0 ? 1.0 : -1.0) * zc_margin(q, pos[onf[f * ZC_ITEMS + j]], pos[onf[f * ZC_ITEMS + j + 1]], f, t);
		}
		for (int j = score >= 0.0 ? 0 : 1; j < ZC_ITEMS - 1; j += 2) {
			if (j >= no - 1) break;
			int A = onf[f * ZC_ITEMS + j], B = onf[f * ZC_ITEMS + j + 1];
			pair[A * 6 + f] = B;
			pair[B * 6 + f] = A;
		}
	}
	// the walk
	ZSeq sq;
	sq.k = 0;
	for (int c = 0; c < ZC_PARTS; c++) sq.n[c] = 0;
	bool seen[ZC_ITEMS];
	for (int i = 0; i < ZC_ITEMS; i++) seen[i] = false;
	int ne = 0;
	for (int c = 0; c < ZC_PARTS + 4; c++) {
		if (sq.k >= ZC_PARTS || ne >= ZC_ITEMS - 1) break;
		// the start: the entry first, then the lowest cut not walked
		int st = -1;
		if (c == 0 && first < ni) st = first;
		for (int i = 0; i < ZC_ITEMS; i++) {
			if (st >= 0 || i >= first) break;
			if (!seen[i]) st = i;
		}
		if (st < 0) break;
		// the face to leave it by: the lowest it has a partner on
		int f0 = -1;
		for (int f = 0; f < 6; f++) {
			if (f0 < 0 && pair[st * 6 + f] >= 0) f0 = f;
		}
		seen[st] = true;
		if (f0 < 0) continue;
		int e0 = ne;
		int cur = st, f = f0;
		bool closed = false;
		for (int s = 0; s < ZC_ITEMS; s++) {
			if (ne >= ZC_ITEMS - 1) break;
			sq.id[ne] = ids[cur];
			int nx = f >= 0 ? pair[cur * 6 + f] : -1;
			sq.face[ne] = nx >= 0 ? f : -1;
			ne++;
			if (nx < 0) break;
			if (nx == st) {
				sq.id[ne] = ids[st];
				sq.face[ne] = -1;
				ne++;
				closed = true;
				break;
			}
			if (seen[nx]) {
				sq.id[ne] = ids[nx];
				sq.face[ne] = -1;
				ne++;
				break;
			}
			seen[nx] = true;
			// on across: the other face it has a partner on
			int g = -1;
			for (int h = 0; h < 6; h++) {
				if (g < 0 && h != f && (fm[nx] & (1 << h)) != 0 && pair[nx * 6 + h] >= 0) g = h;
			}
			cur = nx;
			f = g;
		}
		// open, from a cut: the rest the other way first (the part reversed, then on)
		if (!closed && st < first) {
			int f1 = -1;
			for (int h = 0; h < 6; h++) {
				if (f1 < 0 && h != f0 && pair[st * 6 + h] >= 0 && !seen[pair[st * 6 + h]]) f1 = h;
			}
			if (f1 >= 0) {
				int bid[ZC_ITEMS];
				int bf[ZC_ITEMS];
				int nbk = 0;
				cur = pair[st * 6 + f1];
				f = f1;
				bool going = true;      // no break: zc_margin says why
				for (int s = 0; s < ZC_ITEMS; s++) {
					if (going && (nbk >= ZC_ITEMS - 1 - ne || seen[cur])) going = false;
					if (!going) continue;
					seen[cur] = true;
					bid[nbk] = ids[cur];
					bf[nbk] = f;            // the face back toward the start
					nbk++;
					int g = -1;
					for (int h = 0; h < 6; h++) {
						int nh = pair[cur * 6 + h];
						if (g < 0 && h != f && (fm[cur] & (1 << h)) != 0 && nh >= 0 && !seen[max(nh, 0)]) g = h;
					}
					if (g < 0) {
						going = false;
					} else {
						cur = pair[cur * 6 + g];
						f = g;
					}
				}
				// shift the part on by nbk, the walked back items reversed before it
				for (int j = ZC_ITEMS - 1; j >= 0; j--) {
					if (j >= e0 && j < ne) {
						sq.id[j + nbk] = sq.id[j];
						sq.face[j + nbk] = sq.face[j];
					}
				}
				// bid[i] was reached from the one before it (the start for 0) by face bf[i]
				for (int j = 0; j < ZC_ITEMS; j++) {
					if (j >= nbk) break;
					sq.id[e0 + j] = bid[nbk - 1 - j];
					sq.face[e0 + j] = bf[nbk - 1 - j];
				}
				ne += nbk;
			}
		}
		if (ne - e0 >= 2) {
			sq.n[sq.k] = ne - e0;
			sq.k++;
		} else {
			ne = e0;
		}
	}
	// none (a span of next to no width, to rounding): its first item, all rows there
	if (sq.k == 0 && ni > 0) {
		sq.k = 1;
		sq.n[0] = 2;
		sq.id[0] = ids[0];
		sq.id[1] = ids[0];
		sq.face[0] = -1;
		sq.face[1] = -1;
	}
	return sq;
}

// The knots (the pieces' ends' azimuths, off the axis from th0 in [-pi, pi), round it in [0, 2 pi)),
// sorted, those within 1e-6 of the one before left out; their count.
int zc_knots(ZPieces pcs, bool rnd, float th0, out float kn[ZC_KNOTS]) {
	int n = 0;
	for (int e = 0; e < 12; e++) {
		for (int k = 0; k < ZC_PIECES; k++) {
			if (k >= pcs.n[e]) break;
			vec3 ts = pcs.t[e * ZC_PIECES + k];
			for (int j = 0; j < 2; j++) {
				float a = (j == 0 ? ts.x : ts.z) - th0;
				a -= 2.0 * GEO_PI * floor(a / (2.0 * GEO_PI) + (rnd ? 0.0 : 0.5));
				int h = n - 1;
				while (h >= 0 && kn[h] > a) {
					kn[h + 1] = kn[h];
					h--;
				}
				kn[h + 1] = a;
				n++;
			}
		}
	}
	int m = 0;
	for (int i = 0; i < ZC_KNOTS; i++) {
		if (i >= n) break;
		if (m == 0 || kn[i] - kn[m - 1] > 1e-6) {
			kn[m] = kn[i];
			m++;
		}
	}
	return m;
}

// Column c of columns + 1 (the knots kn, nk of them, from th0):
// (its azimuth, its span's middle, its span); spans: nk - 1, round the axis nk (the last to the
// first a turn on). Each span has columns of its own at both ends (the strip between two on one knot
// has no width) and at least one strip, the rest shared out by angle.
vec3 zc_column(float c, float columns, float kn[ZC_KNOTS], int nk, bool rnd, float th0) {
	int spans = rnd ? nk : nk - 1;
	if (spans < 1) return vec3(th0 + kn[0], th0 + kn[0], 0.0);
	float k0 = kn[0], kl = rnd ? kn[0] + 2.0 * GEO_PI : kn[nk - 1];
	float wide = columns - float(spans - 1);
	float whole = max(kl - k0, 1e-9);
	float c0 = 0.0, e0 = 0.0;
	vec3 r = vec3(th0 + kl, th0 + kl, float(spans - 1));
	for (int i = 0; i < ZC_KNOTS; i++) {
		if (i >= spans) break;
		float ka = kn[i], kb = i + 1 < nk ? kn[i + 1] : kl;
		float e1 = i == spans - 1 ? wide : float(i + 1) + floor((wide - float(spans)) * (kb - k0) / whole + 0.5);
		float c1 = c0 + (e1 - e0);
		if (c <= c1) {
			float th = c1 > c0 ? (c >= c1 ? kb : mix(ka, kb, (c - c0) / (c1 - c0))) : ka;
			r = vec3(th0 + th, th0 + 0.5 * (ka + kb), float(i));
			break;
		}
		c0 = c1 + 1.0;
		e0 = e1;
	}
	return r;
}

// Column c's side of a knot (th_prev, th, th_next: the azimuths zc_column gives c - 1, c, c + 1, the
// ones past the ends any): +1 the first of a knot's two columns, -1 the second; round the axis the
// last +1 and the first -1, on one knot a turn apart; else 0. The two are one section's polylines on
// one line of the picture with vertices of their own (each span's rows), which the rasterizer's
// rounding leaves gaps between (T-junctions): body.gdshaderinc pulls them past each other there and
// draws nothing of the strip between them.
float zc_side(float c, float columns, bool rnd, float th_prev, float th, float th_next) {
	if (c < columns && th_next == th) return 1.0;
	if (c > 0.0 && th_prev == th) return -1.0;
	if (rnd && c == columns) return 1.0;
	if (rnd && c == 0.0) return -1.0;
	return 0.0;
}

// Row r (of rows + 1) of a column (sq: its span's parts; pos: its items at its azimuth, in sq's order;
// t, m: its half-surface's): (l, alpha), kill true where it is a row between two parts. Each part's
// entries' stretches get rows by their count (one at least where there are rows enough), the parts
// three rows apart (the two between them killed, at the last part's end and the next one's start).
vec2 zc_node(ZCube q, float r, float rows, ZSeq sq, vec2 pos[ZC_ITEMS], vec3 t, vec3 m, out bool kill) {
	kill = false;
	int K = sq.k;
	int S = 0;
	for (int c = 0; c < ZC_PARTS; c++) {
		if (c < K) S += sq.n[c] - 1;
	}
	// parts that don't fit left out, the last first
	while (K > 1 && rows - 3.0 * float(K - 1) < float(S)) {
		K--;
		S -= sq.n[K] - 1;
	}
	if (K < 1 || S < 1) return K < 1 ? vec2(0.0) : pos[0];
	float Rp = rows - 3.0 * float(K - 1);
	float row0 = 0.0;
	int e0 = 0, j = 0;
	for (int c = 0; c < ZC_PARTS; c++) {
		if (c >= K) break;
		for (int k = 0; k < ZC_ITEMS; k++) {
			if (k >= sq.n[c] - 1) break;
			float b0 = floor(float(j) * Rp / float(S) + 0.5), b1 = floor(float(j + 1) * Rp / float(S) + 0.5);
			float cnt = b1 - b0;
			if (r <= row0 + cnt) {
				float f = cnt > 0.0 ? (r - row0) / cnt : 0.0;
				return zc_between(q, pos[e0 + k], pos[e0 + k + 1], f, sq.face[e0 + k], t, m);
			}
			row0 += cnt;
			j++;
		}
		if (c < K - 1) {
			if (r <= row0 + 2.0) {
				kill = r > row0;
				return r <= row0 + 1.0 ? pos[e0 + sq.n[c] - 1] : pos[e0 + sq.n[c]];
			}
			row0 += 3.0;
		}
		e0 += sq.n[c];
	}
	return pos[max(e0 - 1, 0)];
}
