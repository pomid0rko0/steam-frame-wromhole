class_name RayPass
extends CompositorEffect
## The ray tracer's GPU work, on the XR camera's compositor before Godot draws the 3D scene: compute
## kernels (shaders/trace_kernels.gdshaderinc, around the core wormhole_core.gdshaderinc) trace
## every pixel of every view into a picture of its own (picture), which the ray tracer's quad shows
## (tracer.gd). The views are the render's own (their eye offsets and projections), so the rays are
## exact for the frame being drawn.
##
## Tracer hands it the frame's values (set_frame, on the render thread) as one block of bytes in
## the order of the kernels' uniform block; the callback adds what only the render knows (the
## camera, the views' eye offsets and projections, the picture's size).

const KERNELS := "res://shaders/trace_kernels.gdshaderinc"
const CORE := "res://shaders/wormhole_core.gdshaderinc"
const VIEW_AT := 1808           # bytes: where the views' part of the block starts (fr_cam)
const SIZE := 2048              # bytes: the block (Frame in trace_kernels.gdshaderinc)
# the kernels' variants by the gravity view (Tracer.GRAVITY_VIEWS); the world kernel's also without
# toys (WH_NO_BALLS) or with those of the flat universes (WH_NO_SHELL_TOYS: the toys kernel searches
# the curved part where it found candidates). Every one is compiled at the start (a switch then
# costs no hitch).
const GRAVITY_DEFINES := ["", "#define WH_GRAVITY\n", "#define WH_GRAVITY\n#define WH_ARROWS\n"]

var picture := Texture2DArrayRD.new()   # what the quad shows: a layer per view
var frame := PackedByteArray()          # Tracer's part of the block
var gravity := 0                        # the gravity view (GRAVITY_DEFINES)
var toys := false                       # movable objects in the kernels
var rings: Array = []                   # Foveation.rings: none, every pixel its own ray
var table: Texture2D                    # the fillet table (WormholeSpace.fillet_table)
var rd: RenderingDevice
var failed := false
var eyes_pipe: RID
var eyes_shader: RID
var world_pipes: Array[RID] = []        # without toys by gravity view, then with them
var world_shaders: Array[RID] = []
var toys_pipes: Array[RID] = []         # by gravity view
var toys_shaders: Array[RID] = []
var tiles: RID                          # the toys kernel's groups (fr_tiles)
var ubo: RID
var eyes_buf: RID
var sampler: RID
var image: RID
var image_size := Vector2i.ZERO
var image_views := 0


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_OPAQUE
	frame.resize(VIEW_AT)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd != null:
		for r: RID in [eyes_pipe, eyes_shader, ubo, eyes_buf, sampler, image, tiles] + world_pipes + world_shaders + toys_pipes + toys_shaders:
			if r.is_valid():
				rd.free_rid(r)


## The foveation's rings (Foveation.rings): rays traced coarser away from where the eyes look.
func set_rings(r: Array) -> void:
	rings = r


## Tracer's values for the frame (on the render thread: RenderingServer.call_on_render_thread).
func set_frame(bytes: PackedByteArray, p_gravity: int, p_toys: bool) -> void:
	frame = bytes
	gravity = p_gravity
	toys = p_toys


func _render_callback(_type: int, render_data: RenderData) -> void:
	if failed:
		return
	if rd == null and not _setup():
		failed = true
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var sd := render_data.get_render_scene_data()
	if buffers == null or sd == null or table == null:
		return
	var size := buffers.get_internal_size()
	var views := buffers.get_view_count()
	if size.x <= 0 or size.y <= 0:
		return
	if size != image_size or views != image_views:
		_make_image(size, views)
	var block := StreamPeerBuffer.new()
	block.data_array = frame
	block.seek(VIEW_AT)
	var cam := sd.get_cam_transform()
	_put_transform(block, cam)
	for v in 2:
		var off := sd.get_view_eye_offset(mini(v, views - 1))
		_put_vec4(block, Vector4(off.x, off.y, off.z, 1.0))
	for v in 2:
		var p := sd.get_view_projection(mini(v, views - 1))
		_put_projection(block, (Projection.create_depth_correction(false) * p).inverse())
	for k in [size.x, size.y, views, 0]:
		block.put_32(k)
	var bytes := block.data_array
	bytes.resize(SIZE)
	# the views count rides in the frame's part (fr_views)
	bytes.encode_s32(1720, views)
	rd.buffer_update(ubo, 0, SIZE, bytes)
	var tex := RenderingServer.texture_get_rd_texture(table.get_rid())
	var u_ubo := RDUniform.new()
	u_ubo.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	u_ubo.binding = 0
	u_ubo.add_id(ubo)
	var u_tab := RDUniform.new()
	u_tab.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_tab.binding = 1
	u_tab.add_id(sampler)
	u_tab.add_id(tex)
	var u_img := RDUniform.new()
	u_img.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_img.binding = 2
	u_img.add_id(image)
	var u_eyes := RDUniform.new()
	u_eyes.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_eyes.binding = 3
	u_eyes.add_id(eyes_buf)
	var u_tiles := RDUniform.new()
	u_tiles.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_tiles.binding = 4
	u_tiles.add_id(tiles)
	var all := [u_ubo, u_tab, u_img, u_eyes, u_tiles]
	var w := gravity + (GRAVITY_DEFINES.size() if toys else 0)
	if toys:
		rd.buffer_update(tiles, 0, 16, PackedInt32Array([0, 1, 1, 0]).to_byte_array())
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, eyes_pipe)
	rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(eyes_shader, 0, all), 0)
	rd.compute_list_dispatch(cl, 1, 1, 1)
	rd.compute_list_add_barrier(cl)
	rd.compute_list_bind_compute_pipeline(cl, world_pipes[w])
	rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(world_shaders[w], 0, all), 0)
	rd.compute_list_dispatch(cl, (size.x + 15) / 16, (size.y + 7) / 8, views)
	if toys:
		rd.compute_list_add_barrier(cl)
		rd.compute_list_bind_compute_pipeline(cl, toys_pipes[gravity])
		rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(toys_shaders[gravity], 0, all), 0)
		rd.compute_list_dispatch_indirect(cl, tiles, 0)
	rd.compute_list_end()


## The kernels and the buffers, once (on the render thread). False: no RenderingDevice (the
## compatibility renderer, headless) or a kernel did not compile.
func _setup() -> bool:
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		return false
	var made := _kernel("#define KERNEL_EYES\n")
	if made.is_empty():
		return false
	eyes_shader = made[0]
	eyes_pipe = made[1]
	for toy in ["#define WH_NO_BALLS\n", "#define WH_NO_SHELL_TOYS\n"]:
		for d: String in GRAVITY_DEFINES:
			made = _kernel("#define KERNEL_WORLD\n" + toy + d)
			if made.is_empty():
				return false
			world_shaders.append(made[0])
			world_pipes.append(made[1])
	for d: String in GRAVITY_DEFINES:
		made = _kernel("#define KERNEL_TOYS\n" + d)
		if made.is_empty():
			return false
		toys_shaders.append(made[0])
		toys_pipes.append(made[1])
	ubo = rd.uniform_buffer_create(SIZE)
	eyes_buf = rd.storage_buffer_create(2 * 5 * 16)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler = rd.sampler_create(ss)
	return true


## A kernel from its defines: [shader, pipeline], or [] (the error printed).
func _kernel(defines: String) -> Array:
	var src := RDShaderSource.new()
	var code: String = (load(KERNELS) as ShaderInclude).code
	code = code.replace("#include_core", (load(CORE) as ShaderInclude).code)
	src.source_compute = "#version 450\n#define WH_COMPUTE\n" + defines + code
	var spirv := rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		push_error("ray_pass.gd, kernel %s: %s" % [defines.strip_edges().replace("\n", " "), spirv.compile_error_compute])
		return []
	var sh := rd.shader_create_from_spirv(spirv)
	return [sh, rd.compute_pipeline_create(sh)]


func _make_image(size: Vector2i, views: int) -> void:
	if image.is_valid():
		picture.texture_rd_rid = RID()
		rd.free_rid(image)
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	fmt.width = size.x
	fmt.height = size.y
	fmt.array_layers = views
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	image = rd.texture_create(fmt, RDTextureView.new(), [])
	image_size = size
	image_views = views
	picture.texture_rd_rid = image
	# a group of 16 x 8 pixels each, at most all of them, after the count
	if tiles.is_valid():
		rd.free_rid(tiles)
	var n := ((size.x + 15) / 16) * ((size.y + 7) / 8) * views + 1
	tiles = rd.storage_buffer_create(16 * n, PackedByteArray(), RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)


static func _put_vec4(b: StreamPeerBuffer, v: Vector4) -> void:
	for k in 4:
		b.put_float(v[k])


# a mat4 in std140: four columns
static func _put_transform(b: StreamPeerBuffer, t: Transform3D) -> void:
	_put_vec4(b, Vector4(t.basis.x.x, t.basis.x.y, t.basis.x.z, 0.0))
	_put_vec4(b, Vector4(t.basis.y.x, t.basis.y.y, t.basis.y.z, 0.0))
	_put_vec4(b, Vector4(t.basis.z.x, t.basis.z.y, t.basis.z.z, 0.0))
	_put_vec4(b, Vector4(t.origin.x, t.origin.y, t.origin.z, 1.0))


static func _put_projection(b: StreamPeerBuffer, p: Projection) -> void:
	for k in 4:
		_put_vec4(b, p[k])
