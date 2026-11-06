// The floor, the sky and what is seen through the curved zone, for foveation (foveation.gd): a
// compute shader's body, not a Godot shader's; foveation.gd puts the header (the version, EYES,
// TABLE, GRAVITY, TAIL_VIEW, TAIL_TILES or TAIL) before it and geo.gdshaderinc, look.gdshaderinc and lens.gdshaderinc where it
// says.
//
// Each eye's picture in a texture warped about the pixel g the eye looks at (foveation.gd's top):
// texel T, rho = |T - c| from g's texel c, is the pixel g + (T - c) F^-1(rho) / rho, F^-1(rho) =
// rho within r0 and r0 + sinh(m (rho - r0)) / m beyond. Each texel is a pixel of floor.gdshaderinc
// at that place in the picture, worked out the same way, with the floor's pattern filtered by the
// texel's size; the floor's quad then takes each pixel's colour from here (floor_sample.gdshader).
//
// EYES: the first pass, one invocation per eye: what floor.gdshaderinc's vertex() works out per
// eye (geo_eye; r, the root of u and r - rho0 there), from the camera Godot renders with, and the
// ends of its rows of the way out (geo_xt_range).
// TABLE: the second, one invocation per texel of those rows (geo.gdshaderinc, «the way out by a
// table»): each eye's way out of the zone by a ray's sigma, outward and inward. A texel of the
// picture then takes its ray's way out from there (geo_xt_way), not from geo_exit's closed forms.
// The texture (neither): each texel's colour, and in its alpha the light's way to what it shows
// (the sky's FOV_SKY), for TAIL.
// The tail of the zone's bodies' images (zone_tail.gdshaderinc), per texel instead of per pixel, in
// three passes after the texture and after ZoneSections' IMAGES pass, which works out where each
// body's tail can be seen (its sectors round the eye's axis and its strips and band off it:
// zone_tail.gdshader's top):
// TAIL_VIEW: each body's sector and ranges for each eye, once (an invocation a body and side), into
// a buffer; TAIL_TILES: the tiles of 8 x 8 texels that reach into one of them, listed (an invocation
// a tile); TAIL: those tiles only (a workgroup a tile, dispatched by the list's count). A texel whose
// ray lies in a sector looks into the copies of that body its strip or band holds, as
// zone_tail.gdshader's fragment does; where it meets one nearer than what the texel shows, the texel
// takes the body's colour there, lit as zone_tail.gdshader lights it. The meshes' images are drawn
// over the floor's quad, so the tail stays behind them as their depth kept it (along a ray the turn
// grows with the way, and the tail's ways in are at turns past the meshes'). A pass over every texel
// costs the headset milliseconds a frame even where no tail is (the speed check's zone passes), so
// only the listed tiles are worked out.

layout(set = 0, binding = 0) uniform sampler2D g_tab;
layout(set = 0, binding = 1, std140) uniform Lens {
	vec4 body[160];     // lens_body (4 LENS_MAX)
	vec4 n;             // lens_n
} lensp;
layout(set = 0, binding = 2, std140) uniform Params {
	vec4 prof;          // g_prof
	vec4 prof2;         // g_prof2
	vec4 tabx;          // g_tabx
	vec4 head_nl;       // head_n, head_l
	vec4 head_p;        // head_pos
	vec4 head_fr[3];    // head_f
	vec4 floor_;        // (g_lift, g_beta)
	mat4 inv_view;      // INV_VIEW_MATRIX
	mat4 ray[2];        // each eye's rays: ray * (clip, 1, 0) is geo_view_ray(PROJECTION_MATRIX, clip)
	vec4 eye_off[2];    // each eye's EYE_OFFSET
	vec4 warp0[2];      // each eye's g (pixels from the picture's corner at clip (-1, -1)) and c (texels)
	vec4 warp1[2];      // each eye's r0 (pixels), m (per pixel), the texels across and down
	vec4 pic;           // the picture's pixels across and down, show, probe
} fovp;
layout(set = 0, binding = 3, std430) buffer Eyes {
	vec4 eyes[12];      // each eye: (el, en), ex, ey, ez, (r, the root of u, r - rho0), (its rows' ends)
};
#if defined(TAIL) || defined(TAIL_VIEW) || defined(TAIL_TILES)
layout(set = 0, binding = 4, rgba16f) uniform restrict image2DArray out_img;
#else
layout(set = 0, binding = 4, rgba16f) uniform restrict writeonly image2DArray out_img;
#endif
// the way out's rows: GEO_XN texels each, eye 0 outward and inward, then eye 1's (geo_xt_texel)
layout(set = 0, binding = 5, rgba32f) uniform restrict image2D xt_img;

#define g_prof fovp.prof
#define g_prof2 fovp.prof2
#define g_tabx fovp.tabx
#define head_l fovp.head_nl.w
#define head_n fovp.head_nl.xyz
#define head_f fovp.head_fr
#define head_pos fovp.head_p.xyz
#define g_lift fovp.floor_.x
#define g_beta fovp.floor_.y
#define lens_body lensp.body
#define lens_n lensp.n.xy

#include_geo_and_look

// the texture's alpha where the texel shows the sky: the farthest a half float holds, past any
// way the tail can meet a body at
#define FOV_SKY 65000.0

// texel id's pixel p (from the picture's corner at clip (-1, -1)), rho its texel's texels from g's,
// the texel's size there in pixels: s along the way from g, k across it; false for a texel the
// filter never takes (beyond the picture by more than one)
bool fov_texel(uvec3 id, out vec2 p, out float rho, out float s, out float k) {
	vec4 w0 = fovp.warp0[id.z], w1 = fovp.warp1[id.z];
	float r0 = w1.x, m = w1.y;
	vec2 q = vec2(id.xy) + 0.5 - w0.zw;
	rho = length(q);
	float t = m * max(rho - r0, 0.0);
	k = rho > r0 ? (r0 + sinh(t) / m) / rho : 1.0;
	s = cosh(t);
	p = w0.xy + k * q;
	return all(lessThan(id.xy, uvec2(w1.zw))) && all(greaterThan(p, vec2(-2.0 * s)))
			&& all(lessThan(p, fovp.pic.xy + 2.0 * s));
}

// show: a coarse texel's tint by its size s in pixels
vec3 fov_tint(float s) {
	return s < 2.0 ? vec3(0.1, 0.8, 0.2) : (s < 3.0 ? vec3(0.95, 0.85, 0.1) : (s < 4.0 ? vec3(1.0, 0.45, 0.05) : vec3(0.9, 0.05, 0.05)));
}

#ifdef EYES
layout(local_size_x = 2, local_size_y = 1, local_size_z = 1) in;
void main() {
	uint v = gl_GlobalInvocationID.x;
	if (v >= 2u) return;
	float el;
	vec3 en;
	vec4 ex, ey, ez;
	geo_eye(fovp.inv_view, fovp.eye_off[v].xyz, el, en, ex, ey, ez);
	float ale = abs(el);
	vec3 eye = vec3(geo_r(ale), sqrt(geo_u(ale)), geo_dr(ale));
	eyes[6u * v] = vec4(el, en);
	eyes[6u * v + 1u] = ex;
	eyes[6u * v + 2u] = ey;
	eyes[6u * v + 3u] = ez;
	eyes[6u * v + 4u] = vec4(eye, 0.0);
	eyes[6u * v + 5u] = vec4(geo_xt_range(ale, eye), 0.0, 0.0);
}
#elif defined(TABLE)
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
void main() {
	int k = int(gl_GlobalInvocationID.x);
	int row = int(gl_GlobalInvocationID.y);
	if (k >= GEO_XN) return;
	uint v = uint(row >> 1);
	vec3 eye = eyes[6u * v + 4u].xyz;
	imageStore(xt_img, ivec2(k, row), geo_xt_texel(abs(eyes[6u * v].x), eye, (row & 1) == 0, eyes[6u * v + 5u].xy, k));
}
#elif defined(TAIL) || defined(TAIL_VIEW) || defined(TAIL_TILES)
// ZoneSections': its IMAGES pass's out (a body's tail's view of it after its images' texels: zone_
// sections.gdshaderinc's IMAGES) and the bodies' rows as Renderer.set_objects has them in its slots
layout(set = 1, binding = 0, rgba32f) uniform restrict readonly image2DArray zone_cull;
layout(set = 1, binding = 1, std140) uniform TailBodies {
	vec4 body[80];      // per slot: C, E1, E2, (size, colour)
} tb;
// TAIL's indirect dispatch: the tiles listed, 1, 1 (TAIL_VIEW sets it, TAIL_TILES counts)
layout(set = 1, binding = 2, std430) restrict buffer TailArgs {
	uint args[4];
} ta;
// each eye's view of each body's tail, the same for all its texels: per eye and body, (b1, the
// sector's half width round the axis with its margins; nought: no tail this frame), and per side and
// strip k (TAIL_STRIPS: the band) the angles off the eye's inward radial it spans and the copies it
// looks into, as zone_tail.gdshader's vertices take them: (least, greatest, first, last), past the
// zone too where first is -1e9 (the band of a body without strips), none where least > greatest;
// then the tiles of 8 x 8 texels TAIL works on (x | y << 12 | eye << 24)
#define FOV_TAIL_MAX 20
#define FOV_TAIL_RANGES (2 * (TAIL_STRIPS + 1))
layout(set = 1, binding = 3, std430) restrict buffer TailData {
	vec4 sec[2 * FOV_TAIL_MAX];
	vec4 rng[2 * FOV_TAIL_MAX * FOV_TAIL_RANGES];
	uint tiles[];
} td;
layout(push_constant, std430) uniform TailKind {
	ivec4 n;            // the zone's balls, its cubes, the cubes' first slot, the images a body (Renderer.ZONE_IMAGES)
	vec4 f;             // psi_min (zone_tail.gdshader's tail_psi_min), the strips drawn (Renderer.tail_strips), 0, 0
} tk;

TailBody fov_tail_body(int s) {
	return tail_body(s >= tk.n.z, tb.body[4 * s], tb.body[4 * s + 1], tb.body[4 * s + 2], tb.body[4 * s + 3].x);
}

int fov_tail_slot(int b) {
	return b < tk.n.x ? b : tk.n.z + b - tk.n.x;
}

// eye v's inward radial direction in the camera's space
vec3 fov_tail_axis(uint v) {
	vec4 ex = eyes[6u * v + 1u], ey = eyes[6u * v + 2u], ez = eyes[6u * v + 3u];
	return normalize((eyes[6u * v].x < 0.0 ? 1.0 : -1.0) * vec3(ex.x, ey.x, ez.x));
}

// the azimuth round the axis ax of direction d off b1, of side 1's sector (round -b1) if side
float fov_tail_azimuth(vec3 d, vec3 ax, vec3 b1, int side) {
	float phi = geo_atan2(dot(d, cross(ax, b1)), dot(d, b1));
	return side == 0 ? phi : (phi > 0.0 ? phi - GEO_PI : phi + GEO_PI);
}

#if defined(TAIL_VIEW)
// An invocation a body and side of eye z's: its sector and its strips' and band's ranges into td
// (from ZoneSections' cull_img, as zone_tail.gdshader's vertices read it); and TAIL's dispatch reset.
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
void main() {
	uint v = gl_WorkGroupID.z;
	int i = int(gl_LocalInvocationIndex);
	if (i == 0 && v == 0u) {
		ta.args[0] = 0u;
		ta.args[1] = 1u;
		ta.args[2] = 1u;
	}
	int b = i >> 1, side = i & 1;
	if (b >= FOV_TAIL_MAX) return;
	int o = int(v) * FOV_TAIL_MAX + b;
	for (int k = 0; k <= TAIL_STRIPS; k++) td.rng[o * FOV_TAIL_RANGES + side * (TAIL_STRIPS + 1) + k] = vec4(1.0, 0.0, 0.0, 0.0);
	if (side == 0) td.sec[o] = vec4(0.0);
	if (b >= tk.n.x + tk.n.y) return;
	int i0 = tk.n.w, sl = fov_tail_slot(b);
	vec4 at = imageLoad(zone_cull, ivec3(i0, sl, v));
	if (at.w < 0.5 || any(notEqual(at.xyz, tb.body[4 * sl].xyz))) return;
	vec4 bw = imageLoad(zone_cull, ivec3(i0 + 1, sl, v));
	vec4 hd = imageLoad(zone_cull, ivec3(i0 + 3, sl, v));
	float half_w = bw.z;
	if (side == 0) {
		vec4 ex = eyes[6u * v + 1u], ey = eyes[6u * v + 2u], ez = eyes[6u * v + 3u];
		vec3 ax = fov_tail_axis(v);
		vec3 u = imageLoad(zone_cull, ivec3(i0 + 2, sl, v)).xyz;
		vec3 b1 = vec3(dot(ex.yzw, u), dot(ey.yzw, u), dot(ez.yzw, u));
		b1 = normalize(b1 - dot(b1, ax) * ax);
		td.sec[o] = vec4(b1, min(min(half_w, GEO_PI) + tail_margins(half_w).x, GEO_PI));
	}
	// a body round the axis: one sector, all of it
	if (side == 1 && half_w >= GEO_PI) return;
	bool strips = tk.f.y > 0.5 && hd.z > 0.5;
	vec2 kk = imageLoad(zone_cull, ivec3(i0 + 4, sl, v)).xy;
	int K = int((side == 1 ? kk.y : kk.x) + 0.5);
	float n0 = side == 1 ? hd.y : hd.x;
	for (int k = 0; k <= TAIL_STRIPS; k++) {
		vec2 range = vec2(1.0, 0.0);
		vec2 copies = vec2(-1e9, 1e9);
		if (strips) {
			if (k < TAIL_STRIPS && k >= K) continue;
			int j = k == TAIL_STRIPS ? K : k;
			vec4 tj = imageLoad(zone_cull, ivec3(i0 + 5 + j, sl, v));
			vec2 sj = side == 1 ? tj.zw : tj.xy;
			if (k == TAIL_STRIPS) {
				range = hd.w > 0.5 ? vec2(bw.x, sj.y) : vec2(sj.x, bw.y);
				copies = vec2(n0 + float(K), 1e9);
			} else {
				range = sj;
				copies = vec2(n0 + float(k));
			}
			range += vec2(-tail_margin(range.x, half_w), tail_margin(range.y, half_w));
		} else if (k == TAIL_STRIPS) {
			float mg = tail_margins(half_w).x;
			range = bw.xy + vec2(-mg, mg);
		} else {
			continue;
		}
		td.rng[o * FOV_TAIL_RANGES + side * (TAIL_STRIPS + 1) + k] = vec4(clamp(range, 0.0, GEO_PI), copies);
	}
}
#elif defined(TAIL_TILES)
// An invocation a tile of 8 x 8 texels of eye z's: listed for TAIL if a cone round its middle's ray
// through its corners' rays reaches into a sector and one of its ranges of any body (all of it a
// hair wider, against the warp's curving of a tile's edges between its corners).
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
vec3 fov_tail_ray(vec2 t, uint v, out bool used) {
	vec4 w0 = fovp.warp0[v], w1 = fovp.warp1[v];
	float r0 = w1.x, m = w1.y;
	vec2 q = t - w0.zw;
	float rho = length(q);
	float tt = m * max(rho - r0, 0.0);
	float k = rho > r0 ? (r0 + sinh(tt) / m) / rho : 1.0;
	float s = cosh(tt);
	vec2 p = w0.xy + k * q;
	used = all(greaterThan(p, vec2(-2.0 * s))) && all(lessThan(p, fovp.pic.xy + 2.0 * s));
	return normalize((fovp.ray[v] * vec4(p / fovp.pic.xy * 2.0 - 1.0, 1.0, 0.0)).xyz);
}
void main() {
	uint v = gl_GlobalInvocationID.z;
	uvec2 nt = (uvec2(fovp.warp1[v].zw) + 7u) / 8u;
	uint t = gl_GlobalInvocationID.x;
	if (t >= nt.x * nt.y) return;
	uvec2 xy = uvec2(t % nt.x, t / nt.x);
	vec2 o = vec2(8u * xy);
	bool u0, u1, u2, u3, u4;
	vec3 dc = fov_tail_ray(o + 4.0, v, u0);
	vec3 d1 = fov_tail_ray(o, v, u1), d2 = fov_tail_ray(o + vec2(8.0, 0.0), v, u2);
	vec3 d3 = fov_tail_ray(o + vec2(0.0, 8.0), v, u3), d4 = fov_tail_ray(o + 8.0, v, u4);
	if (!(u0 || u1 || u2 || u3 || u4)) return;
	float c = min(min(dot(dc, d1), dot(dc, d2)), min(dot(dc, d3), dot(dc, d4)));
	float rad = 1.25 * geo_acos(clamp(c, -1.0, 1.0)) + 1e-4;
	vec3 ax = fov_tail_axis(v);
	float chi = geo_acos(clamp(dot(dc, ax), -1.0, 1.0));
	// the azimuths the cone spans round the axis, off its middle's
	float sc = sin(chi);
	float dphi = chi > rad && GEO_PI - chi > rad ? asin(min(sin(rad) / sc, 1.0)) : GEO_PI;
	int nb = min(tk.n.x + tk.n.y, FOV_TAIL_MAX);
	for (int b = 0; b < nb; b++) {
		int ob = int(v) * FOV_TAIL_MAX + b;
		vec4 sec = td.sec[ob];
		if (sec.w <= 0.0) continue;
		for (int side = 0; side < 2; side++) {
			if (abs(fov_tail_azimuth(dc, ax, sec.xyz, side)) > sec.w + dphi) continue;
			for (int k = 0; k <= TAIL_STRIPS; k++) {
				vec4 rg = td.rng[ob * FOV_TAIL_RANGES + side * (TAIL_STRIPS + 1) + k];
				if (rg.x > rg.y || chi + rad < rg.x || chi - rad > rg.y) continue;
				td.tiles[atomicAdd(ta.args[0], 1u)] = xy.x | (xy.y << 12) | (v << 24);
				return;
			}
		}
	}
}
#else
// TAIL: a workgroup a tile TAIL_TILES listed, an invocation a texel of it.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
shared vec4 s_e[64];
void main() {
	uint tile = td.tiles[gl_WorkGroupID.x];
	uint v = tile >> 24;
	uvec3 id = uvec3(8u * uvec2(tile & 0xfffu, (tile >> 12) & 0xfffu) + gl_LocalInvocationID.xy, v);
	vec4 e = eyes[6u * v];
	vec4 ex = eyes[6u * v + 1u], ey = eyes[6u * v + 2u], ez = eyes[6u * v + 3u];
	vec3 ax = fov_tail_axis(v);
	int nb = min(tk.n.x + tk.n.y, FOV_TAIL_MAX);
	vec2 p;
	float rho, s, k;
	bool used = fov_texel(id, p, rho, s, k) && fovp.pic.w < 0.5;
	// the nearest way into a body among the texel's sectors: its body slot (-1: none), the ray and
	// where on it
	int hit = -1;
	TailRay hz;
	float hy = 0.0, hang = 0.0, best = FOV_SKY;
	int hon = 0;
	if (used) {
		vec2 clip = p / fovp.pic.xy * 2.0 - 1.0;
		vec3 d = normalize((fovp.ray[v] * vec4(clip, 1.0, 0.0)).xyz);
		vec4 D = d.x * ex + d.y * ey + d.z * ez;
		vec3 eye = eyes[6u * v + 4u].xyz;
		best = imageLoad(out_img, ivec3(id)).a;
		float chi = geo_acos(clamp(dot(d, ax), -1.0, 1.0));
		for (int b = 0; b < nb; b++) {
			int ob = int(v) * FOV_TAIL_MAX + b;
			vec4 sec = td.sec[ob];
			if (sec.w <= 0.0) continue;
			int sl = fov_tail_slot(b);
			for (int side = 0; side < 2; side++) {
				if (abs(fov_tail_azimuth(d, ax, sec.xyz, side)) > sec.w) continue;
				for (int st = 0; st <= TAIL_STRIPS; st++) {
					vec4 rg = td.rng[ob * FOV_TAIL_RANGES + side * (TAIL_STRIPS + 1) + st];
					if (rg.x > rg.y || chi < rg.x || chi > rg.y) continue;
					bool far = rg.z < -5e8;
					TailBody q = fov_tail_body(sl);
					TailRay z;
					float y, ang, psi;
					int on;
					if (!tail_ray(e.x, eye, e.yzw, D, tk.f.x, far, z)) continue;
					if (!tail_meet(z, q, tk.f.x, rg.z, rg.w, far, y, ang, psi, on)) continue;
					vec4 P, arrive;
					float len;
					tail_hit(z, y, ang, on, P, arrive, len);
					if (geo_finite(len) && len < best) {
						best = len;
						hit = sl;
						hz = z;
						hy = y;
						hang = ang;
						hon = on;
					}
				}
			}
		}
	}
	// lit as zone_tail.gdshader lights it: a cube's dark edges by the measure's differences within
	// each 2 x 2 square of texels (a fragment shader's fwidth), where the neighbours show the same body
	vec3 col = vec3(0.0);
	float edge = -1.0;
	TailBody q;
	vec4 P = vec4(0.0), arrive = vec4(0.0), Np = vec4(0.0), sh = vec4(0.0), uh = vec4(0.0), qd = vec4(0.0);
	float l = 0.0;
	if (hit >= 0) {
		q = fov_tail_body(hit);
		float len;
		tail_hit(hz, hy, hang, hon, P, arrive, len);
		l = hon == 2 ? hz.dl * (g_prof.w + length(P.xyz) - g_prof2.x) : tail_l(hz, hy);
		Np = geo_normal(P);
		vec4 s4 = look_sun4(l);
		vec4 sun = s4 - dot(s4, Np) * Np;
		vec4 up4 = vec4(0.0, 0.0, 1.0, 0.0) - Np.z * Np;
		sh = sun * inversesqrt(max(dot(sun, sun), 1e-12));
		uh = up4 * inversesqrt(max(dot(up4, up4), 1e-12));
		qd = P - q.C;
		if (q.cube) edge = look_box_edge(vec3(dot(qd, q.E[0]), dot(qd, q.E[1]), dot(qd, q.E[2])) / q.size);
	}
	uvec2 lq = gl_LocalInvocationID.xy;
	s_e[lq.y * 8u + lq.x] = vec4(edge, float(hit), 0.0, 0.0);
	barrier();
	if (hit < 0) return;
	vec3 albedo = tb.body[4 * hit + 3].yzw;
	if (q.cube) {
		uint row = lq.y * 8u + (lq.x & ~1u), cl = (lq.y & ~1u) * 8u + lq.x;
		float dx = s_e[row + 1u].y == s_e[row].y ? s_e[row + 1u].x - s_e[row].x : 0.0;
		float dy = s_e[cl + 8u].y == s_e[cl].y ? s_e[cl + 8u].x - s_e[cl].x : 0.0;
		vec3 box = vec3(dot(qd, q.E[0]), dot(qd, q.E[1]), dot(qd, q.E[2])) / q.size;
		vec3 ab = abs(box);
		int f = ab.x >= ab.y && ab.x >= ab.z ? 0 : (ab.y >= ab.z ? 1 : 2);
		vec4 a = q.E[f] - dot(q.E[f], Np) * Np;
		a *= (box[f] < 0.0 ? -1.0 : 1.0) * inversesqrt(max(dot(a, a), 1e-12));
		col = look_body(albedo, dot(a, sh), dot(a, uh), -dot(a, arrive), l);
		float fw = max(abs(dx) + abs(dy), 1e-5);
		col *= mix(0.45, 1.0, clamp((edge - 0.04) / fw + 0.5, 0.0, 1.0));
	} else {
		vec4 n = qd - dot(qd, Np) * Np;
		n *= inversesqrt(max(dot(n, n), 1e-12));
		col = look_body(albedo, dot(n, sh), dot(n, uh), -dot(n, arrive), l);
	}
	if (!geo_finite(col.r + col.g + col.b)) return;
	if (fovp.pic.z > 0.5 && rho > fovp.warp1[v].x) col = mix(col, fov_tint(s), 0.35);
	imageStore(out_img, ivec3(id), vec4(col, best));
}
#endif
#else
// probe: the pixel's place as phases over this many pixels (floor_sample.gdshader): long beside a
// texel, so that the filter's mix of two neighbours' phases is the phase between them
#define FOV_PROBE 256.0

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
shared vec4 s_a[64];
void main() {
	uvec3 id = gl_GlobalInvocationID;
	uint v = id.z;
	vec2 p;
	float rho, s, k;
	bool used = fov_texel(id, p, rho, s, k);
	float r0 = fovp.warp1[v].x;
	vec3 a = vec3(0.0);
	float edge = -1.0;
	LensSeen sn;
	if (used) {
		// the ray as floor.gdshaderinc's quad has it at that point of the picture
		vec2 clip = p / fovp.pic.xy * 2.0 - 1.0;
		vec3 d = normalize((fovp.ray[v] * vec4(clip, 1.0, 0.0)).xyz);
		vec4 e = eyes[6u * v];
		vec4 D = d.x * eyes[6u * v + 1u] + d.y * eyes[6u * v + 2u] + d.z * eyes[6u * v + 3u];
		// the ray's way out of the zone as geo_exit finds it, its way across from the eye's rows
		vec3 eye = eyes[6u * v + 4u].xyz;
		float ca, sa, b, gap, sigma;
		vec3 tr;
		bool lensed = geo_exit_ray(e.x, eye, e.yzw, D, ca, sa, tr, b, gap, sigma);
		vec3 pos = eye.x * e.yzw, dir = ca * e.yzw + sa * tr;
		float sheet = e.x < 0.0 ? -1.0 : 1.0, way = 0.0;
		if (lensed) {
			float ale = abs(e.x);
			bool outward = ca >= 0.0;
			int xk;
			float x = geo_xt_place(ale, b, gap, sigma, eyes[6u * v + 5u].xy, xk);
			int xrow = 2 * int(v) + (outward ? 0 : 1);
			vec3 w = geo_xt_way(imageLoad(xt_img, ivec2(xk, xrow)), imageLoad(xt_img, ivec2(xk + 1, xrow)), x, ale, eye, b, sigma, gap, outward);
			if (w.z > 0.5) sheet = -sheet;
			geo_exit_at(e.yzw, tr, b, w.x, pos, dir);
			way = w.y;
		}
		// two texels' turn: the quad filters between neighbouring texels (lens_near)
		float ang = length(normalize((fovp.ray[v] * vec4(clip + vec2(4.0 * s / fovp.pic.x, 0.0), 1.0, 0.0)).xyz) - d);
		sn = lens_trace(pos, dir, sheet, way, lensed || lens_near(e.x, eye.x, D, ang));
		a = look_ground_at(lens_floor_xy(pos, dir, sheet));
		edge = dot(sn.box, sn.box) > 0.0 ? look_box_edge(sn.box) : -1.0;
	}
	// a fragment shader's dFdx and dFdy: the differences within each 2 x 2 square of texels
	uvec2 lq = gl_LocalInvocationID.xy;
	s_a[lq.y * 8u + lq.x] = vec4(a, edge);
	barrier();
	if (!used) return;
	uint row = lq.y * 8u + (lq.x & ~1u), col = (lq.y & ~1u) * 8u + lq.x;
	vec4 dx = s_a[row + 1u] - s_a[row];
	vec4 dy = s_a[col + 8u] - s_a[col];
	vec3 c = lens_colour(sn, a, dx.xyz, dy.xyz, vec2(edge, abs(dx.w) + abs(dy.w)), sqrt(s * k));
	if (fovp.pic.z > 0.5 && rho > r0) c = mix(c, fov_tint(s), 0.35);
	vec4 o = vec4(c, sn.kind == 0 ? FOV_SKY : min(sn.way, FOV_SKY));
	if (fovp.pic.w > 0.5) {
		// probe: where this texel's pixel is, as a phase along x and along y (smooth: the filter
		// mixes neighbours' phases into the phase between them)
		vec2 ph = 6.2831853 * p / FOV_PROBE;
		o = vec4(cos(ph.x), sin(ph.x), cos(ph.y), sin(ph.y));
	}
	imageStore(out_img, ivec3(id), o);
}
#endif
