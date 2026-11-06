class_name ZoneSections
extends CompositorEffect
## The meshes of the bodies in the curved zone, worked out once a frame. A body in the zone is drawn
## once per image (Renderer.ZONE_IMAGES), as a mesh made anew for each view round the line through
## its eye and the centre (shaders/zone.gdshaderinc, zone_cube.gdshaderinc): a node's place on the body
## depends on the eye and the body, not on the image. So before the bodies are drawn, a compute
## shader (shaders/zone_sections.gdshaderinc) works out every node of each such body's two meshes
## for each eye into a texture, and the bodies' vertex shader (shaders/body.gdshaderinc, ZONE) takes
## its node from there and only finds its geodesic to the eye: the section once per node and eye,
## not once per vertex of each of the 20 images. A cube's mesh takes three passes before its nodes
## (shaders/zone_cube.gdshaderinc; zone_sections.gdshaderinc's CUBE_*: its edges near the axis and
## their pieces, its spans' sections, its columns' corners), each on the one before, in plan_img and
## col_img; each a workgroup a cube and eye, or a span, or a column's items, so that a pass's time,
## its longest invocation's, is short: their stages side by side, not one after another.
##
## And which images of each body are drawn at all (zone_sections.gdshaderinc, IMAGES): one thinner
## across than CULL_PX of a pixel is not, its vertices go out of the picture at once (cull_tex),
## and so is none whose body is not the one the pass took (a slot not worked out this frame). The
## same pass works out where the body's tail can be seen (cull_tex's last TAIL_TEXELS of a slot's
## row), for the tail's sectors and strips (shaders/zone_tail.gdshader).
##
## And which mesh each image drawn takes (SIZES: where the vertex shader puts a few of its nodes;
## zone_sections.gdshaderinc's ZS_*): none out of the picture, a thin one for a thin image (a turn
## round the throat: a ring as long as the body's first image, 1 / k as thick); and the lists of what
## each of the zone's meshes draws (LISTS: Renderer's ZONE_LODS, drawn indirect: list_tex, and the
## draw commands' instance counts written here).
##
## And then each body's table of the ways light takes from each eye (zone.gdshaderinc, «the paths
## by a table»; zone_sections.gdshaderinc, PATHS): a node of it by geo_see_to's search, as far along
## the turns as the images drawn need (path_tex). A vertex of an image takes its way from the 4 x 4
## nodes about it: 16 reads, not a search of up to 20 rays. The search's work goes from a vertex of
## every image drawn to a node of the table (1600 a body, against 3185 a fine mesh's image).
##
## On the XR camera's compositor (on the desktop the window's camera's), before the opaque pass,
## every frame whatever the foveation. Renderer hands it the space's numbers, the head each frame
## and the bodies in the zone (set_bodies: the same frame's as their instances); the eyes are
## worked out as the vertex shaders work them out (geo.gdshaderinc, geo_eye), from the camera Godot
## renders with.

const BODY_ROWS := 80               # zone_sections.gdshaderinc's body[]: four a slot
# the GPU timestamps of this pass (RenderingDevice.capture_timestamp), before and after it: the
# nodes' and tables' part of the frame's GPU time (frame_rate.gd)
const TS_BEGIN := "zone nodes begin"
const TS_END := "zone nodes end"
# and after each of its passes, this and the pass's name ("ball", "images", the cube's passes, "cube",
# "paths"): what each costs (frame_rate.gd, bench.gd)
const TS_PASS := "zone pass "
const CULL_PX := 0.25               # an image thinner across than this share of a pixel is not drawn
const PLAN_ROWS := 4                # plan_img's rows a cube (zone_sections.gdshaderinc's)
const PLAN_W := 160
const CUBE_SPANS := 32               # a cube's spans at most: CUBE_SPANS' workgroups (zone_cube.gdshaderinc's ZC_SPANS)
const COL_W := 8                    # col_img's texels a column (zone_cube.gdshaderinc's ZC_ITEMS / 2)
const CUBE_PASSES := ["cube_edges", "cube_spans", "cube_columns"]
const TAIL_STRIPS := 8              # the tail's strips a side at most (zone_tail.gdshaderinc's TAIL_STRIPS)
const TAIL_TEXELS := 5 + TAIL_STRIPS + 1   # cull_tex's texels after a body's images': the tail's view of it (IMAGES)

var tex := Texture2DArrayRD.new()   # the nodes (zone_sections.gdshaderinc's out), for the zone's materials
var cull_tex := Texture2DArrayRD.new()   # which images are drawn (IMAGES' out), for them too
var path_tex := Texture2DArrayRD.new()   # the bodies' tables of the ways from the eyes (PATHS' out), for them too
var list_tex := Texture2DRD.new()   # the zone meshes' lists and the bodies' rows (LISTS' out), for them too
const LISTS := 7                    # Renderer.ZONE_LODS: balls fine, coarse, 64 by 6, 32 by 6, 16 by 4, cubes fine, coarse

var _rd: RenderingDevice
var _shaders := {}                  # "ball", "cube" -> RID
var _pipes := {}
var _sets := {}
var _ubo: RID                       # Params
var _bodies: RID                    # Bodies
var _tex: RID
var _cull: RID                      # (images + TAIL_TEXELS) x slots, a layer per eye
var _path: RID                      # (_path_n.y + 1) x slots * _path_n.x, a layer per eye
var _path_n := Vector2i.ZERO        # a body's table's nodes along l and q (zone.gdshaderinc's ZONE_PL, ZONE_PQ)
var _plan: RID                      # the cube passes' (PLAN_W x cubes * PLAN_ROWS, a layer per eye)
var _col: RID                       # the cubes' columns' corners (COL_W x cubes * (columns + 1), a layer per eye)
var _images := 0                    # images a body (Renderer.ZONE_IMAGES)
var _sampler: RID
var _tab: RID                       # the sweep table's RD texture (named by geo.gdshaderinc, not read)
var _grid := Vector4.ZERO           # columns, the fine mesh's rows, the coarse mesh's, a slot's rows
var _slots := 0                     # slots in all: balls' first, cubes' from _cube0
var _cube0 := 0
var _space := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])   # prof, prof2, tabx
var _floor := Vector2.ZERO          # (lift, beta)
var _head := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])   # head_nl, head_p, head_fr[3]
var _bodies_bytes := PackedByteArray()   # set_bodies' rows as the buffer takes them; empty: sent
var _counts := Vector2i.ZERO        # balls and cubes in the zone
var _list: RID                      # list_tex's (a row a list, then the bodies' rows)
var _cmds: Array[RID] = []          # the zone meshes' draw commands (Renderer: set_commands)
var _list_set: RID                  # LISTS' set 1: _list and _cmds
var _sizes_set: RID                 # SIZES' set 1: the bodies' tables (_path) to sample
var _mutex := Mutex.new()


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_OPAQUE
	enabled = true


## The meshes (Renderer._zone_mesh): columns, the fine and the coarse mesh's rows (the same for
## balls and cubes), the slots: balls, then cubes, and the images a body. Once, before the first frame.
func setup(columns: int, fine_rows: int, coarse_rows: int, balls: int, cubes: int, images: int) -> void:
	var slot_rows := fine_rows + coarse_rows + 2
	assert(4 * (balls + cubes) <= BODY_ROWS)
	_grid = Vector4(columns, fine_rows, coarse_rows, slot_rows)
	_slots = balls + cubes
	_cube0 = balls
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return
	_build()
	var f := RDTextureFormat.new()
	f.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	f.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	f.width = 2 * (columns + 1)
	f.height = _slots * slot_rows
	f.array_layers = 2
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_tex = _rd.texture_create(f, RDTextureView.new())
	tex.texture_rd_rid = _tex
	# no image drawn until the pass has said which: a texel of noughts is no body's
	_images = images
	var c := RDTextureFormat.new()
	c.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	c.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	c.width = images + TAIL_TEXELS
	c.height = _slots
	c.array_layers = 2
	c.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var zero := PackedByteArray()
	zero.resize(16 * c.width * _slots)
	_cull = _rd.texture_create(c, RDTextureView.new(), [zero, zero])
	cull_tex.texture_rd_rid = _cull
	var p := RDTextureFormat.new()
	p.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	p.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	p.width = _path_n.y + 1
	p.height = _slots * _path_n.x
	p.array_layers = 2
	p.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_path = _rd.texture_create(p, RDTextureView.new())
	path_tex.texture_rd_rid = _path
	var li := RDTextureFormat.new()
	li.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	li.width = maxi(maxi(balls, cubes) * images, BODY_ROWS)
	li.height = LISTS + 1
	li.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_list = _rd.texture_create(li, RDTextureView.new())
	list_tex.texture_rd_rid = _list
	for k in 2:
		var q := RDTextureFormat.new()
		q.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
		q.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		q.width = PLAN_W if k == 0 else COL_W
		q.height = maxi(cubes, 1) * (PLAN_ROWS if k == 0 else columns + 1)
		q.array_layers = 2
		q.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		var rid := _rd.texture_create(q, RDTextureView.new())
		if k == 0:
			_plan = rid
		else:
			_col = rid


## The space and its table (Renderer.upload_space), as Foveation.set_space takes them.
func set_space(prof: Vector4, prof2: Vector4, tabx: Vector4, tab: Texture2D, floor_: Vector2) -> void:
	_mutex.lock()
	_space = PackedFloat32Array([prof.x, prof.y, prof.z, prof.w, prof2.x, prof2.y, prof2.z, prof2.w,
			tabx.x, tabx.y, tabx.z, tabx.w])
	var t := RenderingServer.texture_get_rd_texture(tab.get_rid())
	if t != _tab:
		_tab = t
		_sets.clear()
	_floor = floor_
	_mutex.unlock()


## Each frame: the head as Renderer.set_head has it.
func set_head(l: float, n: Vector3, hf: PackedVector4Array, head_pos: Vector3) -> void:
	var h := PackedFloat32Array([n.x, n.y, n.z, l, head_pos.x, head_pos.y, head_pos.z, 0.0])
	for v in hf:
		h.append_array([v.x, v.y, v.z, v.w])
	_mutex.lock()
	_head = h
	_mutex.unlock()


## The zone meshes' draw commands (RenderingServer.multimesh_get_command_buffer_rd_rid: Renderer's
## ZONE_LODS, in their order), whose instance counts LISTS writes.
func set_commands(cmds: Array[RID]) -> void:
	_mutex.lock()
	_cmds = cmds
	_list_set = RID()
	_mutex.unlock()


## The bodies in the zone (Renderer.set_objects), four rows a slot: centre C, axes E1, E2 (R^4), and
## (radius or half size, colour); balls in slots from 0, cubes from the balls' count of slots, each
## kind's first ones; balls and cubes: how many of each.
func set_bodies(rows: PackedVector4Array, balls: int, cubes: int) -> void:
	var f := PackedFloat32Array()
	f.resize(16 * _slots)
	for i in mini(rows.size(), 4 * _slots):
		var r := rows[i]
		f[4 * i] = r.x
		f[4 * i + 1] = r.y
		f[4 * i + 2] = r.z
		f[4 * i + 3] = r.w
	_mutex.lock()
	_bodies_bytes = f.to_byte_array()
	_counts = Vector2i(balls, cubes)
	_mutex.unlock()


func _build() -> void:
	var geo: String = (load("res://shaders/geo.gdshaderinc") as ShaderInclude).code
	var zone: String = (load("res://shaders/zone.gdshaderinc") as ShaderInclude).code
	var cube: String = (load("res://shaders/zone_cube.gdshaderinc") as ShaderInclude).code
	var tail: String = (load("res://shaders/zone_tail.gdshaderinc") as ShaderInclude).code
	var body: String = (load("res://shaders/zone_sections.gdshaderinc") as ShaderInclude).code
	body = body.replace("#include_geo_and_zone", geo + "\n" + zone + "\n" + cube + "\n" + tail)
	for k in 2:
		var m := RegEx.create_from_string("const int %s = (\\d+);" % ["ZONE_PL", "ZONE_PQ"][k]).search(zone)
		_path_n[k] = int(m.get_string(1))
	for kind in ["ball", "cube", "images", "sizes", "lists", "paths"] + CUBE_PASSES:
		var src := RDShaderSource.new()
		src.source_compute = "#version 450\n#define %s\n" % kind.to_upper() + body
		var spirv := _rd.shader_compile_spirv_from_source(src)
		if spirv.compile_error_compute != "":
			push_error("zone_sections (%s): %s" % [kind, spirv.compile_error_compute])
			return
		_shaders[kind] = _rd.shader_create_from_spirv(spirv)
		_pipes[kind] = _rd.compute_pipeline_create(_shaders[kind])
	var s := RDSamplerState.new()
	_sampler = _rd.sampler_create(s)
	_ubo = _rd.uniform_buffer_create(400)
	_bodies = _rd.uniform_buffer_create(16 * BODY_ROWS)


func _uniform_set(kind: String) -> RID:
	if _sets.has(kind) and _rd.uniform_set_is_valid(_sets[kind]):
		return _sets[kind]
	var us: Array[RDUniform] = []
	for b in 8:
		var u := RDUniform.new()
		u.binding = b
		match b:
			0:
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				u.add_id(_sampler)
				u.add_id(_tab)
			1:
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
				u.add_id(_ubo)
			2:
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
				u.add_id(_bodies)
			3:
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				u.add_id(_tex)
			4:
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				u.add_id(_cull)
			5:
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				u.add_id(_path)
			6:
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				u.add_id(_plan)
			7:
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				u.add_id(_col)
		us.append(u)
	_sets[kind] = _rd.uniform_set_create(us, _shaders[kind], 0)
	return _sets[kind]


## SIZES' set 1: the bodies' tables to sample, as the vertex shader does.
func _sizes_set_rid() -> RID:
	if _sizes_set.is_valid() and _rd.uniform_set_is_valid(_sizes_set):
		return _sizes_set
	var u := RDUniform.new()
	u.binding = 0
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.add_id(_sampler)
	u.add_id(_path)
	_sizes_set = _rd.uniform_set_create([u], _shaders["sizes"], 1)
	return _sizes_set


## LISTS' set 1 (its list image and the draw commands), made when the commands are there; false if not.
func _lists_set() -> bool:
	if _list_set.is_valid() and _rd.uniform_set_is_valid(_list_set):
		return true
	_mutex.lock()
	var cmds := _cmds.duplicate()
	_mutex.unlock()
	if cmds.size() != LISTS or cmds.any(func(r: RID) -> bool: return not r.is_valid()):
		return false
	var us: Array[RDUniform] = []
	var u := RDUniform.new()
	u.binding = 0
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.add_id(_list)
	us.append(u)
	for k in LISTS:
		var b := RDUniform.new()
		b.binding = 1 + k
		b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		b.add_id(cmds[k])
		us.append(b)
	_list_set = _rd.uniform_set_create(us, _shaders["lists"], 1)
	return _list_set.is_valid()


func _render_callback(type: int, render_data: RenderData) -> void:
	if type != EFFECT_CALLBACK_TYPE_PRE_OPAQUE or not _tex.is_valid() or not _tab.is_valid() or not _pipes.has("cube_columns"):
		return
	_mutex.lock()
	var counts := _counts
	var bodies := _bodies_bytes
	_bodies_bytes = PackedByteArray()
	var p := PackedFloat32Array(_space)
	p.append_array(_head)
	_mutex.unlock()
	if not bodies.is_empty():
		_rd.buffer_update(_bodies, 0, bodies.size(), bodies)
	if counts == Vector2i.ZERO:
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var data := render_data.get_render_scene_data()
	if buffers == null or data == null:
		return
	var views := mini(buffers.get_view_count(), 2)
	var cam := data.get_cam_transform()
	p.append_array([_floor.x, _floor.y, 0.0, 0.0])
	for c in [cam.basis.x, cam.basis.y, cam.basis.z]:
		p.append_array([c.x, c.y, c.z, 0.0])
	p.append_array([cam.origin.x, cam.origin.y, cam.origin.z, 1.0])
	for v in 2:
		var eo := data.get_view_eye_offset(mini(v, views - 1))
		p.append_array([eo.x, eo.y, eo.z, 0.0])
	# a pixel's angle at the middle of each eye's picture: the frustum's tangents across over its pixels
	var size := Vector2(buffers.get_internal_size())
	var px := PackedFloat32Array()
	for v in 2:
		var proj := data.get_view_projection(mini(v, views - 1))
		px.append(minf(absf(2.0 / (proj.x.x * size.x)), absf(2.0 / (proj.y.y * size.y))))   # y may be flipped
	p.append_array([px[0], px[1], CULL_PX, 0.0])
	for v in 2:
		var proj := data.get_view_projection(mini(v, views - 1))
		for c in [proj.x, proj.y, proj.z, proj.w]:
			p.append_array([c.x, c.y, c.z, c.w])
	p.append_array([size.x, size.y, 0.0, 0.0])
	var bytes := p.to_byte_array()
	_rd.buffer_update(_ubo, 0, bytes.size(), bytes)
	var nodes := int(_grid.x + 1.0) * int(_grid.y + _grid.z + 2.0)
	_rd.capture_timestamp(TS_BEGIN)
	var pcb := PackedFloat32Array([_grid.x, _grid.y, _grid.z, _grid.w]).to_byte_array()
	var bpc := pcb.duplicate()
	bpc.append_array(PackedInt32Array([0, 0, 0, 0]).to_byte_array())
	var cpc := pcb.duplicate()
	cpc.append_array(PackedInt32Array([_cube0, 0, 0, 0]).to_byte_array())
	var ipc := pcb.duplicate()
	ipc.append_array(PackedInt32Array([counts.x, counts.y, _cube0, _images]).to_byte_array())
	if counts.x > 0:
		_pass("ball", bpc, int(ceil(nodes / 64.0)), counts.x, views)
	_pass("images", ipc, int(ceil((_images + 2 + TAIL_STRIPS) / 32.0)), counts.x + counts.y, views)
	# a cube's passes, each on the one before (zone_sections.gdshaderinc), then its nodes
	if counts.y > 0:
		_pass("cube_edges", cpc, 1, counts.y, views)
		_pass("cube_spans", cpc, CUBE_SPANS, counts.y, views)
		_pass("cube_columns", cpc, int(ceil((_grid.x + 1.0) * COL_W / 64.0)), counts.y, views)
		_pass("cube", cpc, int(ceil(nodes / 64.0)), counts.y, views)
	# the tables, as far as the images just found drawn need them
	_pass("paths", ipc, int(ceil(_path_n.x * _path_n.y / 64.0)), counts.x + counts.y, views)
	# each image's mesh by its size, the meshes' lists and instance counts
	_pass("sizes", ipc, _images, counts.x + counts.y, views)
	var lpc := PackedFloat32Array([views, 0.0, 0.0, 0.0]).to_byte_array()
	lpc.append_array(PackedInt32Array([counts.x, counts.y, _cube0, _images]).to_byte_array())
	_pass("lists", lpc, 1, 1, 1)
	_rd.capture_timestamp(TS_END)


## A pass of its own compute list (the device puts a barrier between those that share a texture),
## and the GPU's time after it (TS_PASS).
func _pass(kind: String, push: PackedByteArray, x: int, y: int, z: int) -> void:
	if kind == "lists" and not _lists_set():
		return
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipes[kind])
	_rd.compute_list_bind_uniform_set(cl, _uniform_set(kind), 0)
	if kind == "lists":
		_rd.compute_list_bind_uniform_set(cl, _list_set, 1)
	elif kind == "sizes":
		_rd.compute_list_bind_uniform_set(cl, _sizes_set_rid(), 1)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, x, y, z)
	_rd.compute_list_end()
	_rd.capture_timestamp(TS_PASS + kind)
