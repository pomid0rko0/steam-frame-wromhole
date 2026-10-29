class_name Tracer
extends Node3D
## The ray tracer: a full-screen quad under the XR camera whose shader traces every pixel along a
## geodesic of the wormhole space (shaders/wormhole_core.gdshaderinc), and what it needs: its
## uniforms, the shader for what is shown, the movable balls and cubes, and the stencil split.
##
## Shaders. Code costs registers even where no pixel runs it (wormhole_core.gdshaderinc, «The
## compiler»), so each combination is a shader of its own: without movable objects
## (wormhole.gdshader) or with them (wormhole_balls), each also with the gravity view's floor
## colours (_gravity) or the floor and the field's arrows (_arrows). Switching costs a hitch while
## the GPU compiles the other one, so the shader changes only when what is shown changes.
##
## The stencil split. The shader with toys holds more registers and costs more even where it finds
## nothing, so with toys the frame is split: proxies drawn first (render priority -1,
## stencil_mark.gdshader) mark the pixels whose rays may meet a toy, the shader with toys runs only
## there (stencil equal 1), the plain one of the same view everywhere else (a second quad, stencil
## not equal 1). Godot geometry drawn before the ray tracers must not write the stencil. The
## stencil (stencil_mode in a shader) works on Mobile, with multiview and on lavapipe; opaque draws
## go by render_priority, lower first.
##
## A MeshInstance3D whose ShaderMaterial has no shader yet is drawn with Godot's default lit
## material, a huge program: such a node is made only once its shader is known.

# the ray tracers: [plain, gravity floor, gravity floor and arrows], without and with toys
const SHADERS := [preload("res://shaders/wormhole.gdshader"), preload("res://shaders/wormhole_gravity.gdshader"),
		preload("res://shaders/wormhole_arrows.gdshader")]
const SHADERS_TOYS := [preload("res://shaders/wormhole_balls.gdshader"),
		preload("res://shaders/wormhole_balls_gravity.gdshader"), preload("res://shaders/wormhole_balls_arrows.gdshader")]
const SHADER_MARK := preload("res://shaders/stencil_mark.gdshader")
const SHADER_MARK_ALL := preload("res://shaders/stencil_mark_all.gdshader")
const GRAVITY_VIEWS := ["off", "floor", "floor and arrows"]
const MAX_BALLS := 12           # the shader's slots for the toys' and the hands' balls
const MAX_CUBES := 6
# m around each proxy sphere. A ray that meets a toy inside its sphere leaves the sphere at least
# this far beyond the hit, so it is marked even where the near plane clips the sphere's near side,
# as long as the near plane (main.NEAR along the view axis, NEAR / cos of the ray's angle along the
# ray) is nearer than this: within acos(main.NEAR / PROXY_MARGIN) of the view axis.
const PROXY_MARGIN := 0.08
# the proxy sphere's mesh (check_scene.gd's balls take it too); its faces lie inside the sphere
# (Godot's SphereMesh has rings + 1 latitude steps): grown by PROXY_SLACK, more than they lie in
# (_ready asserts it)
const PROXY_SEGMENTS := 48
const PROXY_RINGS := 24
const PROXY_SLACK := 1.02
# how the shader with toys gets its pixels: SPLIT by the stencil (the plain one elsewhere), WHOLE
# the whole view marked, BARE no stencil at all (another source's shader in the speed check, which
# has no stencil test)
enum {SPLIT, WHOLE, BARE}

var space: WormholeSpace
var scene: Dictionary
var xr: XRInterface             # null on the desktop
var xr_view: SubViewport        # where XR renders; null on the desktop
var material := ShaderMaterial.new()        # with the toys where there are any, else the plain one
var plain_material := ShaderMaterial.new()  # with toys: the plain one where none can be seen
var plain_quad: MeshInstance3D
var proxies: MultiMeshInstance3D   # spheres around the shell and this universe's toys (play space)
var mark_all: MeshInstance3D       # the whole view marked instead
var toy_mode := SPLIT
var toy_count := 0              # balls and cubes the shader has (set_objects)
var toy_spheres := [PackedVector4Array(), PackedVector4Array()]   # per universe A, B: the toys' chart spheres
var gravity_view := 0           # 0 off, 1 the floor coloured by gravity, 2 also arrows of its field
var pixel_angle := 0.0          # the pixel angle set_head last saw: wh_pix goes again when it changes


func _init(p_space: WormholeSpace, p_scene: Dictionary, p_xr: XRInterface, p_xr_view: SubViewport) -> void:
	space = p_space
	scene = p_scene
	xr = p_xr
	xr_view = p_xr_view
	material.shader = SHADERS[0]


## Under the camera: the quads it draws on. The proxies go into the play space, the camera's parent.
func _ready() -> void:
	assert(PROXY_SLACK * cos(PI / PROXY_SEGMENTS) * cos(PI / (2.0 * (PROXY_RINGS + 1))) > 1.0,
			"PROXY_SLACK covers the proxy mesh's deepest faces")
	assert(_fits_shader(), "the shader's sizes follow this code's (the errors above)")
	param("wh_rho0", space.rho0)
	param("wh_h", space.h)
	param("wh_fillet", space.fillet)
	upload_fillet_table()
	upload_gravity()
	_upload_scene()
	add_child(_screen_quad(material))
	var mark := ShaderMaterial.new()
	mark.shader = SHADER_MARK
	mark.render_priority = -1
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = PROXY_SEGMENTS
	sphere.rings = PROXY_RINGS
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = sphere
	mm.instance_count = 1 + MAX_BALLS + MAX_CUBES
	mm.visible_instance_count = 0
	proxies = MultiMeshInstance3D.new()
	proxies.multimesh = mm
	proxies.material_override = mark
	proxies.extra_cull_margin = 16384.0
	proxies.visible = false
	get_parent().get_parent().add_child(proxies)
	var all := ShaderMaterial.new()
	all.shader = SHADER_MARK_ALL
	all.render_priority = -1
	mark_all = _screen_quad(all)
	mark_all.visible = false
	add_child(mark_all)


## A quad over the whole view, 1 m in front of the camera (the shaders put it on the screen).
static func _screen_quad(mat: ShaderMaterial) -> MeshInstance3D:
	var q := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(2.0, 2.0)
	q.mesh = mesh
	q.material_override = mat
	q.extra_cull_margin = 16384.0
	q.position = Vector3(0.0, 0.0, -1.0)
	return q


## A uniform both ray tracers read (the toys' own, wh_ball..., go only to material: set_objects).
func param(name: StringName, value: Variant) -> void:
	material.set_shader_parameter(name, value)
	plain_material.set_shader_parameter(name, value)


## Each frame: the head in the curved space (l, n), its frame [right, up, back] there and its place
## in the room (the shader puts each eye there), the pixel's angle, and the proxies placed in the
## room from where the head is (in a flat universe the play-space offset from the head along the
## head's frame), or the whole view marked.
func set_head(l: float, n: Vector3, hf: Array, head_pos: Vector3) -> void:
	param("head_l", l)
	param("head_n", n)
	param("head_f", PackedVector4Array(hf))
	param("head_pos", head_pos)
	# a pixel's angle (the cubes' edge lines, the arrows' soft edges) follows the render scale
	var pix := _pixel_angle()
	if pix != pixel_angle:
		pixel_angle = pix
		param("wh_pix", pix)
	var split := toy_count > 0 and toy_mode == SPLIT and absf(l) > space.L
	proxies.visible = split
	if plain_quad:
		plain_quad.visible = split
	mark_all.visible = toy_count > 0 and not split and toy_mode != BARE
	if not split:
		return
	var side := 1.0 if l > 0.0 else -1.0
	var ch := space.chart_position(l, n)
	# chart -> play: head_pos + (d . v_k)_k for d = X - ch, v_k the chart directions of the play
	# axes (the head's frame)
	var B := Basis(WormholeSpace.vector_to_chart(side, n, hf[0]), WormholeSpace.vector_to_chart(side, n, hf[1]),
			WormholeSpace.vector_to_chart(side, n, hf[2])).transposed()
	var to_play := Transform3D(B, head_pos - B * ch)
	var mm := proxies.multimesh
	var count := 0
	for s in proxy_spheres(l):
		mm.set_instance_transform(count, to_play * Transform3D(Basis.from_scale(Vector3(s.w, s.w, s.w)), Vector3(s.x, s.y, s.z)))
		count += 1
	mm.visible_instance_count = count


## The proxies as spheres in the chart of the universe at l (centre, the mesh's radius: with the
## margin and the slack): the shell and that universe's toys. A ray from an eye in a flat universe
## goes straight until it enters the shell or ends: it meets one of that universe's toys only
## through the toy's bounding sphere, and anything else only through the shell. Drawn from both
## sides: an eye inside a sphere sees its inside. With the head in the curved region there is no
## chart to place them in: none, the whole view is marked (tools/adreno_cost.py --split models the
## split with these).
func proxy_spheres(l: float) -> PackedVector4Array:
	var out := PackedVector4Array()
	if toy_count == 0 or toy_mode != SPLIT or absf(l) <= space.L:
		return out
	out.append(Vector4(0.0, 0.0, 0.0, (space.Rout + PROXY_MARGIN) * PROXY_SLACK))
	for s in toy_spheres[0 if l > 0.0 else 1]:
		out.append(Vector4(s.x, s.y, s.z, (s.w + PROXY_MARGIN) * PROXY_SLACK))
	return out


## Movable balls and cubes. Balls (BallWorld's): centres as points of R^4 (pos), colours with the
## radius (col: rgb, radius), at most MAX_BALLS. Cubes (BallWorld's), at most MAX_CUBES: the centre
## as a point of R^4 (cpos), four orthonormal axes divided by the half size (axes: three body axes
## tangent to the space, then its normal; four per cube), (rgb, half size) (ccol). The shader gets
## them as wormhole_core.gdshaderinc's top says, sorted by where they are (region_order): the flat
## universes' rays and the shell's look only at their own, so a ball's index in the shader is not
## its index in the caller's list. The shader is chosen here: with no toys it is the one without
## their code.
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
	while p.size() < MAX_BALLS:
		p.append(Vector4.ZERO)
		c.append(Vector4.ZERO)
		fb.append(Vector4(0.0, 0.0, 0.0, -1.0))
	while cp.size() < MAX_CUBES:
		cp.append(Vector4.ZERO)
		cc.append(Vector4.ZERO)
	while ax.size() < 5 * MAX_CUBES:
		ax.append(Vector4.ZERO)
	var had := toy_count > 0
	toy_count = n + nc
	if (toy_count > 0) != had:
		_pick_shader()
	material.set_shader_parameter("wh_ball", p)
	material.set_shader_parameter("wh_ballCol", c)
	material.set_shader_parameter("wh_nBall", n)
	material.set_shader_parameter("wh_bIdx", ob[1])
	material.set_shader_parameter("wh_fball", fb)
	material.set_shader_parameter("wh_cube", cp)
	material.set_shader_parameter("wh_cubeE", ax)
	material.set_shader_parameter("wh_cubeCol", cc)
	material.set_shader_parameter("wh_nCube", nc)
	material.set_shader_parameter("wh_cIdx", oc[1])
	# each universe's toys as spheres in its chart (the proxies)
	toy_spheres = [PackedVector4Array(), PackedVector4Array()]
	for k in 2:
		var lo: int = 0 if k == 0 else ob[1].z
		var hi: int = ob[1].y if k == 0 else n
		for i in range(lo, hi):
			if fb[i].w > 0.0:
				toy_spheres[k].append(Vector4(fb[i].x, fb[i].y, fb[i].z, sqrt(fb[i].w)))
		lo = 0 if k == 0 else oc[1].z
		hi = oc[1].y if k == 0 else nc
		for i in range(lo, hi):
			var C: Vector4 = cp[i]
			toy_spheres[k].append(Vector4(C.x if k == 0 else -C.x, C.y, C.z, 2.0 * cc[i].w))
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
	material.set_shader_parameter("wh_bound", bounds)


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


## How gravity is shown (docs/gravity.md, «Показ»): 0 not at all, 1 the floor coloured by its
## strength, 2 also arrows of the field.
func set_gravity_view(view: int) -> void:
	gravity_view = clampi(view, 0, GRAVITY_VIEWS.size() - 1)
	param("wh_pix", _pixel_angle())
	_pick_shader()
	print("gravity view: ", GRAVITY_VIEWS[gravity_view])


## The ray tracer for what is shown. With toys, the plain one of the same view draws where none can
## be seen.
func _pick_shader() -> void:
	if toy_count > 0:
		material.shader = SHADERS_TOYS[gravity_view]
		plain_material.shader = SHADERS[gravity_view]
		if plain_quad == null:
			# made once there are toys: an unused ray tracer would be compiled all the same
			plain_quad = _screen_quad(plain_material)
			add_child(plain_quad)
	else:
		material.shader = SHADERS[gravity_view]


## Whether the shader runs without movable objects (the speed check compares like with like).
func plain() -> bool:
	return toy_count == 0


## Whether the sizes the shader fixes follow this code's: WormholeSpace's table and gravity
## polynomials, MAX_BALLS, MAX_CUBES, the scene's objects. Each that differs is printed. Only
## asserted: debug builds (the tests) run it, an export does not.
func _fits_shader() -> bool:
	var src: String = load("res://shaders/wormhole_view.gdshaderinc").code \
			+ load("res://shaders/wormhole_core.gdshaderinc").code
	var coefs := WormholeSpace.GRAV_DEG + 1
	var want := ["WH_TABN = %d.0;" % WormholeSpace.TABLE_N, "WH_MAXB = %d;" % MAX_BALLS]
	var arrays := {"grav_g": coefs / 4, "grav_d": coefs / 4, "wh_ball": MAX_BALLS, "wh_ballCol": MAX_BALLS,
			"wh_fball": MAX_BALLS, "wh_cube": MAX_CUBES, "wh_cubeE": 5 * MAX_CUBES, "wh_cubeCol": MAX_CUBES,
			"wh_sph": scene["spheres_A"].size() + scene["spheres_B"].size(),
			"wh_pil": scene["pillars_A"].size(), "wh_box": scene["boxes_B"].size()}
	for u: String in arrays:
		want.append("uniform vec4 %s[%d];" % [u, arrays[u]])
	var ok := coefs % 4 == 0
	if not ok:
		push_error("GRAV_DEG + 1 coefficients do not fill whole vec4s")
	for w: String in want:
		if not src.contains(w):
			push_error("the shader lacks \"%s\"" % w)
			ok = false
	return ok


## A pixel's angle in the middle of the view, radians (soft edges of the gravity arrows and the
## cubes' edge lines): the height of eye 0's frustum at unit distance, by the runtime's projection,
## over the pixels it spans.
func _pixel_angle() -> float:
	if xr:
		var px := xr.get_render_target_size() * xr_view.scaling_3d_scale
		var height := view_tangents().x - view_tangents().y
		if not is_finite(height) or height <= 0.0:
			# no frustum from the runtime yet: the last one, or 90 degrees
			return pixel_angle if pixel_angle > 0.0 else 2.0 / maxf(px.y, 1.0)
		return height / maxf(px.y, 1.0)
	var cam := get_parent() as Camera3D
	return 2.0 * tan(0.5 * deg_to_rad(cam.fov)) / maxf(float(get_viewport().get_visible_rect().size.y), 1.0)


## Eye 0's frustum by the runtime's projection: the tangents of its top and bottom edges' angles
## up from the view axis (the bottom's negative below it).
func view_tangents() -> Vector2:
	var p := xr.get_projection_for_view(0, 1.0, 0.05, 100.0)
	# a frustum's projection: y.y = 2 / (top - bottom), z.y = (top + bottom) / (top - bottom)
	return Vector2(1.0 + p.z.y, p.z.y - 1.0) / p.y.y


## Gravity for the gravity views: f / r and f' as the shader evaluates them
## (WormholeSpace.gravity_shader).
func upload_gravity() -> void:
	var g := space.gravity_shader()
	param("grav_cyl", g.cyl)
	param("grav_g", PackedVector4Array(g.g))
	param("grav_d", PackedVector4Array(g.d))
	param("wh_pix", _pixel_angle())


## The fillet polynomials by impact parameter (WormholeSpace.fillet_table).
func upload_fillet_table() -> void:
	var tab := space.fillet_table()
	param("wh_tab", ImageTexture.create_from_image(tab.image))
	param("wh_tabLo", tab.lo)
	param("wh_tabInv", tab.inv)
	param("wh_tabReg", tab.reg)


## The static objects (scene.json, which the physics and the tests read too).
func _upload_scene() -> void:
	var to_v4 := func(rows: Array) -> PackedVector4Array:
		var out := PackedVector4Array()
		for r in rows:
			out.append(Vector4(r[0], r[1], r[2], r[3]))
		return out
	param("wh_sph", to_v4.call(scene["spheres_A"] + scene["spheres_B"]))
	param("wh_pil", to_v4.call(scene["pillars_A"]))
	param("wh_box", to_v4.call(scene["boxes_B"]))
