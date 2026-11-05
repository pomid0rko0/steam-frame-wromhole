class_name ZoneSections
extends CompositorEffect
## The meshes of the bodies in the curved zone, worked out once a frame. A body in the zone is drawn
## once per image (Renderer.ZONE_IMAGES), as a mesh made anew for each view round the line through
## its eye and the centre (shaders/zone.gdshaderinc, zone_vertex): a node's place on the body
## depends on the eye and the body, not on the image. So before the bodies are drawn, a compute
## shader (shaders/zone_sections.gdshaderinc) works out every node of each such body's two meshes
## for each eye into a texture, and the bodies' vertex shader (shaders/body.gdshaderinc, ZONE) takes
## its node from there and only finds its geodesic to the eye: the section once per node and eye,
## not once per vertex of each of the 20 images. A cube's section is the dear part (its corners on
## the space, the edges its half-surface cuts, Newton's steps onto each corner and face).
##
## And which images of each body are drawn at all (zone_sections.gdshaderinc, IMAGES): one thinner
## across than CULL_PX of a pixel is not, its vertices go out of the picture at once (cull_tex),
## and so is none whose body is not the one the pass took (a slot not worked out this frame).
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
const CULL_PX := 0.25               # an image thinner across than this share of a pixel is not drawn

var tex := Texture2DArrayRD.new()   # the nodes (zone_sections.gdshaderinc's out), for the zone's materials
var cull_tex := Texture2DArrayRD.new()   # which images are drawn (IMAGES' out), for them too
var path_tex := Texture2DArrayRD.new()   # the bodies' tables of the ways from the eyes (PATHS' out), for them too

var _rd: RenderingDevice
var _shaders := {}                  # "ball", "cube" -> RID
var _pipes := {}
var _sets := {}
var _ubo: RID                       # Params
var _bodies: RID                    # Bodies
var _tex: RID
var _cull: RID                      # images x slots, a layer per eye
var _path: RID                      # (_path_n.y + 1) x slots * _path_n.x, a layer per eye
var _path_n := Vector2i.ZERO        # a body's table's nodes along l and q (zone.gdshaderinc's ZONE_PL, ZONE_PQ)
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
	c.width = images
	c.height = _slots
	c.array_layers = 2
	c.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var zero := PackedByteArray()
	zero.resize(16 * images * _slots)
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


## The space and its table (Renderer.upload_space), as Foveation.set_space takes them.
func set_space(prof: Vector4, prof2: Vector4, tabx: Vector4, tab: Texture2D, floor_: Vector2) -> void:
	_mutex.lock()
	_space = PackedFloat32Array([prof.x, prof.y, prof.z, prof.w, prof2.x, prof2.y, prof2.z, prof2.w,
			tabx.x, tabx.y, tabx.z, tabx.w])
	_tab = RenderingServer.texture_get_rd_texture(tab.get_rid())
	_floor = floor_
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


## The bodies in the zone (Renderer.set_objects), four rows a slot: centre C, axes E1, E2 (R^4), and
## (radius or half size, 0, 0, 0); balls in slots from 0, cubes from the balls' count of slots, each
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
	var body: String = (load("res://shaders/zone_sections.gdshaderinc") as ShaderInclude).code
	body = body.replace("#include_geo_and_zone", geo + "\n" + zone)
	for k in 2:
		var m := RegEx.create_from_string("const int %s = (\\d+);" % ["ZONE_PL", "ZONE_PQ"][k]).search(zone)
		_path_n[k] = int(m.get_string(1))
	for kind in ["ball", "cube", "images", "paths"]:
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
	_ubo = _rd.uniform_buffer_create(256)
	_bodies = _rd.uniform_buffer_create(16 * BODY_ROWS)


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
		us.append(u)
	_sets[kind] = _rd.uniform_set_create(us, _shaders[kind], 0)
	return _sets[kind]


func _render_callback(type: int, render_data: RenderData) -> void:
	if type != EFFECT_CALLBACK_TYPE_PRE_OPAQUE or not _tex.is_valid() or not _tab.is_valid() or not _pipes.has("paths"):
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
	var bytes := p.to_byte_array()
	_rd.buffer_update(_ubo, 0, bytes.size(), bytes)
	var nodes := int(_grid.x + 1.0) * int(_grid.y + _grid.z + 2.0)
	_rd.capture_timestamp(TS_BEGIN)
	var cl := _rd.compute_list_begin()
	for k in 2:
		var n := counts.x if k == 0 else counts.y
		if n == 0:
			continue
		var kind := "ball" if k == 0 else "cube"
		_rd.compute_list_bind_compute_pipeline(cl, _pipes[kind])
		_rd.compute_list_bind_uniform_set(cl, _uniform_set(kind), 0)
		var pc := PackedFloat32Array([_grid.x, _grid.y, _grid.z, _grid.w]).to_byte_array()
		pc.append_array(PackedInt32Array([0 if k == 0 else _cube0, 0, 0, 0]).to_byte_array())
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, int(ceil(nodes / 64.0)), n, views)
	_rd.compute_list_bind_compute_pipeline(cl, _pipes["images"])
	_rd.compute_list_bind_uniform_set(cl, _uniform_set("images"), 0)
	var ipc := PackedFloat32Array([_grid.x, _grid.y, _grid.z, _grid.w]).to_byte_array()
	ipc.append_array(PackedInt32Array([counts.x, counts.y, _cube0, _images]).to_byte_array())
	_rd.compute_list_set_push_constant(cl, ipc, ipc.size())
	_rd.compute_list_dispatch(cl, int(ceil(_images / 32.0)), counts.x + counts.y, views)
	# the tables, as far as the images just found drawn need them
	_rd.compute_list_add_barrier(cl)
	_rd.compute_list_bind_compute_pipeline(cl, _pipes["paths"])
	_rd.compute_list_bind_uniform_set(cl, _uniform_set("paths"), 0)
	_rd.compute_list_set_push_constant(cl, ipc, ipc.size())
	_rd.compute_list_dispatch(cl, int(ceil(_path_n.x * _path_n.y / 64.0)), counts.x + counts.y, views)
	_rd.compute_list_end()
	_rd.capture_timestamp(TS_END)
