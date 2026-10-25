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
// Gravity (main.gd, set_gravity_map): the potential is g f(l) n_z (WormholeSpace.gravity_f).
// grav_map colours the floor by the strength of gravity there, g f / r; wh_sliceOn adds arrows
// of the field on the vertical surface x = 0 through the wormhole, facing the start. Tables over
// the shell |l| = i L / 32; outside f / r = 1 + beta / r^3 and f' = 1 - 2 beta / r^3.
uniform bool grav_map = false;
uniform bool wh_sliceOn = false;
uniform float grav_tab[33];     // f / r, in g
uniform float grav_dtab[33];    // f'
uniform float grav_beta = 0.0;

#define WH_SLICE
#include "res://shaders/wormhole_core.gdshaderinc"

// (f / r, f') at l
vec2 gravity_at(float l) {
	float al = abs(l);
	float L = wh_Lsh();
	float sg = l < 0.0 ? -1.0 : 1.0;
	if (al >= L) {
		float r = al - L + wh_Rout();
		float b = grav_beta / (r * r * r);
		return vec2(1.0 + b, sg * (1.0 - 2.0 * b));
	}
	float x = al / L * 32.0;
	int i = min(int(x), 31);
	float t = x - float(i);
	return vec2(mix(grav_tab[i], grav_tab[i + 1], t), sg * mix(grav_dtab[i], grav_dtab[i + 1], t));
}

// optozorax's palette: dark is no gravity, yellow 1 g, then red and white at 10 g; in bands of
// 0.1 g below 1 g and of a tenth of a decade above. band_t(g) is the band coordinate.
float band_t(float g) {
	return g < 1.0 ? g * 10.0 : 10.0 + log(g) / log(10.0) * 10.0;
}

vec3 gravity_colour(float t) {
	float band = floor(t);
	float u = clamp((band + 0.5) / 10.0, 0.0, 1.0);
	vec3 c = u < 0.5 ? mix(vec3(0.03, 0.03, 0.10), vec3(0.45, 0.08, 0.50), u * 2.0)
			: mix(vec3(0.45, 0.08, 0.50), vec3(0.95, 0.40, 0.12), u * 2.0 - 1.0);
	c = mix(c, vec3(0.95, 0.80, 0.18), smoothstep(0.85, 0.95, u));
	if (t >= 10.0) {
		float v = clamp((band - 9.5) / 10.0, 0.0, 1.0);
		c = v < 0.5 ? mix(vec3(0.95, 0.80, 0.18), vec3(0.95, 0.12, 0.05), v * 2.0)
				: mix(vec3(0.95, 0.12, 0.05), vec3(1.0), v * 2.0 - 1.0);
	}
	return c;
}

const float ARROW_STEP = 1.0;      // metres between arrows, along l and across
const float SLICE_REACH = 4.5;     // arrows up to this far outside the shell

// The arrow of the field nearest to the slice point (l, n), n = (0, cos a, sin a): arrows sit on
// rings l = k ARROW_STEP, spaced about ARROW_STEP along each half circle above the floor.
// Length: 0.6 ARROW_STEP at 1 g. Colour: the palette. Returns colour and coverage; foot is the
// size of a pixel there (metres), for smooth edges.
vec4 slice_arrow(float l, vec3 n, float foot) {
	if (n.z <= 0.0 || abs(l) > wh_Lsh() + SLICE_REACH) return vec4(0.0);
	float a = atan(n.z, n.y);
	float lk = round(l / ARROW_STEP) * ARROW_STEP;
	float rk = wh_r(lk);
	float N = max(1.0, round(WH_PI * rk / ARROW_STEP));
	float j = min(floor(a * N / WH_PI), N - 1.0);
	float aj = (j + 0.5) * WH_PI / N;
	vec2 G = gravity_at(lk);
	// the field at the node, components along l and along a (unit vectors), in g
	vec2 g = vec2(-G.y * sin(aj), -G.x * cos(aj));
	float gm = length(g);
	if (gm < 1e-4) return vec4(0.0);
	vec2 u = g / gm;
	vec2 q = vec2(l - lk, rk * (a - aj));
	float s = dot(q, u);
	float c = abs(dot(q, vec2(-u.y, u.x)));
	float len = 0.6 * ARROW_STEP * min(gm, 1.4);
	float hl = min(0.3 * ARROW_STEP, 0.6 * len);    // head length
	float hw = 0.13 * ARROW_STEP;                   // head half width
	float sw = 0.035 * ARROW_STEP;                  // shaft half width
	float s0 = 0.5 * len - hl;
	float dShaft = max(c - sw, max(-0.5 * len - s, s - s0));
	float dHead = max(s0 - s, ((s - s0) * hw + (c - hw) * hl) * inversesqrt(hw * hw + hl * hl));
	float d = min(dShaft, dHead);
	float f = max(foot, 1e-4);
	float cover = clamp(0.5 - d / f, 0.0, 1.0);
	float rim = clamp(0.5 - (d + 0.02 * ARROW_STEP) / f, 0.0, 1.0);    // dark outline
	vec3 col = mix(vec3(0.02), 1.15 * gravity_colour(band_t(gm)), rim);
	return vec4(col, 0.92 * cover);
}

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
	float pix = length(fwidth(pd));                                 // a pixel's angle, radians
	vec4 V = pd.x * v_f0 + pd.y * v_f1 + pd.z * v_f2;
	vec4 dbg;
	WhSlice sl;
	vec3 col = wh_trace(v_l, v_n, V.x, V.yzw, dbg, sl);
	// derivatives outside the branches: the floor's band coordinate (garbage off the floor)
	float bt = band_t(gravity_at(dbg.y).x);
	float bw = max(fwidth(bt), 1e-4);
	if (grav_map && (dbg.x == 2.0 || dbg.x == 3.0)) {
		// floor: the colour of its gravity, keeping the floor's lines and checker as brightness,
		// darker at the bands' edges (the contours)
		float lum = dot(col, vec3(0.299, 0.587, 0.114));
		float base = dbg.x == 3.0 ? 0.5 : 0.42;
		float edge = clamp(abs(fract(bt + 0.5) - 0.5) / bw, 0.0, 1.0);
		col = gravity_colour(bt) * (0.8 + 0.2 * edge) * clamp(0.85 + 1.2 * (lum - base), 0.6, 1.3);
	}
	if (sl.found) {
		vec4 ar = slice_arrow(sl.l, sl.n, sl.dist * pix);
		col = mix(col, ar.rgb, ar.a);
	}
	ALBEDO = col;
}
