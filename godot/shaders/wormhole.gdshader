shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;

// Full-screen ray tracer. The script supplies the head's point on the manifold
// (head_l, head_n), the play-space axes parallel-transported to it (head_f, as (U_l, u))
// and the head's play-space position.
//
// Multiview (stereo) in Godot: VIEW_MATRIX / INV_VIEW_MATRIX are the camera between the
// eyes for BOTH views. Each eye's position and rotation relative to it are folded into that
// view's PROJECTION_MATRIX, and EYE_OFFSET is the eye's position in that shared view space.
// So the eye sits at EYE_OFFSET, and the ray of a pixel is the line from EYE_OFFSET through
// the pixel's unprojected point. The eye's manifold state is obtained by following the
// geodesic from the head to the eye. Without multiview EYE_OFFSET is zero.

uniform float wh_rho0 = 3.0;
uniform float wh_h = 5.0;
uniform float wh_fillet = 1.0;
uniform vec4 wh_sph[6];
uniform vec4 wh_pil[4];
uniform vec4 wh_box[4];
uniform vec4 wh_ball[12];
uniform vec4 wh_ballCol[12];
uniform int wh_nBall = 0;
uniform vec4 wh_cube[6];
uniform vec4 wh_cubeE[24];
uniform vec4 wh_cubeCol[6];
uniform int wh_nCube = 0;
uniform float head_l = 10.0;
uniform vec3 head_n = vec3(1.0, 0.0, 0.0);
uniform vec4 head_f[3];
uniform vec3 head_pos;

#include "res://shaders/wormhole_core.gdshaderinc"

varying flat float v_l;
varying flat vec3 v_n;
varying flat vec4 v_f0;
varying flat vec4 v_f1;
varying flat vec4 v_f2;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
	float l = head_l;
	vec3 n = head_n;
	vec4 f0 = head_f[0];
	vec4 f1 = head_f[1];
	vec4 f2 = head_f[2];
	vec3 eye = (INV_VIEW_MATRIX * vec4(EYE_OFFSET, 1.0)).xyz;
	vec3 off = eye - head_pos;                         // this eye relative to the head, play space
	float len = length(off);
	if (len > 1e-6) {
		vec4 dir = (off.x * f0 + off.y * f1 + off.z * f2) / len;
		wh_geodesic(l, n, dir, len, f0, f1, f2);
	}
	v_l = l; v_n = n; v_f0 = f0; v_f1 = f1; v_f2 = f2;
}

void fragment() {
	// unproject the pixel at two depths and use the far point (independent of the depth
	// convention); the ray runs from the eye, EYE_OFFSET, through it
	vec2 ndc = SCREEN_UV * 2.0 - 1.0;
	vec4 pa = INV_PROJECTION_MATRIX * vec4(ndc, 0.001, 1.0);
	vec4 pb = INV_PROJECTION_MATRIX * vec4(ndc, 0.999, 1.0);
	vec3 qa = pa.xyz / pa.w;
	vec3 qb = pb.xyz / pb.w;
	vec3 vd = normalize((dot(qa, qa) > dot(qb, qb) ? qa : qb) - EYE_OFFSET);
	vec3 pd = normalize((INV_VIEW_MATRIX * vec4(vd, 0.0)).xyz);   // play-space direction
	vec4 V = pd.x * v_f0 + pd.y * v_f1 + pd.z * v_f2;
	vec4 dbg;
	ALBEDO = wh_render(v_l, v_n, V.x, V.yzw, dbg);
}
