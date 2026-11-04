// The meshes of the bodies in the curved zone (zone.gdshaderinc, zone_vertex), each node once a
// frame for each eye, for the bodies' vertex shader (body.gdshaderinc, ZONE): a compute shader's
// body, not a Godot shader's; zone_sections.gd puts the header (the version, BALL, CUBE or IMAGES)
// before it and geo.gdshaderinc and zone.gdshaderinc where it says.
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
// IMAGES: which images of each body are drawn at all. A body's images close in on the limit of its
// rays round the photon sphere (b = r_min: the direction asin(r_min / r) off the eye's inward
// radial), from both sides of the eye's axis; seen from the throat's cylinder the k-th turn's image
// is only about 1 / k of a turn's angle off it, and from about the 10th on the images, thinner than
// a pixel but each over the last, fill a band to the limit (issue #141). So every image is drawn up
// to the first whose direction is within a quarter of a pixel of the limit, on each side (need:
// past it the band left is thinner than that; a turn k's two images 2k, 2k + 1 by halving k);
// beyond those of the first ZONE_IMAGES, an image thinner across than a quarter of a pixel
// (ZoneSections.CULL_PX: the stereo test's rays a quarter of a pixel off a pixel's centre each way
// don't all meet it, so it counts for no pixel) is left out: next to the photon sphere a small
// body's images are (a hand's ball's, seen from beside the zone, all but the first). How thick: the
// images of the points the body's reach off its centre in the ray's plane, along l and along
// alpha, and the angle between each pair's directions; a pixel there: its angle at the picture's
// middle times cos^2 of the way off it. Invocation x: the image, and one more (x = images) for need;
// y: the body (the zone's balls, then its cubes), z: the eye. Out: a texel per image, body's slot
// and eye, (the centre's x, y, z the body was taken at, 1 if drawn, else 0), and at x = images (the
// centre's x, y, z, need): the vertex shader draws an image where it says 1, or below need (the
// first ZONE_IMAGES' meshes and the tail's, Renderer.ZONE_TAIL), for the centre its instance has.

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
	vec4 px;            // a pixel's angle at the middle of each eye's picture, rad; what share of one is culled; the turns need may take
} zp;
layout(set = 0, binding = 2, std140) uniform Bodies {
	vec4 body[80];      // per slot: C, E1, E2, (size, 0, 0, 0)
} zb;
layout(push_constant, std430) uniform Kind {
	vec4 grid;          // this kind's meshes: columns, the fine one's rows, the coarse one's, a slot's rows
	ivec4 first;        // its first slot
} pc;
layout(set = 0, binding = 3, rgba32f) uniform restrict writeonly image2DArray out_img;
layout(set = 0, binding = 4, rgba32f) uniform restrict writeonly image2DArray cull_img;   // IMAGES' out

#define g_prof zp.prof
#define g_prof2 zp.prof2
#define g_tabx zp.tabx
#define head_l zp.head_nl.w
#define head_n zp.head_nl.xyz
#define head_f zp.head_fr
#define head_pos zp.head_p.xyz
#define g_lift zp.floor_.x

#include_geo_and_zone

#ifdef IMAGES
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

// whether image j's direction is within a quarter of a pixel of the limit its images close in on
// (lim: its angle off the eye's inward radial); a pixel there: its angle at the picture's middle
// times cos^2 of the way off it, the cosine at least ZS_OFF (off the picture, where the pixel means
// nothing, about the picture's edge's: more images than needed, drawn off it)
const float ZS_OFF = 0.3;
bool zs_near_limit(float el, vec3 en, float pl, vec3 t, float alpha, int j, float lim, vec4 ez, float px) {
	vec4 d = zs_see(el, en, pl, t, alpha, j);
	float side = el < 0.0 ? -1.0 : 1.0;
	float th = geo_atan2(length(d.yzw), -side * d.x);
	float c = max(-dot(d, ez) / length(d), ZS_OFF);
	return !geo_finite(th + c) || abs(th - lim) < zp.px.z * px * c * c;
}

layout(local_size_x = 32, local_size_y = 1, local_size_z = 1) in;
void main() {
	uvec3 id = gl_GlobalInvocationID;
	int j = int(id.x);
	int balls = pc.first.x, all = pc.first.x + pc.first.y;
	if (j > pc.first.w || int(id.y) >= all) return;
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
	float pxe = id.z == 0u ? zp.px.x : zp.px.y;
	if (j == pc.first.w) {
		// need: up to the first image within a quarter of a pixel of the limit, each side; with no
		// photon sphere (a crease, h < R) the first ZONE_IMAGES
		int need = pc.first.w;
		if (g_prof2.w <= 0.0) {
			float lim = geo_asin(min(g_prof2.z / geo_r(abs(el)), 1.0));
			need = 0;
			for (int f = 0; f < 2; f++) {
				int lo = 0, hi = int(zp.px.w);
				for (int it = 0; it < 13; it++) {
					if (lo >= hi) break;
					int mid = (lo + hi) / 2;
					if (zs_near_limit(el, en, pl, t, alpha, 2 * mid + f, lim, ez, pxe)) hi = mid; else lo = mid + 1;
				}
				need = max(need, 2 * lo + f + 1);
			}
		}
		imageStore(cull_img, ivec3(j, s, int(id.z)), vec4(C.xyz, float(need)));
		return;
	}
	vec4 d0 = zs_see(el, en, pl, t, alpha, j);
	float da = min(reach / geo_r(abs(pl)), 0.5 * GEO_PI);
	float thick = max(zs_apart(zs_see(el, en, pl, t, alpha + da, j), zs_see(el, en, pl, t, alpha - da, j)),
			zs_apart(zs_see(el, en, pl + reach, t, alpha, j), zs_see(el, en, pl - reach, t, alpha, j)));
	float c = -dot(d0, ez) / length(d0);
	float px = pxe * max(c * c, 0.0);
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
