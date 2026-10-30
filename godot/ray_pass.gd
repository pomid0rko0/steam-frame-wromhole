class_name RayPass
extends CompositorEffect
## The ray tracer's GPU work, on the XR camera's compositor before Godot draws the 3D scene: compute
## kernels (shaders/trace_kernels.gdshaderinc, around the core wormhole_core.gdshaderinc) trace
## every pixel of every view into a picture of its own (picture), which the ray tracer's quad shows
## (tracer.gd). The views are the render's own (their eye offsets and projections), so the rays are
## exact for the frame being drawn.
##
## Tracer hands it the frame's values (set_frame, on the render thread): one block of bytes in the
## order of the kernels' uniform block, and the head. The callback adds what only the render knows:
## the camera, each view's eye offset and projection, each eye's point of the space (the head moved
## along the geodesic of the eye's offset from it, WormholeSpace.geodesic: here once a view, not in
## every pixel, and as constants, which hold no registers in a kernel), the picture's size.
##
## The kernels, each frame: the tables' (each eye's rows set up, then their cells), the world
## kernel (every pixel, the flat universes' toys with it, without those in the shell; it lists the
## groups whose rays have one to search for), the toys kernel (those groups only, an indirect
## dispatch: each ray's path in the shell searched, the object drawn over the world kernel's
## picture where the ray meets one). Each variant (the gravity view, toys or none) is a kernel of
## its own (code costs registers even where no pixel runs it), all compiled at the start: a switch
## then costs no hitch.

const KERNELS := "res://shaders/trace_kernels.gdshaderinc"
const CORE := "res://shaders/wormhole_core.gdshaderinc"
const VIEW_AT := 1808           # bytes: where the views' part of the block starts (fr_cam)
const SIZE := 2368              # bytes: the block (Frame in trace_kernels.gdshaderinc)
const MAX_RINGS := 5            # fr_rings
# the tables' rows a grid (FR_HALF) and columns (FR_COLS) for a picture of TABLE_PX pixels a side,
# fewer for a smaller one (_table_size)
const TABLE_HALF := 1024
const TABLE_COLS := 256
const TABLE_PX := 1728
const ROW_BYTES := 192          # a row's set-up between the tables' two kernels (FrRow in std430)
const VIEWS_AT := 1720          # bytes: fr_views
const GRAVITY_DEFINES := ["", "#define WH_GRAVITY\n", "#define WH_GRAVITY\n#define WH_ARROWS\n"]
# the kernels in the order _setup compiles them (tools/adreno_stats.sh names them so)
const ORDER := ["world", "world gravity", "world arrows", "world toys", "world toys gravity", "world toys arrows",
		"table rows", "tables", "tables and paths", "toys", "toys arrows"]

var picture := Texture2DArrayRD.new()   # what the quad shows: a layer per view
var space: WormholeSpace                # the eyes' geodesics (Tracer sets it)
var frame := PackedByteArray()          # Tracer's part of the block
var head: Array = [10.0, Vector3(1.0, 0.0, 0.0), [Vector4.ZERO, Vector4.ZERO, Vector4.ZERO], Vector3.ZERO]
var gravity := 0                        # the gravity view (GRAVITY_DEFINES)
var toys := false                       # movable objects in the kernels
var rings: Array = []                   # Foveation.rings: none, every pixel its own ray
var gaze_px: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]   # the rings' middle the last frame had, per view (the tests)
var table: Texture2D                    # the fillet table (WormholeSpace.fillet_table)
var rd: RenderingDevice
var failed := false
var world_pipes: Array[RID] = []        # without toys by gravity view, then with them
var world_shaders: Array[RID] = []
var toys_pipes: Array[RID] = []         # without the arrows, with them (the toys' colour takes no floor)
var toys_shaders: Array[RID] = []
var ubo: RID
var sampler: RID
var image: RID
var tiles: RID                          # the toys kernel's groups (fr_tiles)
var rows_pipe: RID                      # the tables' rows (fr_rowData), then their cells
var rows_shader: RID
var rows_buf: RID
var tab_pipe: RID                       # the tables' cells, and with fr_tabP (shell_toys)
var tab_shader: RID
var tabp_pipe: RID
var tabp_shader: RID
var tab_f: RID                          # fr_tabF, fr_tabE, fr_tabP: a layer per view
var tab_e: RID
var tab_p: RID
var shell_toys := false                 # movable objects within reach of the shell: fr_tabP made
var uniforms: Array[RDUniform] = []    # every binding of the kernels (_make_uniforms)
var uniforms_tex: RID                   # the fillet table's they were made with
var used_sets := {}                     # their subsets by the bindings a kernel takes (_used)
var image_size := Vector2i.ZERO
var table_size := Vector2i(TABLE_HALF, TABLE_COLS)   # rows a grid, columns
var image_views := 0


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_OPAQUE
	frame.resize(VIEW_AT)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd != null:
		for r: RID in [ubo, sampler, image, tiles, rows_pipe, rows_shader, rows_buf, tab_pipe, tab_shader, tabp_pipe, tabp_shader, tab_f, tab_e, tab_p] + world_pipes + world_shaders + toys_pipes + toys_shaders:
			if r.is_valid():
				rd.free_rid(r)


## The foveation's rings (Foveation.rings): rays traced coarser away from where the eyes look.
func set_rings(r: Array) -> void:
	rings = r


## Tracer's values for the frame (on the render thread: RenderingServer.call_on_render_thread):
## the block's part, the head [l, n, its frame, its place in the room, where the eyes look (play
## space; zero: unknown)], what is shown.
func set_frame(bytes: PackedByteArray, p_head: Array, p_gravity: int, p_toys: bool, p_shell_toys: bool) -> void:
	frame = bytes
	head = p_head
	gravity = p_gravity
	toys = p_toys
	shell_toys = p_shell_toys


func _render_callback(_type: int, render_data: RenderData) -> void:
	if failed:
		return
	if rd == null and not _setup():
		failed = true
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var sd := render_data.get_render_scene_data()
	if buffers == null or sd == null or table == null or space == null:
		return
	var size := buffers.get_internal_size()
	var views := buffers.get_view_count()
	if size.x <= 0 or size.y <= 0:
		return
	if size != image_size or views != image_views:
		_make_image(size, views)
	# new textures or another fillet table: the uniforms again
	var tex := RenderingServer.texture_get_rd_texture(table.get_rid())
	if tex != uniforms_tex or uniforms.is_empty():
		_make_uniforms(tex)
	var block := StreamPeerBuffer.new()
	block.data_array = frame
	block.seek(VIEW_AT)
	var cam := sd.get_cam_transform()
	_put_transform(block, cam)
	var offs: Array[Vector3] = []
	for v in 2:
		offs.append(sd.get_view_eye_offset(mini(v, views - 1)))
		_put_vec4(block, Vector4(offs[v].x, offs[v].y, offs[v].z, 1.0))
	# the tables every frame, for the eyes where they are: a frame costs what it costs while the head
	# moves (it always does), also where the speed check holds it still
	var paths := toys and shell_toys
	var rows: Array[Vector4] = []
	for v in 2:
		var e := _eye(cam * offs[v])
		for q in e:
			_put_vec4(block, q)
		rows.append(_rows(e[0].x))
	for v in 2:
		_put_vec4(block, rows[v])
	var projs: Array[Projection] = []
	for v in 2:
		projs.append(Projection.create_depth_correction(false) * sd.get_view_projection(mini(v, views - 1)))
	# where each eye looks, in its picture's pixels: the gaze, else straight ahead
	var look: Vector3 = head[4] if head.size() > 4 and head[4] != Vector3.ZERO else -cam.basis.z
	var at := cam.affine_inverse() * (cam.origin + 10.0 * look)
	for v in 2:
		var c := projs[v] * Vector4(at.x, at.y, at.z, 1.0)
		var ndc := Vector2(c.x, c.y) / c.w if c.w > 1e-6 else Vector2.ZERO
		gaze_px[v] = Vector2((ndc.x + 1.0) * 0.5 * size.x, (ndc.y + 1.0) * 0.5 * size.y)
		_put_vec4(block, Vector4(gaze_px[v].x, gaze_px[v].y, 0.0, 0.0))
	for k in MAX_RINGS:
		var ring: Array = rings[k] if k < rings.size() else [0.0, 1, 1]
		_put_vec4(block, Vector4(ring[0], ring[1], ring[2], 0.0))
	for v in 2:
		_put_projection(block, projs[v].inverse())
	for k in [size.x, size.y, views, mini(rings.size(), MAX_RINGS), table_size.x, table_size.y, 0, 0]:
		block.put_32(k)
	var bytes := block.data_array
	bytes.resize(SIZE)
	bytes.encode_s32(VIEWS_AT, views)
	rd.buffer_update(ubo, 0, SIZE, bytes)
	var all := uniforms
	var w := gravity + (GRAVITY_DEFINES.size() if toys else 0)
	if toys:
		rd.buffer_update(tiles, 0, 16, PackedInt32Array([0, 1, 1, 0]).to_byte_array())
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, rows_pipe)
	rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(rows_shader, 0, _used(all, [0, 1, 2, 7, 10])), 0)
	rd.compute_list_dispatch(cl, (2 * table_size.x + 63) / 64, 1, views)
	rd.compute_list_add_barrier(cl)
	rd.compute_list_bind_compute_pipeline(cl, tabp_pipe if paths else tab_pipe)
	rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(tabp_shader if paths else tab_shader, 0,
			_used(all, [0, 1, 2, 6, 8, 10] if paths else [0, 1, 2, 6, 10])), 0)
	rd.compute_list_dispatch(cl, 2 * table_size.x * table_size.y / 256, 1, views)
	rd.compute_list_add_barrier(cl)
	rd.compute_list_bind_compute_pipeline(cl, world_pipes[w])
	rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(world_shaders[w], 0, _used(all, [0, 1, 2, 3, 4, 5])), 0)
	rd.compute_list_dispatch(cl, _groups(size).x, _groups(size).y, views)
	if toys:
		rd.compute_list_add_barrier(cl)
		var t := 1 if gravity == 2 else 0
		rd.compute_list_bind_compute_pipeline(cl, toys_pipes[t])
		rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(toys_shaders[t], 0, _used(all, [0, 1, 2, 3, 4, 5, 9])), 0)
		rd.compute_list_dispatch_indirect(cl, tiles, 0)
	rd.compute_list_end()


## The kernels' uniforms (made again with the picture, or when the fillet table is another texture).
func _make_uniforms(tex: RID) -> void:
	uniforms_tex = tex
	uniforms.clear()
	used_sets.clear()
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
	var u_tiles := RDUniform.new()
	u_tiles.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_tiles.binding = 3
	u_tiles.add_id(tiles)
	var u_rows := RDUniform.new()
	u_rows.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_rows.binding = 10
	u_rows.add_id(rows_buf)
	uniforms.append_array([u_ubo, u_tab, u_img, u_tiles, u_rows])
	for k in 3:
		var t: RID = [tab_f, tab_e, tab_p][k]
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u.binding = [4, 5, 9][k]
		u.add_id(sampler)
		u.add_id(t)
		uniforms.append(u)
		var o := RDUniform.new()
		o.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		o.binding = 6 + k
		o.add_id(t)
		uniforms.append(o)


## The kernels a frame runs with this gravity view (GRAVITY_DEFINES) and with toys or none, by name:
## [the world kernel's, the toys kernel's or ""].
static func kernels(p_gravity: int, p_toys: bool) -> Array[String]:
	var view: String = ["", " gravity", " arrows"][p_gravity]
	return ["world" + (" toys" if p_toys else "") + view, ("toys" + (" arrows" if p_gravity == 2 else "")) if p_toys else ""]


## The tables' rows a grid and columns for a picture: TABLE_HALF and TABLE_COLS at TABLE_PX pixels
## a side, fewer below as the square root of its pixels (whole groups of 64 rows and 32 columns, at
## least 128 and 64): linear interpolation is off by the square of a step, a pixel is 1 / its size,
## so the tables' error in pixels stays what it is at TABLE_PX.
static func _table_size(size: Vector2i) -> Vector2i:
	var k := sqrt(minf(float(maxi(size.x, size.y)) / TABLE_PX, 1.0))
	return Vector2i(clampi(ceili(TABLE_HALF * k / 64.0) * 64, 128, TABLE_HALF),
			clampi(ceili(TABLE_COLS * k / 32.0) * 32, 64, TABLE_COLS))


## The world kernel's groups: 4 x 4 a block of 64 x 32 pixels (trace_kernels.gdshaderinc, fr_cells).
static func _groups(size: Vector2i) -> Vector2i:
	return Vector2i((size.x + 63) / 64 * 4, (size.y + 31) / 32 * 4)


## The uniforms of all with these bindings (a texture is not both sampled and stored in one set).
func _used(all: Array[RDUniform], bindings: Array) -> Array:
	var key := str(bindings)
	if not used_sets.has(key):
		used_sets[key] = all.filter(func(u: RDUniform) -> bool: return bindings.has(u.binding))
	return used_sets[key]


## The tables' rows for an eye at l: (from, split, to) in angle to +l (fr_row): every ray, or for an
## eye outside the shell those that reach it; split at the critical ray (b = rmin toward the throat).
func _rows(l: float) -> Vector4:
	var re := space.r(l)
	var s0 := sin(0.5 * space.th0)
	var rmin := space.rho0 + 2.0 * space.fillet * s0 * s0
	var lo := 0.0
	var hi := PI
	if absf(l) >= space.L:
		var a := asin(minf(space.Rout / re, 1.0))
		if l > 0.0:
			lo = PI - a
		else:
			hi = a
	var ac := 0.5 * PI
	if re > rmin + 1e-9:
		ac = PI - asin(rmin / re) if l >= 0.0 else asin(rmin / re)
	return Vector4(lo, clampf(ac, lo, hi), hi, 0.0)


## The eye at play-space point eye: (l, n), the play axes f0, f1, f2 moved there, (wh_eye(l), 0, 0).
func _eye(eye: Vector3) -> Array:
	var l: float = head[0]
	var n: Vector3 = head[1]
	var hf: Array = head[2]
	var off: Vector3 = eye - (head[3] as Vector3)    # the eye relative to the head, play space
	var len := off.length()
	var f: Array = hf
	if len > 1e-6:
		var dir: Vector4 = (off.x * hf[0] + off.y * hf[1] + off.z * hf[2]) / len
		var g := space.geodesic(l, n, dir, len, hf)
		l = g[0]
		n = g[1]
		f = g[2]
	# wh_eye: r, and r - rmin as a product (no cancellation near the fillet's inner end)
	var ths := space.th0 + maxf(absf(l) - space.Lc, 0.0) / space.fillet
	var below := 2.0 * space.fillet * sin(0.5 * (ths + space.th0)) * sin(0.5 * (ths - space.th0))
	return [Vector4(l, n.x, n.y, n.z), f[0], f[1], f[2], Vector4(space.r(l), below, 0.0, 0.0)]


## The kernels and the buffers, once (on the render thread). False: no RenderingDevice (the
## compatibility renderer, headless) or a kernel did not compile.
func _setup() -> bool:
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		return false
	for toy in ["#define WH_NO_BALLS\n", "#define WH_NO_SHELL_TOYS\n"]:
		for d: String in GRAVITY_DEFINES:
			var made := _kernel("#define KERNEL_WORLD\n" + toy + d)
			if made.is_empty():
				return false
			world_shaders.append(made[0])
			world_pipes.append(made[1])
	var tr := _kernel("#define KERNEL_ROWS\n#define WH_NO_BALLS\n")
	var tk := _kernel("#define KERNEL_TABLES\n#define WH_NO_BALLS\n")
	var tp := _kernel("#define KERNEL_TABLES\n#define FR_PATHS\n#define WH_NO_BALLS\n")
	if tr.is_empty() or tk.is_empty() or tp.is_empty():
		return false
	rows_shader = tr[0]
	rows_pipe = tr[1]
	tab_shader = tk[0]
	tab_pipe = tk[1]
	tabp_shader = tp[0]
	tabp_pipe = tp[1]
	for d: String in [GRAVITY_DEFINES[0], GRAVITY_DEFINES[2]]:
		var made := _kernel("#define KERNEL_TOYS\n" + d)
		if made.is_empty():
			return false
		toys_shaders.append(made[0])
		toys_pipes.append(made[1])
	ubo = rd.uniform_buffer_create(SIZE)
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


## The picture (a layer per view) and the toys kernel's list (a group of 16 x 8 pixels each, at most
## all of them, after the count) for a size.
func _make_image(size: Vector2i, views: int) -> void:
	if image.is_valid():
		picture.texture_rd_rid = RID()
		rd.free_rid(image)
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	fmt.width = size.x
	fmt.height = size.y
	fmt.array_layers = maxi(views, 2)        # a 2D array has at least two layers
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	image = rd.texture_create(fmt, RDTextureView.new(), [])
	image_size = size
	image_views = views
	picture.texture_rd_rid = image
	for t: RID in [tab_f, tab_e, tab_p]:
		if t.is_valid():
			rd.free_rid(t)
	var tf := RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	tf.array_layers = maxi(views, 2)
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	table_size = _table_size(size)
	tf.width = table_size.y
	tf.height = 2 * table_size.x
	tab_f = rd.texture_create(tf, RDTextureView.new(), [])
	tab_p = rd.texture_create(tf, RDTextureView.new(), [])
	tf.width = 2 * table_size.x
	tf.height = 2
	tab_e = rd.texture_create(tf, RDTextureView.new(), [])
	if rows_buf.is_valid():
		rd.free_rid(rows_buf)
	rows_buf = rd.storage_buffer_create(ROW_BYTES * 2 * table_size.x * maxi(views, 2))
	if tiles.is_valid():
		rd.free_rid(tiles)
	var n := _groups(size).x * _groups(size).y * views + 1
	tiles = rd.storage_buffer_create(16 * n, PackedByteArray(), RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	uniforms.clear()


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
