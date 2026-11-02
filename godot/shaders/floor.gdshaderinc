// The floor, the sky and what is seen through the curved zone, per pixel (floor.gdshader;
// floor_gravity.gdshader defines GRAVITY: the floor coloured by gravity, docs/gravity.md «Показ»).
// A quad over the whole view behind everything: the bodies seen straight and those in the curved
// zone (body.gdshader) are drawn first, and where they are this never runs. Nothing it draws hides
// one of them: a body seen straight is before the zone along its ray, a body in the zone before the
// way out of it, and the floor never hides what stands on it. So its depth is the far plane's: it
// writes nothing new. Opaque (Godot puts depth_draw_never into the transparent pass, after the
// stereo check's overlay), drawn after the bodies (Renderer.FLOOR_PRIORITY).
//
// Per pixel: the ray's way out of the zone (geo_exit, geo.gdshaderinc), then along the straight line
// what it meets (lens_trace, lens.gdshaderinc) and its colour. Each eye (geo_eye) is worked out per
// corner in vertex() and handed on flat.
// fov_on (foveation.gd): the colours were worked out already, into fov_tex, a texel per pixel round
// where the eye looks and coarser away from it (shaders/foveation.gdshaderinc); each pixel takes
// its place there by the same warp, with the numbers fov_warp holds for its eye.
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
varying vec2 v_clip;
uniform bool fov_on = false;
uniform bool lens_mark = false;    // tests: blue where the ray goes through the curved zone, else black
uniform sampler2DArray fov_tex : filter_linear, repeat_disable;
uniform sampler2D fov_warp : filter_nearest, repeat_disable;   // per eye (a row): (g, c), (r0, m, texels across, down), (pixels across, down) (foveation.gd)

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
		// the pixel r from g: at c + (p - g) F(r) / r in the texture
		int v = int(VIEW_INDEX);
		vec4 w0 = texelFetch(fov_warp, ivec2(0, v), 0), w1 = texelFetch(fov_warp, ivec2(1, v), 0);
		vec2 q = (v_clip * 0.5 + 0.5) * texelFetch(fov_warp, ivec2(2, v), 0).xy - w0.xy;
		float r = length(q);
		float k = r > w1.x ? (w1.x + asinh(w1.y * (r - w1.x)) / w1.y) / r : 1.0;
		ALBEDO = textureLod(fov_tex, vec3((w0.zw + k * q) / w1.zw, float(v)), 0.0).rgb;
	} else {
		vec3 d = normalize(v_ray);
		vec4 D = d.x * v_ex + d.y * v_ey + d.z * v_ez;
		vec3 pos, dir;
		float sheet, way;
		bool lensed = geo_exit(v_el, v_eye, v_en, D, pos, dir, sheet, way);
		LensSeen s = lens_trace(pos, dir, sheet, way, lensed);
		// the floor's pattern and a cube's edges from their neighbours' (outside any branch)
		vec3 a = look_ground_at(lens_floor_xy(pos, dir, sheet));
		float e = dot(s.box, s.box) > 0.0 ? look_box_edge(s.box) : -1.0;
		ALBEDO = lens_colour(s, a, dFdx(a), dFdy(a), vec2(e, fwidth(e)), 1.0);
		if (lens_mark) ALBEDO = lensed ? vec3(0.0, 0.0, 1.0) : vec3(0.0);
	}
}
