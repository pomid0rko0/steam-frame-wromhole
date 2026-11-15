// What the worlds look like: the floor, the sky and the light on bodies (after geo.gdshaderinc's
// uniforms: g_prof, g_lift, g_beta, and with GRAVITY g_grav, g_gravtab). Colours are linear (Godot
// shows them through its sRGB output). Universe A is warm, B cool; the light of the throat is
// blended between the two along l, so a ball in the middle is lit half by each sky.

const vec3 LOOK_FLOOR_A[2] = vec3[2](vec3(0.7874, 0.6038, 0.4064), vec3(0.6559, 0.4624, 0.2846));
const vec3 LOOK_FLOOR_B[2] = vec3[2](vec3(0.6383, 0.7106, 0.7874), vec3(0.4624, 0.5542, 0.6739));
const vec3 LOOK_ZENITH_A = vec3(0.2957, 0.1873, 0.3672);
const vec3 LOOK_HORIZON_A = vec3(1.0, 0.6739, 0.3931);
const vec3 LOOK_ZENITH_B = vec3(0.0397, 0.1626, 0.7106);
const vec3 LOOK_HORIZON_B = vec3(0.5071, 0.7293, 1.0);
const vec3 LOOK_SUN = vec3(1.0, 0.9551, 0.8276);
// each universe's sun, in its own chart
const vec3 LOOK_SUN_A = vec3(0.4472, -0.5367, 0.7155);
const vec3 LOOK_SUN_B = vec3(-0.5345, 0.2673, 0.8018);
const float LOOK_SUN_COS = 0.99863;      // cos 3 degrees: the sun's disc
const float LOOK_HAZE = 70.0;            // m: the floor fades to the horizon's colour over this
const float LOOK_LINE = 0.6;             // px: half the width of the floor's white lines

// a box-filtered checker of unit cells at p, iw the inverse of its footprint (1 / fwidth)
float look_checker(vec3 p, vec3 w, vec3 iw) {
	vec3 i = 2.0 * (abs(fract((p - 0.5 * w) * 0.5) - 0.5) - abs(fract((p + 0.5 * w) * 0.5) - 0.5)) * iw;
	return 0.5 - 0.5 * i.x * i.y * i.z;
}

// The floor's pattern: the cells of a block of R^4's (x, y, w) that the floor cuts through (docs/
// geometry.md, «Пол»): q = (x, y, h - |w| + 1/2). Out in a flat universe w = +-h, the third is 1/2,
// the middle of its cell, and the pattern is the chart's: a checker of metre cells with white lines
// (the same lines in chart B, its x mirrored). In the curved zone the floor leaves the sheet along
// w, and the third coordinate's cells and lines come in: rings across the floor of the throat every
// metre along it, where x and y stand still.
// The floor's colour from q and its footprints fw (per pixel), the pixel px of the picture's pixels
// across (1 but in foveation's coarser texels); base: the checker's two colours
vec3 look_floor(vec3 q, vec3 fw, float px, vec3 lightc, vec3 darkc) {
	fw = max(fw, vec3(1e-4));
	vec3 iw = 1.0 / fw;
	float wide = max(fw.x, max(fw.y, fw.z));
	// in a coarser pixel the cells' edges filtered wider: a pixel's box alone leaves steps once the
	// coarse pixels are spread over the picture's
	vec3 fc = fw * (1.0 + 0.5 * smoothstep(1.0, 2.0, px));
	float chk = look_checker(q, fc, 1.0 / fc);
	vec3 col = mix(darkc, lightc, mix(0.5, chk, 1.0 - smoothstep(0.35, 0.8, wide)));
	// white lines a picture's pixel wide (in a coarser pixel thinner than it: then they cover their
	// share of it), every kind fading where any crowds: far off and at a grazing angle the rings
	// crowd first, and the radial lines left alone there stood out (check_grid.gdshader stops where
	// either crowds too)
	float h = LOOK_LINE / px;
	vec3 cov = clamp(min(h + 0.5 - abs(fract(q + 0.5) - 0.5) * iw, 2.0 * h), 0.0, 1.0);
	float line = max(cov.x, max(cov.y, cov.z)) * (1.0 - smoothstep(0.15, 0.35, wide));
	return mix(col, vec3(1.0), 0.75 * line);
}

// the sky of universe side (+1 A, -1 B) toward its chart direction d
vec3 look_sky(vec3 d, float side) {
	vec3 zen = side > 0.0 ? LOOK_ZENITH_A : LOOK_ZENITH_B;
	vec3 hor = side > 0.0 ? LOOK_HORIZON_A : LOOK_HORIZON_B;
	vec3 sun = side > 0.0 ? LOOK_SUN_A : LOOK_SUN_B;
	float up = clamp(d.z, 0.0, 1.0);
	vec3 col = mix(hor, zen, pow(up, 0.6));
	float cs = dot(d, sun);
	float c2 = max(cs, 0.0);
	c2 *= c2; c2 *= c2; c2 *= c2; c2 *= c2; c2 *= c2; c2 *= c2;     // ^64
	col += LOOK_SUN * (0.25 * c2);
	col = mix(col, LOOK_SUN * 1.2, smoothstep(LOOK_SUN_COS - 0.00004, LOOK_SUN_COS + 0.00004, cs));
	return col;
}

// gravity on the floor and the arrows: a colour that runs smoothly with g along optozorax's palette
// (docs/gravity.md, «Показ»): dark blue where there is none, purple, orange, yellow at 1 g, then red,
// white at 10 g; over it the field's contours, every 0.1 g below 1 g and every tenth of a decade
// above, and the one at 1 g, Earth's gravity, darker and wider. look_grav_level(g) is the contours'
// coordinate (a contour at each whole number, 1 g at 10); Renderer._gravity_color is the same colour.
float look_grav_level(float g) {
	return g < 1.0 ? 10.0 * g : 10.0 + 4.342944819 * log(g);
}
vec3 look_grav_colour(float t) {
	float u = clamp(t / 10.0, 0.0, 1.0);
	vec3 c = u < 0.5 ? mix(vec3(0.03, 0.03, 0.10), vec3(0.45, 0.08, 0.50), u * 2.0)
			: mix(vec3(0.45, 0.08, 0.50), vec3(0.95, 0.40, 0.12), u * 2.0 - 1.0);
	c = mix(c, vec3(0.95, 0.80, 0.18), smoothstep(0.85, 1.0, u));
	if (t > 10.0) {
		float v = clamp((t - 10.0) / 10.0, 0.0, 1.0);
		c = v < 0.5 ? mix(vec3(0.95, 0.80, 0.18), vec3(0.95, 0.12, 0.05), v * 2.0)
				: mix(vec3(0.95, 0.12, 0.05), vec3(1.0), v * 2.0 - 1.0);
	}
	return c;
}
// the contours over a floor colour col at level t (look_grav_level), its footprint fw (per pixel,
// px of the picture's pixels across: look_floor), as wide in the picture's pixels anywhere, fading
// where they crowd
vec3 look_grav_contours(vec3 col, float t, float fw, float px) {
	fw = max(fw, 1e-5);
	float d = abs(fract(t + 0.5) - 0.5) / fw;
	float h = LOOK_LINE / px;
	float thin = clamp(min(h + 0.5 - d, 2.0 * h), 0.0, 1.0) * (1.0 - smoothstep(0.15, 0.35, fw));
	float one = clamp(min(2.0 * h + 0.5 - abs(t - 10.0) / fw, 4.0 * h), 0.0, 1.0);
	return col * (1.0 - 0.4 * thin) * (1.0 - 0.85 * one);
}

// how much of universe A's light and colours a point at l has: 1 out in A, 0 out in B, between
// them within 1.5 m of the throat's middle (within the curved zone, if that is shorter): the floor's
// colours (look_ground) and the light on a body (look_sun4, look_ambient)
float look_side(float l) {
	float w = min(1.5, g_prof.w);
	return smoothstep(-w, w, l);
}

// light on a body at l: the sun's direction there as a vector of R^4 (each universe's sun, A's in
// its chart = R^4's xyz, B's mirrored), blended across the throat, and the ambient colour
vec4 look_sun4(float l) {
	vec4 a = vec4(LOOK_SUN_A, 0.0);
	vec4 b = vec4(-LOOK_SUN_B.x, LOOK_SUN_B.yz, 0.0);
	return mix(b, a, look_side(l));
}

vec3 look_ambient(float l, float up) {
	float k = look_side(l);
	vec3 zen = mix(LOOK_ZENITH_B, LOOK_ZENITH_A, k);
	vec3 hor = mix(LOOK_HORIZON_B, LOOK_HORIZON_A, k);
	return mix(hor, zen, 0.5 + 0.5 * up) * 0.45;
}

// a body's colour: albedo lit by the sun (nl = n . sun), the sky (up = n . up) and a soft rim
// toward the edge (nv = n . toward the eye). All of it scales the albedo, so a body keeps its hue
// to the edge (the stereo checks find the balls by it).
vec3 look_body(vec3 albedo, float nl, float up, float nv, float l) {
	float rim = 1.0 - clamp(nv, 0.0, 1.0);
	return albedo * (look_ambient(l, up) + 0.75 * LOOK_SUN * max(nl, 0.0) + 0.25 * rim * rim * rim);
}

// gravity on the floor (in g) rho metres along it from the point under the throat's centre:
// WormholeSpace.floor_gravity, from g_lift and g_beta
float look_grav_floor(float rho) {
	float r2 = rho * rho + g_lift * g_lift;
	float r1 = sqrt(r2);
	float r5 = r2 * r2 * r1;
	float along = 3.0 * g_beta * g_lift * rho / r5;
	float up = 1.0 + g_beta / (r2 * r1) - 3.0 * g_beta * g_lift * g_lift / r5;
	return length(vec2(along, up));
}

#ifdef GRAVITY
// Gravity's strength (in g) at the space's point (l, n), r = r(l), nz = n.z: the length of the
// potential's gradient (f' n_z, (f / r) (e_z - n_z n)), f docs/gravity.md's (WormholeSpace.gravity_f):
// out in a flat universe r + beta / r^2, on the throat's cylinder a cosh(k l) (g_grav = (a, k)), on a
// fillet from g_gravtab (f, f' at its nodes from the fillet's start to its end: Renderer's). On the
// flat floor it is look_grav_floor.
float look_grav_at(float l, float r, float nz) {
	float al = abs(l);
	vec2 f;
	if (al >= g_prof.w) {
		f = vec2(r + g_beta / (r * r), 1.0 - 2.0 * g_beta / (r * r * r));
	} else if (al <= g_prof.z) {
		float e = exp(g_grav.y * al);
		f = 0.5 * g_grav.x * vec2(e + 1.0 / e, g_grav.y * (e - 1.0 / e));
	} else {
		float n = float(textureSize(g_gravtab, 0).x);
		float x = (al - g_prof.z) / (g_prof.w - g_prof.z);
		f = textureLod(g_gravtab, vec2((x * (n - 1.0) + 0.5) / n, 0.5), 0.0).rg;
	}
	return length(vec2(f.y * nz, f.x / r * sqrt(max(1.0 - nz * nz, 0.0))));
}
#endif

// The flat floor at R^4's point xy of a universe (the throat's centre over (0, 0)): its pattern's
// point (look_floor's q), and with GRAVITY the gravity's level there (look_grav_level).
vec4 look_ground_at(vec2 xy) {
#ifdef GRAVITY
	return vec4(xy, 0.5, look_grav_level(look_grav_floor(length(xy))));
#else
	return vec4(xy, 0.5, 0.0);
#endif
}

// The floor's colour at a (look_ground_at's, or the floor's in the curved zone: lens.gdshaderinc),
// ab of it universe A's (look_side), way metres away, from its differences to the next pixel
// along x and along y (dx, dy: what dFdx and dFdy give); the pixel px of the picture's pixels
// across (look_floor)
vec3 look_ground(vec4 a, vec4 dx, vec4 dy, float px, float ab, float way) {
	vec4 fw = abs(dx) + abs(dy);
#ifdef GRAVITY
	vec3 base = look_grav_colour(a.w);
	vec3 col = look_grav_contours(look_floor(a.xyz, fw.xyz, px, base, base * 0.85), a.w, fw.w, px);   // the checker as brightness
#else
	vec3 col = look_floor(a.xyz, fw.xyz, px, mix(LOOK_FLOOR_B[0], LOOK_FLOOR_A[0], ab), mix(LOOK_FLOOR_B[1], LOOK_FLOOR_A[1], ab));
#endif
	return mix(col, mix(LOOK_HORIZON_B, LOOK_HORIZON_A, ab), 1.0 - exp(-way / LOOK_HAZE));
}

// a toy cube's point in its own [-1, 1]^3 to 1 - its distance to the face's nearest edge (the
// cube's dark edges, body.gdshaderinc and look_seen)
float look_box_edge(vec3 box) {
	vec3 a = abs(box);
	float mid = a.x + a.y + a.z - max(max(a.x, a.y), a.z) - min(min(a.x, a.y), a.z);
	return 1.0 - mid;
}
