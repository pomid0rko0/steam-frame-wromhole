// The meshes of the bodies in the curved zone (balls: zone.gdshaderinc, zone_ball_vertex; cubes:
// zone_cube.gdshaderinc), each node once a frame for each eye, for the bodies' vertex shader
// (body.gdshaderinc, ZONE): a compute shader's body, not a Godot shader's; zone_sections.gd puts the
// header (the version, BALL, CUBE_EDGES, CUBE_SPANS, CUBE_COLUMNS, CUBE, IMAGES or
// PATHS) before it and geo.gdshaderinc, zone.gdshaderinc, zone_cube.gdshaderinc and
// zone_tail.gdshaderinc where it says.
//
// A node's place on the body does not depend on which image of it is drawn, only on the eye (whose
// direction from the centre is the axis the mesh is built round) and the body, so each node of a
// body's two meshes (the fine one, ZONE_FINE images, and the coarse one, the rest) is worked out
// here once per eye, not in each vertex of each of its images. BALL and CUBE: invocation x a node,
// the fine mesh's first, column by column; y: the body, of those in the zone of this kind (slots from
// pc.first.x on); z: the eye. Out: per node two texels of a layer per eye, (l, alpha, t.x, t.y) and
// (t.z, 1 if its steps came out not a number, else 0, 1 if it is no part of the surface (a cube's
// row between two parts of its section: body.gdshaderinc drops it), its column's side of a knot
// (zc_side; a ball's 0)) at x = 2 col and 2 col + 1, y = slot * slot_rows + the mesh's first row +
// row.
//
// A cube's nodes come after three passes of its own (zone_cube.gdshaderinc), each into plan_img (a
// layer per eye, PLAN_ROWS rows a cube's slot) or col_img, on what the one before wrote:
//   CUBE_EDGES: a workgroup a cube and eye: its edges near the axis (zc_edge_near's stages side by
//     side: an invocation a point of an edge, then one a fold or the point nearest the axis), the axis
//     (zc_axis; round one turned the edges again), then x the edge, its pieces (zc_pieces): row 1,
//     texels 9 e (the count) and 9 e + 1 + 2 k, 9 e + 2 + 2 k (piece k); the axis: texels 108 and
//     109 (the axis the mesh is built round, the later passes' too, and the knots' origin th0);
//   CUBE_SPANS: a workgroup a span (ZC_SPANS of them; the knots, zc_knots, sorted in each): its
//     section (zc_sequence's stages) at its middle (zc_span_mid), its items' places and its faces'
//     joins (zc_margin) side by side, row 3, texels 5 s to 5 s + 4; the knots (span 0's), row 2,
//     their count at PLAN_KNOTS and four a texel after it;
//   CUBE_COLUMNS: x the column's pair of items (ZC_ITEMS / 2 a column, so that a column's items are
//     worked out side by side, not one after another): the column (zc_column of the knots), its
//     (azimuth, its span's middle, its span) in row 2 (the pair 0's invocation); its two items at its
//     azimuth (zc_item_of, their pieces only read) in its span's order: col_img, a row a column (y =
//     slot * (columns + 1) + column), two items a texel;
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
// image only where it says 1 for the centre its instance has. And invocation x = images: the
// tail's view of the body from the eye (zone_tail.gdshaderinc: its band off the inward radial,
// tail_band, past the last image, and its two sectors round it, tail_sector), once a frame for the
// tail's sectors (zone_tail.gdshader), not in each of their vertices: five texels after the
// images', (the centre's x, y, z, 1), (the band's least and greatest angle, the sectors' half
// width, 0), (their direction u, 0), (its strips' first copy each side, 1 if it has strips, 1 if
// they are outward: tail_strips), (how many of its strips are drawn each side, 0, 0: PATHS works
// them out from the strips); and x = images + 1 + k, its strip k (tail_strip, k up to TAIL_STRIPS:
// the last only where the band starts if every strip before it is apart), the texel after those,
// (side 0's least and greatest angle, side 1's).
//
// PATHS: each body's table of the ways from each eye (zone.gdshaderinc, «the paths by a table»),
// after IMAGES: a node by geo_see_to's search, only the turns up to the last image drawn needs.
// Invocation x: the node (along l, then q), y: the body (as IMAGES), z: the eye. Out: a layer per
// eye, a node a texel at (k, slot * ZONE_PL + i), the body's frame at (ZONE_PQ, slot * ZONE_PL). Its
// invocation x = 0 also: how many of the body's tail's strips are drawn (tail_apart), from IMAGES'.

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
const int PLAN_KNOTS = 135;         // row 2's texel of the knots' count, ZC_KNOTS / 4 of them after it (to PLAN_W)

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

// round cube ci's (slot s) mesh's axis for eye z (CUBE_EDGES' out)
ZCube zs_cube_mesh(int s, int ci, int z) { return zs_cube_at(s, imageLoad(plan_img, ivec3(109, ci * PLAN_ROWS + 1, z)).xyz); }

// cube ci's (of the zone's: its slot less the cubes' first) pieces and axis (CUBE_EDGES' out)
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

// cube ci's piece it's ends' u and azimuths (CUBE_EDGES' out, zs_pieces' one)
void zs_piece(int ci, int z, int it, out vec3 u, out vec3 t) {
	int y = ci * PLAN_ROWS + 1, e = it / ZC_PIECES, k = it % ZC_PIECES;
	vec4 a = imageLoad(plan_img, ivec3(9 * e + 1 + 2 * k, y, z)), b = imageLoad(plan_img, ivec3(9 * e + 2 + 2 * k, y, z));
	u = a.xyz;
	t = vec3(a.w, b.xy);
}

// cube ci's axis (CUBE_EDGES' out, zs_pieces' ax)
ZAxis zs_axis(int ci, int z) {
	int y = ci * PLAN_ROWS + 1;
	vec4 a = imageLoad(plan_img, ivec3(108, y, z));
	ZAxis ax;
	ax.rnd = a.x > 0.5;
	ax.l_in = a.y;
	ax.l_out = a.z;
	ax.aax = a.w;
	ax.en = imageLoad(plan_img, ivec3(109, y, z)).xyz;
	return ax;
}

// cube ci's knots (CUBE_SPANS' out), their count
int zs_knots(int ci, int z, out float kn[ZC_KNOTS]) {
	int y = ci * PLAN_ROWS + 2;
	int nk = int(imageLoad(plan_img, ivec3(PLAN_KNOTS, y, z)).x);
	for (int i = 0; i < ZC_KNOTS / 4; i++) {
		vec4 v = 4 * i < nk ? imageLoad(plan_img, ivec3(PLAN_KNOTS + 1 + i, y, z)) : vec4(0.0);
		kn[4 * i] = v.x;
		kn[4 * i + 1] = v.y;
		kn[4 * i + 2] = v.z;
		kn[4 * i + 3] = v.w;
	}
	return nk;
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
	if (id.x == 0u) {
		imageStore(path_img, ivec3(ZONE_PQ, s * ZONE_PL, int(id.z)), f);
		int i0 = pc.first.w;
		float half_w = imageLoad(cull_img, ivec3(i0 + 1, s, int(id.z))).z;
		vec2 sa[TAIL_STRIPS + 1], sb[TAIL_STRIPS + 1];
		for (int j = 0; j <= TAIL_STRIPS; j++) {
			vec4 v = imageLoad(cull_img, ivec3(i0 + 5 + j, s, int(id.z)));
			sa[j] = v.xy;
			sb[j] = v.zw;
		}
		imageStore(cull_img, ivec3(i0 + 4, s, int(id.z)), vec4(float(tail_apart(sa, half_w)), float(tail_apart(sb, half_w)), 0.0, 0.0));
	}
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
#elif defined(CUBE_EDGES)
// a workgroup a cube and eye: its edges near the axis (zc_edge_near's stages side by side: the 9
// points of each, then each's folds and point nearest the axis), the axis (zc_axis) and, round an
// axis turned, the edges anew; then each edge's pieces (zc_pieces)
layout(local_size_x = 128, local_size_y = 1, local_size_z = 1) in;
shared vec2 s_gh[12 * 9];
shared float s_rh[12 * 9];
shared float s_fold[12 * 2];
shared vec2 s_low[12];
shared vec3 s_en;
shared bool s_turned;
// edge e's zc_edge_near and its ends' rho from the shared stages
vec4 zs_near(int e, out vec2 ends) {
	ends = vec2(s_rh[e * 9], s_rh[e * 9 + 8]);
	vec2 lw = s_low[e];
	return vec4(lw.x, lw.x > -2.0 ? lw.y : min(ends.x, ends.y), s_fold[2 * e], s_fold[2 * e + 1]);
}
void main() {
	int tid = int(gl_LocalInvocationID.x), z = int(gl_GlobalInvocationID.z);
	int s = pc.first.x + int(gl_GlobalInvocationID.y), ci = int(gl_GlobalInvocationID.y);
	vec3 en;
	ZCube q = zs_cube(s, z, en);
	ZAxis ax;
	for (int round = 0; round < 2; round++) {
		if (tid < 12 * 9) s_gh[tid] = zc_edge_sample(q, tid / 9, tid % 9, s_rh[tid]);
		barrier();
		if (tid < 12 * 3) {
			int e = tid / 3, r = tid % 3;
			vec2 gh[9];
			for (int i = 0; i < 9; i++) gh[i] = s_gh[e * 9 + i];
			if (r < 2) s_fold[2 * e + r] = zc_edge_fold(q, e, gh, r);
			else s_low[e] = zc_edge_low(q, e, gh);
		}
		barrier();
		// the axis from the edges round the eye's; round it, if turned, the edges again
		if (round == 0 && tid == 0) {
			vec4 near[12];
			vec2 ends[12];
			for (int e = 0; e < 12; e++) near[e] = zs_near(e, ends[e]);
			ax = zc_axis(q, near, ends);
			s_en = ax.en;
			s_turned = ax.en != q.en;
		}
		barrier();
		if (round == 1 || !s_turned) break;
		q = zs_cube_at(s, s_en);
	}
	if (tid >= 12) return;
	int e = tid;
	vec3 pu[ZC_PIECES], pt[ZC_PIECES];
	vec2 ends;
	int n = zc_pieces(q, e, zs_near(e, ends), pu, pt);
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
}
#elif defined(CUBE_SPANS)
// a workgroup a span: its section's stages (zc_sequence's) side by side, through shared memory
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
shared bool s_go;
shared float s_th;
shared int s_ni, s_first;
shared int s_ids[ZC_ITEMS], s_fm[ZC_ITEMS];
shared vec2 s_pos[ZC_ITEMS];
shared int s_onf[6 * ZC_ITEMS], s_nof[6];
shared float s_mg[6 * ZC_ITEMS];
void main() {
	int span = int(gl_WorkGroupID.x), tid = int(gl_LocalInvocationID.x), z = int(gl_GlobalInvocationID.z);
	int s = pc.first.x + int(gl_GlobalInvocationID.y), ci = int(gl_GlobalInvocationID.y);
	ZCube q = zs_cube_mesh(s, ci, z);
	ZAxis ax = zs_axis(ci, z);
	// the knots (span 0 keeps them for CUBE_COLUMNS), the span's middle, its items
	if (tid == 0) {
		ZPieces pc_;
		ZAxis ax_;
		zs_pieces(ci, z, pc_, ax_);
		float th0 = imageLoad(plan_img, ivec3(109, ci * PLAN_ROWS + 1, z)).w;
		float kn[ZC_KNOTS];
		int nk = zc_knots(pc_, ax.rnd, th0, kn);
		if (span == 0) {
			int y2 = ci * PLAN_ROWS + 2;
			imageStore(plan_img, ivec3(PLAN_KNOTS, y2, z), vec4(float(nk), 0.0, 0.0, 0.0));
			for (int i = 0; i < ZC_KNOTS / 4; i++) {
				if (4 * i >= nk) break;
				imageStore(plan_img, ivec3(PLAN_KNOTS + 1 + i, y2, z), vec4(kn[4 * i], kn[4 * i + 1], kn[4 * i + 2], kn[4 * i + 3]));
			}
		}
		int spans = ax.rnd ? nk : nk - 1;
		s_go = span < max(spans, 1);
		if (s_go) {
			float th = zc_span_mid(span, kn, nk, ax.rnd, th0);
			int ids[ZC_ITEMS], fm[ZC_ITEMS];
			int first;
			s_ni = zc_seq_items(pc_, ax, th, ids, fm, first);
			s_first = first;
			s_th = th;
			for (int i = 0; i < ZC_ITEMS; i++) {
				s_ids[i] = ids[i];
				s_fm[i] = fm[i];
			}
		}
	}
	barrier();
	if (!s_go) return;
	float th = s_th;
	int ni = s_ni;
	vec3 m;
	vec3 t = zc_t(q, th, m);
	// each item's place
	if (tid < ni) {
		int it = s_ids[tid];
		vec3 pu = vec3(0.0), pt = vec3(0.0);
		if (it < ZC_IN) zs_piece(ci, z, it, pu, pt);
		int f = s_fm[tid];
		s_pos[tid] = zc_seq_pos(q, ax, it, pu, pt, th, t, m, f);
		s_fm[tid] = f;
	}
	barrier();
	// each face's items in order
	if (tid < 6) {
		int fm[ZC_ITEMS];
		vec2 pos[ZC_ITEMS];
		for (int i = 0; i < ZC_ITEMS; i++) {
			fm[i] = s_fm[i];
			pos[i] = s_pos[i];
		}
		int o[ZC_ITEMS];
		s_nof[tid] = zc_seq_face(q, t, tid, fm, pos, ni, o);
		for (int j = 0; j < ZC_ITEMS; j++) s_onf[tid * ZC_ITEMS + j] = o[j];
	}
	barrier();
	// the margins between each two in turn
	for (int x = tid; x < 6 * ZC_ITEMS; x += 64) {
		int f = x / ZC_ITEMS, j = x % ZC_ITEMS;
		s_mg[x] = j < s_nof[f] - 1 ? zc_margin(q, s_pos[s_onf[x]], s_pos[s_onf[min(x + 1, 6 * ZC_ITEMS - 1)]], f, t) : 0.0;
	}
	barrier();
	if (tid != 0) return;
	int ids[ZC_ITEMS], fm[ZC_ITEMS];
	for (int i = 0; i < ZC_ITEMS; i++) {
		ids[i] = s_ids[i];
		fm[i] = s_fm[i];
	}
	int onf[6 * ZC_ITEMS];
	float mg[6 * ZC_ITEMS];
	for (int x = 0; x < 6 * ZC_ITEMS; x++) {
		onf[x] = s_onf[x];
		mg[x] = s_mg[x];
	}
	int nof[6];
	for (int f = 0; f < 6; f++) nof[f] = s_nof[f];
	ZSeq sq = zc_seq_walk(ids, fm, ni, s_first, onf, nof, mg);
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
	int c = int(id.x) / (ZC_ITEMS / 2), j = int(id.x) % (ZC_ITEMS / 2), z = int(id.z);
	if (float(c) > pc.grid.x) return;
	int s = pc.first.x + int(id.y), ci = int(id.y);
	ZCube q = zs_cube_mesh(s, ci, z);
	ZAxis ax = zs_axis(ci, z);
	// the column: the sharing out's own (zc_column) of the knots
	float th0 = imageLoad(plan_img, ivec3(109, ci * PLAN_ROWS + 1, z)).w;
	float kn[ZC_KNOTS];
	int nk = zs_knots(ci, z, kn);
	vec3 col = zc_column(float(c), pc.grid.x, kn, nk, ax.rnd, th0);
	if (j == 0) imageStore(plan_img, ivec3(c, ci * PLAN_ROWS + 2, z), vec4(col, 0.0));
	ZSeq sq = zs_seq(ci, z, int(col.z));
	vec3 m;
	vec3 t = zc_t(q, col.x, m);
	int ne = 0;
	for (int i = 0; i < ZC_PARTS; i++) {
		if (i < sq.k) ne += sq.n[i];
	}
	int y = ci * (int(pc.grid.x) + 1) + c;
	vec2 ab[2];
	for (int h = 0; h < 2; h++) {
		int it = sq.id[2 * j + h];
		vec3 pu = vec3(0.0), pt = vec3(0.0);
		if (2 * j + h < ne && it < ZC_IN) zs_piece(ci, z, it, pu, pt);
		ab[h] = 2 * j + h < ne ? zc_item_of(q, ax, it, pu, pt, col.x, t, m) : vec2(0.0);
	}
	imageStore(col_img, ivec3(j, y, z), vec4(ab[0], ab[1]));
}
// The cube's passes as they were before their stages went side by side, one invocation an edge, a
// span, a column (CUBE_OLD_*: the speed check's control, ZoneSections.cube_old; the same out)
#elif defined(CUBE_OLD_EDGES) || defined(CUBE_OLD_PIECES)
layout(local_size_x = 16, local_size_y = 1, local_size_z = 1) in;
void main() {
	uvec3 id = gl_GlobalInvocationID;
	int e = int(id.x), z = int(id.z);
	if (e >= 12) return;
	int s = pc.first.x + int(id.y), ci = int(id.y);
	vec3 en;
	ZCube q = zs_cube(s, z, en);
#ifdef CUBE_OLD_EDGES
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
#elif defined(CUBE_OLD_SPANS)
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
#elif defined(CUBE_OLD_COLUMNS)
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
	if (j > pc.first.w + 1 + TAIL_STRIPS || int(id.y) >= all) return;
	bool cube = int(id.y) >= balls;
	int s = cube ? pc.first.z + int(id.y) - balls : int(id.y);
	vec4 C = zb.body[4 * s];
	float size = zb.body[4 * s + 3].x;
	float reach = cube ? size * 1.7320508 : size;
	float el;
	vec3 en;
	vec4 ex, ey, ez;
	geo_eye(zp.inv_view, zp.eye_off[id.z].xyz, el, en, ex, ey, ez);
	if (j >= pc.first.w) {
		// the tail's view of the body, from the meshes' last image on (Renderer's tail_psi_min)
		TailBody q = tail_body(cube, C, zb.body[4 * s + 1], zb.body[4 * s + 2], size);
		vec3 eye = vec3(geo_r(abs(el)), sqrt(geo_u(abs(el))), geo_dr(abs(el)));
		float psi_min = float(pc.first.w - 1) * GEO_PI;
		vec3 u;
		float half_w = tail_sector(en, q, u);
		TailStrips ts = tail_strips(el, eye, en, q, half_w, psi_min);
		int i0 = pc.first.w;
		if (j == i0) {
			vec2 band = tail_band(el, eye, q, psi_min);
			imageStore(cull_img, ivec3(i0, s, int(id.z)), vec4(C.xyz, 1.0));
			imageStore(cull_img, ivec3(i0 + 1, s, int(id.z)), vec4(band, half_w, 0.0));
			imageStore(cull_img, ivec3(i0 + 2, s, int(id.z)), vec4(u, 0.0));
			imageStore(cull_img, ivec3(i0 + 3, s, int(id.z)), vec4(ts.n0, ts.on ? 1.0 : 0.0, ts.outward ? 1.0 : 0.0));
		} else {
			float k = float(j - i0 - 1);
			vec4 st = vec4(0.0);
			if (ts.on) st = vec4(tail_strip(ts, eye, 0, k), half_w < GEO_PI ? tail_strip(ts, eye, 1, k) : vec2(0.0));
			imageStore(cull_img, ivec3(i0 + 5 + int(k), s, int(id.z)), st);
		}
		return;
	}
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
	float side = 0.0;
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
	int y2 = ci * PLAN_ROWS + 2;
	float th_prev = col > 0u ? imageLoad(plan_img, ivec3(int(col) - 1, y2, int(id.z))).x : 0.0;
	float th_next = float(col) < columns ? imageLoad(plan_img, ivec3(int(col) + 1, y2, int(id.z))).x : 0.0;
	bool rnd = imageLoad(plan_img, ivec3(108, ci * PLAN_ROWS + 1, int(id.z))).x > 0.5;
	side = zc_side(float(col), columns, rnd, th_prev, cv.x, th_next);
#endif
	int y = s * int(pc.grid.w) + (coarse ? int(pc.grid.y) + 1 : 0) + int(row);
	imageStore(out_img, ivec3(2 * int(col), y, int(id.z)), vec4(pe, t.xy));
	imageStore(out_img, ivec3(2 * int(col) + 1, y, int(id.z)), vec4(t.z, none ? 1.0 : 0.0, kill ? 1.0 : 0.0, side));
}
#endif
