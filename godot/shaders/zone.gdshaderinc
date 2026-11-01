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
	// the slabs to first order: the nearest one's crossing, then Newton on it; a second round if
	// another slab is crossed first there
	vec3 s0 = vec3(dot(q, E1), dot(q, E2), dot(q, E3));
	if (max(max(abs(s0.x), abs(s0.y)), abs(s0.z)) >= size) return vec2(l0, al0);
	vec3 ds = vec3(dot(T0, E1), dot(T0, E2), dot(T0, E3));
	vec3 r1 = (size - sign(ds) * s0) / max(abs(ds), vec3(1e-9));
	int f = r1.x <= r1.y && r1.x <= r1.z ? 0 : (r1.y <= r1.z ? 1 : 2);
	float rho = min(min(r1.x, r1.y), r1.z);
	vec3 sv = s0;
	for (int round = 0; round < 2; round++) {
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
	// (rho dphi over the line's slant to it), along the section (both slabs at their bounds:
	// Newton on the two in (l, alpha))
	vec4 Tp = zone_rate(p.x, p.y, en, t, dl, dal);
	vec4 Efp = f == 0 ? E1 : (f == 1 ? E2 : E3);
	float gap = rho * dphi / max(abs(dot(Tp, Efp)) / max(length(Tp), 1e-9), 0.3);
	vec3 left = size - abs(sv);
	left[f] = 1e9;
	int k = left.x <= left.y && left.x <= left.z ? 0 : (left.y <= left.z ? 1 : 2);
	if (left[k] < gap) {
		vec4 Ef = f == 0 ? E1 : (f == 1 ? E2 : E3);
		vec4 Ek = k == 0 ? E1 : (k == 1 ? E2 : E3);
		float gf = sign(sv[f]) * size, gk = sign(sv[k]) * size;
		for (int i = 0; i < 2; i++) {
			vec4 qq = zone_point(p.x, p.y, en, t) - C;
			vec4 Tl = zone_rate(p.x, p.y, en, t, 1.0, 0.0);
			vec4 Ta = zone_rate(p.x, p.y, en, t, 0.0, 1.0);
			float a11 = dot(Tl, Ef), a12 = dot(Ta, Ef), a21 = dot(Tl, Ek), a22 = dot(Ta, Ek);
			float b1 = gf - dot(qq, Ef), b2 = gk - dot(qq, Ek);
			float det = a11 * a22 - a12 * a21;
			if (abs(det) < 1e-12) break;
			p += vec2(b1 * a22 - a12 * b2, a11 * b2 - a21 * b1) / det;
		}
	}
	return p;
}
