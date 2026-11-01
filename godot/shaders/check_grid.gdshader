shader_type spatial;
// Stereo check, drawn by Godot's standard renderer: green lines exactly where the ray-traced
// floor of universe A has its white lines in the flat universe: on the world's whole metres of x and
// y (look.gdshaderinc, look_floor_coords). The mesh lives in universe A's world coordinates (its
// node maps world -> play space). If each eye's ray math is right, the green lines cover the white
// ones; if not, the viewer sees two grids.
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, fog_disabled, shadows_disabled;

uniform float rout;            // chart radius where the flat floor starts
uniform vec2 centre;           // the throat's centre in the world
const float clear = 0.3;       // keep away from the curved part
uniform vec4 balls[3];         // CheckScene.BALLS (world centre, radius) hide the floor behind them
uniform vec4 cube;             // and the check cube (world centre, radius of a ball around it)
uniform bool solid = false;    // tests: fill everywhere a line could be drawn

varying vec3 v_world;
varying flat vec3 v_eye;       // this view's eye in world coordinates

void vertex() {
	v_world = VERTEX;
	v_eye = (inverse(MODEL_MATRIX) * INV_VIEW_MATRIX * vec4(EYE_OFFSET, 1.0)).xyz;
}

void fragment() {
	vec3 o = vec3(centre, 0.0);
	if (length(v_world.xy - centre) < rout + clear) discard;
	// light only goes straight when its path stays out of the wormhole: skip floor points
	// whose straight line of sight from this eye passes near it
	vec3 eye = v_eye;
	vec3 d = v_world - eye;
	float t = clamp(dot(o - eye, d) / dot(d, d), 0.0, 1.0);
	if (length(eye + t * d - o) < rout + clear) discard;
	for (int i = 0; i < balls.length(); i++) {
		float tb = clamp(dot(balls[i].xyz - eye, d) / dot(d, d), 0.0, 1.0);
		if (length(eye + tb * d - balls[i].xyz) < balls[i].w) discard;
	}
	float tc = clamp(dot(cube.xyz - eye, d) / dot(d, d), 0.0, 1.0);
	if (length(eye + tc * d - cube.xyz) < cube.w) discard;
	vec2 q = v_world.xy;
	vec2 fw = max(fwidth(q), vec2(1e-4));
	if (max(fw.x, fw.y) > 0.2) discard;     // lines closer than 5 px: far away, would merge
	vec2 gf = abs(fract(q + 0.5) - 0.5) / fw;
	float a = solid ? 1.0 : 1.0 - clamp(min(gf.x, gf.y) - 1.5, 0.0, 1.0);
	if (a < 0.02) discard;
	ALBEDO = vec3(0.0, 1.0, 0.25);
	ALPHA = a;
}
