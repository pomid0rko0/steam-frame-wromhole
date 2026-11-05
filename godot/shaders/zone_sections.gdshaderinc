// The meshes of the bodies in the curved zone (balls: zone.gdshaderinc, zone_ball_vertex; cubes:
// zone_cube.gdshaderinc), each node once a frame for each eye, for the bodies' vertex shader
// (body.gdshaderinc, ZONE): a compute shader's body, not a Godot shader's; zone_sections.gd puts the
// header (the version, BALL, CUBE_EDGES, CUBE_PIECES, CUBE_SPANS, CUBE_COLUMNS, CUBE, IMAGES or
// PATHS) before it and geo.gdshaderinc, zone.gdshaderinc and zone_cube.gdshaderinc where it says.
//
// A node's place on the body does not depend on which image of it is drawn, only on the eye (whose
// direction from the centre is the axis the mesh is built round) and the body, so each node of a
// body's two meshes (the fine one, ZONE_FINE images, and the coarse one, the rest) is worked out
// here once per eye, not in each vertex of each of its images. BALL and CUBE: invocation x a node,
// the fine mesh's first, column by column; y: the body, of those in the zone of this kind (slots from
// pc.first.x on); z: the eye. Out: per node two texels of a layer per eye, (l, alpha, t.x, t.y) and
// (t.z, 1 if its steps came out not a number, else 0, 1 if it is no part of the surface (a cube's
// row between two parts of its section: body.gdshaderinc drops it), 0) at x = 2 col and 2 col + 1,
// y = slot * slot_rows + the mesh's first row + row.
//
// A cube's nodes come after four passes of its own (zone_cube.gdshaderinc), each into plan_img (a
// layer per eye, PLAN_ROWS rows a cube's slot) or col_img, on what the one before wrote:
//   CUBE_EDGES: invocation x the edge (zc_edge_near): row 0, texels 2 e, 2 e + 1;
//   CUBE_PIECES: x the edge, its pieces (zc_pieces) from all edges' row 0: row 1, texels 9 e (the
//     count) and 9 e + 1 + 2 k, 9 e + 2 + 2 k (piece k); the axis (zc_axis): texels 108 and 109
//     (the axis the mesh is built round, the later passes' too, and the knots' origin th0);
//   CUBE_SPANS: x the span (the knots, zc_knots, sorted in each): its section (zc_sequence) at its
//     middle, row 3, texels 5 s to 5 s + 4; its columns' (azimuth, the span's middle, the span), row 2;
//   CUBE_COLUMNS: x the column, its items at its azimuth (zc_item) in its span's order: col_img, a
//     row a column (y = slot * (columns + 1) + column), two items a texel;
//   CUBE: the nodes from those (zc_node).
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
layout(set = 0, binding = 6, rgba32f) uniform restrict image2DArray plan_img;   // the cube passes' (above)
layout(set = 0, binding = 7, rgba32f) uniform restrict image2DArray col_img;

#define g_prof zp.prof
#define g_prof2 zp.prof2
#define g_tabx zp.tabx
#define head_l zp.head_nl.w
#define head_n zp.head_nl.xyz
#define head_f zp.head_fr
#define head_pos zp.head_p.xyz
#define g_lift zp.floor_.x

#include_geo_and_zone

const int PLAN_ROWS = 4;            // plan_img's rows a cube's slot (zone_sections.gd's)

// a cube's slot s as zone_cube.gdshaderinc takes it, round the axis en (the eye's direction from the
// centre, or zc_axis's turned)
ZCube zs_cube_at(int s, vec3 en) {
	vec4 C = zb.body[4 * s], E1 = zb.body[4 * s + 1], E2 = zb.body[4 * s + 2];
	vec4 N = geo_normal(C);
	return zc_cube(C, E1, E2, -geo_cross4(E1, E2, N), N, zb.body[4 * s + 3].x, en);
}

// round eye z's axis (en: its direction from the centre)
ZCube zs_cube(int s, int z, out vec3 en) {
	float el;
	vec4 ex, ey, ez;
	geo_eye(zp.inv_view, zp.eye_off[z].xyz, el, en, ex, ey, ez);
	return zs_cube_at(s, en);
}

// round cube ci's (slot s) mesh's axis for eye z (CUBE_PIECES' out)
ZCube zs_cube_mesh(int s, int ci, int z) { return zs_cube_at(s, imageLoad(plan_img, ivec3(109, ci * PLAN_ROWS + 1, z)).xyz); }

// cube ci's (of the zone's: its slot less the cubes' first) pieces and axis (CUBE_PIECES' out)
void zs_pieces(int ci, int z, out ZPieces pcs, out ZAxis ax) {
	int y = ci * PLAN_ROWS + 1;
	for (int e = 0; e < 12; e++) {
		pcs.n[e] = int(imageLoad(plan_img, ivec3(9 * e, y, z)).x);
		for (int k = 0; k < ZC_PIECES; k++) {
			if (k >= pcs.n[e]) break;
			vec4 a = imageLoad(plan_img, ivec3(9 * e + 1 + 2 * k, y, z)), b = imageLoad(plan_img, ivec3(9 * e + 2 + 2 * k, y, z));
			pcs.u[e * ZC_PIECES + k] = a.xyz;
			pcs.t[e * ZC_PIECES + k] = vec3(a.w, b.xy);
		}
	}
	vec4 a = imageLoad(plan_img, ivec3(108, y, z));
	ax.rnd = a.x > 0.5;
	ax.l_in = a.y;
	ax.l_out = a.z;
	ax.aax = a.w;
	ax.en = imageLoad(plan_img, ivec3(109, y, z)).xyz;
}

// cube ci's span's section (CUBE_SPANS' out) from plan_img: an entry id 8 + face + 1
ZSeq zs_seq(int ci, int z, int span) {
	ZSeq sq;
	int y = ci * PLAN_ROWS + 3;
	vec4 h = imageLoad(plan_img, ivec3(5 * span, y, z));
	sq.k = int(h.x);
	sq.n[0] = int(h.y);
	sq.n[1] = int(h.z);
	sq.n[2] = int(h.w);
	for (int j = 0; j < 4; j++) {
		vec4 v = imageLoad(plan_img, ivec3(5 * span + 1 + j, y, z));
		for (int i = 0; i < 4; i++) {
			int code = int(v[i]);
			sq.id[4 * j + i] = code / 8;
			sq.face[4 * j + i] = code % 8 - 1;
		}
	}
	return sq;
}

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
#elif defined(CUBE_EDGES) || defined(CUBE_PIECES)
layout(local_size_x = 16, local_size_y = 1, local_size_z = 1) in;
void main() {
	uvec3 id = gl_GlobalInvocationID;
	int e = int(id.x), z = int(id.z);
	if (e >= 12) return;
	int s = pc.first.x + int(id.y), ci = int(id.y);
	vec3 en;
	ZCube q = zs_cube(s, z, en);
#ifdef CUBE_EDGES
	vec2 ends;
	vec4 near = zc_edge_near(q, e, ends);
	imageStore(plan_img, ivec3(2 * e, ci * PLAN_ROWS, z), near);
	imageStore(plan_img, ivec3(2 * e + 1, ci * PLAN_ROWS, z), vec4(ends, 0.0, 0.0));
#else
	vec4 near[12];
	vec2 ends[12];
	for (int i = 0; i < 12; i++) {
		near[i] = imageLoad(plan_img, ivec3(2 * i, ci * PLAN_ROWS, z));
		ends[i] = imageLoad(plan_img, ivec3(2 * i + 1, ci * PLAN_ROWS, z)).xy;
	}
	ZAxis ax = zc_axis(q, near, ends);
	// round an axis turned off a corner or an edge: this edge near it anew
	vec4 ne = near[e];
	if (ax.en != q.en) {
		q = zs_cube_at(s, ax.en);
		vec2 en_;
		ne = zc_edge_near(q, e, en_);
	}
	vec3 pu[ZC_PIECES], pt[ZC_PIECES];
	int n = zc_pieces(q, e, ne, pu, pt);
	int y = ci * PLAN_ROWS + 1;
	imageStore(plan_img, ivec3(9 * e, y, z), vec4(float(n), 0.0, 0.0, 0.0));
	for (int k = 0; k < ZC_PIECES; k++) {
		if (k >= n) break;
		imageStore(plan_img, ivec3(9 * e + 1 + 2 * k, y, z), vec4(pu[k], pt[k].x));
		imageStore(plan_img, ivec3(9 * e + 2 + 2 * k, y, z), vec4(pt[k].yz, 0.0, 0.0));
	}
	if (e == 0) {
		float th0 = ax.rnd ? 0.0 : geo_atan2(dot(q.C.xyz, q.a2), dot(q.C.xyz, q.a1));
		imageStore(plan_img, ivec3(108, y, z), vec4(ax.rnd ? 1.0 : 0.0, ax.l_in, ax.l_out, ax.aax));
		imageStore(plan_img, ivec3(109, y, z), vec4(ax.en, th0));
	}
#endif
}
#elif defined(CUBE_SPANS)
layout(local_size_x = 32, local_size_y = 1, local_size_z = 1) in;
void main() {
	uvec3 id = gl_GlobalInvocationID;
	int span = int(id.x), z = int(id.z);
	int s = pc.first.x + int(id.y), ci = int(id.y);
	ZCube q = zs_cube_mesh(s, ci, z);
	ZPieces pc_;
	ZAxis ax;
	zs_pieces(ci, z, pc_, ax);
	float th0 = imageLoad(plan_img, ivec3(109, ci * PLAN_ROWS + 1, z)).w;
	float kn[ZC_KNOTS];
	int nk = zc_knots(pc_, ax.rnd, th0, kn);
	int spans = ax.rnd ? nk : nk - 1;
	if (span >= max(spans, 1)) return;
	// its columns: the sharing out's own (zc_column), each column's span found in turn
	float columns = pc.grid.x;
	float mid = 0.0;
	for (int c = 0; c <= 128; c++) {
		if (float(c) > columns) break;
		vec3 col = zc_column(float(c), columns, kn, nk, ax.rnd, th0);
		if (int(col.z) != span) continue;
		mid = col.y;
		imageStore(plan_img, ivec3(c, ci * PLAN_ROWS + 2, z), vec4(col, 0.0));
	}
	ZSeq sq = zc_sequence(q, pc_, ax, mid);
	int y = ci * PLAN_ROWS + 3;
	imageStore(plan_img, ivec3(5 * span, y, z), vec4(float(sq.k), float(sq.n[0]), float(sq.n[1]), float(sq.n[2])));
	for (int j = 0; j < 4; j++) {
		vec4 v;
		for (int i = 0; i < 4; i++) v[i] = float(sq.id[4 * j + i] * 8 + sq.face[4 * j + i] + 1);
		imageStore(plan_img, ivec3(5 * span + 1 + j, y, z), v);
	}
}
#elif defined(CUBE_COLUMNS)
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
void main() {
	uvec3 id = gl_GlobalInvocationID;
	int c = int(id.x), z = int(id.z);
	if (float(c) > pc.grid.x) return;
	int s = pc.first.x + int(id.y), ci = int(id.y);
	ZCube q = zs_cube_mesh(s, ci, z);
	ZPieces pc_;
	ZAxis ax;
	zs_pieces(ci, z, pc_, ax);
	vec4 col = imageLoad(plan_img, ivec3(c, ci * PLAN_ROWS + 2, z));
	ZSeq sq = zs_seq(ci, z, int(col.z));
	vec3 m;
	vec3 t = zc_t(q, col.x, m);
	int ne = 0;
	for (int i = 0; i < ZC_PARTS; i++) {
		if (i < sq.k) ne += sq.n[i];
	}
	int y = ci * (int(pc.grid.x) + 1) + c;
	for (int j = 0; j < ZC_ITEMS / 2; j++) {
		vec2 a = 2 * j < ne ? zc_item(q, pc_, ax, sq.id[2 * j], col.x, t, m) : vec2(0.0);
		vec2 b = 2 * j + 1 < ne ? zc_item(q, pc_, ax, sq.id[2 * j + 1], col.x, t, m) : vec2(0.0);
		imageStore(col_img, ivec3(j, y, z), vec4(a, b));
	}
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
	vec3 t;
	bool none, kill = false;
#ifdef BALL
	vec2 pe = zone_ball_vertex(vec2(float(col) / columns, float(row) / rows), en, zb.body[4 * s], zb.body[4 * s + 3].x, t);
	none = false;
#else
	int ci = int(id.y);
	ZCube q = zs_cube_mesh(s, ci, int(id.z));
	vec4 cv = imageLoad(plan_img, ivec3(int(col), ci * PLAN_ROWS + 2, int(id.z)));
	ZSeq sq = zs_seq(ci, int(id.z), int(cv.z));
	vec2 pos[ZC_ITEMS];
	int yc = ci * (int(columns) + 1) + int(col);
	for (int j = 0; j < ZC_ITEMS / 2; j++) {
		vec4 v = imageLoad(col_img, ivec3(j, yc, int(id.z)));
		pos[2 * j] = v.xy;
		pos[2 * j + 1] = v.zw;
	}
	vec3 mv;
	t = zc_t(q, cv.x, mv);
	vec2 pe = zc_node(q, float(row), rows, sq, pos, t, mv, kill);
	none = !geo_finite(pe.x + pe.y);
#endif
	int y = s * int(pc.grid.w) + (coarse ? int(pc.grid.y) + 1 : 0) + int(row);
	imageStore(out_img, ivec3(2 * int(col), y, int(id.z)), vec4(pe, t.xy));
	imageStore(out_img, ivec3(2 * int(col) + 1, y, int(id.z)), vec4(t.z, none ? 1.0 : 0.0, kill ? 1.0 : 0.0, 0.0));
}
#endif
