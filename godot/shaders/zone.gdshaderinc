// Bodies in the curved zone drawn round the eye's axis (body.gdshaderinc, ZONE): a mesh's vertex
// (zone_vertex) as a point of a body's section by a half-surface of the space through that axis,
// worked out once a frame per eye by zone_sections.gdshaderinc's compute shader. Plain GLSL after
// geo.gdshaderinc (ref/test_gpu.py takes it too).

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

// how far the body's definition puts the point P outside it: a ball's |P - C|^2 - radius^2, a
// cube's (ball false) largest offset along its axes less its half size
float zone_out(bool ball, vec4 P, vec4 C, vec4 E1, vec4 E2, vec4 E3, float size) {
	vec4 q = P - C;
	if (ball) return dot(q, q) - size * size;
	return max(max(abs(dot(q, E1)), abs(dot(q, E2))), abs(dot(q, E3))) - size;
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
	vec4 X0 = zone_point(l0, al0, en, t);
	vec4 T0 = zone_rate(l0, al0, en, t, dl, dal);
	vec4 q = X0 - C;
	// the slabs to first order: the nearest one's crossing, then Newton on it; if another slab is
	// crossed first there, another round on the one crossed most, up to one round a slab
	vec3 s0 = vec3(dot(q, E1), dot(q, E2), dot(q, E3));
	if (max(max(abs(s0.x), abs(s0.y)), abs(s0.z)) >= size) return vec2(l0, al0);
	vec3 ds = vec3(dot(T0, E1), dot(T0, E2), dot(T0, E3));
	vec3 r1 = (size - sign(ds) * s0) / max(abs(ds), vec3(1e-9));
	int f = r1.x <= r1.y && r1.x <= r1.z ? 0 : (r1.y <= r1.z ? 1 : 2);
	float rho = min(min(r1.x, r1.y), r1.z);
	for (int round = 0; round < 3; round++) {
		vec4 Ef = f == 0 ? E1 : (f == 1 ? E2 : E3);
		float goal = sign(ds[f]) * size;
		for (int i = 0; i < 2; i++) {
			vec4 X = zone_point(l0 + rho * dl, al0 + rho * dal, en, t);
			vec4 T = zone_rate(l0 + rho * dl, al0 + rho * dal, en, t, dl, dal);
			float dv = dot(T, Ef);
			rho = max(rho - (dot(X - C, Ef) - goal) / (abs(dv) > 1e-9 ? dv : 1e-9), 0.0);
		}
		vec4 qq = zone_point(l0 + rho * dl, al0 + rho * dal, en, t) - C;
		vec3 sv = vec3(dot(qq, E1), dot(qq, E2), dot(qq, E3));
		vec3 over = abs(sv) - size;
		over[f] = -1.0;
		if (max(max(over.x, over.y), over.z) <= 1e-5) break;
		f = over.x >= over.y && over.x >= over.z ? 0 : (over.y >= over.z ? 1 : 2);
		ds[f] = sv[f];
		rho *= 0.9;
	}
	return vec2(l0 + rho * dl, al0 + rho * dal);
}

// Where a cube's edge e (0 to 11: along its axis e / 4, at the other two axes' bounds by e's two
// lowest bits) meets the hyperplane x . m = 0 of R^4's xyz (mu: the axes' parts along m, c: -C . m),
// to first order (in the cube's tangent space at C): the point in the cube's coordinates, clamped to
// the edge, and in .w how far along it (in half sizes: |.w| <= 1 on the edge).
vec4 zone_edge_cut(int e, vec3 mu, float c, float size) {
	int a = e / 4;
	int b = (a + 1) % 3, g = (a + 2) % 3;
	float sb = (e & 1) == 0 ? -size : size, sg = (e & 2) == 0 ? -size : size;
	float xa = abs(mu[a]) > 1e-6 ? (c - mu[b] * sb - mu[g] * sg) / mu[a] : 1e9;
	vec3 x = vec3(0.0);
	x[a] = clamp(xa, -size, size);
	x[b] = sb;
	x[g] = sg;
	return vec4(x, xa / size);
}

// Where the half-surface toward t meets a cube's edge e (zone_edge_cut): both faces' slabs at their
// bounds, by Newton in (l, alpha) from p; ok where it got there (both at their bounds, the third
// slab within) and is a number.
vec2 zone_cube_corner(int e, vec2 p, vec3 en, vec3 t, vec4 C, vec4 E1, vec4 E2, vec4 E3, float size, out bool ok) {
	int a = e / 4;
	int b = (a + 1) % 3, g = (a + 2) % 3;
	vec4 Eb = b == 0 ? E1 : (b == 1 ? E2 : E3), Eg = g == 0 ? E1 : (g == 1 ? E2 : E3);
	float gb = (e & 1) == 0 ? -size : size, gg = (e & 2) == 0 ? -size : size;
	for (int i = 0; i < 3; i++) {
		vec4 qq = zone_point(p.x, p.y, en, t) - C;
		vec4 Tl = zone_rate(p.x, p.y, en, t, 1.0, 0.0);
		vec4 Ta = zone_rate(p.x, p.y, en, t, 0.0, 1.0);
		float a11 = dot(Tl, Eb), a12 = dot(Ta, Eb), a21 = dot(Tl, Eg), a22 = dot(Ta, Eg);
		float b1 = gb - dot(qq, Eb), b2 = gg - dot(qq, Eg);
		float det = a11 * a22 - a12 * a21;
		if (abs(det) < 1e-12) break;
		p += vec2(b1 * a22 - a12 * b2, a11 * b2 - a21 * b1) / det;
	}
	vec4 qc = zone_point(p.x, p.y, en, t) - C;
	vec3 sc = abs(vec3(dot(qc, E1), dot(qc, E2), dot(qc, E3))) - size;
	ok = max(max(abs(sc[b]), abs(sc[g])), sc[a]) <= 4e-5 && p.y >= 0.0 && p.y <= GEO_PI && geo_finite(p.x + p.y);
	return p;
}

// The point of row v (in [0, 1], rows of them) of a cube's section by the half-surface toward t (the
// hyperplane through the axis with normal m), as (l, alpha), so that a row falls on each corner of
// the section, where its outline turns, and the same corner on the same row all through the
// column's span (between two of the cube's corners' azimuths, zone_cube_azimuth; tm, mm: the span's
// middle's): the mesh's strips join each corner to itself. The corners: where this half-surface
// meets the cube's edges the span's middle cuts (on the t side), in their order round the section
// there (where no two of them meet), each by Newton (zone_cube_corner) from where the hyperplane cuts
// the edge to first order. Between two corners the rows go evenly along the chord between them,
// each moved across the chord onto the face they share. Off the axis the section closes, from the
// corner of the lowest edge; round the axis (round_axis) it goes from where the axis enters the
// cube (the first row) to where it leaves (the last), from the axis's point (l, alpha) ax along
// it, into the half-surface by dsg (+1: alpha growing from 0, -1: from pi).
vec2 zone_cube_section(float v, float rows, bool round_axis, vec2 ax, float dsg, vec3 en, vec3 a1, vec3 a2, vec3 t, vec3 m, vec3 tm, vec3 mm,
		float thm, vec4 za, vec4 zb, vec4 C, vec4 E1, vec4 E2, vec4 E3, vec4 N, float size) {
	vec3 mu = vec3(dot(E1.xyz, m), dot(E2.xyz, m), dot(E3.xyz, m));
	float c = -dot(C.xyz, m);
	vec3 mum = vec3(dot(E1.xyz, mm), dot(E2.xyz, mm), dot(E3.xyz, mm));
	float cm = -dot(C.xyz, mm);
	int ed[6];
	int n = 0;
	vec4 summ = vec4(0.0);
	for (int e = 0; e < 12; e++) {
		// cut where the span's middle is between its ends' azimuths, as the spans are: on the arc
		// the edge goes round the axis by from one end to the other. Which way: to first order its
		// ends' cross product's along the axis; where the edge passes nearer the axis than the space's
		// curve moves it (2 size^2 / R), by the azimuth of its middle on the space.
		int a = e / 4;
		int v1 = ((e & 1) << ((a + 1) % 3)) | (((e >> 1) & 1) << ((a + 2) % 3)), v2 = v1 | (1 << a);
		vec4 Ea = a == 0 ? E1 : (a == 1 ? E2 : E3);
		vec4 xm4 = C + size * (((v1 & 1) == 0 ? -1.0 : 1.0) * E1 + ((v1 & 2) == 0 ? -1.0 : 1.0) * E2 + ((v1 & 4) == 0 ? -1.0 : 1.0) * E3) + size * Ea;
		vec3 p1 = xm4.xyz - size * Ea.xyz, p2 = xm4.xyz + size * Ea.xyz;
		p1 -= dot(p1, en) * en;
		p2 -= dot(p2, en) * en;
		vec3 dp = p2 - p1;
		float near = length(p1 + clamp(-dot(p1, dp) / max(dot(dp, dp), 1e-12), 0.0, 1.0) * dp);
		float az1 = v1 < 4 ? za[v1] : zb[v1 - 4];
		float da = (v2 < 4 ? za[v2] : zb[v2 - 4]) - az1, dm = thm - az1;
		da -= 2.0 * GEO_PI * floor(da / (2.0 * GEO_PI));
		dm -= 2.0 * GEO_PI * floor(dm / (2.0 * GEO_PI));
		bool up;
		if (near > 2.0 * size * size / g_prof.y + 0.01) {
			up = dot(cross(p1, p2), en) >= 0.0;
		} else {
			vec4 Pm = geo_onto(xm4, N);
			float dmid = geo_atan2(dot(Pm.xyz, a2), dot(Pm.xyz, a1)) - az1;
			up = dmid - 2.0 * GEO_PI * floor(dmid / (2.0 * GEO_PI)) <= da;
		}
		if ((up ? dm > da : dm < da) || n >= 6) continue;
		vec3 xm = zone_edge_cut(e, mum, cm, size).xyz;
		summ += C + xm.x * E1 + xm.y * E2 + xm.z * E3;
		ed[n] = e;
		n++;
	}
	float rr = floor(clamp(v, 0.0, 1.0) * rows + 0.5);
	vec3 nn;
	if (n == 0 && !round_axis) {
		// no corner (a section at the end of the cube's span, to rounding): the cube's point nearest
		// the hyperplane's nearest to C
		vec3 x = clamp(mu * (c / max(dot(mu, mu), 1e-12)), vec3(-size), vec3(size));
		vec4 P = geo_onto(C + x.x * E1 + x.y * E2 + x.z * E3, N);
		return vec2(geo_l_of(P, nn), geo_atan2(dot(P.xyz, t), dot(P.xyz, en)));
	}
	// The corners' order: by their directions at the span's middle (to first order) from the middle
	// of the corners (off the axis: from the first corner's direction) or from the axis's point
	// (round it: from the axis's entry)
	float ph[6];
	vec2 im = ax;
	if (!round_axis) {
		vec4 X = summ / float(n);
		im = vec2(geo_l_of(X, nn), geo_atan2(dot(X.xyz, tm), dot(X.xyz, en)));
	}
	float rm = geo_r(abs(im.x));
	float ds = round_axis ? dsg : 1.0;
	float p0 = 0.0;
	for (int i = 0; i < 6; i++) {
		if (i >= n) break;
		vec3 xm = zone_edge_cut(ed[i], mum, cm, size).xyz;
		vec4 X = C + xm.x * E1 + xm.y * E2 + xm.z * E3;
		float p = geo_atan2(ds * rm * (geo_atan2(dot(X.xyz, tm), dot(X.xyz, en)) - im.y), geo_l_of(X, nn) - im.x);
		if (i == 0) p0 = p;
		ph[i] = round_axis ? p - 2.0 * GEO_PI * floor(p / (2.0 * GEO_PI) + 0.25) : p - p0 - 2.0 * GEO_PI * floor((p - p0) / (2.0 * GEO_PI));
	}
	// The stretch the row is on: between the corners ranked k and k + 1, each corner ranked k on row
	// round(k rows / n) (off the axis the last on to the first again), or round the axis
	// round((k + 1) rows / (n + 1)) (the entry ranked -1 on row 0, the exit ranked n on the last)
	float nk = round_axis ? float(n + 1) : float(n);
	float k = clamp(floor(rr * nk / rows), 0.0, nk - 1.0);
	float ra = floor(k * rows / nk + 0.5), rb = floor((k + 1.0) * rows / nk + 0.5);
	if (rr < ra) { k -= 1.0; rb = ra; ra = floor(k * rows / nk + 0.5); }
	else if (rr > rb) { k += 1.0; ra = rb; rb = floor((k + 1.0) * rows / nk + 0.5); }
	int ka = int(k) - (round_axis ? 1 : 0);
	int kb = round_axis || ka + 1 < n ? ka + 1 : 0;
	int ca = -1, cb = -1;
	for (int i = 0; i < 6; i++) {
		if (i >= n) break;
		int rank = 0;
		for (int j = 0; j < 6; j++) {
			if (j >= n) break;
			if (ph[j] < ph[i] || (ph[j] == ph[i] && j < i)) rank++;
		}
		if (rank == ka) ca = i;
		if (rank == kb) cb = i;
	}
	float f = rb > ra ? (rr - ra) / (rb - ra) : 0.0;
	// The stretch's two ends: a corner, or where the axis enters or leaves the cube; and the faces
	// each is on (a corner's two: its edge's; the axis's entry or exit: the one it crosses), as
	// axis (0 to 2) and side (-1, 1), (-1, 0) for none
	vec2 pe[2];
	ivec2 fa[2], fb[2];
	for (int s = 0; s < 2; s++) {
		int ci = s == 0 ? ca : cb;
		if (s == 1 && f == 0.0) break;           // on the stretch's first end
		if (s == 0 && f == 1.0) continue;
		if (ci >= 0) {
			int e = ed[ci];
			vec3 x = zone_edge_cut(e, mu, c, size).xyz;
			vec4 P = geo_onto(C + x.x * E1 + x.y * E2 + x.z * E3, N);
			vec2 p = vec2(geo_l_of(P, nn), geo_atan2(dot(P.xyz, t), dot(P.xyz, en)));
			bool ok;
			vec2 pc = zone_cube_corner(e, p, en, t, C, E1, E2, E3, size, ok);
			pe[s] = ok ? pc : p;
			int a = e / 4;
			fa[s] = ivec2((a + 1) % 3, (e & 1) == 0 ? -1 : 1);
			fb[s] = ivec2((a + 2) % 3, (e & 2) == 0 ? -1 : 1);
		} else {
			// the axis's entry (s 0) or exit (s 1): along the axis from its point
			float r0 = geo_r(abs(ax.x));
			pe[s] = zone_edge_cube(ax.x, ax.y, s == 0 ? 1.0 : -1.0, 0.0, en, t, C, E1, E2, E3, size);
			vec4 q = zone_point(pe[s].x, pe[s].y, en, t) - C;
			vec3 sv = vec3(dot(q, E1), dot(q, E2), dot(q, E3));
			vec3 av = abs(sv);
			int a = av.x >= av.y && av.x >= av.z ? 0 : (av.y >= av.z ? 1 : 2);
			fa[s] = ivec2(a, sv[a] < 0.0 ? -1 : 1);
			fb[s] = ivec2(-1, 0);
		}
	}
	if (f == 0.0) return pe[0];
	if (f == 1.0) return pe[1];
	// between: on the chord, then across it onto the face both ends are on (Newton on its slab)
	ivec2 face = fa[0] == fa[1] || fa[0] == fb[1] ? fa[0] : fb[0];
	vec2 p = mix(pe[0], pe[1], f);
	if (face.x < 0 || (face != fa[1] && face != fb[1])) return p;
	vec4 Ef = face.x == 0 ? E1 : (face.x == 1 ? E2 : E3);
	float goal = float(face.y) * size;
	float rc = geo_r(abs(p.x));
	vec2 d = vec2(pe[1].x - pe[0].x, rc * (pe[1].y - pe[0].y));
	vec2 nd = vec2(-d.y, d.x) / max(length(d), 1e-12);
	vec2 dir = vec2(nd.x, nd.y / rc);         // across the chord, in (l, alpha) per metre
	vec2 pk = p;
	for (int round = 0; round < 2; round++) {
		for (int i = 0; i < 3; i++) {
			float g = dot(zone_point(p.x, p.y, en, t) - C, Ef) - goal;
			float dg = dot(zone_rate(p.x, p.y, en, t, dir.x, dir.y), Ef);
			if (abs(dg) < 1e-9) break;
			p -= (g / dg) * dir;
		}
		// past another face (an end on two or three faces, the face shared taken wrong): onto that
		// one, kept where it gets there
		vec4 q = zone_point(p.x, p.y, en, t) - C;
		vec3 sv = vec3(dot(q, E1), dot(q, E2), dot(q, E3));
		vec3 over = abs(sv) - size;
		if (round == 1) return max(max(over.x, over.y), over.z) <= 1e-5 && geo_finite(p.x + p.y) ? p : pk;
		over[face.x] = -1.0;
		int f2 = over.x >= over.y && over.x >= over.z ? 0 : (over.y >= over.z ? 1 : 2);
		if (over[f2] <= 1e-5) break;
		pk = p;
		Ef = f2 == 0 ? E1 : (f2 == 1 ? E2 : E3);
		goal = sv[f2] < 0.0 ? -size : size;
	}
	return p;
}

// The azimuths round the axis (a1, a2 across it) of a cube's corners (on the space: geo_onto from
// the 4D box's corner along N), corner i (E1's side by bit 0, E2's bit 1, E3's bit 2) in za[i] for
// i < 4, else in zb[i - 4].
void zone_cube_corners(vec4 C, vec4 E1, vec4 E2, vec4 E3, vec4 N, float size, vec3 a1, vec3 a2, out vec4 za, out vec4 zb) {
	for (int i = 0; i < 8; i++) {
		vec4 P = geo_onto(C + size * (((i & 1) == 0 ? -1.0 : 1.0) * E1 + ((i & 2) == 0 ? -1.0 : 1.0) * E2
				+ ((i & 4) == 0 ? -1.0 : 1.0) * E3), N);
		float a = geo_atan2(dot(P.xyz, a2), dot(P.xyz, a1));
		if (i < 4) za[i] = a; else zb[i - 4] = a;
	}
}

// A cube's azimuth for the mesh's column u in [0, 1] (columns of strips), and in .y the middle of
// the span it is in: the spans run between its corners' azimuths (za, zb), where its outline turns
// and its sections change their edges: off the axis (round false) from the least of them to the
// greatest, round the axis all the way round. Each span has columns of its own at both ends (two on
// each corner's azimuth, one a span: the strip between them has no width) and at least one strip,
// the rest shared out by angle. th0: an azimuth inside the cube's span (off the axis).
vec2 zone_cube_azimuth(float u, float columns, bool round_axis, float th0, vec4 za, vec4 zb) {
	float k[9];
	for (int i = 0; i < 8; i++) {
		float a = (i < 4 ? za[i] : zb[i - 4]) - th0;
		k[i] = a - 2.0 * GEO_PI * floor(a / (2.0 * GEO_PI) + (round_axis ? 0.0 : 0.5));   // [0, 2 pi) or [-pi, pi)
	}
	// sorted (a network of 19 exchanges)
	const int NET[38] = int[38](0, 1, 2, 3, 4, 5, 6, 7, 0, 2, 1, 3, 4, 6, 5, 7, 1, 2, 5, 6, 0, 4, 3, 7, 1, 5, 2, 6,
			1, 4, 3, 6, 2, 4, 3, 5, 3, 4);
	for (int e = 0; e < 19; e++) {
		int i = NET[2 * e], j = NET[2 * e + 1];
		float lo = min(k[i], k[j]), hi = max(k[i], k[j]);
		k[i] = lo;
		k[j] = hi;
	}
	// the last knot: the greatest corner, or round the axis the first again a turn on
	k[8] = round_axis ? k[0] + 2.0 * GEO_PI : k[7];
	float spans = round_axis ? 8.0 : 7.0;
	float wide = columns - (spans - 1.0);      // the strips with width
	float whole = max(k[8] - k[0], 1e-9);
	float col = floor(clamp(u, 0.0, 1.0) * columns + 0.5);
	float c0 = 0.0, e0 = 0.0;
	vec2 th = vec2(k[8], 0.5 * (k[7] + k[8]));
	for (int i = 0; i < 8; i++) {
		if (float(i) >= spans) break;
		// at least a strip each (a strip joins two columns of one span), the rest by angle
		float e1 = float(i) == spans - 1.0 ? wide : float(i + 1) + floor((wide - spans) * (k[i + 1] - k[0]) / whole + 0.5);
		float c1 = c0 + (e1 - e0);              // the span's columns: c0 to c1
		if (col <= c1) {
			// the span's middle; a span of no angle (two corners on one azimuth: an edge along the
			// axis or w) at the next span's (the last at the one before), whose sections it has
			float mid = 0.5 * (k[i] + k[i + 1]);
			if (k[i + 1] - k[i] < 1e-5) mid = float(i) < spans - 1.0 ? 0.5 * (k[i + 1] + k[min(i + 2, 8)]) : 0.5 * (k[max(i - 1, 0)] + k[i]);
			// a span's last column on its corner's azimuth exactly, as the next span's first is: the
			// strip between them has no area (mix at 1 may come out a float32 step off, and a
			// triangle of almost none gets a pixel now and then, with its varyings no numbers)
			th = vec2(c1 > c0 ? (col >= c1 ? k[i + 1] : mix(k[i], k[i + 1], (col - c0) / (c1 - c0))) : k[i], mid);
			break;
		}
		c0 = c1 + 1.0;
		e0 = e1;
	}
	return th0 + th;
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

// A body's vertex in the curved zone (body.gdshaderinc, ZONE) for the eye whose direction from the
// centre is en: column u of the mesh (columns strips across the azimuths) and row v (rows round the
// section): (l, alpha) of its point on the body, and t, its half-surface's direction (across en).
// A ball (ball true) of radius size, a cube of half size size (axes E1, E2, E3); N the space's
// normal at the centre C. Round the axis where the axis's point nearest the centre is inside the
// body, else off it.
vec2 zone_vertex(vec2 uv, float columns, float rows, bool ball, vec3 en, vec4 C, vec4 E1, vec4 E2, vec4 E3, vec4 N, float size, out vec3 t) {
	float reach = ball ? size : 1.8 * size;    // a cube's cut box is within this chord of C (sqrt 3, and the cut's bulge)
	// the axis's frame: a1, a2 across it; the body's centre's offset across it, and the axis's
	// point nearest the centre, inside the body or not
	vec3 a1 = normalize(cross(en, abs(en.z) < 0.9 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0)));
	vec3 a2 = cross(en, a1);
	vec2 cp = vec2(dot(C.xyz, a1), dot(C.xyz, a2));
	float d = length(cp);
	float ce = dot(C.xyz, en);
	vec3 nn;
	vec2 ax = vec2(geo_l_of(vec4(ce * en, C.w), nn), ce >= 0.0 ? 0.0 : GEO_PI);
	bool round_axis = d < reach && zone_out(true, zone_point(ax.x, ax.y, en, a1), C, E1, E2, E3, size) < 0.0;
	if (!ball && d < reach) {
		vec2 deep = zone_cube_axis(ax.x, ax.y, en, a1, C, E1, E2, E3, size);
		round_axis = deep.y < 0.0;
		ax.x = deep.x;
	}
	// round the axis: every azimuth, each section from the axis's entry round to its exit, into the
	// half-surface
	float dsg = round_axis && ce < 0.0 ? -1.0 : 1.0;
	float th0 = round_axis ? 0.0 : geo_atan2(cp.y, cp.x);
	if (ball) {
		float th = 2.0 * GEO_PI * uv.x;
		if (!round_axis) th = th0 + (2.0 * uv.x - 1.0) * zone_ball_reach(C, d, size);
		// the inner point: the centre's place in the half-surface's hyperplane, its direction there
		// and the l of the profile's point nearest it
		vec2 i0 = zone_ball_inner(C, en, th, a1, a2, t);
		if (round_axis) i0 = ax;
		vec2 sp = geo_sincos((round_axis ? GEO_PI : 2.0 * GEO_PI) * uv.y);
		return zone_edge_ball(i0.x, i0.y, sp.y, dsg * sp.x / geo_r(abs(i0.x)), en, t, C, size);
	}
	// a cube's outline turns at its corners: a column on each one's azimuth (two: one each span),
	// and on each corner of a section a row
	vec4 za, zb;
	zone_cube_corners(C, E1, E2, E3, N, size, a1, a2, za, zb);
	vec2 az = zone_cube_azimuth(uv.x, columns, round_axis, th0, za, zb);
	vec2 sct = geo_sincos(az.x), scm = geo_sincos(az.y);
	t = sct.y * a1 + sct.x * a2;
	return zone_cube_section(uv.y, rows, round_axis, ax, dsg, en, a1, a2, t, sct.y * a2 - sct.x * a1,
			scm.y * a1 + scm.x * a2, scm.y * a2 - scm.x * a1, az.y, za, zb, C, E1, E2, E3, N, size);
}
