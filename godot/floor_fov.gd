class_name FloorFov
extends CompositorEffect
## Our own foveation (Foveation's levels 4 and 5). Per pixel only the floor and the sky cost much
## (a ray's sweep each); the bodies are geometry. So before the bodies are drawn, a compute shader
## works out the floor and the sky into a texture per eye whose texels are as fine as the picture's
## pixels where the eye looks and grow smoothly away from it (shaders/floor_fov.gdshaderinc), and the
## floor's quad then only takes each pixel's colour from there, filtered (floor.gdshaderinc,
## fov_on). The bodies stay at the picture's full resolution. No density map: no tiles of coarse
## pixels, no edge where the density changes; away from the gaze the floor is softer, not blocky.
##
## On the XR camera's compositor, before the opaque pass (which it does not split). Renderer hands
## it the space's numbers, the head each frame, and the material the floor's quad samples with; Main
## the gaze (set_gaze). The warp's numbers each eye's texture was made with go into a small texture
## the quad reads too, so both take the same.

# the warp's strength k by level: away from the gaze by s (in clip space) a texel spans
# sqrt(1 + (k s)^2) times what it spans at the gaze; the texture is n = size asinh(k) / k a side,
# a picture of size pixels a side with the gaze in its middle
const STRENGTH := {4: 2.0, 5: 4.0}
const GAZE_REACH := 0.9             # the warp's middle kept this far inside the picture (clip space)

var level := 0                      # 0: off
var frozen := false                 # the texture is not worked out again (the speed check times the rest)
var gravity := false                # the gravity view's floor (floor_gravity.gdshader)
var floor_mats: Array[ShaderMaterial] = []   # the floor's materials, which sample the texture
var fov_tex := Texture2DArrayRD.new()
var warp_tex := Texture2DRD.new()

var _rd: RenderingDevice
var _shaders := {}                  # "eyes", "floor", "gravity" -> RID
var _pipes := {}
var _sets := {}
var _ubo: RID
var _eyes: RID
var _tex: RID                       # the colours, rgba16f, a layer per eye
var _warp: RID                      # per eye: (gaze x, y, k, n), (A0 x, A1 x, A0 y, A1 y)
var _sampler: RID
var _tab: RID                       # the sweep table's RD texture
var _grav: RID                      # the floor's gravity
var _n := 0                         # texels a side
var _size := 0                      # the picture's pixels a side it was made for
var _k := 1.0
var _space := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])   # prof, prof2, tabx
var _gravx := Vector2.ZERO
var _head := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])   # head_nl, head_p, head_fr[3]
var _gaze := Vector3.ZERO           # a point the eyes look at (play space); _gaze_on: valid
var _gaze_on := false
var _mutex := Mutex.new()


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_OPAQUE
	enabled = false


## The space and its tables (Renderer.upload_space): the shaders' g_prof, g_prof2, g_tabx, g_tab,
## the gravity's g_grav and g_gravx.
func set_space(prof: Vector4, prof2: Vector4, tabx: Vector4, tab: Texture2D, grav: Texture2D, gravx: Vector2) -> void:
	_mutex.lock()
	_space = PackedFloat32Array([prof.x, prof.y, prof.z, prof.w, prof2.x, prof2.y, prof2.z, prof2.w,
			tabx.x, tabx.y, tabx.z, tabx.w])
	_tab = RenderingServer.texture_get_rd_texture(tab.get_rid())
	_grav = RenderingServer.texture_get_rd_texture(grav.get_rid())
	_gravx = gravx
	_sets.clear()
	_mutex.unlock()


## Each frame: the head as Renderer.set_head has it.
func set_head(l: float, n: Vector3, hf: PackedVector4Array, head_pos: Vector3) -> void:
	var h := PackedFloat32Array([n.x, n.y, n.z, l, head_pos.x, head_pos.y, head_pos.z, 0.0])
	for v in hf:
		h.append_array([v.x, v.y, v.z, v.w])
	_mutex.lock()
	_head = h
	_mutex.unlock()


## Each frame: where the eyes look, a point of the play space; on false the middle of each picture.
func set_gaze(point: Vector3, on: bool) -> void:
	_mutex.lock()
	_gaze = point
	_gaze_on = on
	_mutex.unlock()


## The level (0, 4 or 5) and the picture's pixels a side; the texture is made again when they change.
func set_level(p_level: int, size: int) -> void:
	level = p_level if STRENGTH.has(p_level) else 0
	enabled = level > 0
	for m in floor_mats:
		m.set_shader_parameter("fov_on", enabled)
	if not enabled:
		return
	_k = STRENGTH[level]
	var n := int(ceil(size * asinh(_k) / _k))
	if n != _n or size != _size:
		_make(n)
		_size = size


func _make(n: int) -> void:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
		_build()
	fov_tex.texture_rd_rid = RID()
	warp_tex.texture_rd_rid = RID()
	_mutex.lock()
	for r in [_tex, _warp]:
		if r.is_valid() and _rd.texture_is_valid(r):
			_rd.free_rid(r)
	_n = n
	var f := RDTextureFormat.new()
	f.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	f.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	f.width = n
	f.height = n
	f.array_layers = 2
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_tex = _rd.texture_create(f, RDTextureView.new())
	var w := RDTextureFormat.new()
	w.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	w.width = 2
	w.height = 2
	w.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	_warp = _rd.texture_create(w, RDTextureView.new(), [PackedFloat32Array([0, 0, 1, n, -1, 1, -1, 1, 0, 0, 1, n, -1, 1, -1, 1]).to_byte_array()])
	_sets.clear()
	_mutex.unlock()
	fov_tex.texture_rd_rid = _tex
	warp_tex.texture_rd_rid = _warp
	for m in floor_mats:
		m.set_shader_parameter("fov_tex", fov_tex)
		m.set_shader_parameter("fov_warp", warp_tex)


## The compute pipelines: the eyes, then the floor, plain or coloured by gravity.
func _build() -> void:
	var geo: String = (load("res://shaders/geo.gdshaderinc") as ShaderInclude).code
	var look: String = (load("res://shaders/look.gdshaderinc") as ShaderInclude).code
	var body: String = (load("res://shaders/floor_fov.gdshaderinc") as ShaderInclude).code
	body = body.replace("#include_geo_and_look", geo + "\n" + look)
	for kind in ["eyes", "floor", "gravity"]:
		var src := RDShaderSource.new()
		var defs := {"eyes": "#define EYES\n", "floor": "", "gravity": "#define GRAVITY\n"}
		src.source_compute = "#version 450\n" + defs[kind] + body
		var spirv := _rd.shader_compile_spirv_from_source(src)
		if spirv.compile_error_compute != "":
			push_error("floor_fov (%s): %s" % [kind, spirv.compile_error_compute])
			return
		_shaders[kind] = _rd.shader_create_from_spirv(spirv)
		_pipes[kind] = _rd.compute_pipeline_create(_shaders[kind])
	var s := RDSamplerState.new()
	s.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	s.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(s)
	_ubo = _rd.uniform_buffer_create(448)
	_eyes = _rd.storage_buffer_create(160)


func _uniform_set(kind: String) -> RID:
	if _sets.has(kind) and _rd.uniform_set_is_valid(_sets[kind]):
		return _sets[kind]
	var us: Array[RDUniform] = []
	for b in 5:
		var u := RDUniform.new()
		u.binding = b
		match b:
			0, 1:
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				u.add_id(_sampler)
				u.add_id(_tab if b == 0 else _grav)
			2:
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
				u.add_id(_ubo)
			3:
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
				u.add_id(_eyes)
			4:
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				u.add_id(_tex)
		us.append(u)
	_sets[kind] = _rd.uniform_set_create(us, _shaders[kind], 0)
	return _sets[kind]


func _render_callback(type: int, render_data: RenderData) -> void:
	if type != EFFECT_CALLBACK_TYPE_PRE_OPAQUE or level == 0 or frozen or not _tex.is_valid() or not _tab.is_valid():
		return
	if not _pipes.has("floor"):
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var data := render_data.get_render_scene_data()
	if buffers == null or data == null:
		return
	var views := mini(buffers.get_view_count(), 2)
	var cam := data.get_cam_transform()
	var corr := Projection.create_depth_correction(false)   # PROJECTION_MATRIX as the shaders have it
	_mutex.lock()
	var p := PackedFloat32Array(_space)
	p.append_array(_head)
	var gaze := _gaze
	var gaze_on := _gaze_on
	_mutex.unlock()
	p.append_array([_gravx.x, _gravx.y, 0.0, 0.0])
	for c in [cam.basis.x, cam.basis.y, cam.basis.z]:
		p.append_array([c.x, c.y, c.z, 0.0])
	p.append_array([cam.origin.x, cam.origin.y, cam.origin.z, 1.0])
	var off := PackedFloat32Array()
	var wg := PackedFloat32Array()
	var wa := PackedFloat32Array()
	var warp := PackedFloat32Array()
	var g_cam := cam.affine_inverse() * gaze
	for v in 2:
		var vv := mini(v, views - 1)
		var proj := corr * data.get_view_projection(vv)
		var inv := proj.inverse()
		for c in [inv.x, inv.y, inv.z, inv.w]:
			p.append_array([c.x, c.y, c.z, c.w])
		var eo := data.get_view_eye_offset(vv)
		off.append_array([eo.x, eo.y, eo.z, 0.0])
		# the gaze in this eye's clip space; the picture's middle without one, or behind the eye
		var g := Vector2.ZERO
		var cg := proj * Vector4(g_cam.x, g_cam.y, g_cam.z, 1.0)
		if gaze_on and cg.w > 1e-6:
			g = (Vector2(cg.x, cg.y) / cg.w).clamp(Vector2.ONE * -GAZE_REACH, Vector2.ONE * GAZE_REACH)
		var a := [asinh(_k * (-1.0 - g.x)) / _k, asinh(_k * (1.0 - g.x)) / _k,
				asinh(_k * (-1.0 - g.y)) / _k, asinh(_k * (1.0 - g.y)) / _k]
		wg.append_array([g.x, g.y, _k, _n])
		wa.append_array(a)
		warp.append_array([g.x, g.y, _k, _n])
		warp.append_array(a)
	p.append_array(off)
	p.append_array(wg)
	p.append_array(wa)
	p.append_array([_size, 0.0, 0.0, 0.0])
	var bytes := p.to_byte_array()
	_rd.buffer_update(_ubo, 0, bytes.size(), bytes)
	_rd.texture_update(_warp, 0, warp.to_byte_array())
	var groups := int(ceil(_n / 8.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipes["eyes"])
	_rd.compute_list_bind_uniform_set(cl, _uniform_set("eyes"), 0)
	_rd.compute_list_dispatch(cl, 1, 1, 1)
	_rd.compute_list_add_barrier(cl)
	var kind := "gravity" if gravity else "floor"
	_rd.compute_list_bind_compute_pipeline(cl, _pipes[kind])
	_rd.compute_list_bind_uniform_set(cl, _uniform_set(kind), 0)
	_rd.compute_list_dispatch(cl, groups, groups, views)
	_rd.compute_list_end()
