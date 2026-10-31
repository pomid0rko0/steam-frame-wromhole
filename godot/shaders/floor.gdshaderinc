// The floor and the sky, per pixel (floor.gdshader; floor_gravity.gdshader defines GRAVITY: the
// floor coloured by gravity, docs/gravity.md «Показ»). A quad over the whole view behind
// everything: the bodies (body.gdshader) are drawn first, and where they are this never runs.
// The floor never hides a body (docs/geometry.md), so its depth is the far plane's: it writes
// nothing new. Opaque (Godot puts depth_draw_never into the transparent pass, after the stereo
// check's overlay), drawn after the bodies (Renderer.FLOOR_PRIORITY).
//
// Per pixel: where its ray ends, on the floor or in the sky (geo_floor, geo.gdshaderinc), then the
// colour there. Each eye (geo_eye) is worked out per corner in vertex() and handed on flat.
// fov_on (our own foveation, floor_fov.gd): the colours were worked out already, into fov_tex, a
// texel per pixel where the eye looks and coarser away from it (shaders/floor_fov.gdshaderinc);
// each pixel takes its place there by the same warp, with the numbers fov_warp holds for its eye.
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled;

#include "res://shaders/geo_uniforms.gdshaderinc"
#ifdef GRAVITY
uniform sampler2D g_grav : filter_linear, repeat_disable;  // floor gravity in g at |l| in [0, g_gravx.x]
uniform vec2 g_gravx;                                       // (that end, beta: f = r + beta / r^2 beyond)
#endif
#include "res://shaders/geo.gdshaderinc"
#include "res://shaders/look.gdshaderinc"

varying flat float v_el;
varying flat vec3 v_eye;      // the eye's r, the root of its u on the fillet, r - rho0 (geo_r, geo_u, geo_dr)
varying flat vec3 v_en;
varying flat vec4 v_ex;
varying flat vec4 v_ey;
varying flat vec4 v_ez;
varying vec3 v_ray;
varying vec2 v_clip;
uniform bool fov_on = false;
uniform sampler2DArray fov_tex : filter_linear, repeat_disable;
uniform sampler2D fov_warp : filter_nearest, repeat_disable;   // per eye (row): (gaze x, y, k, n), (A0, A1 along x, then y)

void vertex() {
	// a quad over the whole view at the far plane (reversed depth: 0), so that any body's depth wins;
	// each corner's ray from the eye (geo_eye: in multiview not from the camera's origin)
	POSITION = vec4(VERTEX.xy, 0.0, 1.0);
	v_clip = VERTEX.xy;
	vec4 p = inverse(PROJECTION_MATRIX) * vec4(VERTEX.xy, 0.5, 1.0);
	v_ray = p.xyz / p.w - EYE_OFFSET;
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
	if (fov_on) {
		int v = int(VIEW_INDEX);
		vec4 wg = texelFetch(fov_warp, ivec2(0, v), 0), wa = texelFetch(fov_warp, ivec2(1, v), 0);
		vec2 t = (asinh(wg.z * (v_clip - wg.xy)) / wg.z - wa.xz) / (wa.yw - wa.xz);
		ALBEDO = textureLod(fov_tex, vec3(t, float(v)), 0.0).rgb;
	} else {
		vec3 d = normalize(v_ray);
		vec4 D = d.x * v_ex + d.y * v_ey + d.z * v_ez;
		float lh, way, skys;
		vec2 nh;
		vec3 skyd;
		bool hit = geo_floor(v_el, v_eye, v_en, D, lh, nh, way, skyd, skys);
		vec3 col;
		if (hit) {
			vec3 a = look_ground_at(lh, nh);
			col = look_ground(a, dFdx(a), dFdy(a), 1.0, lh, way);
		} else {
			if (skys < 0.0) skyd.x = -skyd.x;
			col = look_sky(normalize(skyd), skys);
		}
		ALBEDO = col;
	}
}
