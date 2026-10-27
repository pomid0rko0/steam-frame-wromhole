extends CompositorEffect
## What every pixel of an eye shares, worked out once per eye and frame on the GPU, before the 3D
## scene is drawn (a compute shader on the XR camera's compositor): the eye's point of the space and
## its play axes (wh_eyeAt: the head's moved along the geodesic of the eye's offset from it), wh_eye of
## it, and the cones of directions in which the toys near the head can be met (wh_coneAt). The eyes
## are the render's own (its views), so the values are exact for the frame being drawn. The shaders
## read them from one texture (wh_eyes in wormhole_uniforms.gdshaderinc), a row per view:
##   0 (l, n)   1-3 the play axes f0, f1, f2   4 wh_eye(l)
##   5 + 2 j    cone j's axis (a tangent vector)   6 + 2 j   (cos of its half angle (-2: none), 0, 0, 0)
## main.gd hands it the head and the near toys each frame (set_frame, on the render thread).

const WIDTH := 13
const CONES := 4
# the frame's data, as the compute shader's uniform block (std140, 56 floats)
const F_HEAD_F := 0         # head_f[3]
const F_CONE := 12          # cone j: (n, l) of the toy's centre
const F_CONE_C := 28        # their chord radii
const F_CONE_ON := 32       # 1: a toy in that place
const F_EYE := 36           # the views' eyes, play space
const F_HEAD_N := 44        # head_n, head_l
const F_HEAD_POS := 48      # head_pos, wh_rho0
const F_SHAPE := 52         # wh_h, wh_fillet
const SIZE := 56

var texture := Texture2DRD.new()
var rd: RenderingDevice
var shader: RID
var pipeline: RID
var ubo: RID
var tex: RID
var data := PackedFloat32Array()


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_OPAQUE
	data.resize(SIZE)
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		return                      # no RenderingDevice (the compatibility renderer, headless)
	var src := RDShaderSource.new()
	src.source_compute = _source()
	var spirv := rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		push_error("eye_data.gd: " + spirv.compile_error_compute)
		return
	shader = rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader)
	ubo = rd.uniform_buffer_create(SIZE * 4)
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.width = WIDTH
	fmt.height = 2
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	tex = rd.texture_create(fmt, RDTextureView.new(), [])
	texture.texture_rd_rid = tex


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd != null:
		for r in [pipeline, shader, ubo, tex]:
			if r.is_valid():
				rd.free_rid(r)


## The frame's head and near toys (main.gd, through RenderingServer.call_on_render_thread, so that
## the render that uses this frame's materials uses this frame's data too)
func set_frame(d: PackedFloat32Array) -> void:
	data = d


func _render_callback(_type: int, render_data: RenderData) -> void:
	if not pipeline.is_valid():
		return
	var sd := render_data.get_render_scene_data()
	var cam := sd.get_cam_transform()
	var views := sd.get_view_count()
	var d := data.duplicate()
	for v in 2:
		var e := cam * sd.get_view_eye_offset(mini(v, views - 1))
		d[F_EYE + 4 * v] = e.x
		d[F_EYE + 4 * v + 1] = e.y
		d[F_EYE + 4 * v + 2] = e.z
	rd.buffer_update(ubo, 0, SIZE * 4, d.to_byte_array())
	var u_img := RDUniform.new()
	u_img.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_img.binding = 0
	u_img.add_id(tex)
	var u_buf := RDUniform.new()
	u_buf.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	u_buf.binding = 1
	u_buf.add_id(ubo)
	var set := UniformSetCacheRD.get_cache(shader, 0, [u_img, u_buf])
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set, 0)
	rd.compute_list_dispatch(cl, 1, 1, 1)
	rd.compute_list_end()


# The compute shader: the renderer's core (plain GLSL, wormhole_core.gdshaderinc) with the
# uniforms it reads declared as one block. One invocation per (view, part): part 0 the eye's frame,
# parts 1-4 one cone each.
func _source() -> String:
	var core: String = (load("res://shaders/wormhole_core.gdshaderinc") as ShaderInclude).code
	return """#version 450
layout(local_size_x = 5, local_size_y = 2, local_size_z = 1) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict writeonly image2D eyes;
layout(set = 0, binding = 1, std140) uniform Frame {
	vec4 head_f[3];
	vec4 cone_tn[4];
	vec4 cone_c;
	vec4 cone_on;
	vec4 eye_p[2];
	vec3 head_n; float head_l;
	vec3 head_pos; float wh_rho0;
	float wh_h; float wh_fillet; float wh_pad0; float wh_pad1;
};
// the shading's screen derivatives and the static objects, which the core's flat trace reads: not
// used here
#define dFdx(x) ((x) * 0.0)
#define dFdy(x) ((x) * 0.0)
#define fwidth(x) ((x) * 0.0)
const vec4 wh_sph[6] = vec4[6](vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0));
const vec4 wh_pil[4] = vec4[4](vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0));
const vec4 wh_box[4] = vec4[4](vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0));
""" + core + """
void main() {
	int part = int(gl_LocalInvocationID.x);
	int v = int(gl_LocalInvocationID.y);
	float l; vec3 n; vec4 f0; vec4 f1; vec4 f2;
	wh_eyeAt(eye_p[v].xyz, l, n, f0, f1, f2);
	if (part == 0) {
		imageStore(eyes, ivec2(0, v), vec4(l, n));
		imageStore(eyes, ivec2(1, v), f0);
		imageStore(eyes, ivec2(2, v), f1);
		imageStore(eyes, ivec2(3, v), f2);
		imageStore(eyes, ivec2(4, v), vec4(wh_eye(l), 0.0, 0.0));
	} else {
		int j = part - 1;
		vec4 axis = vec4(1.0, 0.0, 0.0, 0.0);
		float ct = -2.0;
		if (cone_on[j] > 0.5) axis = wh_coneAt(l, n, cone_tn[j].w, cone_tn[j].xyz, cone_c[j], ct);
		imageStore(eyes, ivec2(5 + 2 * j, v), axis);
		imageStore(eyes, ivec2(6 + 2 * j, v), vec4(ct, 0.0, 0.0, 0.0));
	}
}
"""
