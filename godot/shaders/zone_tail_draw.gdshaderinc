// zone_tail.gdshader's uniforms, vertex and fragment (its top says what they do), shared with the
// variants the speed check times it against (bench.gd's VARIANTS, Renderer.TAIL_SHADERS): defined
// before the include, TAIL_FLAT_EYE hands the eye on from the vertices as flat varyings instead of
// each fragment's own geo_eye, TAIL_NO_SINGLE (zone_tail.gdshaderinc) searches a strip's copy as the
// band's copies are searched.

const int TAIL_CUBE0 = 12;          // Renderer.MAX_BALLS: the cubes' first slot
uniform vec4 tail_rows[80];         // per slot: C, E1, E2, (size, 0, 0, 0)
uniform vec4 tail_col[20];          // per slot: its colour (linear)
uniform ivec2 tail_count = ivec2(0);   // balls, cubes in the zone
uniform float tail_psi_min = 59.6902604182061;   // (Renderer.ZONE_IMAGES - 1) pi: the meshes' last image on
uniform float tail_far = 4000.0;       // m: the camera's far plane (Main.FAR)
uniform sampler2DArray zone_cull : filter_nearest, repeat_disable;   // ZoneSections.cull_tex
uniform int tail_images = 20;          // Renderer.ZONE_IMAGES: the tail's texels of a slot's row after them
uniform int tail_probe = 0;            // tests (tail_cost_test.gd): 1, each fragment green where its ray meets the body, else red
uniform int tail_only = -1;            // tests: only this body slot's side drawn (2 slot + side)
uniform bool tail_strips_on = true;    // the strips drawn (Renderer.tail_strips), else one band from the first copy

varying flat float v_slot;      // the body's slot
#ifdef TAIL_FLAT_EYE
varying flat float v_el;        // the eye as the vertices found it (geo_eye)
varying flat vec3 v_eye;
varying flat vec3 v_en;
varying flat vec4 v_ex;
varying flat vec4 v_ey;
varying flat vec4 v_ez;
#endif
varying flat vec3 v_copies;     // the copies looked into: the first, the last, 1 if past the zone too
varying vec3 v_ray;

TailBody slot_body(int s) {
	return tail_body(s >= TAIL_CUBE0, tail_rows[4 * s], tail_rows[4 * s + 1], tail_rows[4 * s + 2], tail_rows[4 * s + 3].x);
}

void vertex() {
	const int per = TAIL_STRIPS + 1;
	int b = INSTANCE_ID / (2 * per);
	int s = b < tail_count.x ? b : TAIL_CUBE0 + b - tail_count.x;
	int side_i = INSTANCE_ID / per % 2;
	int k = INSTANCE_ID % per;
	bool side2 = side_i == 1;
	v_slot = float(s);
	v_copies = vec3(-1e9, 1e9, 1.0);
	v_ray = vec3(0.0);
	POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	int i0 = tail_images;
	int layer = int(VIEW_INDEX);
	vec4 at = b < tail_count.x + tail_count.y ? texelFetch(zone_cull, ivec3(i0, s, layer), 0) : vec4(0.0);
	vec2 range = vec2(1.0, 0.0);
	vec4 bw = vec4(0.0);
	if (at.w > 0.5 && all(equal(at.xyz, tail_rows[4 * s].xyz)) && (tail_only < 0 || 2 * s + side_i == tail_only)) {
		bw = texelFetch(zone_cull, ivec3(i0 + 1, s, layer), 0);
		vec4 hd = texelFetch(zone_cull, ivec3(i0 + 3, s, layer), 0);
		vec2 band = bw.xy;
		float half_w = bw.z;
		// strip k drawn if it is one of the first K, each apart from the next (tail_apart), the band
		// from strip K on, a margin past each edge off the radial (tail_margin); where the body has no
		// strips, the band whole, its margins those round the axis
		if (tail_strips_on && hd.z > 0.5) {
			vec2 kk = texelFetch(zone_cull, ivec3(i0 + 4, s, layer), 0).xy;
			int K = int((side2 ? kk.y : kk.x) + 0.5);
			int j = k == TAIL_STRIPS ? K : k;
			vec4 tj = texelFetch(zone_cull, ivec3(i0 + 5 + j, s, layer), 0);
			vec2 sj = side2 ? tj.zw : tj.xy;
			float n0 = side2 ? hd.y : hd.x;
			if (k == TAIL_STRIPS) {
				range = hd.w > 0.5 ? vec2(band.x, sj.y) : vec2(sj.x, band.y);
				v_copies = vec3(n0 + float(K), 1e9, 0.0);
			} else if (k < K) {
				range = sj;
				v_copies = vec3(n0 + float(k), n0 + float(k), 0.0);
			}
			range += vec2(-tail_margin(range.x, half_w), tail_margin(range.y, half_w));
		} else if (k == TAIL_STRIPS) {
			float mg = tail_margins(half_w).x;
			range = band + vec2(-mg, mg);
		}
		if (side2 && half_w >= GEO_PI) range = vec2(1.0, 0.0);
	}
	if (range.x <= range.y) {
		// in the camera's space: the inward radial direction, the body's direction round it, and
		// across both; a hair past the sector round the axis
		float el;
		vec3 en;
		vec4 ex, ey, ez;
		geo_eye(INV_VIEW_MATRIX, EYE_OFFSET, el, en, ex, ey, ez);
		vec3 u = texelFetch(zone_cull, ivec3(i0 + 2, s, layer), 0).xyz;
		float half_w = bw.z;
		float sd = el < 0.0 ? -1.0 : 1.0;
		vec3 ax = normalize(-sd * vec3(ex.x, ey.x, ez.x));
		vec3 b1 = vec3(dot(ex.yzw, u), dot(ey.yzw, u), dot(ez.yzw, u));
		b1 = normalize(b1 - dot(b1, ax) * ax) * (side2 ? -1.0 : 1.0);
		vec3 b2 = cross(ax, b1);
		float phi = (2.0 * VERTEX.x - 1.0) * min(min(half_w, GEO_PI) + tail_margins(half_w).x, GEO_PI);
		float chi = clamp(VERTEX.y < 0.5 ? range.x : range.y, 0.0, GEO_PI);
		vec2 sp = geo_sincos(phi);
		vec2 sc = geo_sincos(chi);
		vec3 d = sc.y * ax + sc.x * (sp.y * b1 + sp.x * b2);
		v_ray = d;
#ifdef TAIL_FLAT_EYE
		v_el = el;
		v_eye = vec3(geo_r(abs(el)), sqrt(geo_u(abs(el))), geo_dr(abs(el)));
		v_en = en;
		v_ex = ex;
		v_ey = ey;
		v_ez = ez;
#endif
		POSITION = PROJECTION_MATRIX * vec4(EYE_OFFSET + d, 1.0);
	}
}

void fragment() {
#ifdef TAIL_FLAT_EYE
	float el = v_el;
	vec3 en = v_en, eye = v_eye;
	vec4 ex = v_ex, ey = v_ey, ez = v_ez;
#else
	float el;
	vec3 en;
	vec4 ex, ey, ez;
	geo_eye(INV_VIEW_MATRIX, EYE_OFFSET, el, en, ex, ey, ez);
	vec3 eye = vec3(geo_r(abs(el)), sqrt(geo_u(abs(el))), geo_dr(abs(el)));
#endif
	vec3 d = normalize(v_ray);
	vec4 D = d.x * ex + d.y * ey + d.z * ez;
	TailRay z;
	int slot = int(v_slot + 0.5);
	TailBody q = slot_body(slot);
	float y = 0.0, ang = 0.0, psi = 0.0;
	int on = 0;
	bool far = v_copies.z > 0.5;
	bool met = tail_ray(el, eye, en, D, tail_psi_min, far, z) && tail_meet(z, q, tail_psi_min, v_copies.x, v_copies.y, far, y, ang, psi, on);
	if (tail_probe == 1) {
		ALBEDO = met ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
		DEPTH = 1.0;
	} else {
		if (!met) discard;
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
		vec4 c = PROJECTION_MATRIX * vec4(EYE_OFFSET + lc * d, 1.0);
		DEPTH = c.z / c.w * (lc / len);
	}
}
