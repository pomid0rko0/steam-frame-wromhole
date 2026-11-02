// What a pixel's ray meets, and its colour (after look.gdshaderinc), for the floor's quad (floor.gdshaderinc) and our own foveation's
// compute shader (floor_fov.gdshaderinc): docs/geometry.md, «Как рисуется кадр». After geo_exit
// (geo.gdshaderinc) the ray is a straight line in universe A or B; along it the floor (R^4's z =
// -lift), the sky, and, if it came through the curved zone, the bodies out in the flat universes
// (Renderer's lens list: those seen straight from an eye outside are drawn as meshes, in front of
// this, and those in the zone are meshes too). The includer declares (lens_uniforms.gdshaderinc, or
// the compute shader's buffer):
//   lens_body[4 LENS_MAX]: per body, A's first then B's, in R^4's xyz of its universe:
//     (centre, kind: 0 a sphere, 1 a box, 2 a box with dark edges (a toy cube), 3 an upright
//      cylinder), (E1, s1), (E2, s2), (colour, s3): a box's axes E1, E2 (E3 = E1 x E2) and half
//      sizes; a sphere's radius s1; a cylinder's radius s1 and half height s3 along E3
//   lens_n = (A's count, B's count)

#define LENS_MAX 40

// what a ray meets: kind 0 the sky, 1 the floor, 2 a body
struct LensSeen {
	int kind;
	float sheet;     // the universe: +1 A, -1 B
	float way;       // m along the ray from the eye
	vec3 d;          // the ray's direction there (R^4's xyz)
	vec3 p;          // the point (R^4's xyz)
	vec3 n;          // a body's outward normal
	vec3 albedo;
	vec3 box;        // a toy cube's point in its own [-1, 1]^3, else 0
};

// the first of a body's crossings with the straight ray o + t d (unit d) past t = 0, before tmax:
// its t (or tmax) and normal
float lens_sphere(vec3 o, vec3 d, vec3 c, float r, float tmax, inout vec3 nrm) {
	vec3 oc = o - c;
	float bq = dot(oc, d);
	float disc = bq * bq - (dot(oc, oc) - r * r);
	if (disc < 0.0) return tmax;
	float t = -bq - sqrt(disc);
	if (t <= 0.0 || t >= tmax) return tmax;
	nrm = (oc + t * d) / r;
	return t;
}

float lens_box(vec3 o, vec3 d, vec3 c, vec3 e1, vec3 e2, vec3 s, float tmax, inout vec3 nrm, inout vec3 box) {
	vec3 e3 = cross(e1, e2);
	vec3 oc = o - c;
	vec3 lo = vec3(dot(oc, e1), dot(oc, e2), dot(oc, e3));
	vec3 ld = vec3(dot(d, e1), dot(d, e2), dot(d, e3));
	vec3 inv = 1.0 / ld;
	vec3 t1 = (-s - lo) * inv, t2 = (s - lo) * inv;
	vec3 tn = min(t1, t2), tf = max(t1, t2);
	float t = max(max(tn.x, tn.y), tn.z);
	float tout = min(min(tf.x, tf.y), tf.z);
	if (t > tout || t <= 0.0 || t >= tmax) return tmax;
	vec3 q = lo + t * ld;
	vec3 a = abs(q) / s;
	vec3 ax = a.x >= a.y && a.x >= a.z ? vec3(1.0, 0.0, 0.0) : (a.y >= a.z ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0));
	vec3 sg = sign(q) * ax;
	nrm = sg.x * e1 + sg.y * e2 + sg.z * e3;
	box = q / s;
	return t;
}

float lens_cylinder(vec3 o, vec3 d, vec3 c, vec3 e1, vec3 e2, float r, float hh, float tmax, inout vec3 nrm) {
	vec3 e3 = cross(e1, e2);
	vec3 oc = o - c;
	vec3 lo = vec3(dot(oc, e1), dot(oc, e2), dot(oc, e3));
	vec3 ld = vec3(dot(d, e1), dot(d, e2), dot(d, e3));
	float best = tmax;
	float A = dot(ld.xy, ld.xy);
	if (A > 1e-12) {
		float B = dot(lo.xy, ld.xy);
		float disc = B * B - A * (dot(lo.xy, lo.xy) - r * r);
		if (disc >= 0.0) {
			float t = (-B - sqrt(disc)) / A;
			float z = lo.z + t * ld.z;
			if (t > 0.0 && t < best && abs(z) <= hh) {
				best = t;
				vec2 q = (lo.xy + t * ld.xy) / r;
				nrm = q.x * e1 + q.y * e2;
			}
		}
	}
	if (abs(ld.z) > 1e-12) {
		float cap = lo.z > 0.0 ? hh : -hh;
		float t = (cap - lo.z) / ld.z;
		vec2 q = lo.xy + t * ld.xy;
		if (t > 0.0 && t < best && dot(q, q) <= r * r) {
			best = t;
			nrm = sign(cap) * e3;
		}
	}
	return best;
}

// the straight ray from pos along dir (unit) in universe sheet, way metres from the eye so far:
// the floor or the sky, and with bodies (it came through the zone) the nearest body before them
LensSeen lens_trace(vec3 pos, vec3 dir, float sheet, float way, bool bodies) {
	LensSeen s;
	s.kind = 0;
	s.sheet = sheet;
	s.way = way;
	s.d = dir;
	s.p = pos;
	s.n = vec3(0.0, 0.0, 1.0);
	s.albedo = vec3(0.0);
	s.box = vec3(0.0);
	float lift = g_lift;
	float tmax = 1e30;
	if (dir.z < 0.0) {
		tmax = (-lift - pos.z) / dir.z;
		s.kind = 1;
	}
	if (bodies) {
		// the ray stays in its plane through the centre: a body further from that plane than its
		// size is never met
		vec3 m = cross(pos, dir);
		float ml = length(m);
		m = ml > 1e-6 ? m / ml : vec3(0.0);
		int i0 = sheet > 0.0 ? 0 : int(lens_n.x);
		int i1 = i0 + int(sheet > 0.0 ? lens_n.x : lens_n.y);
		int hit = -1;
		for (int i = i0; i < i1; i++) {
			vec4 r0 = lens_body[4 * i], r1 = lens_body[4 * i + 1], r2 = lens_body[4 * i + 2], r3 = lens_body[4 * i + 3];
			int kind = int(r0.w + 0.5);
			float reach = kind == 0 ? r1.w : (kind == 3 ? length(vec2(r1.w, r3.w)) : length(vec3(r1.w, r2.w, r3.w)));
			if (abs(dot(r0.xyz, m)) > reach || dot(r0.xyz - pos, dir) < -reach) continue;
			float t = tmax;
			vec3 nrm = s.n, box = vec3(0.0);
			if (kind == 0) t = lens_sphere(pos, dir, r0.xyz, r1.w, tmax, nrm);
			else if (kind == 3) t = lens_cylinder(pos, dir, r0.xyz, r1.xyz, r2.xyz, r1.w, r3.w, tmax, nrm);
			else t = lens_box(pos, dir, r0.xyz, r1.xyz, r2.xyz, vec3(r1.w, r2.w, r3.w), tmax, nrm, box);
			if (t < tmax) {
				tmax = t;
				hit = i;
				s.n = nrm;
				s.box = kind == 2 ? box : vec3(0.0);
			}
		}
		if (hit >= 0) {
			s.kind = 2;
			s.albedo = lens_body[4 * hit + 3].rgb;
		}
	}
	if (s.kind > 0) {
		s.p = pos + tmax * dir;
		s.way = way + tmax;
	}
	return s;
}

// Whether a ray from an eye out of the curved zone that misses its ball (geo_exit false) passes so
// near it that the bodies on its straight line are looked for too (lens_trace's bodies), ang
// (radians) of a pixel's or texel's neighbourhood off it reaching into the ball: there the bodies
// seen straight are this quad's, not their meshes' (body.gdshaderinc drops a fragment whose line of
// sight goes through the ball), and the filtered texels or a pixel's neighbours must have them on
// both sides of its edge, or a light seam goes round the zone where a body crosses it. el, re: the
// eye's l and r; D: the ray (geo_exit's).
bool lens_near(float el, float re, vec4 D, float ang) {
	float ca = (el < 0.0 ? -D.x : D.x);
	float sa = length(D.yzw);
	float k = inversesqrt(max(ca * ca + sa * sa, 1e-30));
	float b = re * sa * k;
	// b grows by sqrt(re^2 - b^2) per radian of the ray's turn off the centre
	return ca < 0.0 && b < g_prof2.x + ang * sqrt(max(re * re - b * b, 0.0));
}

// where the straight ray from pos along dir (sheet) meets the floor, as look_ground_at takes it
// (chart x, y), whether or not something is in front: its pattern's neighbours are smooth across
// a body's edge. Far off (none) the point under the horizon's haze.
vec2 lens_floor_xy(vec3 pos, vec3 dir, float sheet) {
	float t = dir.z < -1e-6 ? (-g_lift - pos.z) / dir.z : 1e5;
	vec2 xy = pos.xy + t * dir.xy;
	return vec2(sheet * xy.x, xy.y);
}

// The colour of what lens_trace met: the sky, the floor (a = look_ground_at at
// the point, dx, dy its neighbours' differences), or a body (edge: a toy cube's dark edges, the
// distance to its face's nearest edge in box units and that distance's footprint)
vec3 lens_colour(LensSeen s, vec3 a, vec3 dx, vec3 dy, vec2 edge, float px) {
	if (s.kind == 0) {
		vec3 d = normalize(s.d);
		return look_sky(vec3(s.sheet * d.x, d.yz), s.sheet);
	}
	if (s.kind == 1) return look_ground(a, dx, dy, px, s.sheet, s.way);
	vec4 sun = look_sun4(100.0 * s.sheet);
	float nl = dot(s.n, sun.xyz);
	vec3 col = look_body(s.albedo, nl, s.n.z, -dot(s.n, s.d), 100.0 * s.sheet);
	if (edge.x >= 0.0) col *= mix(0.45, 1.0, clamp((edge.x - 0.04) / max(edge.y, 1e-5) + 0.5, 0.0, 1.0));
	return col;
}

