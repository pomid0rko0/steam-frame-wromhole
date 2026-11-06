// Bodies: meshes drawn by Godot's rasterizer, each vertex put where the eye of this view sees it,
// at the length of the light's way there along that direction, so depth orders bodies by how far
// light goes. The pixel then only shades. docs/geometry.md, «Как рисуется кадр».
//   DIRECT (toy_ball.gdshader, toy_cube.gdshader) and STATIC: bodies out in a flat universe, seen
//     straight: only from an eye out in the same universe, by the straight line from it (an
//     ordinary camera); a fragment whose line of sight goes through the curved zone's ball is
//     dropped: that part of the view is the lens's (floor.gdshaderinc, which draws these bodies
//     there along the rays that come out of the zone).
//   Else: each vertex along its geodesics (geo_see_image; ZONE: a table's, zone_path_see), every image.
//   TOY: balls (BALL) and cubes (CUBE) of the physics (ball_world.gd), one MultiMesh each. An
//     instance: its centre C (a point of R^4) and body axes E1, E2 packed in the transform's 12
//     numbers (Renderer.pack), E3 from them and the space's normal; INSTANCE_CUSTOM = (colour,
//     radius or half size). A ball is the space's points at chord distance radius from C
//     (BallWorld's ball); a cube its 4D box cut by the space: the points whose offsets from C
//     along E1, E2, E3 are within the half size. With DIRECT the mesh is the unit sphere or the
//     cube [-1, 1]^3, each point taken along the space's normal at C.
//     Below the floor they are hidden: the floor hides whatever is below it.
//   ZONE (zone_ball.gdshader, zone_cube.gdshader): toys in the curved zone, each drawn once per image
//     in the picture, on the mesh its place there needs (an instance: its body's slot and image
//     from its list, zone_list: ZoneSections' LISTS; the body's centre, axes, size and colour from
//     the same texture's last row), as a mesh made anew for each view round the line
//     through its eye and the centre (the axis): there the images of a point fold into a ring (an
//     Einstein ring), and a triangle across the axis would join a point's image on one side with its
//     neighbour's on the other. So the mesh is a grid (VERTEX.xy in [0, 1]^2) of the azimuth theta
//     about the axis and of the place round the body's section by the half-surface of that azimuth
//     (points (l, alpha): alpha the angle from the eye's direction toward theta): a body off the axis
//     takes the azimuths it spans, each section a closed curve round the point nearest its centre;
//     a body round the axis every azimuth, each section an arc from where the axis enters it to
//     where it leaves. No triangle crosses the axis, and the images come out as rings where they
//     are. A ball's points by Newton's steps on its definition along a straight line of (l, r alpha)
//     from the inner point (zone.gdshaderinc); a cube's on its edges and faces, its columns on the
//     knots of its edges' azimuths and a row on each corner of its sections, the same corner on the
//     same row all through a span between two knots, a section of two parts with two rows between
//     them that are dropped (v_kill; zone_cube.gdshaderinc); on a knot two columns, one line in the
//     picture, pulled past each other by ZONE_KNOT_PX and the strip between them dropped (v_knot),
//     else the rasterizer's rounding would leave pinholes between them. A node's point is the same
//     in every image: it is worked out once a frame for each eye (zone_sections.gd, ZoneSections'
//     texture zone_nodes), and here each image's vertex takes it and its geodesic from the body's
//     table of the ways from the eye (zone_paths, zone.gdshaderinc's zone_path_see), worked out
//     once a frame too.
//   STATIC (scene.gdshader): the scene's objects, vertices in chart coordinates of universe
//     sheet (A +1, B -1), all in the flat sheets.
//   ARROWS and BEAM: one instance per image, each vertex by its own plane through the centre.
//   ARROWS (arrows.gdshader): the gravity view's arrows (Renderer._arrow_mesh), vertices as points
//     (l, n) of the space (n in VERTEX, l in UV.x), unlit, in their COLOR, but for their outline
//     (arrow_rim): the pixels neither inside the coloured part (CUSTOM0's three numbers all at least
//     0) nor inside the line's (UV2's two; Renderer._line); COLOR.a 1 (an arrow, coloured over its
//     line) a hair nearer the eye in depth than 0 (a line), in the same place in the view.
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
// instance i draws the body slot and image at texel (i, zone_list_row) of zone_list; the bodies' rows
// (C, E1, E2, (size, colour)) at (4 slot + k, ZONE_LIST_BODIES) (ZoneSections' LISTS)
uniform sampler2D zone_list : filter_nearest, repeat_disable;
uniform int zone_list_row = 0;
const int ZONE_LIST_BODIES = 7;
uniform float zone_round = 48.0; // the nodes' points round a section and azimuths a mesh's VERTEX.xy spans (Renderer._zone_mesh)
uniform float zone_columns = 64.0;
// the nodes (zone_sections.gdshaderinc's out): per eye a layer, per node two texels; this mesh's
// first row in a slot, a slot's rows
uniform sampler2DArray zone_nodes : filter_nearest, repeat_disable;
// per image, slot and eye: (the body's centre's x, y, z as the pass took it, its mesh if the image is
// drawn in this eye, else 0)
uniform sampler2DArray zone_cull : filter_nearest, repeat_disable;
// per slot and eye the body's table of the ways from the eye (zone.gdshaderinc, «the paths by a table»)
uniform sampler2DArray zone_paths : filter_nearest, repeat_disable;
uniform int zone_row = 0;
uniform int zone_slot_rows = 62;
// pixels a knot's two columns are pulled past each other by, each way: beyond the rasterizer's
// rounding of a vertex (a 256th of a pixel)
const float ZONE_KNOT_PX = 1.0 / 64.0;
#endif
#ifdef BEAM
#define BEAM_POINTS 48           // Renderer.BEAM_POINTS
uniform vec4 beam_p[BEAM_POINTS];
uniform float beam_r[BEAM_POINTS];
uniform int beam_n = 0;
uniform vec3 beam_col : source_color = vec3(1.0);
#endif
#ifdef ARROWS
uniform vec3 arrow_rim : source_color = vec3(0.02);   // the outline's colour (Renderer.ARROW_RIM_COLOR)
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
#if defined(ZONE) && defined(CUBE)
// 1 at a node no part of the surface (a cube's rows between two parts of its section,
// zone_cube.gdshaderinc's zc_node): a triangle of three such is dropped, one with fewer has no area
varying float v_kill;
// 2 column + its side of a knot (zone_cube.gdshaderinc's zc_side), mod 8: the same at all three
// vertices only of a triangle of the strip between a knot's two columns (a cube's meshes take every
// column; a ball has no knots)
varying float v_knot;
#endif
varying vec3 v_col;
#ifdef DIRECT
varying vec3 v_p;       // the point (R^4's xyz)
varying flat vec3 v_eye;     // the eye (R^4's xyz)
#endif
#ifdef TOY
varying vec3 v_box;     // a cube's point in its own coordinates [-1, 1]^3
#endif
#ifdef ARROWS
varying vec3 v_inner;   // how far inside the coloured part (CUSTOM0), and inside its line's (UV2)
varying vec2 v_line;
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
	vec4 li = texelFetch(zone_list, ivec2(INSTANCE_ID, zone_list_row), 0);
	int slot = int(li.x + 0.5), image = int(li.y + 0.5);
	vec4 C = texelFetch(zone_list, ivec2(4 * slot, ZONE_LIST_BODIES), 0);
	vec4 E1 = texelFetch(zone_list, ivec2(4 * slot + 1, ZONE_LIST_BODIES), 0);
	vec4 E2 = texelFetch(zone_list, ivec2(4 * slot + 2, ZONE_LIST_BODIES), 0);
	vec4 sc = texelFetch(zone_list, ivec2(4 * slot + 3, ZONE_LIST_BODIES), 0);
	vec4 N = geo_normal(C);
	vec4 E3 = -geo_cross4(E1, E2, N);
	float size = sc.x;
	float pl = 0.0;
	float len = 0.0, fell = 0.0;
	vec4 arrive = vec4(0.0);
	bool none = false;            // the node came out not a number (zone_sections.gdshaderinc)
#ifdef CUBE
	v_kill = 0.0;
	v_knot = 0.0;
#endif
	// an image the pass leaves out (thinner than a share of a pixel), or of a body it did not take
	// this frame (a slot not worked out: its nodes are another's, or none): every vertex out of the
	// picture at the centre, no triangle drawn, no geodesic sought
	vec4 cull = texelFetch(zone_cull, ivec3(image, slot, int(VIEW_INDEX)), 0);
	if (cull.w > 0.5 && all(equal(cull.xyz, C.xyz))) {
		// the node's point on the body: (l, alpha) and its half-surface's direction t
		// (zone_sections.gdshaderinc)
		ivec2 node = ivec2(round(VERTEX.xy * vec2(zone_columns, zone_round)));
		int row = slot * zone_slot_rows + zone_row + node.y;
		vec4 na = texelFetch(zone_nodes, ivec3(2 * node.x, row, int(VIEW_INDEX)), 0);
		vec4 nb = texelFetch(zone_nodes, ivec3(2 * node.x + 1, row, int(VIEW_INDEX)), 0);
		vec2 pe = na.xy;
		vec3 t = vec3(na.zw, nb.x);
		none = nb.y > 0.5;
#ifdef CUBE
		v_kill = nb.z;
#endif
		pl = pe.x;
		float alpha = clamp(pe.y, 0.0, GEO_PI);
		vec2 sca = geo_sincos(alpha);
		vec3 pn = sca.y * en + sca.x * t;
		P = vec4(geo_r(abs(pl)) * pn, zone_w(pl));
		vec4 dir = zone_path_see(zone_paths, slot * ZONE_PL, int(VIEW_INDEX), el, en, pl, pn, t, alpha, image, len, arrive, fell);
		vec3 pv = EYE_OFFSET + len * vec3(dot(dir, ex), dot(dir, ey), dot(dir, ez));
		POSITION = PROJECTION_MATRIX * vec4(pv, 1.0);
		// a knot's two columns (zc_side: +1 the first, -1 the second): one line in the picture, each
		// with vertices of its own, which the rasterizer rounds to its grid apart. So each is pulled
		// ZONE_KNOT_PX past the line toward the other, the way the picture of a point goes as its
		// azimuth grows: dir (its radial part, then its part across) turned about the axis, toward
		// en x t, or -(en x t) in the odd images, which leave on the -t side (zone_path_see). The
		// strip between them is not drawn (v_knot). A ball has no knots
#ifdef CUBE
		float side = nb.w;
		v_knot = mod(2.0 * float(node.x) + side, 8.0);
		if (side != 0.0 && POSITION.w > 0.0) {
			vec3 to = normalize(t - dot(t, en) * en);
			vec4 way = vec4(0.0, ((image & 1) == 1 ? -1.0 : 1.0) * cross(en, to));
			vec4 p2 = PROJECTION_MATRIX * vec4(pv + 1e-3 * len * vec3(dot(way, ex), dot(way, ey), dot(way, ez)), 1.0);
			vec2 d = (p2.xy / p2.w - POSITION.xy / POSITION.w) * VIEWPORT_SIZE;
			if (p2.w > 0.0 && dot(d, d) > 0.0) {
				POSITION.xy += side * ZONE_KNOT_PX * 2.0 * normalize(d) / VIEWPORT_SIZE * POSITION.w;
			}
		}
#endif
	} else {
		P = C;
		POSITION = vec4(0.0, 0.0, 2.0, 1.0);
	}
	vec4 q = P - C;
#ifdef BALL
	nrm = q;
#else
	v_box = vec3(dot(q, E1), dot(q, E2), dot(q, E3)) / size;
#endif
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
	v_inner = CUSTOM0.xyz;
	v_line = UV2;
#elif defined(BEAM)
	vec4 Np = N;
	v_col = beam_col;
#else
	vec4 Np = geo_normal(P);
#ifdef ZONE
	v_col = sc.yzw;
#elif defined(TOY)
	v_col = INSTANCE_CUSTOM.rgb;
#endif
#ifdef TOY
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
	// cyan where one was passed over, magenta where geo_see's stand-in took the vertex (ZONE: in a
	// node of the table about it)
	if (fell > 0.0) v_col = mix(v_col, fell > 0.75 ? vec3(1.0, 0.0, 1.0) : vec3(0.0, 1.0, 1.0), 0.7);
#ifdef ZONE
	// and orange where a node came out not a number
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
#ifdef ARROWS
	bool inside = min(v_inner.x, min(v_inner.y, v_inner.z)) >= 0.0 || min(v_line.x, v_line.y) >= 0.0;
	ALBEDO = inside ? v_col : arrow_rim;
#elif defined(BEAM)
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
	// gets one now and then, its varyings no numbers; nor is one of a triangle between a cube's
	// section's parts (v_kill), nor of the strip between a knot's two columns (v_knot the same at
	// its vertices: none across it, while across any other triangle it changes by 2 to 6 over a
	// column, a few thousand pixels at most). Dropped after the derivatives, which take its
	// neighbours; by the bits (geo_finite): a compiler may take a comparison as if no number were NaN
	bool off = !geo_finite(col.r + col.g + col.b);
#ifdef CUBE
	off = off || v_kill > 0.5 || fwidth(v_knot) < 1e-5;
#endif
	if (off) discard;
#endif
	ALBEDO = col;
#endif
}
