// The floor and the sky, per pixel (floor.gdshader; floor_gravity.gdshader defines GRAVITY: the
// floor coloured by gravity, docs/gravity.md «Показ»). A quad over the whole view behind
// everything: the bodies (body.gdshader) are drawn first, and where they are this never runs.
// The floor never hides a body (docs/geometry.md), so its depth is the far plane's: it writes
// nothing new. Opaque (Godot puts depth_draw_never into the transparent pass, after the stereo
// check's overlay), drawn after the bodies (Renderer.FLOOR_PRIORITY).
//
// Per pixel: where its ray ends, on the floor or in the sky (geo_floor, geo.gdshaderinc), then the
// colour there. Each eye (geo_eye) is worked out per corner in vertex() and handed on flat.
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled;

#include "res://shaders/geo_uniforms.gdshaderinc"
#include "res://shaders/geo.gdshaderinc"
#include "res://shaders/look.gdshaderinc"

#ifdef GRAVITY
uniform sampler2D g_grav : filter_linear, repeat_disable;  // floor gravity in g at |l| in [0, g_gravx.x]
uniform vec2 g_gravx;                                       // (that end, beta: f = r + beta / r^2 beyond)
#endif

varying flat float v_el;
varying flat vec3 v_eye;      // the eye's r, the root of its u on the fillet, r - rho0 (geo_r, geo_u, geo_dr)
varying flat vec3 v_en;
varying flat vec4 v_ex;
varying flat vec4 v_ey;
varying flat vec4 v_ez;
varying vec3 v_ray;

void vertex() {
	// a quad over the whole view at the far plane (reversed depth: 0), so that any body's depth wins;
	// each corner's ray from the eye (geo_eye: in multiview not from the camera's origin)
	POSITION = vec4(VERTEX.xy, 0.0, 1.0);
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
	vec3 d = normalize(v_ray);
	vec4 D = d.x * v_ex + d.y * v_ey + d.z * v_ez;
	float lh, way, skys;
	vec2 nh;
	vec3 skyd;
	bool hit = geo_floor(v_el, v_eye, v_en, D, lh, nh, way, skyd, skys);
	vec3 col;
	if (hit) {
		vec2 c = look_floor_coords(lh, vec3(nh, 0.0));
		// the footprint; across the sectors' seam at the chart's -x the angle jumps by 24: taken out
		vec2 dx = dFdx(c), dy = dFdy(c);
		dx.y -= 24.0 * round(dx.y / 24.0);
		dy.y -= 24.0 * round(dy.y / 24.0);
		vec2 fw = abs(dx) + abs(dy);
#ifdef GRAVITY
		float al = abs(lh);
		float g;
		if (al < g_gravx.x) g = textureLod(g_grav, vec2(al / g_gravx.x, 0.5), 0.0).r;
		else { float r = geo_r(al); g = 1.0 + g_gravx.y / (r * r * r); }
		float t = look_grav_level(g);
		vec3 base = look_grav_colour(t);
		col = look_grav_contours(look_floor(c, fw, geo_r(al), base, base * 0.85), t);     // the checker as brightness
#else
		col = look_floor(c, fw, geo_r(abs(lh)), lh >= 0.0 ? LOOK_FLOOR_A[0] : LOOK_FLOOR_B[0], lh >= 0.0 ? LOOK_FLOOR_A[1] : LOOK_FLOOR_B[1]);
#endif
		vec3 hor = lh >= 0.0 ? LOOK_HORIZON_A : LOOK_HORIZON_B;
		col = mix(col, hor, 1.0 - exp(-way / LOOK_HAZE));
	} else {
		if (skys < 0.0) skyd.x = -skyd.x;
		col = look_sky(normalize(skyd), skys);
	}
	ALBEDO = col;
}
