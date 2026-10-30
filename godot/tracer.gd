class_name Tracer
extends Node3D
## The ray tracer: compute kernels trace every pixel of every view along geodesics of the wormhole
## space (ray_pass.gd, on the camera's compositor), and a full-screen quad under the XR camera
## shows their picture (shaders/show.gdshader). This node keeps the frame's values the kernels read
## (the shape, the static scene, the head, the toys, the gravity view) and hands them to the pass
## each frame.
##
## The quad's material is a plain lookup, so Godot's own geometry is drawn over the picture as it
## was over the fragment ray tracer (frag_tracer.gd, kept for the speed check's comparison).

const SHOW := preload("res://shaders/show.gdshader")
const GRAVITY_VIEWS := ["off", "floor", "floor and arrows"]
const MAX_BALLS := 12           # the kernels' slots for the toys' and the hands' balls
const MAX_CUBES := 6

var space: WormholeSpace
var scene: Dictionary
var xr: XRInterface             # null on the desktop
var xr_view: SubViewport        # where XR renders; null on the desktop
var pass_: RayPass = RayPass.new()      # on the camera's compositor (main.gd puts it there)
var quad: MeshInstance3D
var values := {}                # the kernels' uniforms by name (get_param)
var toy_count := 0              # balls and cubes the kernels have (set_objects)
var gravity_view := 0           # 0 off, 1 the floor coloured by gravity, 2 also arrows of its field
var pixel_angle := 0.0          # the pixel angle set_head last saw: wh_pix goes again when it changes


func _init(p_space: WormholeSpace, p_scene: Dictionary, p_xr: XRInterface, p_xr_view: SubViewport) -> void:
	space = p_space
	scene = p_scene
	xr = p_xr
	xr_view = p_xr_view


func _ready() -> void:
	values["wh_rho0"] = space.rho0
	values["wh_h"] = space.h
	values["wh_fillet"] = space.fillet
	upload_fillet_table()
	upload_gravity()
	_upload_scene()
	set_objects(PackedVector4Array(), PackedVector4Array())
	var mat := ShaderMaterial.new()
	mat.shader = SHOW
	mat.set_shader_parameter("picture", pass_.picture)
	quad = MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(2.0, 2.0)
	quad.mesh = mesh
	quad.material_override = mat
	quad.extra_cull_margin = 16384.0
	quad.position = Vector3(0.0, 0.0, -1.0)
	quad.visible = false
	add_child(quad)


## A uniform the kernels read, as last set.
func get_param(name: StringName) -> Variant:
	return values.get(name)


## Set one (the stereo check scene's static objects out of sight).
func param(name: StringName, value: Variant) -> void:
	values[name] = value


## Each frame: the head in the curved space (l, n), its frame [right, up, back] there and its place
## in the room (the kernels move it to each eye), then the frame's values to the pass.
func set_head(l: float, n: Vector3, hf: Array, head_pos: Vector3) -> void:
	values["head_l"] = l
	values["head_n"] = n
	values["head_f"] = PackedVector4Array(hf)
	values["head_pos"] = head_pos
	# a pixel's angle (the cubes' edge lines, the arrows' soft edges) follows the render scale
	var pix := _pixel_angle()
	if pix != pixel_angle:
		pixel_angle = pix
		values["wh_pix"] = pix
	RenderingServer.call_on_render_thread(pass_.set_frame.bind(_pack(), gravity_view, toy_count > 0))
	# shown once the pass has made its picture (a material whose texture does not exist yet is not
	# drawn: an error each frame)
	quad.visible = pass_.picture.texture_rd_rid.is_valid()


## Movable balls (pos, col) and cubes (cpos, axes, ccol), laid out as wormhole_core.gdshaderinc's
## top says, at most MAX_BALLS and MAX_CUBES. The kernels get them sorted by where they are
## (region_order), so a ball's index there is not its index in the caller's list.
func set_objects(pos: PackedVector4Array, col: PackedVector4Array, cpos := PackedVector4Array(),
		axes := PackedVector4Array(), ccol := PackedVector4Array()) -> void:
	var n := pos.size()
	var nc := cpos.size()
	var rb := PackedFloat64Array()
	for i in n:
		rb.append(col[i].w)
	var rc := PackedFloat64Array()
	for i in nc:
		rc.append(2.0 * ccol[i].w)       # a cube's reach: its half diagonal
	var ob := region_order(pos, rb, space.h, space.Rout)
	var oc := region_order(cpos, rc, space.h, space.Rout)
	var p := PackedVector4Array()
	var c := PackedVector4Array()
	var fb := PackedVector4Array()     # the sphere a flat sheet cuts from it, in that chart
	for i in ob[0]:
		p.append(pos[i])
		c.append(col[i])
		var C := pos[i]
		var side := 1.0 if C.w > 0.0 else -1.0
		var dw := C.w - side * space.h
		var r2 := col[i].w * col[i].w - dw * dw
		fb.append(Vector4(side * C.x, C.y, C.z, r2) if r2 > 0.0 else Vector4(0.0, 0.0, 0.0, -1.0))
	var cp := PackedVector4Array()
	var cc := PackedVector4Array()
	var ax := PackedVector4Array()
	for i in oc[0]:
		cp.append(cpos[i])
		cc.append(ccol[i])
		var o := Vector4.ZERO
		for k in 4:
			ax.append(axes[4 * i + k])
			o[k] = cpos[i].dot(axes[4 * i + k])
		ax.append(o)
	toy_count = n + nc
	values["wh_ball"] = p
	values["wh_ballCol"] = c
	values["wh_nBall"] = n
	values["wh_bIdx"] = ob[1]
	values["wh_fball"] = fb
	values["wh_cube"] = cp
	values["wh_cubeE"] = ax
	values["wh_cubeCol"] = cc
	values["wh_nCube"] = nc
	values["wh_cIdx"] = oc[1]
	# the bounding spheres per flat universe: balls a sheet w = side h cuts, cubes the same (half
	# diagonal 2 half); in the order balls A, balls B, cubes A, cubes B
	var bounds := PackedVector4Array()
	for group in 2:
		for side in [1.0, -1.0]:
			var lo := Vector3(INF, INF, INF)
			var hi := -lo
			var pts := []
			var count := n if group == 0 else nc
			for i in count:
				var C: Vector4 = pos[i] if group == 0 else cpos[i]
				var rr: float = col[i].w if group == 0 else 2.0 * ccol[i].w
				if absf(C.w - side * space.h) < rr:
					var c3 := Vector3(C.x, C.y, C.z)
					lo = lo.min(c3)
					hi = hi.max(c3)
					pts.append([c3, rr])
			if pts.is_empty():
				bounds.append(Vector4(0.0, 0.0, 0.0, -1.0))
				continue
			var mid := 0.5 * (lo + hi)
			var rad := 0.0
			for q in pts:
				rad = maxf(rad, mid.distance_to(q[0]) + q[1])
			bounds.append(Vector4(mid.x, mid.y, mid.z, rad))
	values["wh_bound"] = bounds


## Where each object can be met: in universe A's flat sheet (its reach crosses w = h), in the
## shell (it comes within reach of |xyz| < Rout) or in B's sheet (w = -h); none is in both sheets.
## Returns [the order, Vector4i(x, y, z, w)]: sorted A only, A and the shell, the shell only, the
## shell and B, B only, A's are 0 .. y, the shell's x .. w, B's z .. the end (wh_bIdx, wh_cIdx).
## pos: centres as points of R^4, reach: each one's radius of reach (a ball's radius, a cube's
## half diagonal).
static func region_order(pos: PackedVector4Array, reach: PackedFloat64Array, h: float, rout: float) -> Array:
	var groups := [[], [], [], [], []]
	for i in pos.size():
		var C := pos[i]
		var r := reach[i]
		var in_a := absf(C.w - h) < r
		var in_b := absf(C.w + h) < r
		var in_s := Vector3(C.x, C.y, C.z).length() - r < rout
		var g := 2
		if in_a:
			g = 1 if in_s else 0
		elif in_b:
			g = 3 if in_s else 4
		groups[g].append(i)
	var order := []
	var ends := []
	for g in groups:
		order.append_array(g)
		ends.append(order.size())
	return [order, Vector4i(ends[0], ends[1], ends[2], ends[3])]


## How gravity is shown: GRAVITY_VIEWS (docs/gravity.md, «Показ»). Every kernel is compiled at the
## start, so the switch costs no hitch.
func set_gravity_view(view: int) -> void:
	gravity_view = clampi(view, 0, GRAVITY_VIEWS.size() - 1)
	values["wh_pix"] = _pixel_angle()
	print("gravity view: ", GRAVITY_VIEWS[gravity_view])


## Whether there are no movable objects (the speed check compares like with like).
func plain() -> bool:
	return toy_count == 0


## The block of the kernels' uniforms up to the views' part (RayPass: the order of Frame in
## shaders/trace_kernels.gdshaderinc), from values.
func _pack() -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	for k in ["wh_rho0", "wh_h", "wh_fillet", "wh_pix"]:
		b.put_float(values.get(k, 0.0))
	for k in ["wh_tabLo", "wh_tabInv", "wh_tabReg", "grav_cyl"]:
		_put4(b, values.get(k, Vector4.ZERO))
	for k: String in ["grav_g:2", "grav_d:2", "wh_sph:6", "wh_pil:4", "wh_box:4", "wh_ball:12", "wh_ballCol:12",
			"wh_fball:12", "wh_cube:6", "wh_cubeE:30", "wh_cubeCol:6", "wh_bound:4"]:
		var name := k.get_slice(":", 0)
		var count := int(k.get_slice(":", 1))
		var arr: PackedVector4Array = values.get(name, PackedVector4Array())
		for i in count:
			_put4(b, arr[i] if i < arr.size() else Vector4.ZERO)
	for k in ["wh_bIdx", "wh_cIdx"]:
		var v: Vector4i = values.get(k, Vector4i.ZERO)
		for j in 4:
			b.put_32(v[j])
	for v in [values.get("wh_nBall", 0), values.get("wh_nCube", 0), 1, 0]:
		b.put_32(v)
	var hf: PackedVector4Array = values.get("head_f", PackedVector4Array([Vector4.ZERO, Vector4.ZERO, Vector4.ZERO]))
	for i in 3:
		_put4(b, hf[i])
	var hn: Vector3 = values.get("head_n", Vector3(1.0, 0.0, 0.0))
	_put4(b, Vector4(hn.x, hn.y, hn.z, values.get("head_l", 10.0)))
	var hp: Vector3 = values.get("head_pos", Vector3.ZERO)
	_put4(b, Vector4(hp.x, hp.y, hp.z, 0.0))
	return b.data_array


static func _put4(b: StreamPeerBuffer, v: Vector4) -> void:
	for k in 4:
		b.put_float(v[k])


## A pixel's angle in the middle of the view, radians (soft edges of the gravity arrows and the
## cubes' edge lines): the height of eye 0's frustum at unit distance, by the runtime's projection,
## over the pixels it spans.
func _pixel_angle() -> float:
	if xr:
		var px := xr.get_render_target_size() * xr_view.scaling_3d_scale
		var f := frustum(0)
		var height := f.w - f.z
		if not is_finite(height) or height <= 0.0:
			# no frustum from the runtime yet: the last one, or 90 degrees
			return pixel_angle if pixel_angle > 0.0 else 2.0 / maxf(px.y, 1.0)
		return height / maxf(px.y, 1.0)
	var cam := get_parent() as Camera3D
	return 2.0 * tan(0.5 * deg_to_rad(cam.fov)) / maxf(float(get_viewport().get_visible_rect().size.y), 1.0)


## Eye v's frustum by the runtime's projection: the tangents of its sides' angles off the view
## axis, left, right, bottom, top (negative left of and below the axis).
func frustum(v: int) -> Vector4:
	var p := xr.get_projection_for_view(v, 1.0, Main.NEAR, 100.0)
	# a frustum's projection: x.x = 2 / (right - left), z.x = (right + left) / (right - left), and
	# y.y, z.y likewise for top and bottom
	var across := Vector2(p.z.x - 1.0, p.z.x + 1.0) / p.x.x
	var up := Vector2(p.z.y - 1.0, p.z.y + 1.0) / p.y.y
	return Vector4(across.x, across.y, up.x, up.y)


## Gravity for the gravity views: f / r and f' as the kernels evaluate them
## (WormholeSpace.gravity_shader).
func upload_gravity() -> void:
	var g := space.gravity_shader()
	values["grav_cyl"] = g.cyl
	values["grav_g"] = PackedVector4Array(g.g)
	values["grav_d"] = PackedVector4Array(g.d)
	values["wh_pix"] = _pixel_angle()


## The fillet polynomials by impact parameter (WormholeSpace.fillet_table).
func upload_fillet_table() -> void:
	var tab := space.fillet_table()
	pass_.table = ImageTexture.create_from_image(tab.image)
	values["wh_tabLo"] = tab.lo
	values["wh_tabInv"] = tab.inv
	values["wh_tabReg"] = tab.reg


## The static objects (scene.json, which the physics and the tests read too).
func _upload_scene() -> void:
	var to_v4 := func(rows: Array) -> PackedVector4Array:
		var out := PackedVector4Array()
		for r in rows:
			out.append(Vector4(r[0], r[1], r[2], r[3]))
		return out
	values["wh_sph"] = to_v4.call(scene["spheres_A"] + scene["spheres_B"])
	values["wh_pil"] = to_v4.call(scene["pillars_A"])
	values["wh_box"] = to_v4.call(scene["boxes_B"])
