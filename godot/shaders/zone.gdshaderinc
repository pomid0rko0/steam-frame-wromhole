// Bodies in the curved zone drawn round the eye's axis (body.gdshaderinc, ZONE): the points of a
// half-surface of the space through that axis, and where a line in it meets a body. Plain GLSL
// after geo.gdshaderinc (ref/test_gpu.py takes it too).

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
// (zone_edge_cube), (l, alpha); the inner point if it is not inside. A cube's: a point nearer an
// edge of its section than the points round it are apart there (dphi apart in the line's angle)
// goes onto that edge (the section's corner): the section keeps its corners.
vec2 zone_edge_ball(float l0, float al0, float dl, float dal, vec3 en, vec3 t, vec4 C, float size) {
	vec4 X0 = zone_point(l0, al0, en, t);
	vec4 T0 = zone_rate(l0, al0, en, t, dl, dal);
	vec4 q = X0 - C;
	// the chord's square along the line: a quadratic to first order, then Newton on the exact one
	float c0 = dot(q, q) - size * size;
	if (c0 >= 0.0) return vec2(l0, al0);
	float bq = dot(q, T0), tt = max(dot(T0, T0), 1e-12);
	float rho = (-bq + sqrt(max(bq * bq - tt * c0, 0.0))) / tt;
	for (int i = 0; i < 2; i++) {
		vec4 X = zone_point(l0 + rho * dl, al0 + rho * dal, en, t);
		vec4 T = zone_rate(l0 + rho * dl, al0 + rho * dal, en, t, dl, dal);
		vec4 qq = X - C;
		rho = max(rho - (dot(qq, qq) - size * size) / max(2.0 * dot(qq, T), 1e-12), 0.0);
	}
	return vec2(l0 + rho * dl, al0 + rho * dal);
}

vec2 zone_edge_cube(float l0, float al0, float dl, float dal, float dphi, vec3 en, vec3 t, vec4 C, vec4 E1, vec4 E2, vec4 E3, float size) {
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
	vec3 sv = s0;
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
		sv = vec3(dot(qq, E1), dot(qq, E2), dot(qq, E3));
		vec3 over = abs(sv) - size;
		over[f] = -1.0;
		if (max(max(over.x, over.y), over.z) <= 1e-5) break;
		f = over.x >= over.y && over.x >= over.z ? 0 : (over.y >= over.z ? 1 : 2);
		ds[f] = sv[f];
		rho *= 0.9;
	}
	vec2 p = vec2(l0 + rho * dl, al0 + rho * dal);
	// the nearest other face: onto its edge with face f if within the points' spacing along face f
	// (rho dphi over the cosine of the line's slant to its normal: lines that graze a face meet it
	// far apart), along the section (both slabs at their bounds: Newton on the two in (l, alpha))
	vec4 Tp = zone_rate(p.x, p.y, en, t, dl, dal);
	vec4 Efp = f == 0 ? E1 : (f == 1 ? E2 : E3);
	float gap = rho * dphi / max(abs(dot(Tp, Efp)) / max(length(Tp), 1e-9), 0.05);
	vec3 left = size - abs(sv);
	left[f] = 1e9;
	int k = left.x <= left.y && left.x <= left.z ? 0 : (left.y <= left.z ? 1 : 2);
	if (left[k] < gap) {
		vec4 Ef = f == 0 ? E1 : (f == 1 ? E2 : E3);
		vec4 Ek = k == 0 ? E1 : (k == 1 ? E2 : E3);
		float gf = sign(sv[f]) * size, gk = sign(sv[k]) * size;
		vec2 c = p;
		for (int i = 0; i < 2; i++) {
			vec4 qq = zone_point(c.x, c.y, en, t) - C;
			vec4 Tl = zone_rate(c.x, c.y, en, t, 1.0, 0.0);
			vec4 Ta = zone_rate(c.x, c.y, en, t, 0.0, 1.0);
			float a11 = dot(Tl, Ef), a12 = dot(Ta, Ef), a21 = dot(Tl, Ek), a22 = dot(Ta, Ek);
			float b1 = gf - dot(qq, Ef), b2 = gk - dot(qq, Ek);
			float det = a11 * a22 - a12 * a21;
			if (abs(det) < 1e-12) break;
			c += vec2(b1 * a22 - a12 * b2, a11 * b2 - a21 * b1) / det;
		}
		// a corner of the section only if Newton got there (both slabs at their bounds: their planes
		// may also meet almost along each other, and Newton then runs off), it is on the cube (the
		// two faces' planes may meet beyond a third), within the spacing of the point it replaces
		// and a number
		vec4 qc = zone_point(c.x, c.y, en, t) - C;
		vec3 sc = abs(vec3(dot(qc, E1), dot(qc, E2), dot(qc, E3))) - size;
		float moved = length(zone_point(c.x, c.y, en, t) - zone_point(p.x, p.y, en, t));
		bool on = abs(sc[f]) <= 4e-5 && abs(sc[k]) <= 4e-5 && sc[3 - f - k] <= 4e-5;
		if (on && moved <= gap && c.y >= 0.0 && c.y <= GEO_PI && geo_finite(c.x + c.y + moved)) p = c;
	}
	return p;
}

// A point inside a cube's section by the half-surface toward t (the hyperplane through the axis with
// normal m, R^4's xyz): the middle of where the hyperplane cuts the cube's edges, to first order (in
// the cube's tangent space at C, then onto the space along N), as (l, alpha). The centre's own
// place in the hyperplane is outside the small sections near a corner.
bool zone_inner_cube(vec4 C, vec4 E1, vec4 E2, vec4 E3, vec4 N, float size, vec3 m, vec3 en, vec3 t, out vec2 la) {
	vec3 mu = vec3(dot(E1.xyz, m), dot(E2.xyz, m), dot(E3.xyz, m));
	float c = -dot(C.xyz, m);
	vec3 sum = vec3(0.0);
	float count = 0.0;
	for (int a = 0; a < 3; a++) {
		int b = (a + 1) % 3, e = (a + 2) % 3;
		if (abs(mu[a]) < 1e-6) continue;
		for (int k = 0; k < 4; k++) {
			float sb = (k & 1) == 0 ? -size : size, se = (k & 2) == 0 ? -size : size;
			float xa = (c - mu[b] * sb - mu[e] * se) / mu[a];
			if (abs(xa) <= size) {
				vec3 x = vec3(0.0);
				x[a] = xa;
				x[b] = sb;
				x[e] = se;
				sum += x;
				count += 1.0;
			}
		}
	}
	// none (a section at the end of the cube's span, to rounding): the cube's point nearest the
	// hyperplane's nearest to C, so the section's points gather on the cube, not beside it
	vec3 x = count < 0.5 ? clamp(mu * (c / max(dot(mu, mu), 1e-12)), vec3(-size), vec3(size)) : sum / count;
	vec4 P = geo_onto(C + x.x * E1 + x.y * E2 + x.z * E3, N);
	vec3 nn;
	la = vec2(geo_l_of(P, nn), geo_atan2(dot(P.xyz, t), dot(P.xyz, en)));
	return true;
}

// A cube's azimuth for the mesh's column u in [0, 1] (columns of them), so that a column falls on
// the azimuth of each of its corners (on the space: geo_onto from the 4D box's corner along N),
// where its outline turns: off the axis (round false) from the least to the greatest of those
// azimuths, round the axis all the way round; the columns between them shared out by their
// angles (each corner on the column nearest its share). a1, a2: the axis's frame across it; th0:
// an azimuth inside the cube's span (off the axis).
float zone_cube_azimuth(float u, float columns, bool round_axis, float th0, vec4 C, vec4 E1, vec4 E2, vec4 E3, vec4 N, float size, vec3 a1, vec3 a2) {
	float k[9];
	for (int i = 0; i < 8; i++) {
		vec4 P = geo_onto(C + size * (((i & 1) == 0 ? -1.0 : 1.0) * E1 + ((i & 2) == 0 ? -1.0 : 1.0) * E2
				+ ((i & 4) == 0 ? -1.0 : 1.0) * E3), N);
		float a = geo_atan2(dot(P.xyz, a2), dot(P.xyz, a1)) - th0;
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
	float span = max(k[8] - k[0], 1e-9);
	float col = clamp(u, 0.0, 1.0) * columns;
	float c0 = 0.0;
	float th = k[8];
	for (int i = 0; i < 8; i++) {
		float c1 = i == 7 ? columns : floor(columns * (k[i + 1] - k[0]) / span + 0.5);
		if (col <= c1 + 1e-4) {
			th = c1 > c0 ? mix(k[i], k[i + 1], clamp((col - c0) / (c1 - c0), 0.0, 1.0)) : k[i + 1];
			break;
		}
		c0 = c1;
	}
	return th0 + th;
}
