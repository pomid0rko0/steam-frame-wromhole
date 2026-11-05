// The meshes of the bodies in the curved zone (zone.gdshaderinc, zone_vertex), each node once a
// frame for each eye, for the bodies' vertex shader (body.gdshaderinc, ZONE): a compute shader's
// body, not a Godot shader's; zone_sections.gd puts the header (the version, BALL, CUBE, IMAGES or
// PATHS) before it and geo.gdshaderinc and zone.gdshaderinc where it says.
//
// A node's place on the body does not depend on which image of it is drawn, only on the eye (whose
// direction from the centre is the axis the mesh is built round) and the body, so each node of a
// body's two meshes (the fine one, ZONE_FINE images, and the coarse one, the rest) is worked out
// here once per eye, not in each vertex of each of its images. Invocation x: a node, the fine mesh's
// first, column by column (a column's nodes share a half-surface: a cube's corners there); y: the
// body, of those in the zone of this kind (slots from pc.first.x on); z: the eye.
// Out: per node two texels of a layer per eye, (l, alpha, t.x, t.y) and (t.z, 1 if zone_vertex's
// steps came out not a number, else 0, 0, 0) at x = 2 col
// and 2 col + 1, y = slot * slot_rows + the mesh's first row + row.
//
// IMAGES: which images of each body are drawn at all. An image thinner across than a quarter of a
// pixel (ZoneSections.CULL_PX: the stereo test's rays a quarter of a pixel off a pixel's centre
// each way don't all meet it, so it counts for no pixel) is left out: next to the photon sphere and
// round the throat most of a small body's 20 are (a hand's ball's, seen from beside the zone, all
// but the first). How thick: the images of the points the body's reach off its centre in the ray's
// plane, along l and along alpha, and the angle between each pair's directions; a pixel there: its
// angle at the picture's middle times cos^2 of the way off it. Invocation x: the image, y: the body
// (the zone's balls, then its cubes), z: the eye. Out: a texel per image, body's slot and eye,
// (the centre's x, y, z the body was taken at, 1 if drawn, else 0): the vertex shader draws an
// image only where it says 1 for the centre its instance has.
//
// PATHS: each body's table of the ways from each eye (zone.gdshaderinc, «the paths by a table»),
// after IMAGES: a node by geo_see_to's search, only the turns up to the last image drawn needs.
// Invocation x: the node (along l, then q), y: the body (as IMAGES), z: the eye. Out: a layer per
// eye, a node a texel at (k, slot * ZONE_PL + i), the body's frame at (ZONE_PQ, slot * ZONE_PL).

layout(set = 0, binding = 0) uniform sampler2D g_tab;   // geo.gdshaderinc names it; not read here
layout(set = 0, binding = 1, std140) uniform Params {
	vec4 prof;          // g_prof
	vec4 prof2;         // g_prof2
	vec4 tabx;          // g_tabx
	vec4 head_nl;       // head_n, head_l
	vec4 head_p;        // head_pos
	vec4 head_fr[3];    // head_f
	vec4 floor_;        // (g_lift, g_beta)
	mat4 inv_view;      // INV_VIEW_MATRIX
	vec4 eye_off[2];    // each eye's EYE_OFFSET
	vec4 px;            // a pixel's angle at the middle of each eye's picture, rad; what share of one is culled
} zp;
layout(set = 0, binding = 2, std140) uniform Bodies {
	vec4 body[80];      // per slot: C, E1, E2, (size, 0, 0, 0)
} zb;
layout(push_constant, std430) uniform Kind {
	vec4 grid;          // this kind's meshes: columns, the fine one's rows, the coarse one's, a slot's rows
	ivec4 first;        // its first slot
} pc;
layout(set = 0, binding = 3, rgba32f) uniform restrict writeonly image2DArray out_img;
layout(set = 0, binding = 4, rgba32f) uniform restrict image2DArray cull_img;   // IMAGES' out, PATHS' in
layout(set = 0, binding = 5, rgba32f) uniform restrict writeonly image2DArray path_img;   // PATHS' out

#define g_prof zp.prof
#define g_prof2 zp.prof2
#define g_tabx zp.tabx
#define head_l zp.head_nl.w
#define head_n zp.head_nl.xyz
#define head_f zp.head_fr
#define head_pos zp.head_p.xyz
#define g_lift zp.floor_.x

#include_geo_and_zone

#if defined(PATHS)
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
void main() {
	uvec3 id = gl_GlobalInvocationID;
	int balls = pc.first.x, all = pc.first.x + pc.first.y;
	if (id.x >= uint(ZONE_PL * ZONE_PQ) || int(id.y) >= all) return;
	bool cube = int(id.y) >= balls;
	int s = cube ? pc.first.z + int(id.y) - balls : int(id.y);
	int i = int(id.x) / ZONE_PQ, k = int(id.x) % ZONE_PQ;
	vec4 C = zb.body[4 * s];
	float size = zb.body[4 * s + 3].x;
	vec4 f = zone_path_frame(C, cube ? 1.8 * size : size, GEO_PI * float(pc.first.w));
	if (id.x == 0u) imageStore(path_img, ivec3(ZONE_PQ, s * ZONE_PL, int(id.z)), f);
	// the nodes the images IMAGES draws need: image j turns by pi j to pi (j + 1), and a vertex takes
	// the nodes up to the third past its own
	int last = -1;
	for (int j = 0; j < pc.first.w; j++) {
		if (imageLoad(cull_img, ivec3(j, s, int(id.z))).w > 0.5) last = j;
	}
	float pm = GEO_PI * float(last + 1);
	if (last < 0 || float(k) > log(pm + sqrt(pm * pm + 1.0)) / f.z + 3.0) return;
	float el;
	vec3 en;
	vec4 ex, ey, ez;
	geo_eye(zp.inv_view, zp.eye_off[id.z].xyz, el, en, ex, ey, ez);
	vec2 at = zone_path_at(f, i, k);
	vec4 node = zone_path_node(el, en, at.x, at.y);
	imageStore(path_img, ivec3(k, s * ZONE_PL + i, int(id.z)), node);
}
#elif defined(IMAGES)
// image j's direction (a tangent vector at the eye) of the point at l, alpha off the eye's axis
// toward t (alpha past 0 or pi: on the far side, toward -t)
vec4 zs_see(float el, vec3 en, float pl, vec3 t, float a, int j) {
	if (a < 0.0) {
		a = -a;
		t = -t;
	}
	if (a > GEO_PI) {
		a = 2.0 * GEO_PI - a;
		t = -t;
	}
	vec2 sc = geo_sincos(a);
	float len, fell;
	vec4 arrive;
	return geo_see_image(el, en, pl, sc.y * en + sc.x * t, t, a, j, len, arrive, fell);
}

// the angle between two directions, small: their unit vectors' distance
float zs_apart(vec4 a, vec4 b) { return length(a / length(a) - b / length(b)); }

layout(local_size_x = 32, local_size_y = 1, local_size_z = 1) in;
void main() {
	uvec3 id = gl_GlobalInvocationID;
	int j = int(id.x);
	int balls = pc.first.x, all = pc.first.x + pc.first.y;
	if (j >= pc.first.w || int(id.y) >= all) return;
	bool cube = int(id.y) >= balls;
	int s = cube ? pc.first.z + int(id.y) - balls : int(id.y);
	vec4 C = zb.body[4 * s];
	float size = zb.body[4 * s + 3].x;
	float reach = cube ? size * 1.7320508 : size;
	float el;
	vec3 en;
	vec4 ex, ey, ez;
	geo_eye(zp.inv_view, zp.eye_off[id.z].xyz, el, en, ex, ey, ez);
	vec3 n;
	float pl = geo_l_of(C, n);
	float ca = dot(n, en);
	vec3 across = n - ca * en;
	float sa = length(across);
	vec3 t = sa > 1e-7 ? across / sa : normalize(cross(en, abs(en.z) < 0.9 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0)));
	float alpha = geo_atan2(sa, ca);
	vec4 d0 = zs_see(el, en, pl, t, alpha, j);
	float da = min(reach / geo_r(abs(pl)), 0.5 * GEO_PI);
	float thick = max(zs_apart(zs_see(el, en, pl, t, alpha + da, j), zs_see(el, en, pl, t, alpha - da, j)),
			zs_apart(zs_see(el, en, pl + reach, t, alpha, j), zs_see(el, en, pl - reach, t, alpha, j)));
	float c = -dot(d0, ez) / length(d0);
	float px = (id.z == 0u ? zp.px.x : zp.px.y) * max(c * c, 0.0);
	// not a number anywhere: drawn
	bool drawn = !geo_finite(thick + c) || thick >= zp.px.z * px;
	imageStore(cull_img, ivec3(j, s, int(id.z)), vec4(C.xyz, drawn ? 1.0 : 0.0));
}
#else
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
void main() {
	uvec3 id = gl_GlobalInvocationID;
	float columns = pc.grid.x;
	uint fine = uint(columns + 1.0) * uint(pc.grid.y + 1.0);
	uint nodes = fine + uint(columns + 1.0) * uint(pc.grid.z + 1.0);
	if (id.x >= nodes) return;
	bool coarse = id.x >= fine;
	float rows = coarse ? pc.grid.z : pc.grid.y;
	uint m = coarse ? id.x - fine : id.x;
	uint col = m / uint(rows + 1.0), row = m % uint(rows + 1.0);
	int s = pc.first.x + int(id.y);
	float el;
	vec3 en;
	vec4 ex, ey, ez;
	geo_eye(zp.inv_view, zp.eye_off[id.z].xyz, el, en, ex, ey, ez);
	vec4 C = zb.body[4 * s], E1 = zb.body[4 * s + 1], E2 = zb.body[4 * s + 2];
	float size = zb.body[4 * s + 3].x;
	vec4 N = geo_normal(C);
	vec4 E3 = -geo_cross4(E1, E2, N);
	vec3 t;
	bool none;
#ifdef BALL
	vec2 pe = zone_vertex(vec2(float(col) / columns, float(row) / rows), columns, rows, true, en, C, E1, E2, E3, N, size, t, none);
#else
	vec2 pe = zone_vertex(vec2(float(col) / columns, float(row) / rows), columns, rows, false, en, C, E1, E2, E3, N, size, t, none);
#endif
	int y = s * int(pc.grid.w) + (coarse ? int(pc.grid.y) + 1 : 0) + int(row);
	imageStore(out_img, ivec3(2 * int(col), y, int(id.z)), vec4(pe, t.xy));
	imageStore(out_img, ivec3(2 * int(col) + 1, y, int(id.z)), vec4(t.z, none ? 1.0 : 0.0, 0.0, 0.0));
}
#endif
