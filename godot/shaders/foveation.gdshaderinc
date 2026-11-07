// The floor, the sky and what is seen through the curved zone, for foveation (foveation.gd): a
// compute shader's body, not a Godot shader's; foveation.gd puts the header (the version, EYES,
// TABLE, GRAVITY, TAIL_VIEW, TAIL_TILES, TAIL_QUADS or TAIL with TAIL_CUBES 0 or 1) before it and geo.gdshaderinc, look.gdshaderinc and lens.gdshaderinc where it
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
// a tile); TAIL_QUADS: in those, each texel's strips and bands its ray lies in, into an image, and the
// quads of 2 x 2 texels one of whose rays lies in one listed (an invocation a quad, a workgroup four
// tiles, dispatched by the tiles' count), a list for the balls and one for the cubes; TAIL: those
// quads only, sixteen to a workgroup, packed as a rasterizer packs a primitive's quads, the balls'
// and then in a pass of its own the cubes' (a program each: TAIL_CUBES). A texel looks into the copies of each body whose strip or
// band its ray lies in (TAIL_QUADS' list of them, not looked for again), as
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
#if defined(TAIL) || defined(TAIL_VIEW) || defined(TAIL_TILES) || defined(TAIL_QUADS)
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
#elif defined(TAIL) || defined(TAIL_VIEW) || defined(TAIL_TILES) || defined(TAIL_QUADS)
// ZoneSections': its IMAGES pass's out (a body's tail's view of it after its images' texels: zone_
// sections.gdshaderinc's IMAGES) and the bodies' rows as Renderer.set_objects has them in its slots
layout(set = 1, binding = 0, rgba32f) uniform restrict readonly image2DArray zone_cull;
layout(set = 1, binding = 1, std140) uniform TailBodies {
	vec4 body[80];      // per slot: C, E1, E2, (size, colour)
} tb;
// the indirect dispatches: TAIL_QUADS' (its workgroups, 1, 1, the tiles listed), then TAIL's for the
// balls and for the cubes (its workgroups, 1, 1, the quads listed); TAIL_VIEW sets them, TAIL_TILES
// and TAIL_QUADS count
layout(set = 1, binding = 2, std430) restrict buffer TailArgs {
	uint args[12];
} ta;
// each eye's view of each body's tail, the same for all its texels: per eye and body, (b1, the
// sector's half width round the axis with its margins; nought: no tail this frame), (ax x b1, the
// half width's cosine, -2 for all the way round: fov_tail_ranges), per body its axes E3 and N
// (tail_body_of's: once a frame, not each texel's), and per side and
// strip k (TAIL_STRIPS: the band) the angles off the eye's inward radial it spans and the copies it
// looks into, as zone_tail.gdshader's vertices take them: (least, greatest, first, last), past the
// zone too where first is -1e9 (the band of a body without strips), none where least > greatest;
// then the tiles of 8 x 8 texels listed (x | y << 12 | eye << 24), and from fov_tail_quads(kind) on
// the quads of 2 x 2 texels TAIL works on for the balls (kind 0) and for the cubes (1) (likewise, in
// quads)
#define FOV_TAIL_MAX 20
#define FOV_TAIL_RANGES (2 * (TAIL_STRIPS + 1))
layout(set = 1, binding = 3, std430) restrict buffer TailData {
	vec4 sec[2 * FOV_TAIL_MAX];
	vec4 sec2[2 * FOV_TAIL_MAX];
	vec4 bod[2 * FOV_TAIL_MAX];
	vec4 rng[2 * FOV_TAIL_MAX * FOV_TAIL_RANGES];
	uint lists[];
} td;
// each texel's ranges its ray lies in, as TAIL_QUADS found them for TAIL (texels of the quads it
// listed only): the balls' in x, the cubes' in y, each FOV_TAIL_PICK (body b's range r: b
// FOV_TAIL_RANGES + r) in 9 bits, the first three in the order fov_tail_pick takes them, how many
// (up to 3) from bit 27 on, and bit 29 if there are more (then TAIL looks for them past the third)
layout(set = 1, binding = 4, rg32ui) uniform restrict uimage2DArray pick_img;
layout(push_constant, std430) uniform TailKind {
	ivec4 n;            // the zone's balls, its cubes, the cubes' first slot, the images a body (Renderer.ZONE_IMAGES)
	vec4 f;             // psi_min (zone_tail.gdshader's tail_psi_min), the strips drawn (Renderer.tail_strips), 0, 0
} tk;

int fov_tail_slot(int b) {
	return b < tk.n.x ? b : tk.n.z + b - tk.n.x;
}

// the zone's body b (its slot's row, its other axes as TAIL_VIEW worked them out); in TAIL, a body of
// its program's kind, known as it compiles: the other kind's search is not in it
TailBody fov_tail_body(int b) {
	int s = fov_tail_slot(b);
#ifdef TAIL
	bool cube = TAIL_CUBES == 1;
#else
	bool cube = s >= tk.n.z;
#endif
	return tail_body_of(cube, tb.body[4 * s], tb.body[4 * s + 1], tb.body[4 * s + 2], td.bod[2 * b], td.bod[2 * b + 1], tb.body[4 * s + 3].x);
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

// where in td.lists the quads of a kind (0 balls, 1 cubes) start: past every tile of both eyes, the
// cubes' past as many quads of the balls' (16 a tile)
uint fov_tail_quads(uint kind) {
	uvec2 nt = (uvec2(fovp.warp1[0].zw) + 7u) / 8u;
	return 2u * nt.x * nt.y * (1u + 16u * kind);
}

// the ranges of the bodies whose strip or band, within its sector, the ray d of eye v (off its
// inward radial ax) lies in, as pick_img holds them (the balls', the cubes'). Round the axis by the
// cosine of its way off b1 rather than its angle: the same sector, without an arctangent per body;
// and a cube's only where the ray's plane through the centre (normal nu) meets its 4D box, which its
// sector, by the box's bounding ball, takes wider (a hair wider: the sector's margin round the axis)
uvec2 fov_tail_ranges(vec3 d, uint v, vec3 ax) {
	float chi = geo_acos(clamp(dot(d, ax), -1.0, 1.0));
	vec4 D = d.x * eyes[6u * v + 1u] + d.y * eyes[6u * v + 2u] + d.z * eyes[6u * v + 3u];
	vec3 nu = cross(eyes[6u * v].yzw, D.yzw);
	int nb = min(tk.n.x + tk.n.y, FOV_TAIL_MAX);
	uvec2 w = uvec2(0u);
	for (int b = 0; b < nb; b++) {
		int ob = int(v) * FOV_TAIL_MAX + b;
		vec4 sec = td.sec[ob];
		if (sec.w <= 0.0) continue;
		vec4 s2 = td.sec2[ob];
		float x = dot(d, sec.xyz), y = dot(d, s2.xyz);
		float rc = s2.w * sqrt(x * x + y * y);
		int kind = b < tk.n.x ? 0 : 1;
		if (kind == 1) {
			int sl = fov_tail_slot(b);
			vec3 C = tb.body[4 * sl].xyz;
			float sup = abs(dot(nu, tb.body[4 * sl + 1].xyz)) + abs(dot(nu, tb.body[4 * sl + 2].xyz))
					+ abs(dot(nu, td.bod[2 * b].xyz)) + abs(dot(nu, td.bod[2 * b + 1].xyz));
			if (abs(dot(nu, C)) > tb.body[4 * sl + 3].x * sup + 2e-3 * length(C) * length(nu)) continue;
		}
		for (int side = 0; side < 2; side++) {
			if ((side == 0 ? x : -x) < rc) continue;
			for (int k = 0; k <= TAIL_STRIPS; k++) {
				int r = side * (TAIL_STRIPS + 1) + k;
				vec4 rg = td.rng[ob * FOV_TAIL_RANGES + r];
				if (rg.x > rg.y || chi < rg.x || chi > rg.y) continue;
				uint n = (w[kind] >> 27) & 3u;
				if (n < 3u) w[kind] = (w[kind] & ~(3u << 27)) | (uint(b * FOV_TAIL_RANGES + r) << (9u * n)) | ((n + 1u) << 27);
				else w[kind] |= 1u << 29;
			}
		}
	}
	return w;
}

// texel id's ray, as the texture's pass has it (fov_texel's pixel), false if the filter never takes it
bool fov_tail_texel(uvec3 id, out vec3 d, out vec2 p, out float rho, out float s) {
	float k;
	bool used = fov_texel(id, p, rho, s, k) && fovp.pic.w < 0.5;
	d = normalize((fovp.ray[id.z] * vec4(p / fovp.pic.xy * 2.0 - 1.0, 1.0, 0.0)).xyz);
	return used;
}

#if defined(TAIL_VIEW)
// An invocation a body and side of eye z's: its sector and its strips' and band's ranges into td
// (from ZoneSections' cull_img, as zone_tail.gdshader's vertices read it), and once the body's axes
// E3 and N (fov_tail_body); and TAIL's dispatch reset.
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
void main() {
	uint v = gl_WorkGroupID.z;
	int i = int(gl_LocalInvocationIndex);
	if (i == 0 && v == 0u) {
		ta.args[0] = 0u;
		ta.args[1] = 1u;
		ta.args[2] = 1u;
		ta.args[3] = 0u;
		for (int j = 4; j < 12; j += 4) {
			ta.args[j] = 0u;
			ta.args[j + 1] = 1u;
			ta.args[j + 2] = 1u;
			ta.args[j + 3] = 0u;
		}
	}
	int b = i >> 1, side = i & 1;
	if (b >= FOV_TAIL_MAX) return;
	int o = int(v) * FOV_TAIL_MAX + b;
	for (int k = 0; k <= TAIL_STRIPS; k++) td.rng[o * FOV_TAIL_RANGES + side * (TAIL_STRIPS + 1) + k] = vec4(1.0, 0.0, 0.0, 0.0);
	if (side == 0) {
		td.sec[o] = vec4(0.0);
		td.sec2[o] = vec4(0.0);
	}
	if (b >= tk.n.x + tk.n.y) return;
	int i0 = tk.n.w, sl = fov_tail_slot(b);
	if (v == 0u && side == 0) {
		TailBody q = tail_body(sl >= tk.n.z, tb.body[4 * sl], tb.body[4 * sl + 1], tb.body[4 * sl + 2], tb.body[4 * sl + 3].x);
		td.bod[2 * b] = q.E[2];
		td.bod[2 * b + 1] = q.E[3];
	}
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
		float w = min(min(half_w, GEO_PI) + tail_margins(half_w).x, GEO_PI);
		td.sec[o] = vec4(b1, w);
		td.sec2[o] = vec4(cross(ax, b1), w >= GEO_PI ? -2.0 : geo_cos(w));
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
// An invocation a tile of 8 x 8 texels of eye z's: listed for TAIL_QUADS if a cone round its middle's
// ray through its corners' rays reaches into a sector and one of its ranges of any body (all of it a
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
				uint i = atomicAdd(ta.args[3], 1u);
				td.lists[i] = xy.x | (xy.y << 12) | (v << 24);
				atomicMax(ta.args[0], i / 4u + 1u);
				return;
			}
		}
	}
}
#elif defined(TAIL_QUADS)
// A workgroup four tiles TAIL_TILES listed (a wave of sixteen would leave the most of the headset's
// wave idle), an invocation a quad of 2 x 2 texels of one: each texel's ranges into pick_img
// (fov_tail_ranges), and the quad listed for TAIL's balls if one of its texels' rays lies in a ball's
// strip or band, for its cubes if in a cube's, so that TAIL's waves hold only quads where the tail
// can be, and of one kind of body, as a rasterizer's hold only those a primitive covers (a wave of
// both would go through both searches).
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
void main() {
	uint t = 4u * gl_WorkGroupID.x + (gl_LocalInvocationIndex >> 4);
	if (t >= ta.args[3]) return;
	uint tile = td.lists[t];
	uint v = tile >> 24, l = gl_LocalInvocationIndex & 15u;
	uvec2 q = 4u * uvec2(tile & 0xfffu, (tile >> 12) & 0xfffu) + uvec2(l & 3u, l >> 2);
	vec3 ax = fov_tail_axis(v);
	uint kinds = 0u;
	for (uint j = 0u; j < 4u; j++) {
		vec3 d;
		vec2 p;
		float rho, s;
		uvec3 id = uvec3(2u * q + uvec2(j & 1u, j >> 1), v);
		if (!fov_tail_texel(id, d, p, rho, s)) continue;
		uvec2 w = fov_tail_ranges(d, v, ax);
		imageStore(pick_img, ivec3(id), uvec4(w, 0u, 0u));
		kinds |= (w.x != 0u ? 1u : 0u) | (w.y != 0u ? 2u : 0u);
	}
	for (uint kind = 0u; kind < 2u; kind++) {
		if ((kinds & (1u << kind)) == 0u) continue;
		uint a = 4u + 4u * kind;
		uint i = atomicAdd(ta.args[a + 3u], 1u);
		td.lists[fov_tail_quads(kind) + i] = q.x | (q.y << 12) | (v << 24);
		atomicMax(ta.args[a], i / 16u + 1u);
	}
}
#else
// TAIL: a workgroup 16 quads TAIL_QUADS listed for its kind (TAIL_CUBES: the balls, then in a pass of its
// own the cubes, over what the balls' left: the texture's alpha the way to what a texel shows), an
// invocation a texel of one: the 2 x 2 texels of a quad side by side, as a fragment shader's.
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
shared vec4 s_e[64];
// the texel of invocation lq of a workgroup in quad (as TAIL_QUADS lists it)
uvec3 fov_tail_id(uint quad, uint lq) {
	return uvec3(2u * uvec2(quad & 0xfffu, (quad >> 12) & 0xfffu) + uvec2(lq & 1u, (lq >> 1) & 1u), quad >> 24);
}

// its ray in the camera's space
vec3 fov_tail_dir(uint quad, uint lq) {
	vec2 p;
	float rho, s, k;
	uvec3 id = fov_tail_id(quad, lq);
	fov_texel(id, p, rho, s, k);
	return normalize((fovp.ray[id.z] * vec4(p / fovp.pic.xy * 2.0 - 1.0, 1.0, 0.0)).xyz);
}

// the first range from the from-th on (body b's range r: b FOV_TAIL_RANGES + r) of the sectors of
// the bodies of TAIL's kind that its ray lies in (fov_tail_ranges'), -1 past the last: past the
// three pick_img holds of a texel in more
int fov_tail_pick(uint quad, uint lq, int from) {
	uint v = quad >> 24;
	vec3 d = fov_tail_dir(quad, lq), ax = fov_tail_axis(v);
	float chi = geo_acos(clamp(dot(d, ax), -1.0, 1.0));
	bool cubes = TAIL_CUBES == 1;
	int nb = min(tk.n.x + tk.n.y, FOV_TAIL_MAX);
	int b0 = from / FOV_TAIL_RANGES;
	for (int b = max(b0, cubes ? tk.n.x : 0); b < (cubes ? nb : min(tk.n.x, nb)); b++) {
		int ob = int(v) * FOV_TAIL_MAX + b;
		vec4 sec = td.sec[ob];
		if (sec.w <= 0.0) continue;
		for (int r = b == b0 ? from - b0 * FOV_TAIL_RANGES : 0; r < FOV_TAIL_RANGES; r++) {
			vec4 rg = td.rng[ob * FOV_TAIL_RANGES + r];
			if (rg.x > rg.y || chi < rg.x || chi > rg.y) continue;
			if (abs(fov_tail_azimuth(d, ax, sec.xyz, r / (TAIL_STRIPS + 1))) > sec.w) continue;
			return b * FOV_TAIL_RANGES + r;
		}
	}
	return -1;
}
void main() {
	uint lq = gl_LocalInvocationIndex;
	uint qi = 16u * gl_WorkGroupID.x + (lq >> 2);
	uint kind = uint(TAIL_CUBES);
	bool listed = qi < ta.args[7u + 4u * kind];
	uint quad = listed ? td.lists[fov_tail_quads(kind) + qi] : 0u;
	uint v = quad >> 24;
	bool used;
	{
		vec2 p;
		float rho, s, k;
		used = listed && fov_texel(fov_tail_id(quad, lq), p, rho, s, k) && fovp.pic.w < 0.5;
	}
	// the nearest way into a body among the texel's sectors' ranges: its body slot (-1: none), its
	// colour there as zone_tail.gdshader lights it, and for a cube its dark edges' measure
	// (look_box_edge), whose differences within the quad stand for a fragment shader's fwidth. Range
	// after range (pick_img's, then fov_tail_pick's past them), each shaded at once: through a search
	// only these are kept, the ray worked out again for the next (in a fragment shader its varyings
	// are read again where needed: registers, waves at once)
	int hit = -1;
	bool cube = false;
	vec3 col = vec3(0.0);
	float edge = -1.0;
	float best = used ? imageLoad(out_img, ivec3(fov_tail_id(quad, lq))).a : FOV_SKY;
	uvec2 pw = used ? imageLoad(pick_img, ivec3(fov_tail_id(quad, lq))).xy : uvec2(0u);
	uint word = kind == 1u ? pw.y : pw.x;
	int pick = -1;
	for (int n = 0; used && n < FOV_TAIL_MAX * FOV_TAIL_RANGES; n++) {
		if (uint(n) < ((word >> 27) & 3u)) {
			pick = int((word >> (9u * uint(n))) & 511u);
		} else {
			if ((word >> 29) == 0u) break;
			pick = fov_tail_pick(quad, lq, pick + 1);
			if (pick < 0) break;
		}
		int b = pick / FOV_TAIL_RANGES;
		int ob = int(v) * FOV_TAIL_MAX + b;
		vec4 rg = td.rng[ob * FOV_TAIL_RANGES + pick % FOV_TAIL_RANGES];
		bool far = rg.z < -5e8;
		int sl = fov_tail_slot(b);
		TailBody q = fov_tail_body(b);
		vec3 d = fov_tail_dir(quad, lq);
		vec4 D = d.x * eyes[6u * v + 1u] + d.y * eyes[6u * v + 2u] + d.z * eyes[6u * v + 3u];
		vec4 ev = eyes[6u * v];
		TailRay z;
		float y, ang, psi;
		int on;
		if (!tail_ray(ev.x, eyes[6u * v + 4u].xyz, ev.yzw, D, tk.f.x, far, z)) continue;
		if (!tail_meet(z, q, tk.f.x, rg.z, rg.w, far, y, ang, psi, on)) continue;
		vec4 P, arrive;
		float len;
		tail_hit(z, y, ang, on, P, arrive, len);
		if (!geo_finite(len) || len >= best) continue;
		// lit as zone_tail.gdshader lights it
		float l = on == 2 ? z.dl * (g_prof.w + length(P.xyz) - g_prof2.x) : tail_l(z, y);
		vec4 Np = geo_normal(P);
		vec4 s4 = look_sun4(l);
		vec4 sun = s4 - dot(s4, Np) * Np;
		vec4 up4 = vec4(0.0, 0.0, 1.0, 0.0) - Np.z * Np;
		vec4 sh = sun * inversesqrt(max(dot(sun, sun), 1e-12));
		vec4 uh = up4 * inversesqrt(max(dot(up4, up4), 1e-12));
		vec4 qd = P - q.C;
		vec3 albedo = tb.body[4 * sl + 3].yzw;
		vec4 nn;
		float ed = -1.0;
		if (q.cube) {
			vec3 box = vec3(dot(qd, q.E[0]), dot(qd, q.E[1]), dot(qd, q.E[2])) / q.size;
			vec3 ab = abs(box);
			int f = ab.x >= ab.y && ab.x >= ab.z ? 0 : (ab.y >= ab.z ? 1 : 2);
			nn = q.E[f] - dot(q.E[f], Np) * Np;
			nn *= box[f] < 0.0 ? -1.0 : 1.0;
			ed = look_box_edge(box);
		} else {
			nn = qd - dot(qd, Np) * Np;
		}
		nn *= inversesqrt(max(dot(nn, nn), 1e-12));
		vec3 c = look_body(albedo, dot(nn, sh), dot(nn, uh), -dot(nn, arrive), l);
		if (!geo_finite(c.r + c.g + c.b)) continue;
		best = len;
		hit = sl;
		cube = q.cube;
		col = c;
		edge = ed;
	}
	s_e[lq] = vec4(edge, float(hit), 0.0, 0.0);
	barrier();
	if (hit < 0) return;
	if (cube) {
		// the quad's texels: 0 (x, y), 1 (x + 1, y), 2 (x, y + 1), 3 (x + 1, y + 1)
		uint qb = lq & ~3u, row = qb + (lq & 2u), cl = qb + (lq & 1u);
		float dx = s_e[row + 1u].y == s_e[row].y ? s_e[row + 1u].x - s_e[row].x : 0.0;
		float dy = s_e[cl + 2u].y == s_e[cl].y ? s_e[cl + 2u].x - s_e[cl].x : 0.0;
		float fw = max(abs(dx) + abs(dy), 1e-5);
		col *= mix(0.45, 1.0, clamp((edge - 0.04) / fw + 0.5, 0.0, 1.0));
	}
	uvec3 id = fov_tail_id(quad, lq);
	if (fovp.pic.z > 0.5) {
		vec2 p;
		float rho, s, k;
		fov_texel(id, p, rho, s, k);
		if (rho > fovp.warp1[v].x) col = mix(col, fov_tint(s), 0.35);
	}
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
