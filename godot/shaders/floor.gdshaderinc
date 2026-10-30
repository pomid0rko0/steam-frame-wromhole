// The floor and the sky, per pixel (floor.gdshader; floor_gravity.gdshader defines GRAVITY: the
// floor coloured by gravity, docs/gravity.md «Показ»). A quad over the whole view behind
// everything: the bodies (body.gdshader) are drawn first, and where they are this never runs.
// The floor never hides a body (docs/geometry.md), so its depth is the far plane's: it writes
// nothing new. Opaque (Godot puts depth_draw_never into the transparent pass, after the stereo
// check's overlay), drawn after the bodies (Renderer.FLOOR_PRIORITY).
//
// Per pixel: the ray's plane and impact b, where in that plane the floor is (the angle phif from
// the eye), and from the sweep (geo.gdshaderinc) where the ray turns that far, or that it reaches
// the sky first. Rays of an eye in a flat universe that never come near the throat go straight.
// Each eye (geo_eye) is worked out per corner in vertex() and handed on flat.
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled;

#include "res://shaders/geo_uniforms.gdshaderinc"
#include "res://shaders/geo.gdshaderinc"
#include "res://shaders/look.gdshaderinc"

#ifdef GRAVITY
uniform sampler2D g_grav : filter_linear, repeat_disable;  // floor gravity in g at |l| in [0, g_gravx.x]
uniform vec2 g_gravx;                                       // (that end, beta: f = r + beta / r^2 beyond)
#endif

varying flat float v_el;
varying flat vec2 v_eye;      // the eye's r, and the root of its u on the fillet (geo_r, geo_u): per eye
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
	v_eye = vec2(geo_r(abs(el)), sqrt(geo_u(abs(el))));
	v_en = en;
	v_ex = ex;
	v_ey = ey;
	v_ez = ez;
}

void fragment() {
	vec3 d = normalize(v_ray);
	vec4 D = d.x * v_ex + d.y * v_ey + d.z * v_ez;
	float side = v_el < 0.0 ? -1.0 : 1.0;
	float le = abs(v_el);
	float re = v_eye.x;
	float L = g_prof.w, Rout = g_prof2.x;
	float ca = side * D.x;                  // along the outward radial direction
	float sa = length(D.yzw);
	vec3 t = sa > 1e-7 ? D.yzw / sa : normalize(cross(v_en, vec3(0.0, 1.0, 0.0)));
	float nrm = 1.0 / sqrt(ca * ca + sa * sa);
	ca *= nrm;
	sa *= nrm;
	float b = re * sa;
	// where the floor is in the ray's plane: the angle from the eye (0, pi), the eye above it
	float phif = atan(v_en.z, -t.z);
	bool hit = false;
	float lh = 0.0;                         // the floor point's l, its n's x and y (any length), the way's length
	vec2 nh = vec2(1.0, 0.0);
	float way = 0.0;
	vec3 skyd = vec3(0.0, 0.0, 1.0);        // else: the sky's chart direction in universe skys
	float skys = side;
	if (le >= L && (ca >= 0.0 || b >= Rout)) {
		// straight: in the eye's sheet (R^4's xyz there)
		vec3 xe = re * v_en;
		vec3 dc = ca * v_en + sa * t;
		if (dc.z < 0.0) {
			way = -xe.z / dc.z;
			vec2 p = xe.xy + way * dc.xy;
			float rp = length(p);
			hit = true;
			lh = side * (L + rp - Rout);
			nh = p;
		} else {
			skyd = dc;
		}
	} else {
		// what the ray's sweeps share: its impact, the cylinder's rates, the fillet's closed forms
		float oms = ca * ca / (1.0 + sa);   // 1 - sin: exact for rays along the sphere of the eye
		float gap_e = re * oms;
		float sigma = geo_sigma((re - g_prof.x) - gap_e);
		float R2 = 2.0 * g_prof.y;
		float Lc = g_prof.z;
		bool pass = b < g_prof2.z;
		float k = sqrt(max(-R2 * sigma * (g_prof.x + b), 0.0));
		vec2 cyl = pass ? vec2(b / g_prof.x, g_prof.x) / max(k, 1e-12) : vec2(0.0);   // per metre of l
		vec2 cylL = cyl * Lc;
		float ul = max(sigma, g_prof2.y);
		float span = 0.5 - ul;
		vec2 f0 = geo_F(b, ul);
		vec2 f1 = geo_Fu(b, ul, f0);
		float s0 = sqrt(ul), e0 = sqrt(ul - sigma);
		float D = s0 + e0, P0 = s0 * e0;
		float sL = sqrt(max(0.5 - sigma, 0.0));
		float wL = 2.0 * log((0.70710678 + sL) / D);
		// from the ray's origin to the curved zone's edge, and to the eye
		vec2 SL = cylL + f0 * wL + f1 * (0.70710678 * sL - P0 + (0.5 * sigma - ul) * wL) + geo_poly(sigma);
		float qR = sqrt(max((Rout - b) * (Rout + b), 0.0));
		vec2 se;
		if (le >= L) {
			float q2 = sqrt(max(gap_e * (re + b), 0.0));
			float dq = (re - Rout) * (re + Rout) / max(qR + q2, 1e-20);
			se = SL + vec2(atan(b * dq, b * b + qR * q2), dq);
		} else if (le > Lc) {
			float su = v_eye.y, eu = sqrt(gap_e / R2);
			float ue = su * su;
			float w = 2.0 * log((su + eu) / D);
			se = cylL + f0 * w + f1 * (su * eu - P0 + (0.5 * sigma - ul) * w) + geo_G(sigma, sqrt(max(ue - ul, 0.0) / span));
		} else {
			se = cyl * le;
		}
		float ab = geo_asin(b / Rout);
		float pinf = SL.x + ab;             // to infinity
		float target = 0.0;                 // the sweep from the ray's origin to the floor point
		float far = 1.0;                    // +1: the point's |l| on the eye's side, -1 the other
		float sgnw = 1.0;                   // the way: se.y + sgnw * (length from the origin)
		float tot = 0.0;
		if (ca >= 0.0) {
			tot = pinf - se.x;
			target = se.x + phif;
		} else {
			tot = se.x + pinf;
			target = abs(se.x - phif);
			sgnw = phif <= se.x ? -1.0 : 1.0;
			if (pass) {
				// through the throat
				far = phif <= se.x ? 1.0 : -1.0;
				sgnw = -far;
				skys = -side;
			}
		}
		// t is done with before the fillet's inversion (it costs registers there): where it ends, the
		// sky's direction, and the floor point's
		hit = phif < tot;
		if (!hit) {
			skyd = cos(tot) * v_en + sin(tot) * t;
		} else {
			nh = (cos(phif) * v_en + sin(phif) * t).xy;
			vec2 at;                        // (|l|, length from the origin)
			if (target >= SL.x) {
				// beyond the curved zone: straight
				float a = target - SL.x + 0.5 * GEO_PI - ab;
				hit = a < 0.5 * GEO_PI;
				if (!hit) skyd = cos(tot) * v_en + sin(tot) * t;
				float r = b / cos(a);
				at = vec2(L + r - Rout, SL.y + sqrt(max((r - b) * (r + b), 0.0)) - qR);
			} else if (pass && target <= cylL.x) {
				at = vec2(target / max(cyl.x, 1e-20), 0.0);
				at.y = cyl.y * at.x;
			} else {
				// the fillet: the weight inverted exactly, a Newton step on the closed forms, one with the table
				float pf = target - cylL.x;
				float X = D * exp(min(pf / max(2.0 * f0.x, 1e-20), 40.0));
				float du;
				if (sigma > g_prof2.y) { float y = 0.5 * (X - sigma / X); du = y * y; }
				else { float y = 0.5 * (X + sigma / X); du = y * y - ul; }
				float v = clamp(sqrt(max(du, 0.0) / span), 0.0, 1.0);
				vec2 val = vec2(0.0);
				for (int i = 0; i < 2; i++) {
					float u = ul + span * v * v;
					float su = sqrt(u), eu = sqrt(u - ul + e0 * e0);
					float w = 2.0 * log((su + eu) / D);
					val = f0 * w + f1 * (su * eu - P0 + (0.5 * sigma - ul) * w);
					if (i == 1) val += geo_G(sigma, v);
					float der = geo_F(b, u).x * 2.0 * span * v / (su * eu);
					if (der > 0.0) v = clamp(v - (val.x - pf) / der, 0.0, 1.0);
				}
				float u = ul + span * v * v;
				at = vec2(Lc + g_prof.y * (2.0 * geo_asin(sqrt(u)) - g_prof2.w), cylL.y + val.y);
			}
			lh = side * far * at.x;
			way = ca >= 0.0 ? at.y - se.y : se.y + sgnw * at.y;
		}
	}
	vec3 col;
	if (hit) {
		vec2 c = look_floor_coords(lh, vec3(nh, 0.0));
		vec2 fw = fwidth(c);
		// the sectors' seam at the chart's -x: the other branch of the angle there
		fw.y = min(fw.y, fwidth(fract(c.y / 24.0 + 0.5) * 24.0));
#ifdef GRAVITY
		float al = abs(lh);
		float g;
		if (al < g_gravx.x) g = textureLod(g_grav, vec2(al / g_gravx.x, 0.5), 0.0).r;
		else { float r = geo_r(al); g = 1.0 + g_gravx.y / (r * r * r); }
		float t = look_grav_level(g);
		vec3 base = look_grav_colour(t);
		col = look_grav_contours(look_floor(c, fw, base, base * 0.85), t);     // the checker as brightness
#else
		col = lh >= 0.0 ? look_floor(c, fw, LOOK_FLOOR_A[0], LOOK_FLOOR_A[1]) : look_floor(c, fw, LOOK_FLOOR_B[0], LOOK_FLOOR_B[1]);
#endif
		vec3 hor = lh >= 0.0 ? LOOK_HORIZON_A : LOOK_HORIZON_B;
		col = mix(col, hor, 1.0 - exp(-way / LOOK_HAZE));
	} else {
		if (skys < 0.0) skyd.x = -skyd.x;
		col = look_sky(normalize(skyd), skys);
	}
	ALBEDO = col;
}
