shader_type spatial;
// The balls in the curved zone found per pixel (zone_pixel.gdshaderinc; Renderer.zone_pixel): a quad
// over the whole view drawn before every body (Renderer.ZONE_PX_PRIORITY). Where a pixel's ray meets
// a ball it is drawn at the depth of the light's way there, as the bodies' meshes are
// (body.gdshaderinc), so the meshes drawn after it and the floor's quad last are ordered by the way
// light goes; a pixel whose ray meets none is dropped.
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled;

#include "res://shaders/geo_uniforms.gdshaderinc"
uniform vec4 zone_ball[24];      // 2 ZONE_PIXEL_MAX
uniform int zone_balls = 0;
#include "res://shaders/geo.gdshaderinc"
#include "res://shaders/look.gdshaderinc"
#include "res://shaders/zone.gdshaderinc"
#include "res://shaders/zone_pixel.gdshaderinc"

varying flat float v_el;
varying flat vec3 v_eye;      // the eye's r, the root of its u on the fillet, r - rho0 (floor.gdshaderinc)
varying flat vec3 v_en;
varying flat vec4 v_ex;
varying flat vec4 v_ey;
varying flat vec4 v_ez;
varying flat vec3 v_off;      // the eye in the camera's space (EYE_OFFSET)
varying vec3 v_ray;

void vertex() {
	// as the floor's quad (floor.gdshaderinc), its depth written per pixel
	POSITION = vec4(VERTEX.xy, 0.0, 1.0);
	vec4 p = inverse(PROJECTION_MATRIX) * vec4(VERTEX.xy, 0.5, 1.0);
	v_ray = p.xyz / p.w - EYE_OFFSET;
	v_off = EYE_OFFSET;
	float el;
	vec3 en;
	vec4 ex, ey, ez;
	geo_eye(INV_VIEW_MATRIX, EYE_OFFSET, el, en, ex, ey, ez);
	v_el = el;
	v_eye = vec3(geo_r(abs(el)), sqrt(geo_u(abs(el))), geo_dr(abs(el)));
	v_en = en;
	v_ex = ex;
	v_ey = ey;
	v_ez = ez;
}

void fragment() {
	vec3 d = normalize(v_ray);
	vec4 D = d.x * v_ex + d.y * v_ey + d.z * v_ez;
	vec3 col;
	float len;
	if (!zone_pixel_trace(v_el, v_eye, v_en, D, col, len)) discard;
	ALBEDO = col;
	vec4 c = PROJECTION_MATRIX * vec4(v_off + len * d, 1.0);
	DEPTH = c.z / c.w;
}
