// Bodies: meshes drawn by Godot's rasterizer, each vertex put where the eye of this view sees it,
// at the length of the light's way there along that direction, so depth orders bodies by how far
// light goes. The pixel then only shades. docs/geometry.md, «Как рисуется кадр».
//   DIRECT (toy_ball.gdshader, toy_cube.gdshader) and STATIC: bodies out in a flat universe, seen
//     straight: only from an eye out in the same universe, by the straight line from it (an
//     ordinary camera); a fragment whose line of sight goes through the curved zone's ball is
//     dropped: that part of the view is the lens's (floor.gdshaderinc, which draws these bodies
//     there along the rays that come out of the zone).
//   Else: each vertex along its geodesics (geo_see_image), every image.
//   TOY: balls (BALL) and cubes (CUBE) of the physics (ball_world.gd), one MultiMesh each. An
//     instance: its centre C (a point of R^4) and body axes E1, E2 packed in the transform's 12
//     numbers (Renderer.pack), E3 from them and the space's normal; INSTANCE_CUSTOM = (colour,
//     radius or half size). A ball is the space's points at chord distance radius from C
//     (BallWorld's ball); a cube its 4D box cut by the space: the points whose offsets from C
//     along E1, E2, E3 are within the half size. With DIRECT the mesh is the unit sphere or the
//     cube [-1, 1]^3, each point taken along the space's normal at C.
//     Below the floor they are hidden: the floor hides whatever is below it.
//   ZONE (zone_ball.gdshader, zone_cube.gdshader): toys in the curved zone, each drawn once per image
//     (zone_first, zone_images), as a mesh made anew for each view round the line
//     through its eye and the centre (the axis): there the images of a point fold into a ring (an
//     Einstein ring), and a triangle across the axis would join a point's image on one side with its
//     neighbour's on the other. So the mesh is a grid (VERTEX.xy in [0, 1]^2) of the azimuth theta
//     about the axis and of the place round the body's section by the half-surface of that azimuth
//     (points (l, alpha): alpha the angle from the eye's direction toward theta): a body off the axis
//     takes the azimuths it spans, each section a closed curve round the point nearest its centre;
//     a body round the axis every azimuth, each section an arc from where the axis enters it to
//     where it leaves. No triangle crosses the axis, and the images come out as rings where they
//     are. Each point found by Newton's steps on the body's own definition along a straight line of
//     (l, r alpha) from the inner point (zone.gdshaderinc). A cube's columns stand on its corners'
//     azimuths, and a row on each corner of its sections, the same corner on the same row from one
//     corner's azimuth to the next: its outline keeps its corners. Every point stays on the body:
//     where those steps leave one off (the axis next to an edge), a line from the section's
//     inside puts it there.
//   STATIC (scene.gdshader): the scene's objects, vertices in chart coordinates of universe
//     sheet (A +1, B -1), all in the flat sheets.
//   ARROWS and BEAM: one instance per image, each vertex by its own plane through the centre.
//   ARROWS (arrows.gdshader): the gravity view's arrows (Renderer._arrow_mesh), vertices as points
//     (l, n) of the space (n in VERTEX, l in UV.x), unlit, in their COLOR; COLOR.a 1 (the arrow,
//     over its outline of COLOR.a 0) a hair nearer the eye in depth, in the same place in the view.
//   BEAM (beam.gdshader): a hand's pointing beam (Renderer.set_beam), a tube round a line of up to
//     BEAM_POINTS points of R^4 (beam_p, beam_n of them), beam_r[i] in radius at point i; its mesh
//     (Renderer._beam_mesh) a ring a point, VERTEX.x the point, VERTEX.y the angle round it from
//     up (R^4's z, else x, made orthogonal to the line and the space's normal). Unlit, in beam_col;
//     below the floor hidden.
// Lit in R^4: the normal of the surface and the sun (look_sun4) as tangent vectors at the point. A
// cube is lit by the face each pixel is on (its largest box coordinate): a vertex on an edge is on
// two faces, and a normal of either in it would be spread over the other's triangles (along every
// edge of a cube seen straight, and in the zone's meshes, which share their vertices round the
// section, column by column, in wedges).
#if defined(STATIC) && !defined(DIRECT)
#define DIRECT
#endif
#if defined(ARROWS) || defined(BEAM) || defined(ZONE)
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled;
#else
render_mode unshaded, cull_back, fog_disabled, shadows_disabled;
#endif

#include "res://shaders/geo_uniforms.gdshaderinc"
#include "res://shaders/geo.gdshaderinc"
#include "res://shaders/look.gdshaderinc"

#ifdef STATIC
uniform float sheet = 1.0;       // the universe: A +1, B -1
#endif
#ifdef ZONE
uniform int zone_first = 0;      // instance i draws image zone_first + i % zone_images (Renderer)
uniform int zone_images = 1;
uniform float zone_round = 48.0; // the mesh's points round a section and azimuths (Renderer._zone_mesh)
uniform float zone_columns = 64.0;
#endif
#ifdef BEAM
#define BEAM_POINTS 48           // Renderer.BEAM_POINTS
uniform vec4 beam_p[BEAM_POINTS];
uniform float beam_r[BEAM_POINTS];
uniform int beam_n = 0;
uniform vec3 beam_col : source_color = vec3(1.0);
#endif

#ifdef CUBE
// each face axis's normal (the axis, tangent at the point, unit) against the sun, up and the
// light's way in (n . sun, n . up, -n . ray): the fragment takes its face's
varying vec3 v_lit1;
varying vec3 v_lit2;
varying vec3 v_lit3;
#else
varying vec4 v_n;       // the surface's normal (R^4)
varying vec4 v_sun;     // toward the sun (R^4, tangent there)
varying vec4 v_up;      // up (R^4, tangent there)
varying vec4 v_ray;     // the light's way in (R^4)
#endif
varying float v_l;
varying float v_h;      // height above the floor
varying vec3 v_col;
#ifdef DIRECT
varying vec3 v_p;       // the point (R^4's xyz)
varying flat vec3 v_eye;     // the eye (R^4's xyz)
#endif
#ifdef TOY
varying vec3 v_box;     // a cube's point in its own coordinates [-1, 1]^3
#endif

#ifdef ZONE
#include "res://shaders/zone.gdshaderinc"
#endif

void vertex() {
	vec4 P;
#ifndef CUBE
	vec4 nrm;
#endif
#ifdef ZONE
	float el;
	vec3 en;
	vec4 ex, ey, ez;
	geo_eye(INV_VIEW_MATRIX, EYE_OFFSET, el, en, ex, ey, ez);
	int image = zone_first + INSTANCE_ID % zone_images;
	vec4 C = vec4(MODEL_MATRIX[0].xyz, MODEL_MATRIX[1].x);
	vec4 E1 = vec4(MODEL_MATRIX[1].yz, MODEL_MATRIX[2].xy);
	vec4 E2 = vec4(MODEL_MATRIX[2].z, MODEL_MATRIX[3].xyz);
	vec4 N = geo_normal(C);
	vec4 E3 = -geo_cross4(E1, E2, N);
	float size = INSTANCE_CUSTOM.a;
	vec3 t;
#ifdef BALL
	bool none;
	vec2 pe = zone_vertex(VERTEX.xy, zone_columns, zone_round, true, en, C, E1, E2, E3, N, size, t, none);
#else
	bool none;
	vec2 pe = zone_vertex(VERTEX.xy, zone_columns, zone_round, false, en, C, E1, E2, E3, N, size, t, none);
#endif
	float pl = pe.x;
	float alpha = clamp(pe.y, 0.0, GEO_PI);
	vec2 sca = geo_sincos(alpha);
	vec3 pn = sca.y * en + sca.x * t;
	P = vec4(geo_r(abs(pl)) * pn, zone_w(pl));
	vec4 q = P - C;
#ifdef BALL
	nrm = q;
#else
	v_box = vec3(dot(q, E1), dot(q, E2), dot(q, E3)) / size;
#endif
	float len, fell;
	vec4 arrive;
	vec4 dir = geo_see_image(el, en, pl, pn, t, alpha, image, len, arrive, fell);
	POSITION = PROJECTION_MATRIX * vec4(EYE_OFFSET + len * vec3(dot(dir, ex), dot(dir, ey), dot(dir, ez)), 1.0);
#elif defined(TOY)
	vec4 C = vec4(MODEL_MATRIX[0].xyz, MODEL_MATRIX[1].x);
	vec4 E1 = vec4(MODEL_MATRIX[1].yz, MODEL_MATRIX[2].xy);
	vec4 E2 = vec4(MODEL_MATRIX[2].z, MODEL_MATRIX[3].xyz);
	vec4 N = geo_normal(C);
	// the third axis completing a right-handed frame of a chart (A's x, y, z; B's mirrored): its
	// orientation is the eyes' (geo_normal points to A's -w, B's +w), so the mesh keeps its winding
	vec4 E3 = -geo_cross4(E1, E2, N);
	float size = INSTANCE_CUSTOM.a;
	vec4 x = size * (VERTEX.x * E1 + VERTEX.y * E2 + VERTEX.z * E3);
	P = geo_onto(C + x, N);
#ifdef BALL
	// the chord from C is radius long: shorten the step in the tangent space by what the normal adds
	// (twice: the normal's part changes with the step)
	for (int k = 0; k < 2; k++) {
		float c = dot(P - C, N);
		P = geo_onto(C + x * (sqrt(max(size * size - c * c, 0.0)) / size), N);
	}
	nrm = P - C;
#endif
#elif defined(ARROWS)
	P = vec4(0.0);
	nrm = vec4(0.0);
#elif defined(BEAM)
	int last = max(beam_n - 1, 0);
	int i = clamp(int(VERTEX.x + 0.5), 0, last);
	vec4 C = beam_p[i];
	vec4 N = geo_normal(C);
	vec4 T = beam_p[min(i + 1, last)] - beam_p[max(i - 1, 0)];
	T = normalize(T - dot(T, N) * N);
	vec4 up = vec4(0.0, 0.0, 1.0, 0.0);
	vec4 e1 = up - dot(up, N) * N - dot(up, T) * T;
	if (dot(e1, e1) < 1e-4) {
		up = vec4(1.0, 0.0, 0.0, 0.0);
		e1 = up - dot(up, N) * N - dot(up, T) * T;
	}
	e1 = normalize(e1);
	vec4 e2 = geo_cross4(T, e1, N);
	P = geo_onto(C + beam_r[i] * (cos(VERTEX.y) * e1 + sin(VERTEX.y) * e2), N);
	nrm = vec4(0.0);
#else
	vec3 xc = VERTEX - vec3(0.0, 0.0, g_lift);
	float h = g_prof.z - g_prof.y * geo_sin(g_prof2.w) + g_prof.y;
	P = sheet > 0.0 ? vec4(xc, h) : vec4(-xc.x, xc.yz, -h);
	nrm = vec4(sheet > 0.0 ? NORMAL.x : -NORMAL.x, NORMAL.yz, 0.0);
#endif
#ifndef ZONE
	vec3 pn;
#ifdef ARROWS
	pn = normalize(VERTEX);
	float pl = UV.x;
#else
	float pl = geo_l_of(P, pn);
#endif
	// the place in the view first: what only the shading needs is worked out after the search,
	// not held through it
	float el;
	vec3 en;
	vec4 ex, ey, ez;
	geo_eye(INV_VIEW_MATRIX, EYE_OFFSET, el, en, ex, ey, ez);
	vec4 arrive;
#ifdef DIRECT
	// straight from an eye out in the same flat universe; from anywhere else not at all (all its
	// corners off the view's right edge)
	float side = el < 0.0 ? -1.0 : 1.0;
	vec3 xe = geo_r(abs(el)) * en;
	vec3 d3 = P.xyz - xe;
	v_p = P.xyz;
	v_eye = xe;
	float fell = 0.0;
	arrive = vec4(normalize(d3), 0.0);
	if (abs(el) >= g_prof.w && P.w * side > 0.0) {
		vec4 Dv = vec4(side * dot(d3, en), d3 - dot(d3, en) * en);
		POSITION = PROJECTION_MATRIX * vec4(EYE_OFFSET + vec3(dot(Dv, ex), dot(Dv, ey), dot(Dv, ez)), 1.0);
	} else {
		POSITION = vec4(2.0, 0.0, 0.5, 1.0);
	}
#else
	// image INSTANCE_ID of each vertex, by its own plane (a triangle across the axis
	// through the eye and the centre would join two images: a long thin line or tube there does)
	float c = dot(en, pn);
	float sd = length(cross(en, pn));
	vec3 t = sd > 1e-9 ? (pn - c * en) / sd : normalize(cross(en, abs(en.z) < 0.9 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0)));
	float len, fell;
	vec4 dir = geo_see_image(el, en, pl, pn, t, geo_atan2(sd, c), INSTANCE_ID, len, arrive, fell);
#ifdef ARROWS
	len *= 1.0 - 1e-3 * COLOR.a;
#endif
	POSITION = PROJECTION_MATRIX * vec4(EYE_OFFSET + len * vec3(dot(dir, ex), dot(dir, ey), dot(dir, ez)), 1.0);
#endif
#endif
#ifdef ARROWS
	vec4 Np = vec4(0.0);
	v_col = COLOR.rgb;
#elif defined(BEAM)
	vec4 Np = N;
	v_col = beam_col;
#else
	vec4 Np = geo_normal(P);
#ifdef TOY
	v_col = INSTANCE_CUSTOM.rgb;
#if defined(CUBE) && !defined(ZONE)
	v_box = VERTEX;
#endif
#else
	v_col = COLOR.rgb;
#endif
#endif
	vec4 s4 = look_sun4(pl);
	vec4 sun = s4 - dot(s4, Np) * Np;
	vec4 up4 = vec4(0.0, 0.0, 1.0, 0.0) - Np.z * Np;
#ifdef CUBE
	// unit vectors here (up is none where the space's normal is up: nought, as is its light)
	vec4 sh = sun * inversesqrt(max(dot(sun, sun), 1e-12));
	vec4 uh = up4 * inversesqrt(max(dot(up4, up4), 1e-12));
	vec4 rh = arrive * inversesqrt(max(dot(arrive, arrive), 1e-12));
	vec4 a1 = E1 - dot(E1, Np) * Np, a2 = E2 - dot(E2, Np) * Np, a3 = E3 - dot(E3, Np) * Np;
	a1 *= inversesqrt(max(dot(a1, a1), 1e-12));
	a2 *= inversesqrt(max(dot(a2, a2), 1e-12));
	a3 *= inversesqrt(max(dot(a3, a3), 1e-12));
	v_lit1 = vec3(dot(a1, sh), dot(a1, uh), -dot(a1, rh));
	v_lit2 = vec3(dot(a2, sh), dot(a2, uh), -dot(a2, rh));
	v_lit3 = vec3(dot(a3, sh), dot(a3, uh), -dot(a3, rh));
#else
	v_n = nrm - dot(nrm, Np) * Np;
	v_sun = sun;
	v_up = up4;
	v_ray = arrive;
#endif
	v_l = pl;
	v_h = P.z + g_lift;
	// to find where the headset's GPU makes a ray of the search not finite (the PC's never do):
	// cyan where one was passed over, magenta where geo_see's stand-in took the vertex
	if (fell > 0.0) v_col = mix(v_col, fell > 0.75 ? vec3(1.0, 0.0, 1.0) : vec3(0.0, 1.0, 1.0), 0.7);
#ifdef ZONE
	// and orange where a cube's section's steps came out not a number (zone_cube_section)
	if (none) v_col = mix(v_col, vec3(1.0, 0.5, 0.0), 0.7);
#endif
}

void fragment() {
#if defined(TOY) || defined(BEAM)
	if (v_h < 0.0) discard;
#endif
#ifdef DIRECT
	// the line of sight through the curved zone's ball: the lens's
	vec3 d = v_p - v_eye;
	float t = clamp(-dot(v_eye, d) / dot(d, d), 0.0, 1.0);
	vec3 m = v_eye + t * d;
	if (dot(m, m) < g_prof2.x * g_prof2.x) discard;
#endif
#if defined(ARROWS) || defined(BEAM)
	ALBEDO = v_col;
#else
#ifdef CUBE
	// the face this pixel is on: its largest box coordinate
	vec3 ab = abs(v_box);
	vec3 lit = ab.x >= ab.y && ab.x >= ab.z ? sign(v_box.x) * v_lit1 : (ab.y >= ab.z ? sign(v_box.y) * v_lit2 : sign(v_box.z) * v_lit3);
	vec3 col = look_body(v_col, lit.x, lit.y, lit.z, v_l);
	// dark edges: the distance to the face's nearest edge in pixels
	float e = look_box_edge(v_box);
	float fw = max(fwidth(e), 1e-5);
	col *= mix(0.45, 1.0, clamp((e - 0.04) / fw + 0.5, 0.0, 1.0));
#else
	vec4 n = normalize(v_n);
	float nl = dot(n, normalize(v_sun));
	float up = dot(n, normalize(v_up));
	float nv = -dot(n, normalize(v_ray));
	vec3 col = look_body(v_col, nl, up, nv, v_l);
#endif
#ifdef ZONE
	// a pixel whose numbers came out none is no part of the surface: a triangle of next to no area
	// (a cube's strip between two columns on one corner's azimuth, zone_cube_azimuth: its vertices
	// all on that azimuth's line in the view, each placed by its own search) gets one now and then,
	// its varyings no numbers. Dropped after the derivatives, which take its neighbours; by the bits
	// (geo_finite): a compiler may take a comparison as if no number were NaN
	if (!geo_finite(col.r + col.g + col.b)) discard;
#endif
	ALBEDO = col;
#endif
}
