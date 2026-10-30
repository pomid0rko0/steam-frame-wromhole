// What the worlds look like: the floor, the sky and the light on bodies. Colours are linear (Godot
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

// a box-filtered checker of unit cells at p, w its footprint (fwidth)
float look_checker(vec2 p, vec2 w) {
	w = max(w, vec2(1e-4));
	vec2 i = 2.0 * (abs(fract((p - 0.5 * w) * 0.5) - 0.5) - abs(fract((p + 0.5 * w) * 0.5) - 0.5)) / w;
	return 0.5 - 0.5 * i.x * i.y;
}

// the floor's pattern coordinates at (l, n) (n.z = 0): rings at whole metres of |l|, 24 sectors of
// the chart's azimuth (chart B is mirrored in x); the check scene's green lines follow the same
// (check_grid.gdshader). Returns (|l|, sector).
vec2 look_floor_coords(float l, vec3 n) {
	float x = l < 0.0 ? -n.x : n.x;
	return vec2(abs(l), atan(n.y, x) * (24.0 / (2.0 * GEO_PI)));
}

// the floor's colour from its pattern coordinates c (look_floor_coords), their footprints fw (per
// pixel) and the way's length; base: the checker's two colours
vec3 look_floor(vec2 q, vec2 fw, vec3 lightc, vec3 darkc) {
	float chk = look_checker(q, fw);
	vec3 col = mix(darkc, lightc, mix(0.5, chk, 1.0 - smoothstep(0.35, 0.8, max(fw.x, fw.y))));
	// white lines a pixel wide, fading where they crowd
	vec2 d = abs(fract(q + 0.5) - 0.5) / max(fw, vec2(1e-5));
	vec2 cov = clamp(LOOK_LINE + 0.5 - d, 0.0, 1.0) * (1.0 - smoothstep(0.15, 0.35, fw));
	float line = max(cov.x, cov.y);
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
	col += LOOK_SUN * (0.25 * pow(max(cs, 0.0), 64.0));
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
// the contours over a floor colour col at level t (look_grav_level), as wide in pixels anywhere,
// fading where they crowd
vec3 look_grav_contours(vec3 col, float t) {
	float fw = max(fwidth(t), 1e-5);
	float d = abs(fract(t + 0.5) - 0.5) / fw;
	float thin = clamp(LOOK_LINE + 0.5 - d, 0.0, 1.0) * (1.0 - smoothstep(0.15, 0.35, fw));
	float one = clamp(2.0 * LOOK_LINE + 0.5 - abs(t - 10.0) / fw, 0.0, 1.0);
	return col * (1.0 - 0.4 * thin) * (1.0 - 0.85 * one);
}

// light on a body at l: the sun's direction there as a vector of R^4 (each universe's sun, A's in
// its chart = R^4's xyz, B's mirrored), blended across the throat, and the ambient colour
vec4 look_sun4(float l) {
	vec4 a = vec4(LOOK_SUN_A, 0.0);
	vec4 b = vec4(-LOOK_SUN_B.x, LOOK_SUN_B.yz, 0.0);
	return mix(b, a, smoothstep(-1.5, 1.5, l));
}

vec3 look_ambient(float l, float up) {
	float k = smoothstep(-1.5, 1.5, l);
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
