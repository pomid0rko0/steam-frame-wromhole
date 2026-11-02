shader_type spatial;
// The floor's quad under our own foveation (floor_fov.gd): the floor, the sky and what is seen
// through the curved zone were worked out already, into fov_tex, a texel per pixel where the eye
// looks and coarser away from it (floor_fov.gdshaderinc); each pixel only takes its colour from
// there, filtered, by the same warp, with the numbers fov_warp holds for its eye. A program of its
// own, not floor.gdshaderinc's with the lens in it: a pixel here holds a few registers, not the
// lens's (tools/adreno_stats.sh), so the GPU keeps more of them going at once. Where the quad stands and when it is
// drawn: floor.gdshaderinc's top (Renderer draws the quad with this while floor_fov is on).
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled;

uniform sampler2DArray fov_tex : filter_linear, repeat_disable;
uniform sampler2D fov_warp : filter_nearest, repeat_disable;   // per eye (row): (gaze x, y, k, n), (A0, A1 along x, then y)

varying vec2 v_clip;

void vertex() {
	// a quad over the whole view at the far plane (reversed depth: 0), so that any body's depth wins
	POSITION = vec4(VERTEX.xy, 0.0, 1.0);
	v_clip = VERTEX.xy;
}

void fragment() {
	int v = int(VIEW_INDEX);
	vec4 wg = texelFetch(fov_warp, ivec2(0, v), 0), wa = texelFetch(fov_warp, ivec2(1, v), 0);
	vec2 t = (asinh(wg.z * (v_clip - wg.xy)) / wg.z - wa.xz) / (wa.yw - wa.xz);
	ALBEDO = textureLod(fov_tex, vec3(t, float(v)), 0.0).rgb;
}
