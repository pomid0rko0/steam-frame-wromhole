// The floor, the sky and what is seen through the curved zone, per pixel (floor.gdshader;
// floor_gravity.gdshader defines GRAVITY: the floor coloured by gravity, docs/gravity.md «Показ»).
// A quad over the whole view behind everything: the bodies seen straight and those in the curved
// zone (body.gdshader) are drawn first, and where they are this never runs. Nothing it draws hides
// one of them: a body seen straight is before the zone along its ray, a body in the zone before the
// way out of it, and the floor never hides what stands on it. So its depth is the far plane's: it
// writes nothing new. Opaque (Godot puts depth_draw_never into the transparent pass, after the
// stereo check's overlay), drawn after the bodies (Renderer.FLOOR_PRIORITY).
//
// Per pixel: the ray's way across the zone (geo_exit_ray, geo_exit_way: geo.gdshaderinc), then what
// it meets (lens_seen, lens.gdshaderinc) and its colour. Each eye (geo_eye) is worked out per
// corner in vertex() and handed on flat. Under foveation (foveation.gd) the same per texel of its
// texture (foveation.gdshaderinc), and the quad is drawn with floor_sample.gdshader instead.
//
// FLOOR_ZONE (floor_zone.gdshader, floor_gravity_zone.gdshader: the floor reaches into the zone's
// ball, lift < Rout): there the floor can hide a body in the zone, or one of its images (a way to it
// that goes under the floor first), so this writes the depth of what it draws, by the light's way to
// it as the zone's meshes and the tail do (body.gdshaderinc, zone_tail.gdshader), and the depth test
// sorts them; a pixel under a body is then worked out too.
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled;

#include "res://shaders/geo_uniforms.gdshaderinc"
#include "res://shaders/lens_uniforms.gdshaderinc"
#include "res://shaders/geo.gdshaderinc"
#include "res://shaders/look.gdshaderinc"
#include "res://shaders/lens.gdshaderinc"

varying flat float v_el;
varying flat vec3 v_eye;      // the eye's r, the root of its u on the fillet, r - rho0 (geo_r, geo_u, geo_dr)
varying flat vec3 v_en;
varying flat vec4 v_ex;
varying flat vec4 v_ey;
varying flat vec4 v_ez;
varying vec3 v_ray;
uniform bool lens_mark = false;    // tests: blue where the ray goes through the curved zone, else black
#ifdef FLOOR_ZONE
uniform float lens_far = 4000.0;   // the camera's far plane (Main.FAR): lens_depth
#endif

void vertex() {
	// a quad over the whole view at the far plane (reversed depth: 0), so that any body's depth wins;
	// each corner's ray from the eye (geo_eye: in multiview not from the camera's origin)
	POSITION = vec4(VERTEX.xy, 0.0, 1.0);
	v_ray = geo_view_ray(PROJECTION_MATRIX, VERTEX.xy);
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
	// two pixels' turn (lens_near)
	float ang = 2.0 * length(fwidth(d));
	float ca, sa, b, gap, sigma;
	vec3 t;
	bool lensed = geo_exit_ray(v_el, v_eye, v_en, D, ca, sa, t, b, gap, sigma);
	vec3 w = vec3(0.0);
	if (lensed) w = geo_exit_way(abs(v_el), v_eye, b, sigma, gap, ca >= 0.0);
	LensSeen s = lens_seen(v_el, v_eye, v_en, t, ca, sa, b, gap, sigma, lensed, w, lens_near(v_el, v_eye.x, D, ang));
	// the floor's pattern and a cube's edges from their neighbours' (outside any branch)
	vec4 a = s.a;
	float e = dot(s.box, s.box) > 0.0 ? look_box_edge(s.box) : -1.0;
	ALBEDO = lens_colour(s, dFdx(a), dFdy(a), vec2(e, fwidth(e)), 1.0);
	if (lens_mark) ALBEDO = lensed ? vec3(0.0, 0.0, 1.0) : vec3(0.0);
#ifdef FLOOR_ZONE
	DEPTH = s.kind == 0 ? 0.0 : lens_depth(PROJECTION_MATRIX, EYE_OFFSET, d, s.way, lens_far);
#endif
}
