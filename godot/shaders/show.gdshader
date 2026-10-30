shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;

// The ray tracer's picture (ray_pass.gd), pixel for pixel: a layer per view.
uniform sampler2DArray picture : filter_nearest, repeat_disable;
uniform bool squared = false;   // a picture of eight bits a channel holds the colour's square root (RayPass.picture8)

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	vec3 c = texelFetch(picture, ivec3(ivec2(FRAGCOORD.xy), int(VIEW_INDEX)), 0).rgb;
	ALBEDO = squared ? c * c : c;
}
