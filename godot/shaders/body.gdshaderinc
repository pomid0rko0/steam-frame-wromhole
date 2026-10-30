// Bodies: meshes drawn by Godot's rasterizer, each vertex put where the eye of this view sees it
// (geo_see: the one geodesic to it, docs/geometry.md), at the geodesic's length along that
// direction, so depth orders bodies by how far light goes. The pixel then only shades.
//   TOY (toy.gdshader): balls (BALL) and cubes (CUBE) of the physics (ball_world.gd), one
//     MultiMesh each. An instance: its centre C (a point of R^4) and body axes E1, E2 packed in the
//     transform's 12 numbers (Renderer.pack), E3 from them and the space's normal; INSTANCE_CUSTOM =
//     (colour, radius or half size). A ball's mesh is the unit sphere: the point of the space at
//     chord distance radius from C in that direction (BallWorld's ball). A cube's is the cube
//     [-1, 1]^3: its 4D box cut by the space, each point taken along the space's normal at C.
//     Below the floor they are hidden: the floor hides whatever is below it.
//   STATIC (scene.gdshader): the scene's objects, vertices in chart coordinates of universe
//     sheet (A +1, B -1), all in the flat sheets.
//   ARROWS (arrows.gdshader): the gravity view's arrows (Renderer._arrow_mesh), vertices as points
//     (l, n) of the space (n in VERTEX, l in UV.x), unlit, in their COLOR; COLOR.a 1 (the arrow,
//     over its outline of COLOR.a 0) a hair nearer the eye in depth, in the same place in the view.
// Lit in R^4: the normal of the surface and the sun (look_sun4) as tangent vectors at the point.
#ifdef ARROWS
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

varying vec4 v_n;       // the surface's normal (R^4)
varying vec4 v_sun;     // toward the sun (R^4, tangent there)
varying vec4 v_up;      // up (R^4, tangent there)
varying vec4 v_ray;     // the light's way in (R^4)
varying float v_l;
varying float v_h;      // height above the floor (R^4's z)
varying vec3 v_col;
#ifdef TOY
varying vec3 v_box;     // a cube's point in its own coordinates [-1, 1]^3
#endif

void vertex() {
	vec4 P;
	vec4 nrm;
#ifdef TOY
	vec4 C = vec4(MODEL_MATRIX[0].xyz, MODEL_MATRIX[1].x);
	vec4 E1 = vec4(MODEL_MATRIX[1].yz, MODEL_MATRIX[2].xy);
	vec4 E2 = vec4(MODEL_MATRIX[2].z, MODEL_MATRIX[3].xyz);
	vec4 N = geo_normal(C);
	// the third axis completing a right-handed frame of a chart (A's x, y, z; B's mirrored): its
	// orientation is the eyes' (geo_normal points to A's -w, B's +w), so the mesh keeps its winding
	vec4 E3 = -geo_cross4(E1, E2, N);
	float size = INSTANCE_CUSTOM.a;
	v_col = INSTANCE_CUSTOM.rgb;
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
#else
	v_box = VERTEX;
	nrm = abs(VERTEX.x) > 0.999 ? sign(VERTEX.x) * E1 : (abs(VERTEX.y) > 0.999 ? sign(VERTEX.y) * E2 : sign(VERTEX.z) * E3);
#endif
#elif defined(ARROWS)
	P = vec4(0.0);
	nrm = vec4(0.0);
	v_col = COLOR.rgb;
#else
	vec3 xc = VERTEX;
	v_col = COLOR.rgb;
	float h = g_prof.z - g_prof.y * geo_sin(g_prof2.w) + g_prof.y;
	P = sheet > 0.0 ? vec4(xc, h) : vec4(-xc.x, xc.yz, -h);
	nrm = vec4(sheet > 0.0 ? NORMAL.x : -NORMAL.x, NORMAL.yz, 0.0);
#endif
	vec3 pn;
#ifdef ARROWS
	pn = normalize(VERTEX);
	float pl = UV.x;
	vec4 Np = vec4(0.0);
#else
	float pl = geo_l_of(P, pn);
	vec4 Np = geo_normal(P);
#endif
	v_n = nrm - dot(nrm, Np) * Np;
	vec4 s4 = look_sun4(pl);
	v_sun = s4 - dot(s4, Np) * Np;
	v_up = vec4(0.0, 0.0, 1.0, 0.0) - Np.z * Np;
	v_l = pl;
	v_h = P.z;
	float el;
	vec3 en;
	vec4 ex, ey, ez;
	geo_eye(INV_VIEW_MATRIX, EYE_OFFSET, el, en, ex, ey, ez);
	float len, fell;
	vec4 arrive;
	vec4 dir = geo_see(el, en, pl, pn, len, arrive, fell);
	v_ray = arrive;
	// to find where the headset's GPU makes a ray of the search not finite (the PC's never do):
	// cyan where one was passed over, magenta where geo_see's stand-in took the vertex
	if (fell > 0.0) v_col = mix(v_col, fell > 0.75 ? vec3(1.0, 0.0, 1.0) : vec3(0.0, 1.0, 1.0), 0.7);
#ifdef ARROWS
	len *= 1.0 - 1e-3 * COLOR.a;
#endif
	POSITION = PROJECTION_MATRIX * vec4(EYE_OFFSET + len * vec3(dot(dir, ex), dot(dir, ey), dot(dir, ez)), 1.0);
}

void fragment() {
#ifdef TOY
	if (v_h < 0.0) discard;
#endif
#ifdef ARROWS
	ALBEDO = v_col;
#else
	vec4 n = normalize(v_n);
	float nl = dot(n, normalize(v_sun));
	float up = dot(n, normalize(v_up));
	float nv = -dot(n, normalize(v_ray));
	vec3 col = look_body(v_col, nl, up, nv, v_l);
#ifdef CUBE
	// dark edges: the distance to the face's nearest edge in pixels
	vec3 a = abs(v_box);
	float mid = a.x + a.y + a.z - max(max(a.x, a.y), a.z) - min(min(a.x, a.y), a.z);
	float e = 1.0 - mid;
	float fw = max(fwidth(e), 1e-5);
	col *= mix(0.45, 1.0, clamp((e - 0.04) / fw + 0.5, 0.0, 1.0));
#endif
	ALBEDO = col;
#endif
}
