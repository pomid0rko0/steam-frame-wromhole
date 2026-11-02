// The meshes of the bodies in the curved zone (zone.gdshaderinc, zone_vertex), each node once a
// frame for each eye, for the bodies' vertex shader (body.gdshaderinc, ZONE): a compute shader's
// body, not a Godot shader's; zone_sections.gd puts the header (the version, BALL or CUBE) before it
// and geo.gdshaderinc and zone.gdshaderinc where it says.
//
// A node's place on the body does not depend on which image of it is drawn, only on the eye (whose
// direction from the centre is the axis the mesh is built round) and the body, so each node of a
// body's two meshes (the fine one, ZONE_FINE images, and the coarse one, the rest) is worked out
// here once per eye, not in each vertex of each of its images. Invocation x: a node, the fine mesh's
// first, column by column (a column's nodes share a half-surface: a cube's corners there); y: the
// body, of those in the zone of this kind (slots from pc.first.x on); z: the eye.
// Out: per node two texels of a layer per eye, (l, alpha, t.x, t.y) and (t.z, 0, 0, 0) at x = 2 col
// and 2 col + 1, y = slot * slot_rows + the mesh's first row + row.

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
} zp;
layout(set = 0, binding = 2, std140) uniform Bodies {
	vec4 body[80];      // per slot: C, E1, E2, (size, 0, 0, 0)
} zb;
layout(push_constant, std430) uniform Kind {
	vec4 grid;          // this kind's meshes: columns, the fine one's rows, the coarse one's, a slot's rows
	ivec4 first;        // its first slot
} pc;
layout(set = 0, binding = 3, rgba32f) uniform restrict writeonly image2DArray out_img;

#define g_prof zp.prof
#define g_prof2 zp.prof2
#define g_tabx zp.tabx
#define head_l zp.head_nl.w
#define head_n zp.head_nl.xyz
#define head_f zp.head_fr
#define head_pos zp.head_p.xyz
#define g_lift zp.floor_.x

#include_geo_and_zone

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
#ifdef BALL
	vec2 pe = zone_vertex(vec2(float(col) / columns, float(row) / rows), columns, rows, true, en, C, E1, E2, E3, N, size, t);
#else
	vec2 pe = zone_vertex(vec2(float(col) / columns, float(row) / rows), columns, rows, false, en, C, E1, E2, E3, N, size, t);
#endif
	int y = s * int(pc.grid.w) + (coarse ? int(pc.grid.y) + 1 : 0) + int(row);
	imageStore(out_img, ivec3(2 * int(col), y, int(id.z)), vec4(pe, t.xy));
	imageStore(out_img, ivec3(2 * int(col) + 1, y, int(id.z)), vec4(t.z, 0.0, 0.0, 0.0));
}
