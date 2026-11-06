// The meshes of the bodies in the curved zone (balls: zone.gdshaderinc, zone_ball_vertex; cubes:
// zone_cube.gdshaderinc), each node once a frame for each eye, for the bodies' vertex shader
// (body.gdshaderinc, ZONE): a compute shader's body, not a Godot shader's; zone_sections.gd puts the
// header (the version, BALL, CUBE_EDGES, CUBE_SPANS, CUBE_COLUMNS, CUBE, IMAGES, SIZES, RIBBONS,
// LISTS, PATHS or LINES) before it and geo.gdshaderinc, zone.gdshaderinc, zone_cube.gdshaderinc and
// zone_tail.gdshaderinc where it says.
//
// A node's place on the body does not depend on which image of it is drawn, only on the eye (whose
// direction from the centre is the axis the mesh is built round) and the body, so each node of a
// body's two meshes (the fine one and the coarse one, whose nodes the thin ones take) is worked out
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
// (the centre's x, y, z the body was taken at, its mesh if drawn: 1 fine, 2 coarse as the index has
// it, then SIZES' as its place in the picture needs, ZS_*, 0 out of it; else 0): the vertex shader
// draws an image only where it says one for the centre its instance has; LISTS puts it in its mesh's
// list. And invocation x = images: the
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
	mat4 proj[2];       // each eye's PROJECTION_MATRIX
	vec4 view;          // the pictures' size in pixels
} zp;
layout(set = 0, binding = 2, std140) uniform Bodies {
	vec4 body[80];      // per slot: C, E1, E2, (size, colour)
} zb;
layout(push_constant, std430) uniform Kind {
	vec4 grid;          // this kind's meshes: columns, the fine one's rows, the coarse one's, a slot's rows
	ivec4 first;        // its first slot
} pc;
layout(set = 0, binding = 3, rgba32f) uniform restrict image2DArray out_img;   // the nodes (SIZES reads them)
layout(set = 0, binding = 4, rgba32f) uniform restrict image2DArray cull_img;   // IMAGES' out, PATHS' in
layout(set = 0, binding = 5, rgba32f) uniform restrict writeonly image2DArray path_img;   // PATHS' out
layout(set = 0, binding = 6, rgba32f) uniform restrict image2DArray plan_img;   // the cube passes' (above)
layout(set = 0, binding = 7, rgba32f) uniform restrict image2DArray col_img;
#if defined(SIZES) || defined(RIBBONS)
layout(set = 1, binding = 0) uniform sampler2DArray s_paths;   // PATHS' out, as the vertices take it
#endif
#ifdef RIBBONS
// a cube's thin image's ribbon: per column the rows of its two nodes at the ends of its line in the
// picture and of the nearest (RIBBONS' out, the cubes' vertex shader's in: body.gdshaderinc, zone_ribbons): texel
// (column, image + images * the cube's index), a layer per eye
layout(set = 1, binding = 1, rgba32f) uniform restrict writeonly image2DArray ribbon_img;
#endif
#ifdef LINES
// the field lines' vertices (Renderer.arrow_arrays: l, n.y, n.z, 1 for an arrow's) and where each is in
// the view of each eye, image by image (LINES' out, the lines' vertex shader's in: body.gdshaderinc,
// ARROWS, line_view)
layout(set = 1, binding = 0, std430) restrict readonly buffer LineIn { vec4 v[]; } line_in;
layout(set = 1, binding = 1, rgba32f) uniform restrict writeonly image2D line_out;
#endif
#ifdef LISTS
// the lists of what each zone mesh draws (LISTS' out, the bodies' vertex shader's in: body.gdshaderinc,
// zone_list), and the draw commands' instance counts (Renderer's zone meshes', drawn indirect)
layout(set = 1, binding = 0, rgba32f) uniform restrict writeonly image2D list_img;
layout(set = 1, binding = 1, std430) buffer Cmd0 { uint v[]; } cmd0;
layout(set = 1, binding = 2, std430) buffer Cmd1 { uint v[]; } cmd1;
layout(set = 1, binding = 3, std430) buffer Cmd2 { uint v[]; } cmd2;
layout(set = 1, binding = 4, std430) buffer Cmd3 { uint v[]; } cmd3;
layout(set = 1, binding = 5, std430) buffer Cmd4 { uint v[]; } cmd4;
layout(set = 1, binding = 6, std430) buffer Cmd5 { uint v[]; } cmd5;
layout(set = 1, binding = 7, std430) buffer Cmd6 { uint v[]; } cmd6;
layout(set = 1, binding = 8, std430) buffer Cmd7 { uint v[]; } cmd7;
#endif

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
// an image's mesh (SIZES; Renderer.ZONE_LODS) by where its nodes come in the picture, each within a
// quarter of a pixel of the body's outline. A column of a mesh (an azimuth about the eye's axis: a
// half-surface, whose paths to the eye keep to its plane) is a line in the picture, its points round
// the section a segment of it as long as the image is thick there; n of them a polygon off the
// section's curve by a share 1 - cos(pi / n) of its half. Its columns, N uniform in azimuth, are off
// the outline at its tips, where the section shrinks to a point as the root of the way to it, by at
// most 0.354 sqrt(2 / N) of its half thickness, and where it bends, by an eighth of the second
// difference over a column's step. The fine mesh (48 round) for the first ZS_FINE images thicker
// than ZS_COARSE_PX, else the coarse one (12; 64 azimuths); a ball's thin ones (the coarse one's
// nodes: 64 by 6, every 2nd point; 32 by 6, every 2nd azimuth too; 16 by 4, every 4th and 3rd) where
// they keep to that: codes 1 to 5 in that order (cull_img's .w), each mesh keeping to what the next
// keeps to. A cube's rows are its sections' corners and the points between, on rows of their own
// in each span: its thin image (ZS_THIN_PX.x) takes the ribbon (code 3), each column's two nodes at
// the ends of its line in the picture and the nearest between (RIBBONS), its outline the coarse
// mesh's, its inside two strips. A turn round the throat's sphere is a ring as long as the body's first image and
// thinner only as 1 / k: those take the thin ones.
const int ZS_FINE = 4;
const float ZS_COARSE_PX = 15.0;    // 12 round: 0.034 of the half, a quarter of a pixel at 15 across
const vec2 ZS_THIN_PX = vec2(3.7, 1.7);   // 6 round: 0.134 of the half; 4: 0.293
// the second difference over 8 columns, pixels, for 64, 32 and 16 of them: D / 512, D / 128, D / 32 a
// quarter of a pixel (the tips: 0.0625, 0.088, 0.125 of the half; up to 8, 5.7, 4 across)
const vec3 ZS_BEND_PX = vec3(128.0, 32.0, 8.0);
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
// a workgroup a span: its section's stages (zc_sequence's) side by side, through shared memory: the
// pieces read an invocation each (not into one invocation's arrays: the headset keeps those in
// memory, and reading them back is most of such a pass), the knots sorted by each one's rank (as
// zc_knots' insertion sort, equal ones in their order), the items' places and the faces' joins
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
shared vec3 s_pu[12 * ZC_PIECES], s_pt[12 * ZC_PIECES];
shared bool s_valid[12 * ZC_PIECES], s_has[12 * ZC_PIECES];
shared float s_cand[ZC_KNOTS], s_sorted[ZC_KNOTS], s_kn[ZC_KNOTS];
shared int s_nk, s_nsorted;
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
	float th0 = imageLoad(plan_img, ivec3(109, ci * PLAN_ROWS + 1, z)).w;
	// the pieces, and each piece's ends' azimuths off th0 as zc_knots takes them
	if (tid < 12 * ZC_PIECES) {
		int e = tid / ZC_PIECES, k = tid % ZC_PIECES;
		bool valid = k < int(imageLoad(plan_img, ivec3(9 * e, ci * PLAN_ROWS + 1, z)).x);
		vec3 pu = vec3(0.0), pt = vec3(0.0);
		if (valid) zs_piece(ci, z, tid, pu, pt);
		s_valid[tid] = valid;
		s_pu[tid] = pu;
		s_pt[tid] = pt;
		for (int j = 0; j < 2; j++) {
			float a = (j == 0 ? pt.x : pt.z) - th0;
			a -= 2.0 * GEO_PI * floor(a / (2.0 * GEO_PI) + (ax.rnd ? 0.0 : 0.5));
			s_cand[2 * tid + j] = a;
		}
	}
	barrier();
	// each knot's place in order: those below it, and those equal to it before it
	for (int c = tid; c < ZC_KNOTS; c += 64) {
		if (s_valid[c / 2]) {
			float a = s_cand[c];
			int r = 0;
			for (int o = 0; o < ZC_KNOTS; o++) {
				if (s_valid[o / 2] && (s_cand[o] < a || (s_cand[o] == a && o < c))) r++;
			}
			s_sorted[r] = a;
		}
	}
	if (tid == 0) {
		int n = 0;
		for (int i = 0; i < 12 * ZC_PIECES; i++) {
			if (s_valid[i]) n += 2;
		}
		s_nsorted = n;
	}
	barrier();
	// those within 1e-6 of the one before left out (zc_knots'), the span's middle (zc_span_mid's)
	if (tid == 0) {
		int n = s_nsorted, m = 0;
		for (int i = 0; i < ZC_KNOTS; i++) {
			if (i >= n) break;
			if (m == 0 || s_sorted[i] - s_kn[m - 1] > 1e-6) {
				s_kn[m] = s_sorted[i];
				m++;
			}
		}
		s_nk = m;
		int y2 = ci * PLAN_ROWS + 2;
		if (span == 0) {
			imageStore(plan_img, ivec3(PLAN_KNOTS, y2, z), vec4(float(m), 0.0, 0.0, 0.0));
			for (int i = 0; i < ZC_KNOTS / 4; i++) {
				if (4 * i >= m) break;
				imageStore(plan_img, ivec3(PLAN_KNOTS + 1 + i, y2, z), vec4(s_kn[4 * i], s_kn[4 * i + 1], s_kn[4 * i + 2], s_kn[4 * i + 3]));
			}
		}
		int spans = ax.rnd ? m : m - 1;
		s_go = span < max(spans, 1);
		if (spans < 1) {
			s_th = th0 + s_kn[0];
		} else {
			float kl = ax.rnd ? s_kn[0] + 2.0 * GEO_PI : s_kn[m - 1];
			float ka = s_kn[span], kb = span + 1 < m ? s_kn[span + 1] : kl;
			s_th = th0 + 0.5 * (ka + kb);
		}
	}
	barrier();
	if (!s_go) return;
	float th = s_th;
	// the items: the cuts of the pieces whose azimuths hold th, in order (zc_seq_items')
	if (tid < 12 * ZC_PIECES) s_has[tid] = s_valid[tid] && zc_has(s_pt[tid], th);
	barrier();
	if (tid == 0) {
		int ni = 0;
		for (int i = 0; i < 12 * ZC_PIECES; i++) {
			if (ni >= ZC_ITEMS - 2) break;
			if (s_has[i]) {
				s_ids[ni] = i;
				s_fm[ni] = zc_edge_faces(i / ZC_PIECES);
				ni++;
			}
		}
		s_first = ni;
		if (ax.rnd) {
			for (int i = 0; i < 2; i++) {
				s_ids[ni] = ZC_IN + i;
				s_fm[ni] = 0;
				ni++;
			}
		}
		for (int i = ni; i < ZC_ITEMS; i++) {
			s_ids[i] = 0;
			s_fm[i] = 0;
		}
		s_ni = ni;
	}
	barrier();
	int ni = s_ni;
	vec3 m;
	vec3 t = zc_t(q, th, m);
	// each item's place
	if (tid < ni) {
		int it = s_ids[tid];
		int k = min(it, 12 * ZC_PIECES - 1);
		int f = s_fm[tid];
		s_pos[tid] = zc_seq_pos(q, ax, it, s_pu[k], s_pt[k], th, t, m, f);
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
#elif defined(SIZES)
// A workgroup an image IMAGES draws (x: the image, y: the zone's body, balls first, z: the eye): the
// coarse mesh's nodes at 9 azimuths an eighth of its columns apart, every 2nd point (9 by 7 nodes),
// where the vertex shader puts them (zone_path_see by the table PATHS made, the eye's projection), in
// pixels from the picture's middle; from them the image's thickness (its columns' segments' longest;
// 6 points round, short of the section's by up to 1 - cos(pi / 6)), its bend (the second
// differences of their middles and lengths) and whether it is out of the picture (every node beyond
// one side of it, a quarter of the image's size across and 2 pixels past, or behind the eye): its
// mesh (ZS_*; 0 out of the picture), into IMAGES' texel. A node not a number, or some behind the eye
// and some not: the mesh as the index has it.
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
shared vec2 s_p[63];
shared uint s_bad[63];      // 1 behind the eye, 2 not a number
shared vec3 s_col[9];       // a column's segment: its middle, its length
void main() {
	int j = int(gl_WorkGroupID.x), b = int(gl_WorkGroupID.y), z = int(gl_WorkGroupID.z);
	int tid = int(gl_LocalInvocationID.x);
	int balls = pc.first.x;
	bool cube = b >= balls;
	int s = cube ? pc.first.z + b - balls : b;
	vec4 cull = imageLoad(cull_img, ivec3(j, s, z));
	if (cull.w < 0.5) return;
	if (tid < 63) {
		float el;
		vec3 en;
		vec4 ex, ey, ez;
		geo_eye(zp.inv_view, zp.eye_off[z].xyz, el, en, ex, ey, ez);
		int y = s * int(pc.grid.w) + int(pc.grid.y) + 1 + 2 * (tid % 7);
		int col = (tid / 7) * (int(pc.grid.x) / 8);
		vec4 na = imageLoad(out_img, ivec3(2 * col, y, z));
		vec4 nb = imageLoad(out_img, ivec3(2 * col + 1, y, z));
		vec3 t = vec3(na.zw, nb.x);
		float alpha = clamp(na.y, 0.0, GEO_PI);
		vec2 sca = geo_sincos(alpha);
		vec3 pn = sca.y * en + sca.x * t;
		float len, fell;
		vec4 arrive;
		vec4 dir = zone_path_see(s_paths, s * ZONE_PL, z, el, en, na.x, pn, t, alpha, j, len, arrive, fell);
		vec3 pv = zp.eye_off[z].xyz + len * vec3(dot(dir, ex), dot(dir, ey), dot(dir, ez));
		vec4 cp = zp.proj[z] * vec4(pv, 1.0);
		bool nan = nb.y > 0.5 || !geo_finite(cp.x + cp.y + cp.w);
		s_bad[tid] = nan ? 2u : (cp.w > 0.0 ? 0u : 1u);
		s_p[tid] = s_bad[tid] == 0u ? 0.5 * zp.view.xy * cp.xy / cp.w : vec2(0.0);
	}
	barrier();
	if (tid < 9) {
		// the column's farthest two points
		float far2 = 0.0;
		vec2 mid = s_p[7 * tid];
		for (int a = 0; a < 7; a++) {
			for (int c = a + 1; c < 7; c++) {
				vec2 d = s_p[7 * tid + c] - s_p[7 * tid + a];
				if (dot(d, d) > far2) {
					far2 = dot(d, d);
					mid = 0.5 * (s_p[7 * tid + c] + s_p[7 * tid + a]);
				}
			}
		}
		s_col[tid] = vec3(mid, sqrt(far2));
	}
	barrier();
	if (tid != 0) return;
	uint bad = 0u, behind = 0u;
	vec2 lo = vec2(1e30), hi = vec2(-1e30);
	for (int i = 0; i < 63; i++) {
		bad |= s_bad[i];
		behind += s_bad[i] & 1u;
		lo = min(lo, s_p[i]);
		hi = max(hi, s_p[i]);
	}
	float thick = 0.0, bend = 0.0;
	for (int c = 0; c < 9; c++) thick = max(thick, s_col[c].z);
	for (int c = 1; c < 8; c++) {
		vec3 d2 = s_col[c - 1] - 2.0 * s_col[c] + s_col[c + 1];
		bend = max(bend, length(d2.xy) + 0.5 * abs(d2.z));
	}
	thick /= 0.866;
	vec2 across = hi - lo;
	vec2 edge = 0.5 * zp.view.xy + 0.25 * max(across.x, across.y) + 2.0;
	bool out_ = behind == 63u || any(greaterThan(lo, edge)) || any(lessThan(hi, -edge));
	float mesh = cull.w;
	if (bad == 0u) {
		if (out_) mesh = 0.0;
		else if (j < ZS_FINE && thick > ZS_COARSE_PX) mesh = 1.0;
		else if (cube) mesh = thick <= ZS_THIN_PX.x ? 3.0 : 2.0;
		else if (thick <= ZS_THIN_PX.y && bend <= ZS_BEND_PX.z) mesh = 5.0;
		else if (thick <= ZS_THIN_PX.x && bend <= ZS_BEND_PX.y) mesh = 4.0;
		else if (thick <= ZS_THIN_PX.x && bend <= ZS_BEND_PX.x) mesh = 3.0;
		else mesh = 2.0;
	} else if (behind == 63u) {
		mesh = 0.0;
	}
	imageStore(cull_img, ivec3(j, s, z), vec4(cull.xyz, mesh));
}
#elif defined(RIBBONS)
// A workgroup a cube's image SIZES gave the ribbon (x: the image, y: the cube, z: the eye): an
// invocation a column of the coarse mesh, its nodes' ways to the eye (zone_path_see), and of them the
// two whose angles off the eye's outward radial are the least and the greatest: the ends of the
// column's line in the picture, so the ribbon's outline is the coarse mesh's; and the nearest along
// its way, on the side of the section the eye sees (the corner between the faces seen, whose edge is
// drawn dark). Into ribbon_img: (the row of the least, of the greatest, of the nearest). A column
// with a node that is no part of the surface (between
// two parts of the section, where a strip would join them) or not a number: the image back to the
// coarse mesh. pc.first: (balls, cubes, the cubes' first slot, images).
layout(local_size_x = 128, local_size_y = 1, local_size_z = 1) in;
shared bool s_bad;
void main() {
	int j = int(gl_WorkGroupID.x), ci = int(gl_WorkGroupID.y), z = int(gl_WorkGroupID.z);
	int tid = int(gl_LocalInvocationID.x);
	int s = pc.first.z + ci;
	vec4 cull = imageLoad(cull_img, ivec3(j, s, z));
	if (int(cull.w + 0.5) != 3) return;
	if (tid == 0) s_bad = false;
	barrier();
	if (tid <= int(pc.grid.x)) {
		float el;
		vec3 en;
		vec4 ex, ey, ez;
		geo_eye(zp.inv_view, zp.eye_off[z].xyz, el, en, ex, ey, ez);
		float side = el < 0.0 ? -1.0 : 1.0;
		float amin = 1e30, amax = -1e30, lmin = 1e30;
		int rmin = 0, rmax = 0, rnear = 0;
		bool bad = false;
		int rows = int(pc.grid.z + 0.5);
		for (int r = 0; r <= rows; r++) {
			int y = s * int(pc.grid.w) + int(pc.grid.y) + 1 + r;
			vec4 na = imageLoad(out_img, ivec3(2 * tid, y, z));
			vec4 nb = imageLoad(out_img, ivec3(2 * tid + 1, y, z));
			vec3 t = vec3(na.zw, nb.x);
			float alpha = clamp(na.y, 0.0, GEO_PI);
			vec2 sca = geo_sincos(alpha);
			vec3 pn = sca.y * en + sca.x * t;
			float len, fell;
			vec4 arrive;
			vec4 dir = zone_path_see(s_paths, s * ZONE_PL, z, el, en, na.x, pn, t, alpha, j, len, arrive, fell);
			float a = atan(length(dir.yzw), side * dir.x);
			bad = bad || nb.y > 0.5 || nb.z > 0.5 || !geo_finite(a);
			if (a < amin) {
				amin = a;
				rmin = r;
			}
			if (a > amax) {
				amax = a;
				rmax = r;
			}
			if (len < lmin) {
				lmin = len;
				rnear = r;
			}
		}
		if (bad) s_bad = true;
		imageStore(ribbon_img, ivec3(tid, j + pc.first.w * ci, z), vec4(float(rmin), float(rmax), float(rnear), 0.0));
	}
	barrier();
	if (tid == 0 && s_bad) imageStore(cull_img, ivec3(j, s, z), vec4(cull.xyz, 2.0));
}
#elif defined(LISTS)
// One workgroup: each body's image drawn in either eye (IMAGES' cull_img, its mesh there, the finer of
// the two: each mesh of a kind keeps to what the next keeps to), into its mesh's list (rows: balls
// fine, coarse, 64 by 6, 32 by 6, 16 by 4, cubes fine, coarse, ribbon; texel k: (slot, image)), the lists'
// lengths into the draw commands (their second number: the instance count), and the bodies' rows
// (zb.body) into row ZS_LIST_BODIES for the vertices. pc.first: (balls, cubes, the cubes' first slot,
// images), pc.grid.x: the views.
const int ZS_LIST_BODIES = 8;
layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;
shared uint s_n[8];
void main() {
	int tid = int(gl_LocalInvocationID.x);
	if (tid < 8) s_n[tid] = 0u;
	barrier();
	int balls = pc.first.x, all = (pc.first.x + pc.first.y) * pc.first.w;
	int views = int(pc.grid.x + 0.5);
	for (int it = tid; it < all; it += 256) {
		int b = it / pc.first.w, j = it % pc.first.w;
		bool cube = b >= balls;
		int s = cube ? pc.first.z + b - balls : b;
		int mesh = 0;
		for (int z = 0; z < 2; z++) {
			if (z >= views) break;
			int m = int(imageLoad(cull_img, ivec3(j, s, z)).w + 0.5);
			if (m > 0) mesh = mesh == 0 ? m : min(mesh, m);
		}
		if (mesh == 0) continue;
		int list = cube ? 4 + min(mesh, 3) : mesh - 1;
		uint k = atomicAdd(s_n[list], 1u);
		imageStore(list_img, ivec2(int(k), list), vec4(float(s), float(j), 0.0, 0.0));
	}
	for (int r = tid; r < 80; r += 256) imageStore(list_img, ivec2(r, ZS_LIST_BODIES), zb.body[r]);
	barrier();
	if (tid == 0) {
		cmd0.v[1] = s_n[0];
		cmd1.v[1] = s_n[1];
		cmd2.v[1] = s_n[2];
		cmd3.v[1] = s_n[3];
		cmd4.v[1] = s_n[4];
		cmd5.v[1] = s_n[5];
		cmd6.v[1] = s_n[6];
		cmd7.v[1] = s_n[7];
	}
}
#elif defined(LINES)
// The gravity view's field lines: each vertex's place in the view of each eye, image by image (an
// invocation each: x the vertex, y the image, z the eye; pc.first.x the vertices), as the vertex
// shader would put it (geo_see_image, the point at EYE_OFFSET + len dir; an arrow's a hair nearer,
// over its line): a search a vertex, image and eye once a frame here, not in each vertex shader the
// GPU runs on it. Out at (vertex, 2 image + eye): that point, and fell (body.gdshaderinc's colours).
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
void main() {
	uvec3 id = gl_GlobalInvocationID;
	if (int(id.x) >= pc.first.x) return;
	vec4 q = line_in.v[id.x];
	vec3 pn = vec3(0.0, q.y, q.z);
	float el;
	vec3 en;
	vec4 ex, ey, ez;
	geo_eye(zp.inv_view, zp.eye_off[id.z].xyz, el, en, ex, ey, ez);
	// its plane through the centre, as the vertex shader's: a triangle across the axis through the
	// eye and the centre would join two images
	float c = dot(en, pn);
	float sd = length(cross(en, pn));
	vec3 t = sd > 1e-9 ? (pn - c * en) / sd : normalize(cross(en, abs(en.z) < 0.9 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0)));
	float len, fell;
	vec4 arrive;
	vec4 dir = geo_see_image(el, en, q.x, pn, t, geo_atan2(sd, c), int(id.y), len, arrive, fell);
	len *= 1.0 - 1e-3 * q.w;
	vec3 pv = zp.eye_off[id.z].xyz + len * vec3(dot(dir, ex), dot(dir, ey), dot(dir, ez));
	imageStore(line_out, ivec2(id.x, 2 * id.y + id.z), vec4(pv, fell));
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
	// and its mesh as the index has it (SIZES makes it the one its place in the picture needs)
	imageStore(cull_img, ivec3(j, s, int(id.z)), vec4(C.xyz, drawn ? (j < ZS_FINE ? 1.0 : 2.0) : 0.0));
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
