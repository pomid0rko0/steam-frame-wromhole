shader_type spatial;
// The gravity view's arrows (docs/gravity.md, «Показ»): on the surface n.x = 0 through the throat,
// above the floor, drawn over what is behind it. The mesh is a grid in (l, a), n = (0, cos a,
// sin a) (Renderer._arrow_sheet); each vertex goes where this view's eye sees that point (as a
// body's, body.gdshader), and the arrows are drawn by (l, a) per pixel.
render_mode unshaded, cull_disabled, depth_draw_never, skip_vertex_transform, fog_disabled, blend_mix;

#include "res://shaders/eye.gdshaderinc"
#include "res://shaders/look.gdshaderinc"

varying vec2 v_la;
varying float v_dist;

void vertex() {
	float le;
	vec3 ne;
	vec4 f0;
	vec4 f1;
	vec4 f2;
	vec3 eye;
	sp_eye(INV_VIEW_MATRIX, EYE_OFFSET, le, ne, f0, f1, f2, eye);
	float lp = VERTEX.x;
	vec3 np = vec3(0.0, cos(VERTEX.y), sin(VERTEX.y));
	v_la = VERTEX.xy;
	float dist;
	vec4 V = sp_toward(le, ne, sp_r(abs(le)), lp, np, dist);
	v_dist = dist;
	vec3 dir = vec3(dot(V, f0), dot(V, f1), dot(V, f2));
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(eye + dist * dir, 1.0));
}

void fragment() {
	// a pixel's size on the surface, in metres: the footprint of (l, r a)
	vec2 q = vec2(v_la.x, sp_r(abs(v_la.x)) * v_la.y);
	vec2 fw = fwidth(q);
	vec4 ar = lk_arrow(v_la.x, v_la.y, max(fw.x, fw.y));
	float side = v_la.x >= 0.0 ? 1.0 : -1.0;
	ALBEDO = lk_fog(side, ar.rgb, v_dist);
	ALPHA = ar.a;
}
