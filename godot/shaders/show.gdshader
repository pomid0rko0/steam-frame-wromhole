shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;

// The ray tracer's picture (ray_pass.gd), pixel for pixel: a layer per view.
uniform sampler2DArray picture : filter_nearest, repeat_disable;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	ALBEDO = texelFetch(picture, ivec3(ivec2(FRAGCOORD.xy), int(VIEW_INDEX)), 0).rgb;
}
