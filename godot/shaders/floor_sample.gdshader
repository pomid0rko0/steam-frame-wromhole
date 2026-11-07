shader_type spatial;
// The floor's quad under foveation (foveation.gd): the floor, the sky and what is seen through the
// curved zone were worked out already, into fov_tex, a texel per pixel round where the eye looks
// and coarser away from it (foveation.gdshaderinc); each pixel only takes its colour from there,
// filtered, by the same warp, with the numbers fov_warp holds for its eye. A program of its own,
// not floor.gdshaderinc's with the lens in it: a pixel here holds a few registers, not the lens's
// (tools/adreno_stats.sh), so the GPU keeps more of them going at once. Those numbers are taken per
// corner, not per pixel (each eye's own: VIEW_INDEX in vertex()), and the pixel's place from g, q,
// is an affine function of its place in the picture, so its corners' values carry it across: a
// pixel costs one texture read, its colour. Where the quad stands and when it is drawn:
// floor.gdshaderinc's top (Renderer draws the quad with this while foveation is on).
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled;

uniform sampler2DArray fov_tex : filter_linear, repeat_disable;
uniform sampler2D fov_warp : filter_nearest, repeat_disable;   // per eye (a row): (g, c), (r0, m, texels across, down), (pixels across, down) (foveation.gd)
uniform bool fov_probe = false;    // tests: how far from its place each pixel took its colour (foveation.gd's probe)

varying vec2 v_q;               // the pixel's place from g, in pixels
varying flat vec4 v_w0;         // this eye's (g, c)
varying flat vec4 v_w1;         // its (r0, m, the texels across, down)

void vertex() {
	// a quad over the whole view at the far plane (reversed depth: 0), so that any body's depth wins
	POSITION = vec4(VERTEX.xy, 0.0, 1.0);
	int v = int(VIEW_INDEX);
	v_w0 = texelFetch(fov_warp, ivec2(0, v), 0);
	v_w1 = texelFetch(fov_warp, ivec2(1, v), 0);
	v_q = (VERTEX.xy * 0.5 + 0.5) * texelFetch(fov_warp, ivec2(2, v), 0).xy - v_w0.xy;
}

void fragment() {
	// the pixel r from g: at c + (p - g) F(r) / r in the texture
	vec2 q = v_q;
	float r = length(q);
	float k = r > v_w1.x ? (v_w1.x + asinh(v_w1.y * (r - v_w1.x)) / v_w1.y) / r : 1.0;
	vec4 t = textureLod(fov_tex, vec3((v_w0.zw + k * q) / v_w1.zw, float(VIEW_INDEX)), 0.0);
	ALBEDO = t.rgb;
	if (fov_probe) {
		// the place the texture holds there (phases over 256 pixels, foveation.gdshaderinc's
		// FOV_PROBE) against this pixel's own: blue, and red by the larger error, 0.5 px full
		vec2 e = vec2(atan(t.y, t.x), atan(t.w, t.z)) - 6.2831853 * (q + v_w0.xy) / 256.0;
		e = mod(e + 3.14159265, 6.2831853) - 3.14159265;
		ALBEDO = vec3(min(max(abs(e.x), abs(e.y)) * 256.0 / 6.2831853 / 0.5, 1.0), 0.0, 1.0);
	}
}
