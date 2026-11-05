// The floor, the sky and what is seen through the curved zone, for foveation (foveation.gd): a
// compute shader's body, not a Godot shader's; foveation.gd puts the header (the version, EYES,
// TABLE or GRAVITY) before it and geo.gdshaderinc, look.gdshaderinc and lens.gdshaderinc where it
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
// probe: the pixel's place as phases over this many pixels (floor_sample.gdshader): long beside a
// texel, so that the filter's mix of two neighbours' phases is the phase between them
#define FOV_PROBE 256.0

// show: a coarse texel's tint by its size s in pixels
vec3 fov_tint(float s) {
	return s < 2.0 ? vec3(0.1, 0.8, 0.2) : (s < 3.0 ? vec3(0.95, 0.85, 0.1) : (s < 4.0 ? vec3(1.0, 0.45, 0.05) : vec3(0.9, 0.05, 0.05)));
}

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
shared vec4 s_a[64];
void main() {
	uvec3 id = gl_GlobalInvocationID;
	uint v = id.z;
	vec4 w0 = fovp.warp0[v], w1 = fovp.warp1[v];
	float r0 = w1.x, m = w1.y;
	// the pixel this texel stands for, and the texel's size there in pixels: s along the way from
	// g, k across it
	vec2 q = vec2(id.xy) + 0.5 - w0.zw;
	float rho = length(q);
	float t = m * max(rho - r0, 0.0);
	float k = rho > r0 ? (r0 + sinh(t) / m) / rho : 1.0;
	float s = cosh(t);
	vec2 p = w0.xy + k * q;
	// texels beyond the picture by more than one never reach it through the filter
	bool used = all(lessThan(id.xy, uvec2(w1.zw))) && all(greaterThan(p, vec2(-2.0 * s)))
			&& all(lessThan(p, fovp.pic.xy + 2.0 * s));
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
	vec4 o = vec4(c, 1.0);
	if (fovp.pic.w > 0.5) {
		// probe: where this texel's pixel is, as a phase along x and along y (smooth: the filter
		// mixes neighbours' phases into the phase between them)
		vec2 ph = 6.2831853 * p / FOV_PROBE;
		o = vec4(cos(ph.x), sin(ph.x), cos(ph.y), sin(ph.y));
	}
	imageStore(out_img, ivec3(id), o);
}
#endif
