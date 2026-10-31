shader_type spatial;
// A body: a ball, a cube or a static object of a flat universe, rasterized. Each vertex is a point
// of the space; sp_toward finds the direction from this view's eye whose geodesic reaches it, and
// the vertex is put at its path length along that direction from the eye. The eye's rays are
// straight in those coordinates (the eye's normal coordinates), so the GPU's straight-line
// rasterization draws what the eye sees, exactly at the vertices; between them the mesh is fine
// enough (Renderer: the meshes' detail by distance). Each point of the space has one such direction
// at most (docs/geometry.md), so each body is drawn once; the depth is its path length, so bodies
// hide each other as they should. The floor hides no body (docs/geometry.md): a vertex below it is
// moved onto it.
render_mode unshaded, cull_disabled, skip_vertex_transform, fog_disabled;

#include "res://shaders/eye.gdshaderinc"
#include "res://shaders/look.gdshaderinc"

// 0 a ball (the mesh: the unit sphere), 1 a cube (the mesh: the faces of [-1, 1]^3), 2 a mesh about
// centre.xyz in the chart of the universe side (static objects)
uniform int kind = 0;
// balls and cubes: the centre, a point of R^4 on the space, and orthonormal axes of R^4 there: three
// body axes along the space, then the space's normal; the radius or half the edge
uniform vec4 centre;
uniform vec4 ax0;
uniform vec4 ax1;
uniform vec4 ax2;
uniform vec4 ax3;
uniform float size = 1.0;
uniform float side = 1.0;
uniform vec3 color = vec3(0.8);

varying vec3 v_nrm;         // the surface's normal, in the chart (the curved zone as if flat)
varying vec3 v_body;        // a cube's point in its axes, in half sizes
varying float v_dist;
varying flat float v_side;

void vertex() {
	float le;
	vec3 ne;
	vec4 f0;
	vec4 f1;
	vec4 f2;
	vec3 eye;
	sp_eye(INV_VIEW_MATRIX, EYE_OFFSET, le, ne, f0, f1, f2, eye);
	vec4 P;
	vec4 N4;                // the surface's normal in R^4 (balls, cubes)
	if (kind == 0) {
		// the point of the space at chord distance size from the centre, in the body direction VERTEX:
		// on the circle C + size (cos g D + sin g ax3), where the space crosses it
		vec4 D = VERTEX.x * ax0 + VERTEX.y * ax1 + VERTEX.z * ax2;
		float g = 0.0;
		for (int i = 0; i < 3; i++) {
			vec4 grad;
			P = centre + size * (cos(g) * D + sin(g) * ax3);
			float f = sp_sdf(P, grad);
			float df = dot(grad, size * (cos(g) * ax3 - sin(g) * D));
			g -= f / (abs(df) > 1e-9 ? df : 1e-9);
		}
		P = centre + size * (cos(g) * D + sin(g) * ax3);
		N4 = P - centre;
	} else if (kind == 1) {
		// the point of the face where the space crosses the box's line along its normal axis
		vec4 Q = centre + size * (VERTEX.x * ax0 + VERTEX.y * ax1 + VERTEX.z * ax2);
		float t = 0.0;
		for (int i = 0; i < 3; i++) {
			vec4 grad;
			float f = sp_sdf(Q + t * ax3, grad);
			float df = dot(grad, ax3);
			t -= f / (abs(df) > 1e-9 ? df : 1e-9);
		}
		P = Q + t * ax3;
		vec3 a = abs(VERTEX);
		N4 = a.x >= a.y && a.x >= a.z ? sign(VERTEX.x) * ax0 : (a.y >= a.z ? sign(VERTEX.y) * ax1 : sign(VERTEX.z) * ax2);
		v_body = VERTEX;
	} else {
		// Godot's meshes stand along y, the charts along z
		P = vec4(sp_M(side, centre.xyz + vec3(VERTEX.x, -VERTEX.z, VERTEX.y)), side * (sp_Lc + sp_R));
		N4 = vec4(sp_M(side, vec3(NORMAL.x, -NORMAL.z, NORMAL.y)), 0.0);
	}
	vec3 np;
	float lp = sp_lOf(P, np);
	if (np.z < 0.0) {
		// below the floor: onto it
		np.z = 0.0;
		np = normalize(np);
	}
	float s = lp >= 0.0 ? 1.0 : -1.0;
	vec4 Un = sp_project(lp, np, N4);
	v_nrm = sp_M(s, s * Un.x * np + Un.yzw);
	v_side = s;
	float dist;
	vec4 V = sp_toward(le, ne, sp_r(abs(le)), lp, np, dist);
	v_dist = dist;
	// V in the play space: its parts along the eye's play axes
	vec3 dir = vec3(dot(V, f0), dot(V, f1), dot(V, f2));
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(eye + dist * dir, 1.0));
}

void fragment() {
	vec3 c = color;
	if (kind == 1) {
		// darker along the edges: lines 0.07 of the half size wide, soft over a pixel or two
		vec3 a = abs(v_body);
		float e = 1.0 - (a.x + a.y + a.z - max(max(a.x, a.y), a.z) - min(min(a.x, a.y), a.z));
		float fw = clamp(fwidth(e), 1e-4, 0.05);
		c *= 1.0 - 0.55 * (1.0 - smoothstep(0.07 - fw, 0.07 + fw, e));
	}
	ALBEDO = lk_fog(v_side, lk_shade(v_side, c, normalize(v_nrm)), v_dist);
}
