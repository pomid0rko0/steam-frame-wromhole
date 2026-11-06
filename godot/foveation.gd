class_name Foveation
extends CompositorEffect
## Foveated rendering: where the eyes look the picture is as without it; away from there the floor
## is worked out coarser, smoothly, with no edge anywhere.
##
## Per pixel only the floor's quad costs much (a ray's way out of the curved zone, and through it
## the bodies out in the flat universes); the bodies seen straight and in the zone are geometry,
## drawn at the picture's full resolution always. So before the bodies are drawn, a compute shader
## (shaders/foveation.gdshaderinc) works out what the quad would draw into a texture per eye, and
## the quad then only takes each pixel's colour from there, filtered, with a program of its own
## (shaders/floor_sample.gdshader, sample_mat: Renderer draws the quad with it while this is on).
##
## The warp, per eye, about the pixel g the eye looks at: the pixel centred at p, r = |p - g| from
## g, takes the texture at c + (p - g) F(r) / r, c being g's texel, with
##   F(r) = r                            for r <= r0: the fovea, a texel a pixel;
##   F(r) = r0 + asinh(m (r - r0)) / m   beyond: a texel there spans s = sqrt(1 + (m (r - r0))^2)
##                                       pixels along r and r / F(r) across, growing from 1 smoothly.
## g and c are whole pixels and texels, so in the fovea each pixel takes the centre of a texel
## worked out at its own centre: the colour it has without foveation (tools/test_stereo.sh checks
## that). c - g is even along each axis, so the texels' 2 x 2 squares (a fragment shader's
## derivatives, which the floor's pattern is filtered by) are the pixels' squares. LEVELS give r0
## and the r where s is 2. Being concave, F keeps the picture within 2 F(half its width) + margins
## texels across wherever g is: the texture's size.
##
## g follows where the eyes look (set_gaze: Main gives SteamVR's eye tracking, or the head's
## forward without it) only once that is GAZE_SLACK away: the tracker's jitter does not move the
## coarse texels about the fovea frame after frame (a shimmer in the corner of the eye).
##
## show: the coarse texels tinted by their size (fov_tint in the shader): green up to 2 pixels
## across, yellow up to 3, orange up to 4, red beyond; the fovea as it is.
##
## probe (tests): each texel holds where its pixel is instead of its colour, and the floor's quad
## draws how far from its own place each pixel took it (floor_sample.gdshader, fov_probe): every
## pixel of the floor and the sky, not only the fovea, takes the colour worked out where it is.
##
## Three passes: the eyes, their rows of the way out of the zone (a ray's sigma to where it leaves:
## geo.gdshaderinc, «the way out by a table»), the texture. GPU timestamps before, between and after
## them (TS_*) give frame_rate.gd the GPU time of each part of the frame.
##
## On the XR camera's compositor, before the opaque pass (the 3D scene's render pass stays one).
## Renderer hands it the space's numbers, the head each frame, and the material the floor's quad
## samples with; Main the level and the gaze. Each eye's warp also goes into a small texture
## the quad reads (fov_warp): both take the same numbers in the same frame. Its line in the log at
## each new level or size says what the level is in degrees on this headset.
##
## Threads. The pass runs on the render thread (Godot's own with project.godot's thread model
## "Separate", else the main thread), the setters on the main thread. A frame's numbers go to the
## pass through RenderingServer.call_on_render_thread, queued with that frame's drawing: with the
## render thread a frame behind, a setter called now must not reach the frame being drawn (the floor
## would be worked out for a head other than the camera's). The pass's own state (the _rt_ fields,
## the RenderingDevice's resources) is the render thread's alone; fovea, which the tests read on the
## main thread, under _mutex.

# by level (1 weak .. 5 strongest; 0 is off): [r0, the r where a texel spans 2 pixels], in shares
# of half the picture's width
const LEVELS := [[0.30, 0.83], [0.25, 0.65], [0.22, 0.48], [0.175, 0.372], [0.123, 0.255]]
const GAZE_SLACK := 0.03            # share of half the picture's width
const MARGIN := 2                   # texels round the picture's warp: the filter reads one beyond it
# the GPU timestamps of these passes (RenderingDevice.capture_timestamp): before the eyes, after the
# way out's table, after the floor's texture
const TS_BEGIN := "foveation begin"
const TS_TABLE := "foveation table"
const TS_END := "foveation end"

signal toggled                      # turned on or off (Renderer draws the quad with sample_mat while on)

var level := 0                      # 0: off, else LEVELS' index + 1
var show := false:                  # the coarse texels tinted by their size
	set(v):
		show = v
		RenderingServer.call_on_render_thread(_set_rt.bind("_rt_show", v))
var probe := false:                 # tests: where each texel's pixel is instead of its colour (the top)
	set(v):
		probe = v
		RenderingServer.call_on_render_thread(_set_rt.bind("_rt_probe", v))
var gravity := false:               # the gravity view's floor (floor_gravity.gdshader)
	set(v):
		gravity = v
		RenderingServer.call_on_render_thread(_set_rt.bind("_rt_gravity", v))
var sample_mat: ShaderMaterial:     # the floor's quad's while on (floor_sample.gdshader): it samples the texture
	set(v):
		sample_mat = v
		sample_mat.set_shader_parameter("fov_tex", fov_tex)
		sample_mat.set_shader_parameter("fov_warp", warp_tex)
var xr: XRInterface                 # the picture's size; on the desktop (none) target's
var target: Viewport
var gaze_on := false                # the eyes tracked (set_gaze)
var size := Vector2i.ZERO           # the picture's pixels the texture is made for (resize)
var fov_tex := Texture2DArrayRD.new()
var warp_tex := Texture2DRD.new()
# the last frame's warp, each eye: g's pixel (x, y), r0, m (the tests), written by the render thread
var fovea: PackedFloat32Array:
	get:
		_mutex.lock()
		var f := _fovea
		_mutex.unlock()
		return f
var _fovea := PackedFloat32Array()
var _mutex := Mutex.new()

# the render thread's
var _rd: RenderingDevice
var _shaders := {}                  # "eyes", "table", "floor", "gravity" -> RID
var _pipes := {}
var _sets := {}
var _ubo: RID
var _eyes: RID
var _tex: RID                       # the colours, rgba16f, a layer per eye
var _xt: RID                        # the way out's rows (foveation.gdshaderinc, xt_img): _xt_n x 4, rgba32f
var _xt_n := 0                      # texels a row: geo.gdshaderinc's GEO_XN
var _warp: RID                      # a row per eye: (g, c), (r0, m, the texels across, down), (the picture's pixels across, down)
var _sampler: RID
var _tab: RID                       # the sweep table's RD texture
var _lens: RID                      # the lens list (lens.gdshaderinc), a uniform buffer
var _n := Vector2i.ZERO             # texels across and down
var _rt_size := Vector2i.ZERO       # the picture's pixels it was made for
var _rt_level := 0
var _rt_show := false
var _rt_probe := false
var _rt_gravity := false
var _r0 := 0.0                      # pixels
var _m := 1.0                       # per pixel
var _space := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])   # prof, prof2, tabx
var _floor := Vector2.ZERO          # (lift, beta)
var _lens_bytes := PackedByteArray()   # the lens list as the buffer takes it; empty: sent
var _lens_size := 160 * 16 + 16
var _head := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])   # head_nl, head_p, head_fr[3]
var _gaze := Vector3.FORWARD        # where the eyes look, in the head's space
var _recentre := true               # each eye's g where it looks at the next frame, slack or not
var _tell := false                  # the log's line at the next frame
var _centre: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]   # each eye's g before rounding


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_OPAQUE
	enabled = false


## On the render thread: a field of its own.
func _set_rt(field: StringName, value: Variant) -> void:
	set(field, value)


## The space and its table (Renderer.upload_space): the shaders' g_prof, g_prof2, g_tabx, g_tab,
## and (g_lift, g_beta).
func set_space(prof: Vector4, prof2: Vector4, tabx: Vector4, tab: Texture2D, floor_: Vector2) -> void:
	var sp := PackedFloat32Array([prof.x, prof.y, prof.z, prof.w, prof2.x, prof2.y, prof2.z, prof2.w,
			tabx.x, tabx.y, tabx.z, tabx.w])
	RenderingServer.call_on_render_thread(_space_rt.bind(sp, tab.get_rid(), floor_))


func _space_rt(sp: PackedFloat32Array, tab: RID, floor_: Vector2) -> void:
	_space = sp
	var t := RenderingServer.texture_get_rd_texture(tab)
	if t != _tab:
		_tab = t
		_sets.clear()
	_floor = floor_


## The lens list as Renderer has it: lens_body's rows and lens_n.
func set_lens(rows: PackedVector4Array, counts: Vector2) -> void:
	var f := PackedFloat32Array()
	for r in rows:
		f.append_array([r.x, r.y, r.z, r.w])
	f.append_array([counts.x, counts.y, 0.0, 0.0])
	RenderingServer.call_on_render_thread(_set_rt.bind("_lens_bytes", f.to_byte_array()))


## Each frame: the head as Renderer.set_head has it.
func set_head(l: float, n: Vector3, hf: PackedVector4Array, head_pos: Vector3) -> void:
	var h := PackedFloat32Array([n.x, n.y, n.z, l, head_pos.x, head_pos.y, head_pos.z, 0.0])
	for v in hf:
		h.append_array([v.x, v.y, v.z, v.w])
	RenderingServer.call_on_render_thread(_set_rt.bind("_head", h))


## Each frame: where the eyes look, a direction in the head's space (the XR camera's); on: tracked.
func set_gaze(dir: Vector3, on: bool) -> void:
	gaze_on = on
	RenderingServer.call_on_render_thread(_set_rt.bind("_gaze", dir))


## The level: 0 off, 1.. LEVELS'.
func set_level(p_level: int) -> void:
	level = clampi(p_level, 0, LEVELS.size())
	var was := enabled
	enabled = level > 0
	if enabled != was:
		toggled.emit()
	resize()


## The picture's size changed (Menu.set_eye), or the level: the warp follows, and the texture is
## made again if its size changes.
func resize() -> void:
	if level == 0:
		RenderingServer.call_on_render_thread(_set_rt.bind("_rt_level", 0))
		return
	size = Vector2i.ONE
	if xr:
		size = Vector2i(xr.get_render_target_size())
	elif target:
		size = Vector2i(target.get_visible_rect().size)
	var half := 0.5 * size.x
	var lv: Array = LEVELS[level - 1]
	var r0: float = lv[0] * half
	var m: float = sqrt(3.0) / ((lv[1] - lv[0]) * half)
	var n := Vector2i(ceili(2.0 * _warp_at(0.5 * size.x, r0, m)), ceili(2.0 * _warp_at(0.5 * size.y, r0, m))) \
			+ Vector2i.ONE * (2 * MARGIN + 2)
	RenderingServer.call_on_render_thread(_resize_rt.bind(level, r0, m, n, size))


func _resize_rt(p_level: int, r0: float, m: float, n: Vector2i, size: Vector2i) -> void:
	_rt_level = p_level
	_r0 = r0
	_m = m
	_recentre = true
	_tell = true
	if n != _n:
		_make(n)
	_rt_size = size


## On the render thread: the texture and the warp's for n texels.
func _make(n: Vector2i) -> void:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
		_build()
	fov_tex.texture_rd_rid = RID()
	warp_tex.texture_rd_rid = RID()
	for r in [_tex, _warp]:
		if r.is_valid() and _rd.texture_is_valid(r):
			_rd.free_rid(r)
	_n = n
	var f := RDTextureFormat.new()
	f.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	f.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	f.width = n.x
	f.height = n.y
	f.array_layers = 2
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_tex = _rd.texture_create(f, RDTextureView.new())
	var w := RDTextureFormat.new()
	w.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	w.width = 3
	w.height = 2
	w.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var row := [0.0, 0.0, MARGIN, MARGIN, _r0, _m, n.x, n.y, 1.0, 1.0, 0.0, 0.0]
	_warp = _rd.texture_create(w, RDTextureView.new(), [PackedFloat32Array(row + row).to_byte_array()])
	_sets.clear()
	fov_tex.texture_rd_rid = _tex
	warp_tex.texture_rd_rid = _warp


## The compute pipelines: the eyes, the way out's rows, then the floor, plain or coloured by gravity.
func _build() -> void:
	var geo: String = (load("res://shaders/geo.gdshaderinc") as ShaderInclude).code
	var look: String = (load("res://shaders/look.gdshaderinc") as ShaderInclude).code
	var lens: String = (load("res://shaders/lens.gdshaderinc") as ShaderInclude).code
	var body: String = (load("res://shaders/foveation.gdshaderinc") as ShaderInclude).code
	body = body.replace("#include_geo_and_look", geo + "\n" + look + "\n" + lens)
	var n := RegEx.create_from_string("const int GEO_XN = (\\d+);").search(geo)
	_xt_n = int(n.get_string(1))
	for kind in ["eyes", "table", "floor", "gravity"]:
		var src := RDShaderSource.new()
		var defs := {"eyes": "#define EYES\n", "table": "#define TABLE\n", "floor": "", "gravity": "#define GRAVITY\n"}
		src.source_compute = "#version 450\n" + defs[kind] + body
		var spirv := _rd.shader_compile_spirv_from_source(src)
		if spirv.compile_error_compute != "":
			push_error("foveation (%s): %s" % [kind, spirv.compile_error_compute])
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
	_eyes = _rd.storage_buffer_create(192)
	var x := RDTextureFormat.new()
	x.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	x.width = _xt_n
	x.height = 4
	x.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_xt = _rd.texture_create(x, RDTextureView.new())
	_lens = _rd.uniform_buffer_create(_lens_size)


func _uniform_set(kind: String) -> RID:
	if _sets.has(kind) and _rd.uniform_set_is_valid(_sets[kind]):
		return _sets[kind]
	var us: Array[RDUniform] = []
	for b in 6:
		var u := RDUniform.new()
		u.binding = b
		match b:
			0:
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				u.add_id(_sampler)
				u.add_id(_tab)
			1:
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
				u.add_id(_lens)
			2:
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
				u.add_id(_ubo)
			3:
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
				u.add_id(_eyes)
			4:
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				u.add_id(_tex)
			5:
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				u.add_id(_xt)
		us.append(u)
	_sets[kind] = _rd.uniform_set_create(us, _shaders[kind], 0)
	return _sets[kind]


func _render_callback(type: int, render_data: RenderData) -> void:
	if type != EFFECT_CALLBACK_TYPE_PRE_OPAQUE or _rt_level == 0 or not _tex.is_valid() or not _tab.is_valid():
		return
	if not _pipes.has("floor"):
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var data := render_data.get_render_scene_data()
	if buffers == null or data == null:
		return
	var views := mini(buffers.get_view_count(), 2)
	var pic := Vector2(buffers.get_internal_size())
	var cam := data.get_cam_transform()
	var corr := Projection.create_depth_correction(false)   # PROJECTION_MATRIX as the shaders have it
	var p := PackedFloat32Array(_space)
	p.append_array(_head)
	var gaze := _gaze
	var lens := _lens_bytes
	_lens_bytes = PackedByteArray()
	var r0 := _r0
	var m := _m
	var slack := GAZE_SLACK * 0.5 * _rt_size.x
	var recentre := _recentre
	_recentre = false
	var tell := _tell
	_tell = false
	if not lens.is_empty():
		_rd.buffer_update(_lens, 0, lens.size(), lens)
	p.append_array([_floor.x, _floor.y, 0.0, 0.0])
	for c in [cam.basis.x, cam.basis.y, cam.basis.z]:
		p.append_array([c.x, c.y, c.z, 0.0])
	p.append_array([cam.origin.x, cam.origin.y, cam.origin.z, 1.0])
	var off := PackedFloat32Array()
	var w0 := PackedFloat32Array()
	var w1 := PackedFloat32Array()
	var rows := PackedFloat32Array()
	var used := PackedFloat32Array()
	for v in 2:
		var vv := mini(v, views - 1)
		var proj := corr * data.get_view_projection(vv)
		# the rays as geo_view_ray has them: by the projection's rows x, y and w alone
		var ray := Basis(Vector3(proj.x.x, proj.x.y, proj.x.w), Vector3(proj.y.x, proj.y.y, proj.y.w),
				Vector3(proj.z.x, proj.z.y, proj.z.w)).inverse()
		for c in [ray.x, ray.y, ray.z]:
			p.append_array([c.x, c.y, c.z, 0.0])
		p.append_array([0.0, 0.0, 0.0, 1.0])
		var eo := data.get_view_eye_offset(vv)
		off.append_array([eo.x, eo.y, eo.z, 0.0])
		# where the eye looks, in pixels from the picture's corner at clip (-1, -1): the gaze's
		# direction (a point at infinity), or the middle if that is not before the eye
		var cg := proj * Vector4(gaze.x, gaze.y, gaze.z, 0.0)
		var at := 0.5 * pic
		if cg.w > 1e-6:
			at = (Vector2(cg.x, cg.y) / cg.w * 0.5 + Vector2(0.5, 0.5)) * pic
		at = at.clamp(Vector2.ZERO, pic)
		var d := at - _centre[v]
		if recentre:
			_centre[v] = at
		elif d.length() > slack:
			_centre[v] += d * (1.0 - slack / d.length())
		var g := _centre[v].round().clamp(Vector2.ZERO, pic)
		var c := Vector2(MARGIN + ceilf(_warp_at(g.x, r0, m)), MARGIN + ceilf(_warp_at(g.y, r0, m)))
		c += Vector2(posmod(int(c.x - g.x), 2), posmod(int(c.y - g.y), 2))
		used.append_array([g.x, g.y, r0, m])
		w0.append_array([g.x, g.y, c.x, c.y])
		w1.append_array([r0, m, _n.x, _n.y])
		rows.append_array([g.x, g.y, c.x, c.y, r0, m, _n.x, _n.y, pic.x, pic.y, 0.0, 0.0])
	p.append_array(off)
	p.append_array(w0)
	p.append_array(w1)
	p.append_array([pic.x, pic.y, 1.0 if _rt_show else 0.0, 1.0 if _rt_probe else 0.0])
	var bytes := p.to_byte_array()
	_rd.buffer_update(_ubo, 0, bytes.size(), bytes)
	_rd.texture_update(_warp, 0, rows.to_byte_array())
	_mutex.lock()
	_fovea = used
	_mutex.unlock()
	if tell:
		_tell_level(data.get_view_projection(0), pic)
	# a timestamp orders the GPU's work: what was recorded before it runs before it, what after, after
	_rd.capture_timestamp(TS_BEGIN)
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipes["eyes"])
	_rd.compute_list_bind_uniform_set(cl, _uniform_set("eyes"), 0)
	_rd.compute_list_dispatch(cl, 1, 1, 1)
	_rd.compute_list_add_barrier(cl)
	_rd.compute_list_bind_compute_pipeline(cl, _pipes["table"])
	_rd.compute_list_bind_uniform_set(cl, _uniform_set("table"), 0)
	_rd.compute_list_dispatch(cl, ceili(_xt_n / 64.0), 2 * views, 1)
	_rd.compute_list_end()
	_rd.capture_timestamp(TS_TABLE)
	cl = _rd.compute_list_begin()
	var kind := "gravity" if _rt_gravity else "floor"
	_rd.compute_list_bind_compute_pipeline(cl, _pipes[kind])
	_rd.compute_list_bind_uniform_set(cl, _uniform_set(kind), 0)
	_rd.compute_list_dispatch(cl, ceili(_n.x / 8.0), ceili(_n.y / 8.0), views)
	_rd.compute_list_end()
	_rd.capture_timestamp(TS_END)


static func _warp_at(r: float, r0: float, m: float) -> float:
	return r if r <= r0 else r0 + asinh(m * (r - r0)) / m


## The log's line: the level in degrees on this headset, along the first eye's picture's width
## from the middle of its projection (Projection's x scale: a share k of half the width is atan(k /
## scale) off its axis).
func _tell_level(proj: Projection, pic: Vector2) -> void:
	var lv: Array = LEVELS[_rt_level - 1]
	var sx := proj.x.x
	var across := rad_to_deg(atan((1.0 + proj.z.x) / sx) + atan((1.0 - proj.z.x) / sx))
	print("foveation: %s, the fovea %.0f deg round where the eyes look, a texel 2 pixels across %.0f deg from it; the picture %.0f deg and %d pixels across; the texture %dx%d texels of %dx%d pixels"
			% [Menu.FOV_LOG[_rt_level], rad_to_deg(atan(lv[0] / sx)), rad_to_deg(atan(lv[1] / sx)), across, int(pic.x),
			_n.x, _n.y, int(pic.x), int(pic.y)])
