shader_type spatial;
// The tail of the zone bodies' images, per pixel (zone_tail.gdshaderinc): a band of the view round
// each eye's inward radial direction (tail_band: the rays that wind round the throat's cylinder
// enough), a ring of ZONE_TAIL_SEGMENTS quads (Renderer._tail_mesh: VERTEX.x the way round, VERTEX.y
// 0 its inner edge, 1 its outer). Where a pixel's ray meets a body past the meshes' images it is
// drawn at the depth of the light's way there, as the meshes are (body.gdshaderinc), lit as they
// are; a pixel whose ray meets none is dropped. Bodies as Renderer.set_objects has them in ZoneSections'
// slots: balls' first, cubes' from TAIL_CUBE0.
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled;

#include "res://shaders/geo_uniforms.gdshaderinc"
#include "res://shaders/geo.gdshaderinc"
#include "res://shaders/look.gdshaderinc"
#include "res://shaders/zone.gdshaderinc"
#include "res://shaders/zone_tail.gdshaderinc"

const int TAIL_CUBE0 = 12;          // Renderer.MAX_BALLS: the cubes' first slot
const int TAIL_SLOTS = 20;          // Renderer.MAX_BALLS + MAX_CUBES
uniform vec4 tail_rows[80];         // per slot: C, E1, E2, (size, 0, 0, 0)
uniform vec4 tail_col[20];          // per slot: its colour (linear)
uniform ivec2 tail_count = ivec2(0);   // balls, cubes in the zone
uniform float tail_psi_min = 59.6902604182061;   // (Renderer.ZONE_IMAGES - 1) pi: the meshes' last image on

varying flat float v_el;
varying flat vec3 v_eye;      // the eye's r, the root of its u on the fillet, r - rho0 (floor.gdshaderinc)
varying flat vec3 v_en;
varying flat vec4 v_ex;
varying flat vec4 v_ey;
varying flat vec4 v_ez;
varying flat vec2 v_band;
varying flat vec3 v_off;      // the eye in the camera's space (EYE_OFFSET)
varying vec3 v_ray;

void vertex() {
	float el;
	vec3 en;
	vec4 ex, ey, ez;
	geo_eye(INV_VIEW_MATRIX, EYE_OFFSET, el, en, ex, ey, ez);
	vec3 eye = vec3(geo_r(abs(el)), sqrt(geo_u(abs(el))), geo_dr(abs(el)));
	vec2 band = tail_band(el, eye, tail_psi_min);
	v_el = el;
	v_eye = eye;
	v_en = en;
	v_ex = ex;
	v_ey = ey;
	v_ez = ez;
	v_band = band;
	v_off = EYE_OFFSET;
	// the inward radial direction in the camera's space, and two directions across it
	float side = el < 0.0 ? -1.0 : 1.0;
	vec3 ax = -side * vec3(ex.x, ey.x, ez.x);
	ax /= max(length(ax), GEO_TINY20);
	vec3 b1 = normalize(cross(ax, abs(ax.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
	vec3 b2 = cross(ax, b1);
	// the ring's edges a hair past the band: its sides are chords of the circles round the axis
	float chi = VERTEX.y < 0.5 ? max(band.x - 2e-3, 0.0) : min(band.y + 2e-3, GEO_PI);
	vec2 sp = geo_sincos(2.0 * GEO_PI * VERTEX.x);
	vec2 sc = geo_sincos(chi);
	vec3 d = sc.y * ax + sc.x * (sp.y * b1 + sp.x * b2);
	v_ray = d;
	bool none = band.x >= band.y || tail_count.x + tail_count.y == 0;
	POSITION = none ? vec4(2.0, 2.0, 2.0, 1.0) : PROJECTION_MATRIX * vec4(EYE_OFFSET + d, 1.0);
}

void fragment() {
	vec3 d = normalize(v_ray);
	vec4 D = d.x * v_ex + d.y * v_ey + d.z * v_ez;
	TailRay z;
	if (!tail_ray(v_el, v_eye, v_en, D, tail_psi_min, z)) discard;
	float best = 1e30, by = 0.0, bang = 0.0;
	int bon = 0, slot = -1;
	for (int i = 0; i < TAIL_SLOTS; i++) {
		bool cube = i >= TAIL_CUBE0;
		int k = cube ? i - TAIL_CUBE0 : i;
		if (k >= (cube ? tail_count.y : tail_count.x)) continue;
		TailBody q = tail_body(cube, tail_rows[4 * i], tail_rows[4 * i + 1], tail_rows[4 * i + 2], tail_rows[4 * i + 3].x);
		float y, ang, psi;
		int on;
		if (tail_meet(z, q, tail_psi_min, y, ang, psi, on) && y < best) {
			best = y;
			by = y;
			bang = ang;
			bon = on;
			slot = i;
		}
	}
	if (slot < 0) discard;
	vec4 P, arrive;
	float len;
	tail_hit(z, by, bang, bon, P, arrive, len);
	bool cube = slot >= TAIL_CUBE0;
	TailBody q = tail_body(cube, tail_rows[4 * slot], tail_rows[4 * slot + 1], tail_rows[4 * slot + 2], tail_rows[4 * slot + 3].x);
	float l = bon == 2 ? z.dl * (g_prof.w + length(P.xyz) - g_prof2.x) : tail_l(z, by);
	// lit as body.gdshaderinc lights the zone's balls and cubes
	vec4 Np = geo_normal(P);
	vec4 s4 = look_sun4(l);
	vec4 sun = s4 - dot(s4, Np) * Np;
	vec4 up4 = vec4(0.0, 0.0, 1.0, 0.0) - Np.z * Np;
	vec4 sh = sun * inversesqrt(max(dot(sun, sun), 1e-12));
	vec4 uh = up4 * inversesqrt(max(dot(up4, up4), 1e-12));
	vec3 col;
	vec4 qd = P - q.C;
	if (cube) {
		vec3 box = vec3(dot(qd, q.E[0]), dot(qd, q.E[1]), dot(qd, q.E[2])) / q.size;
		vec3 ab = abs(box);
		int f = ab.x >= ab.y && ab.x >= ab.z ? 0 : (ab.y >= ab.z ? 1 : 2);
		vec4 a = q.E[f] - dot(q.E[f], Np) * Np;
		a *= (box[f] < 0.0 ? -1.0 : 1.0) * inversesqrt(max(dot(a, a), 1e-12));
		col = look_body(tail_col[slot].rgb, dot(a, sh), dot(a, uh), -dot(a, arrive), l);
		float e = look_box_edge(box);
		float fw = max(fwidth(e), 1e-5);
		col *= mix(0.45, 1.0, clamp((e - 0.04) / fw + 0.5, 0.0, 1.0));
	} else {
		vec4 n = qd - dot(qd, Np) * Np;
		n *= inversesqrt(max(dot(n, n), 1e-12));
		col = look_body(tail_col[slot].rgb, dot(n, sh), dot(n, uh), -dot(n, arrive), l);
	}
	if (!geo_finite(col.r + col.g + col.b + len)) discard;
	ALBEDO = col;
	vec4 c = PROJECTION_MATRIX * vec4(v_off + len * d, 1.0);
	DEPTH = c.z / c.w;
}
