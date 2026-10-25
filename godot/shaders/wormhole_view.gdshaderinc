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
uniform float head_l = 10.0;
uniform vec3 head_n = vec3(1.0, 0.0, 0.0);
uniform vec4 head_f[3];
uniform vec3 head_pos;
#ifdef WH_TABLE
uniform sampler2D wh_tab : filter_linear, repeat_disable;
uniform vec4 wh_tabLo;
uniform vec4 wh_tabInv;
uniform vec4 wh_tabReg;
#endif
#ifdef WH_GRAVITY
uniform vec4 grav_cyl;
uniform vec4 grav_g[2];
uniform vec4 grav_d[2];
#endif
// a pixel's angle: the arrows' soft edges, the cubes' edge lines
#ifndef WH_NO_BALLS
#define WH_PIX
#else
#ifdef WH_ARROWS
#define WH_PIX
#endif
#endif
#ifdef WH_PIX
uniform float wh_pix = 0.0015;
#endif
#ifndef WH_NO_BALLS
uniform vec4 wh_cube[6];
uniform vec4 wh_cubeE[30];
uniform vec4 wh_cubeCol[6];
uniform int wh_nCube = 0;
// balls' and cubes' bounding spheres (R^4 xyz of the centre, radius; < 0: none) in universe A, B
// (main.set_objects): a ray of a flat universe that misses one tests none of them
uniform vec4 wh_bound[4];
// where in the sorted lists the balls and cubes of universe A, of the shell and of universe B are
uniform ivec4 wh_bIdx;
uniform ivec4 wh_cIdx;
#endif

#include "res://shaders/wormhole_core.gdshaderinc"

varying flat float v_l;
varying flat vec3 v_n;
varying flat vec4 v_f0;
varying flat vec4 v_f1;
varying flat vec4 v_f2;
varying flat vec2 v_eye;        // wh_eye(v_l): once per eye, not per pixel
varying vec4 v_ray;

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
	v_eye = wh_eye(l);
	// this corner's ray: the line from the eye, EYE_OFFSET, through the corner unprojected at two
	// depths (the far point, whatever the depth convention). Unnormalised, it is affine in the
	// screen position, so the interpolated value is each pixel's ray exactly.
	vec4 pa = INV_PROJECTION_MATRIX * vec4(VERTEX.xy, 0.001, 1.0);
	vec4 pb = INV_PROJECTION_MATRIX * vec4(VERTEX.xy, 0.999, 1.0);
	vec3 qa = pa.xyz / pa.w;
	vec3 qb = pb.xyz / pb.w;
	vec3 pd = mat3(INV_VIEW_MATRIX) * ((dot(qa, qa) > dot(qb, qb) ? qa : qb) - EYE_OFFSET);   // play space
	v_ray = pd.x * f0 + pd.y * f1 + pd.z * f2;
}

void fragment() {
	vec4 V = normalize(v_ray);
	vec4 dbg;
	ALBEDO = wh_renderE(v_l, v_n, V.x, V.yzw, v_eye, dbg);
}
