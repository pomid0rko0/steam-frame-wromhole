// Full-screen ray tracer. The script supplies the head's point on the manifold
// (head_l, head_n), the play-space axes parallel-transported to it (head_f, as (U_l, u))
// and the head's play-space position.
//
// Multiview (stereo) in Godot: VIEW_MATRIX / INV_VIEW_MATRIX are the camera between the
// eyes for BOTH views. Each eye's position and rotation relative to it are folded into that
// view's PROJECTION_MATRIX, and EYE_OFFSET is the eye's position in that shared view space.
// So the eye sits at EYE_OFFSET, and the ray of a pixel is the line from EYE_OFFSET through
// the pixel's unprojected point. The eye's manifold state (the geodesic from the head to the
// eye) is worked out once per eye and frame (eye_data.gd). Without multiview EYE_OFFSET is zero.

#include "res://shaders/wormhole_uniforms.gdshaderinc"
#include "res://shaders/wormhole_core.gdshaderinc"

varying flat float v_l;
varying flat vec3 v_n;
varying flat vec4 v_f0;
varying flat vec4 v_f1;
varying flat vec4 v_f2;
varying flat vec2 v_eye;        // wh_eye(v_l): once per eye, not per pixel
varying vec4 v_ray;

void vertex() {
	// at the far plane: the movable objects' passes, drawn first, write their depth, and the GPU
	// skips this ray tracer wherever one of them is seen (main.gd, the toys)
	POSITION = vec4(VERTEX.xy, 1e-6, 1.0);
	float l; vec3 n; vec4 f0; vec4 f1; vec4 f2; vec2 eye;
	wh_eyeOf(int(VIEW_INDEX), l, n, f0, f1, f2, eye);
	v_l = l; v_n = n; v_f0 = f0; v_f1 = f1; v_f2 = f2;
	v_eye = eye;
	vec3 pd = mat3(INV_VIEW_MATRIX) * wh_cornerRay(VERTEX.xy, INV_PROJECTION_MATRIX, EYE_OFFSET);   // play space
	v_ray = pd.x * f0 + pd.y * f1 + pd.z * f2;
}

void fragment() {
	vec4 V = normalize(v_ray);
	vec4 dbg;
	ALBEDO = wh_renderE(v_l, v_n, V.x, V.yzw, v_eye, dbg);
}
