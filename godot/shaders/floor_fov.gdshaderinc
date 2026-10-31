// The floor and the sky for our own foveation (floor_fov.gd): a compute shader's body, not a Godot
// shader's; floor_fov.gd puts the header (the version, these bindings, EYES or GRAVITY) and
// geo.gdshaderinc and look.gdshaderinc before it.
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
// eye (geo_eye; r, the root of u and r - rho0 there), from the camera Godot renders with.

layout(set = 0, binding = 0) uniform sampler2D g_tab;
layout(set = 0, binding = 1) uniform sampler2D g_grav;
layout(set = 0, binding = 2, std140) uniform Params {
	vec4 prof;          // g_prof
	vec4 prof2;         // g_prof2
	vec4 tabx;          // g_tabx
	vec4 head_nl;       // head_n, head_l
	vec4 head_p;        // head_pos
	vec4 head_fr[3];    // head_f
	vec4 gravx;         // g_gravx
	mat4 inv_view;      // INV_VIEW_MATRIX
	mat4 inv_proj[2];   // each eye's inverse(PROJECTION_MATRIX)
	vec4 eye_off[2];    // each eye's EYE_OFFSET
	vec4 warp_g[2];     // each eye's gaze (x, y) in clip space, k, texels a side
	vec4 warp_a[2];     // each eye's A0, A1 along x, then along y
	vec4 pic;           // the picture's pixels a side
} fovp;
layout(set = 0, binding = 3, std430) buffer Eyes {
	vec4 eyes[10];      // each eye: (el, en), ex, ey, ez, (r, the root of u, r - rho0)
};
layout(set = 0, binding = 4, rgba16f) uniform restrict writeonly image2DArray out_img;

#define g_prof fovp.prof
#define g_prof2 fovp.prof2
#define g_tabx fovp.tabx
#define head_l fovp.head_nl.w
#define head_n fovp.head_nl.xyz
#define head_f fovp.head_fr
#define head_pos fovp.head_p.xyz
#define g_gravx fovp.gravx.xy

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
	eyes[5u * v] = vec4(el, en);
	eyes[5u * v + 1u] = ex;
	eyes[5u * v + 2u] = ey;
	eyes[5u * v + 3u] = ez;
	eyes[5u * v + 4u] = vec4(geo_r(ale), sqrt(geo_u(ale)), geo_dr(ale), 0.0);
}
#else
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
shared vec3 s_a[64];
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
	vec4 e = eyes[5u * v];
	vec4 D = d.x * eyes[5u * v + 1u] + d.y * eyes[5u * v + 2u] + d.z * eyes[5u * v + 3u];
	float lh, way, skys;
	vec2 nh;
	vec3 skyd;
	bool hit = geo_floor(e.x, eyes[5u * v + 4u].xyz, e.yzw, D, lh, nh, way, skyd, skys);
	vec3 a = hit ? look_ground_at(lh, nh) : vec3(0.0);
	// a fragment shader's dFdx and dFdy: the differences within each 2 x 2 square of texels
	uvec2 q = gl_LocalInvocationID.xy;
	s_a[q.y * 8u + q.x] = a;
	barrier();
	uint row = q.y * 8u + (q.x & ~1u), col = (q.y & ~1u) * 8u + q.x;
	vec3 dx = s_a[row + 1u] - s_a[row];
	vec3 dy = s_a[col + 8u] - s_a[col];
	vec3 c;
	if (hit) {
		c = look_ground(a, dx, dy, sqrt(px2.x * px2.y), lh, way);
	} else {
		if (skys < 0.0) skyd.x = -skyd.x;
		c = look_sky(normalize(skyd), skys);
	}
	if (id.x < uint(n) && id.y < uint(n)) imageStore(out_img, ivec3(id), vec4(c, 1.0));
}
#endif
