// The floor, the sky and what is seen through the curved zone, for our own foveation
// (floor_fov.gd): a compute shader's body, not a Godot shader's; floor_fov.gd puts the header (the
// version, EYES, TABLE or GRAVITY) before it and geo.gdshaderinc, look.gdshaderinc and
// lens.gdshaderinc where it says.
//
// Each eye's picture in a texture whose texels are thin round where the eye looks and thicker away
// from it, in each direction alike: along x, the texel coordinate t in [0, 1] is the clip
// coordinate x = g + sinh(k (A0 + t (A1 - A0))) / k, g the gaze's x, A0 = asinh(k (-1 - g)) / k,
// A1 = asinh(k (1 - g)) / k (y likewise): a texel spans 1 / sqrt(1 + (k (x - g))^2) of what it
// spans at g, smoothly, with no edge between densities. Each texel is a pixel of floor.gdshaderinc
// at that place in the picture, worked out the same way; the floor's quad then takes each pixel's
// colour from here (floor.gdshaderinc, FOV).
//
// EYES: the first pass, one invocation per eye: what floor.gdshaderinc's vertex() works out per
// eye (geo_eye; r, the root of u and r - rho0 there), from the camera Godot renders with, and the
// ends of its rows of the way out (geo_xt_range).
// TABLE: the second, one invocation per texel of those rows (geo.gdshaderinc, «the way out by a
// table»): each eye's way out of the zone by a ray's sigma, outward and inward. A texel of the
// picture then takes its ray's way out from there (geo_xt_way), not from geo_exit's closed forms.

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
	mat4 inv_proj[2];   // each eye's inverse(PROJECTION_MATRIX)
	vec4 eye_off[2];    // each eye's EYE_OFFSET
	vec4 warp_g[2];     // each eye's gaze (x, y) in clip space, k, texels a side
	vec4 warp_a[2];     // each eye's A0, A1 along x, then along y
	vec4 pic;           // the picture's pixels a side
} fovp;
layout(set = 0, binding = 3, std430) buffer Eyes {
	vec4 eyes[12];      // each eye: (el, en), ex, ey, ez, (r, the root of u, r - rho0), (its rows' ends)
};
layout(set = 0, binding = 4, rgba16f) uniform restrict writeonly image2DArray out_img;
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
#else
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
shared vec4 s_a[64];
void main() {
	uvec3 id = gl_GlobalInvocationID;
	uint v = id.z;
	vec4 wg = fovp.warp_g[v], wa = fovp.warp_a[v];
	float k = wg.z;
	int n = int(wg.w);
	vec2 t = (vec2(id.xy) + 0.5) / float(n);
	vec2 u = k * vec2(mix(wa.x, wa.y, t.x), mix(wa.z, wa.w, t.y));
	vec2 clip = wg.xy + vec2(sinh(u.x), sinh(u.y)) / k;
	// the texel's size in the picture's pixels, along x and y: d clip / d t times their pixels per clip unit
	vec2 px2 = vec2(wa.y - wa.x, wa.w - wa.z) * vec2(cosh(u.x), cosh(u.y)) * (0.5 * fovp.pic.x / float(n));
	// the ray as floor.gdshaderinc's quad has it at that point of the picture
	vec4 p = fovp.inv_proj[v] * vec4(clip, 0.5, 1.0);
	vec3 d = normalize(p.xyz / p.w - fovp.eye_off[v].xyz);
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
		int k;
		float x = geo_xt_place(ale, b, gap, sigma, eyes[6u * v + 5u].xy, k);
		int row = 2 * int(v) + (outward ? 0 : 1);
		vec3 w = geo_xt_way(imageLoad(xt_img, ivec2(k, row)), imageLoad(xt_img, ivec2(k + 1, row)), x, ale, eye, b, sigma, gap, outward);
		if (w.z > 0.5) sheet = -sheet;
		geo_exit_at(e.yzw, tr, b, w.x, pos, dir);
		way = w.y;
	}
	LensSeen sn = lens_trace(pos, dir, sheet, way, lensed);
	vec3 a = look_ground_at(lens_floor_xy(pos, dir, sheet));
	float edge = dot(sn.box, sn.box) > 0.0 ? look_box_edge(sn.box) : -1.0;
	// a fragment shader's dFdx and dFdy: the differences within each 2 x 2 square of texels
	uvec2 q = gl_LocalInvocationID.xy;
	s_a[q.y * 8u + q.x] = vec4(a, edge);
	barrier();
	uint row = q.y * 8u + (q.x & ~1u), col = (q.y & ~1u) * 8u + q.x;
	vec4 dx = s_a[row + 1u] - s_a[row];
	vec4 dy = s_a[col + 8u] - s_a[col];
	vec3 c = lens_colour(sn, a, dx.xyz, dy.xyz, vec2(edge, abs(dx.w) + abs(dy.w)), sqrt(px2.x * px2.y));
	if (id.x < uint(n) && id.y < uint(n)) imageStore(out_img, ivec3(id), vec4(c, 1.0));
}
#endif
