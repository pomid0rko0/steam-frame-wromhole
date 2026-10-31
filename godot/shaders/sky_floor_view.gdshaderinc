// The floor and the sky behind everything: a quad over the whole view at the far plane, drawn
// last of the opaque things (Renderer: its render_priority), so the depth test leaves out every
// pixel a body covers. Each pixel's ray: the line from the eye through it, interpolated from the
// corners (each pixel's exactly: unnormalised, it is affine in the screen position; a foveated
// coarse pixel gets the ray through its centre). sp_trace follows it to the floor or the sky.
// (the including shader's render_mode: unshaded, cull_disabled, depth_draw_never, skip_vertex_transform)

#include "res://shaders/eye.gdshaderinc"
#include "res://shaders/look.gdshaderinc"

varying flat float v_l;
varying flat vec3 v_n;
varying vec4 v_ray;

void vertex() {
	POSITION = vec4(VERTEX.xy, 0.0, 1.0);      // the far plane (Godot's depth is reversed)
	float l;
	vec3 n;
	vec4 f0;
	vec4 f1;
	vec4 f2;
	vec3 eye;
	sp_eye(INV_VIEW_MATRIX, EYE_OFFSET, l, n, f0, f1, f2, eye);
	v_l = l;
	v_n = n;
	// this corner's ray: from the eye through the corner unprojected at two depths (the far one,
	// whatever the depth convention), in the play space, then as a tangent vector at the eye
	vec4 pa = INV_PROJECTION_MATRIX * vec4(VERTEX.xy, 0.001, 1.0);
	vec4 pb = INV_PROJECTION_MATRIX * vec4(VERTEX.xy, 0.999, 1.0);
	vec3 qa = pa.xyz / pa.w;
	vec3 qb = pb.xyz / pb.w;
	vec3 pd = mat3(INV_VIEW_MATRIX) * ((dot(qa, qa) > dot(qb, qb) ? qa : qb) - EYE_OFFSET);
	v_ray = pd.x * f0 + pd.y * f1 + pd.z * f2;
}

void fragment() {
	float side;
	vec3 d;
	float fl;
	float dist;
	int kind = sp_trace(v_l, v_n, normalize(v_ray), side, d, fl, dist);
	ALBEDO = lk_background(kind, side, d, fl, dist);
}
