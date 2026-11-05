shader_type spatial;
// The tail of the zone bodies' images, per pixel (zone_tail.gdshaderinc), only where a body's tail can
// be: an instance per body slot and side, a ring sector of the view round the eye's inward radial
// direction (Renderer._zone_mesh: VERTEX.x across the sector, VERTEX.y 0 its inner edge, 1 its outer):
// round the axis the azimuths whose rays' planes pass by the body (tail_sector: two, round its
// direction and the opposite), off it the angles whose rays wind round the throat's cylinder enough
// on their way to it (tail_band). Where a pixel's ray meets that body past the meshes' images it is
// drawn at the depth of the light's way there, as the meshes are (body.gdshaderinc), lit as they are;
// a pixel whose ray meets it not is dropped. Bodies as Renderer.set_objects has them in ZoneSections'
// slots: balls' first, cubes' from TAIL_CUBE0; instance i is slot i / 2, side i % 2.
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled;

#include "res://shaders/geo_uniforms.gdshaderinc"
#include "res://shaders/geo.gdshaderinc"
#include "res://shaders/look.gdshaderinc"
#include "res://shaders/zone.gdshaderinc"
#include "res://shaders/zone_tail.gdshaderinc"

const int TAIL_CUBE0 = 12;          // Renderer.MAX_BALLS: the cubes' first slot
uniform vec4 tail_rows[80];         // per slot: C, E1, E2, (size, 0, 0, 0)
uniform vec4 tail_col[20];          // per slot: its colour (linear)
uniform ivec2 tail_count = ivec2(0);   // balls, cubes in the zone
uniform float tail_psi_min = 59.6902604182061;   // (Renderer.ZONE_IMAGES - 1) pi: the meshes' last image on
uniform float tail_segments = 32.0;    // the mesh's quads across a sector (Renderer.TAIL_SEGMENTS)
uniform float tail_far = 4000.0;       // m: the camera's far plane (Main.FAR)

varying flat float v_el;
varying flat vec3 v_eye;      // the eye's r, the root of its u on the fillet, r - rho0 (floor.gdshaderinc)
varying flat vec3 v_en;
varying flat vec4 v_ex;
varying flat vec4 v_ey;
varying flat vec4 v_ez;
varying flat vec3 v_off;      // the eye in the camera's space (EYE_OFFSET)
varying flat float v_slot;      // the body's slot
varying vec3 v_ray;

TailBody slot_body(int s) {
	return tail_body(s >= TAIL_CUBE0, tail_rows[4 * s], tail_rows[4 * s + 1], tail_rows[4 * s + 2], tail_rows[4 * s + 3].x);
}

void vertex() {
	int s = INSTANCE_ID / 2;
	bool cube = s >= TAIL_CUBE0;
	bool used = (cube ? s - TAIL_CUBE0 < tail_count.y : s < tail_count.x);
	float el;
	vec3 en;
	vec4 ex, ey, ez;
	geo_eye(INV_VIEW_MATRIX, EYE_OFFSET, el, en, ex, ey, ez);
	vec3 eye = vec3(geo_r(abs(el)), sqrt(geo_u(abs(el))), geo_dr(abs(el)));
	v_el = el;
	v_eye = eye;
	v_en = en;
	v_ex = ex;
	v_ey = ey;
	v_ez = ez;
	v_off = EYE_OFFSET;
	v_slot = float(s);
	POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	if (used) {
		TailBody q = slot_body(s);
		vec2 band = tail_band(el, eye, q, tail_psi_min);
		vec3 u;
		float half_w = tail_sector(en, q, u);
		bool side2 = (INSTANCE_ID & 1) == 1;
		if (band.x < band.y && !(side2 && half_w >= GEO_PI)) {
			// in the camera's space: the inward radial direction, the body's direction round it, and
			// across both
			float sd = el < 0.0 ? -1.0 : 1.0;
			vec3 ax = normalize(-sd * vec3(ex.x, ey.x, ez.x));
			vec3 b1 = vec3(dot(ex.yzw, u), dot(ey.yzw, u), dot(ez.yzw, u));
			b1 = normalize(b1 - dot(b1, ax) * ax) * (side2 ? -1.0 : 1.0);
			vec3 b2 = cross(ax, b1);
			// a hair past the sector: its inner and outer edges are chords of circles round the axis
			float w = min(half_w, GEO_PI);
			float step = 2.0 * w / tail_segments;
			float mg = 2e-3 + 0.125 * step * step;
			float phi = (2.0 * VERTEX.x - 1.0) * min(w + mg, GEO_PI);
			float chi = VERTEX.y < 0.5 ? max(band.x - mg, 0.0) : min(band.y + mg, GEO_PI);
			vec2 sp = geo_sincos(phi);
			vec2 sc = geo_sincos(chi);
			vec3 d = sc.y * ax + sc.x * (sp.y * b1 + sp.x * b2);
			v_ray = d;
			POSITION = PROJECTION_MATRIX * vec4(EYE_OFFSET + d, 1.0);
		}
	}
}

void fragment() {
	vec3 d = normalize(v_ray);
	vec4 D = d.x * v_ex + d.y * v_ey + d.z * v_ez;
	TailRay z;
	if (!tail_ray(v_el, v_eye, v_en, D, tail_psi_min, z)) discard;
	int slot = int(v_slot + 0.5);
	TailBody q = slot_body(slot);
	float y, ang, psi;
	int on;
	if (!tail_meet(z, q, tail_psi_min, y, ang, psi, on)) discard;
	vec4 P, arrive;
	float len;
	tail_hit(z, y, ang, on, P, arrive, len);
	float l = on == 2 ? z.dl * (g_prof.w + length(P.xyz) - g_prof2.x) : tail_l(z, y);
	// lit as body.gdshaderinc lights the zone's balls and cubes
	vec4 Np = geo_normal(P);
	vec4 s4 = look_sun4(l);
	vec4 sun = s4 - dot(s4, Np) * Np;
	vec4 up4 = vec4(0.0, 0.0, 1.0, 0.0) - Np.z * Np;
	vec4 sh = sun * inversesqrt(max(dot(sun, sun), 1e-12));
	vec4 uh = up4 * inversesqrt(max(dot(up4, up4), 1e-12));
	vec3 col;
	vec4 qd = P - q.C;
	vec3 albedo = tail_col[slot].rgb;
	if (q.cube) {
		vec3 box = vec3(dot(qd, q.E[0]), dot(qd, q.E[1]), dot(qd, q.E[2])) / q.size;
		vec3 ab = abs(box);
		int f = ab.x >= ab.y && ab.x >= ab.z ? 0 : (ab.y >= ab.z ? 1 : 2);
		vec4 a = q.E[f] - dot(q.E[f], Np) * Np;
		a *= (box[f] < 0.0 ? -1.0 : 1.0) * inversesqrt(max(dot(a, a), 1e-12));
		col = look_body(albedo, dot(a, sh), dot(a, uh), -dot(a, arrive), l);
		float e = look_box_edge(box);
		float fw = max(fwidth(e), 1e-5);
		col *= mix(0.45, 1.0, clamp((e - 0.04) / fw + 0.5, 0.0, 1.0));
	} else {
		vec4 n = qd - dot(qd, Np) * Np;
		n *= inversesqrt(max(dot(n, n), 1e-12));
		col = look_body(albedo, dot(n, sh), dot(n, uh), -dot(n, arrive), l);
	}
	if (!geo_finite(col.r + col.g + col.b + len)) discard;
	ALBEDO = col;
	// the light's way deep in the tail is kilometres: past half the far plane its depth there shrunk
	// as 1 / len, still ordered by the way and before the floor's (0)
	float lc = min(len, 0.5 * tail_far);
	vec4 c = PROJECTION_MATRIX * vec4(v_off + lc * d, 1.0);
	DEPTH = c.z / c.w * (lc / len);
}
