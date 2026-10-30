class_name Renderer
extends Node3D
## How a frame is drawn (docs/geometry.md, «Как рисуется кадр»): every body is a mesh that
## Godot's rasterizer draws, each of its vertices put where this view's eye sees it along the one
## geodesic to it (shaders/body.gdshaderinc); then the floor and the sky, per pixel, behind them
## (shaders/floor.gdshaderinc). A body costs its vertices, a few thousand per frame, and one cheap
## shading per pixel it covers, wherever it is and however close: the pixels behind it never run
## the floor's shader. Each view's own eye is worked out in the shaders from the head this gets
## each frame (set_head) and the view's matrices.
##
## What it draws: the physics' balls and cubes, the hands' balls (set_objects), the scene's static
## objects (scene.json), the gravity view's floor and arrows (set_gravity_view), the floor and the
## sky. The floor quad hangs under the camera (its parent); the bodies go into the play space, the
## camera's parent's parent (the origin, which never moves: their shader reads their numbers from the
## instance transform, which must stay theirs).
##
## A MeshInstance3D whose ShaderMaterial has no shader yet is drawn with Godot's default lit
## material, a huge program: a node is made only with its shader.

# the floor's shaders: plain, coloured by gravity (both gravity views), each in a material of its own:
# a ShaderMaterial keeps only the uniforms its shader has, so one material switched between them
# would lose the gravity table
const FLOOR_SHADERS := [preload("res://shaders/floor.gdshader"), preload("res://shaders/floor_gravity.gdshader")]
const BALL_SHADER := preload("res://shaders/toy_ball.gdshader")
const CUBE_SHADER := preload("res://shaders/toy_cube.gdshader")
const SCENE_SHADER := preload("res://shaders/scene.gdshader")
const ARROW_SHADER := preload("res://shaders/arrows.gdshader")
const GRAVITY_VIEWS := ["off", "floor", "floor and arrows"]
const MAX_BALLS := 12           # the toys' balls and both hands'
const MAX_CUBES := 8           # the toys' and the speed check's cube before the eyes
# the meshes: a ball's (the unit sphere; check_scene.gd's balls take the same), a cube's faces in
# CUBE_STEPS x CUBE_STEPS squares, the scene's spheres by size
const BALL_SEGMENTS := 48
const BALL_RINGS := 24
const CUBE_STEPS := 8
const FLOOR_PRIORITY := 100     # opaque draws go by render_priority, lower first: the floor last
# the static objects' colours (linear), each sphere its own in scene.json's order, A's then B's
const SPHERE_COLORS := [Color(0.62, 0.27, 0.22), Color(0.25, 0.45, 0.62), Color(0.55, 0.52, 0.2),
		Color(0.3, 0.55, 0.35), Color(0.5, 0.3, 0.6), Color(0.65, 0.45, 0.2)]
const PILLAR_COLOR := Color(0.55, 0.45, 0.38)
const BOX_COLOR := Color(0.42, 0.48, 0.58)
# the gravity view's arrows: on the vertical surface n.x = 0 (through the throat, across chart x),
# every ARROW_STEP of l out to ARROW_REACH beyond the curved zone, rows ARROW_STEP apart in height;
# each in the colour of its g with a dark outline, which keeps it seen on the floor of the same g
const ARROW_STEP := 1.0
const ARROW_REACH := 4.5
const ARROW_LENGTH := 0.6       # m at 1 g; no longer than at ARROW_MAX_G
const ARROW_MAX_G := 1.4
const ARROW_SHAFT := 0.035      # half the shaft's width, m
const ARROW_HEAD := 0.13        # half the head's width, m
const ARROW_RIM := 0.02         # the outline's width, m
const ARROW_RIM_COLOR := Color(0.02, 0.02, 0.02)

var space: WormholeSpace
var scene: Dictionary
var xr: XRInterface             # null on the desktop
var xr_view: SubViewport        # where XR renders; null on the desktop
var floor_mats: Array[ShaderMaterial] = []   # FLOOR_SHADERS' materials
var floor_mat: ShaderMaterial   # the one drawn (gravity_view)
var ball_mat := ShaderMaterial.new()
var cube_mat := ShaderMaterial.new()
var scene_mats: Array[ShaderMaterial] = []
var arrow_mat := ShaderMaterial.new()
var balls: MultiMeshInstance3D
var cubes: MultiMeshInstance3D
var statics: Array[MeshInstance3D] = []
var arrows: MeshInstance3D
var floor_quad: MeshInstance3D
var gravity_view := 0           # 0 off, 1 the floor coloured by gravity, 2 also arrows of its field
var toy_count := 0              # balls and cubes drawn (set_objects)
var ball_col := PackedVector4Array()   # the balls' (colour, radius) as set_objects got them
var bodies: Array = []          # what set_objects drew: [kind ("ball", "cube"), centre (R^4), radius or half size]


func _init(p_space: WormholeSpace, p_scene: Dictionary, p_xr: XRInterface, p_xr_view: SubViewport) -> void:
	space = p_space
	scene = p_scene
	xr = p_xr
	xr_view = p_xr_view
	for sh in FLOOR_SHADERS:
		var m := ShaderMaterial.new()
		m.shader = sh
		m.render_priority = FLOOR_PRIORITY
		floor_mats.append(m)
	floor_mat = floor_mats[0]
	ball_mat.shader = BALL_SHADER
	cube_mat.shader = CUBE_SHADER
	arrow_mat.shader = ARROW_SHADER


func _ready() -> void:
	var play: Node3D = get_parent().get_parent()
	for side in [1.0, -1.0]:
		var m := ShaderMaterial.new()
		m.shader = SCENE_SHADER
		m.set_shader_parameter("sheet", side)
		scene_mats.append(m)
	upload_space()
	floor_quad = MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(2.0, 2.0)
	floor_quad.mesh = q
	floor_quad.material_override = floor_mat
	floor_quad.extra_cull_margin = 16384.0
	floor_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(floor_quad)
	balls = _multimesh(_ball_mesh(), ball_mat, MAX_BALLS)
	cubes = _multimesh(_cube_mesh(), cube_mat, MAX_CUBES)
	play.add_child(balls)
	play.add_child(cubes)
	for k in 2:
		var mi := _body(_scene_mesh(1.0 if k == 0 else -1.0), scene_mats[k])
		statics.append(mi)
		play.add_child(mi)
	arrows = _body(_arrow_mesh(), arrow_mat)
	arrows.visible = false
	play.add_child(arrows)


## Every material that reads geo_uniforms.gdshaderinc.
func materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = [ball_mat, cube_mat, arrow_mat]
	out.append_array(floor_mats)
	out.append_array(scene_mats)
	return out


## The throat's shape and what is built for it (WormholeSpace.set_profile's list): the profile,
## the sweep table, gravity on the floor. Slow in GDScript: not per frame.
func upload_space() -> void:
	var tab := space.sweep_table()
	var tex := ImageTexture.create_from_image(tab.image)
	var grav := space.gravity_table()
	var gtex := ImageTexture.create_from_image(grav.image)
	_sweep_tex = tex
	_sweep_axes = tab.axes
	_sweep_poly = tab.poly
	for m in materials():
		_space_params(m)
	floor_mats[1].set_shader_parameter("g_grav", gtex)
	floor_mats[1].set_shader_parameter("g_gravx", grav.axes)


var _sweep_tex: Texture2D
var _sweep_axes := Vector4.ZERO
var _sweep_poly := PackedVector4Array()


func _space_params(m: ShaderMaterial) -> void:
	var u0 := sin(0.5 * space.th0) * sin(0.5 * space.th0)
	m.set_shader_parameter("g_prof", Vector4(space.rho0, space.fillet, space.Lc, space.L))
	m.set_shader_parameter("g_prof2", Vector4(space.Rout, u0, space.rho0 + 2.0 * space.fillet * u0, space.th0))
	m.set_shader_parameter("g_tabx", _sweep_axes)
	m.set_shader_parameter("g_tab", _sweep_tex)
	m.set_shader_parameter("g_poly", _sweep_poly)


## Each frame: the head in the curved space (l, n), its frame [right, up, back] there (the play
## space's axes) and its place in the room; the shaders put each view's eye there.
func set_head(l: float, n: Vector3, hf: Array, head_pos: Vector3) -> void:
	var f := PackedVector4Array(hf)
	for m in materials():
		m.set_shader_parameter("head_l", l)
		m.set_shader_parameter("head_n", n)
		m.set_shader_parameter("head_f", f)
		m.set_shader_parameter("head_pos", head_pos)


## The movable balls and cubes: balls by their centres (points of R^4) and (colour, radius), cubes
## by their centres, two body axes each (unit vectors of R^4, tangent at the centre: cube_axes holds
## E1, E2 of the first cube, then the second's...; the third follows from them) and (colour, half
## size). Colours as Godot's Color takes them (sRGB). At most MAX_BALLS and MAX_CUBES.
func set_objects(pos: PackedVector4Array, col: PackedVector4Array, cpos := PackedVector4Array(),
		cube_axes := PackedVector4Array(), ccol := PackedVector4Array()) -> void:
	var n := mini(pos.size(), MAX_BALLS)
	var nc := mini(cpos.size(), MAX_CUBES)
	var mm := balls.multimesh
	for i in n:
		var C := pos[i]
		var e := _tangent_pair(C)
		mm.set_instance_transform(i, pack(C, e[0], e[1]))
		mm.set_instance_custom_data(i, _linear(col[i]))
	mm.visible_instance_count = n
	mm = cubes.multimesh
	for i in nc:
		mm.set_instance_transform(i, pack(cpos[i], cube_axes[2 * i], cube_axes[2 * i + 1]))
		mm.set_instance_custom_data(i, _linear(ccol[i]))
	mm.visible_instance_count = nc
	toy_count = n + nc
	ball_col = col.slice(0, n)
	bodies.clear()
	for i in n:
		bodies.append(["ball", pos[i], col[i].w])
	for i in nc:
		bodies.append(["cube", cpos[i], ccol[i].w])


static func _linear(c: Vector4) -> Color:
	var k := Color(c.x, c.y, c.z).srgb_to_linear()
	return Color(k.r, k.g, k.b, c.w)


## A body's centre and two axes (points and vectors of R^4) in the 12 numbers of an instance
## transform, as body.gdshaderinc reads them.
static func pack(C: Vector4, E1: Vector4, E2: Vector4) -> Transform3D:
	return Transform3D(Basis(Vector3(C.x, C.y, C.z), Vector3(C.w, E1.x, E1.y), Vector3(E1.z, E1.w, E2.x)),
			Vector3(E2.y, E2.z, E2.w))


## Two orthonormal vectors of R^4 tangent to the space at its point C (a ball's frame: any).
func _tangent_pair(C: Vector4) -> Array:
	var p := space.point_of(C)
	var N := space.normal4(p[0], p[1])
	var axes := [Vector4(1, 0, 0, 0), Vector4(0, 1, 0, 0), Vector4(0, 0, 1, 0), Vector4(0, 0, 0, 1)]
	axes.sort_custom(func(a: Vector4, b: Vector4) -> bool: return absf(a.dot(N)) < absf(b.dot(N)))
	var e1: Vector4 = axes[0] - axes[0].dot(N) * N
	e1 = e1.normalized()
	var e2: Vector4 = axes[1] - axes[1].dot(N) * N
	e2 = (e2 - e2.dot(e1) * e1).normalized()
	return [e1, e2]


## How gravity is shown: GRAVITY_VIEWS (docs/gravity.md, «Показ»).
func set_gravity_view(view: int) -> void:
	gravity_view = clampi(view, 0, GRAVITY_VIEWS.size() - 1)
	floor_mat = floor_mats[mini(gravity_view, 1)]
	floor_quad.material_override = floor_mat
	arrows.visible = gravity_view == 2
	print("gravity view: ", GRAVITY_VIEWS[gravity_view])


## The scene's static objects shown or not (the stereo check scene takes them away).
func show_scene(on: bool) -> void:
	for s in statics:
		s.visible = on


## Eye v's frustum by the runtime's projection: the tangents of its sides' angles off the view
## axis, left, right, bottom, top (negative left of and below the axis).
func frustum(v: int) -> Vector4:
	var p := xr.get_projection_for_view(v, 1.0, Main.NEAR, 100.0)
	# a frustum's projection: x.x = 2 / (right - left), z.x = (right + left) / (right - left), and
	# y.y, z.y likewise for top and bottom
	var across := Vector2(p.z.x - 1.0, p.z.x + 1.0) / p.x.x
	var up := Vector2(p.z.y - 1.0, p.z.y + 1.0) / p.y.y
	return Vector4(across.x, across.y, up.x, up.y)


# ---------------------------------------------------------------- meshes

static func _multimesh(mesh: Mesh, mat: ShaderMaterial, count: int) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = count
	mm.visible_instance_count = 0
	mm.custom_aabb = AABB(Vector3.ONE * -1e4, Vector3.ONE * 2e4)
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = mat
	mi.extra_cull_margin = 16384.0
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


static func _body(mesh: Mesh, mat: ShaderMaterial) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.extra_cull_margin = 16384.0
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


static func _ball_mesh() -> Mesh:
	var s := SphereMesh.new()
	s.radius = 1.0
	s.height = 2.0
	s.radial_segments = BALL_SEGMENTS
	s.rings = BALL_RINGS
	return s


static func _cube_mesh() -> Mesh:
	var b := BoxMesh.new()
	b.size = Vector3(2.0, 2.0, 2.0)
	b.subdivide_width = CUBE_STEPS - 1
	b.subdivide_height = CUBE_STEPS - 1
	b.subdivide_depth = CUBE_STEPS - 1
	return b


## One universe's static objects in its chart coordinates (z up), each with its colour.
func _scene_mesh(side: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var key := "A" if side > 0.0 else "B"
	var up := Basis(Vector3(1, 0, 0), PI / 2.0)      # Godot's meshes are y up: y -> z
	var spheres: Array = scene["spheres_" + key]
	for i in spheres.size():
		var s: Array = spheres[i]
		var m := SphereMesh.new()
		m.radius = s[3]
		m.height = 2.0 * s[3]
		m.radial_segments = 64 if s[3] >= 2.0 else 48
		m.rings = m.radial_segments / 2
		_append(st, m, Transform3D(up, Vector3(s[0], s[1], s[2])), SPHERE_COLORS[(i + (0 if side > 0.0 else spheres.size())) % SPHERE_COLORS.size()])
	for p: Array in scene.get("pillars_" + key, []):
		var c := CylinderMesh.new()
		c.top_radius = p[2]
		c.bottom_radius = p[2]
		c.height = p[3]
		c.radial_segments = 48
		c.rings = 8
		_append(st, c, Transform3D(up, Vector3(p[0], p[1], 0.5 * p[3])), PILLAR_COLOR)
	for bx: Array in scene.get("boxes_" + key, []):
		var m := BoxMesh.new()
		m.size = Vector3.ONE * 2.0 * bx[3]
		m.subdivide_width = 3
		m.subdivide_height = 3
		m.subdivide_depth = 3
		_append(st, m, Transform3D(up, Vector3(bx[0], bx[1], bx[2])), BOX_COLOR)
	# shared corners once: each vertex costs the GPU a geodesic (body.gdshaderinc), and without an
	# index every triangle would have its own three
	st.index()
	return st.commit()


static func _append(st: SurfaceTool, mesh: PrimitiveMesh, xf: Transform3D, color: Color) -> void:
	var arr := mesh.get_mesh_arrays()
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var nv: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	for k in idx:
		st.set_color(color)
		st.set_normal(xf.basis * nv[k])
		st.add_vertex(xf * v[k])


## The gravity view's arrows (docs/gravity.md, «Показ»): on the surface n.x = 0, a grid in l and in
## height along it, each an arrow along the force there, its length and colour the strength.
## Vertices as points of the space: n in the vertex, l in UV.x (body.gdshaderinc, ARROWS).
func _arrow_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lmax := space.L + ARROW_REACH
	var nl := int(lmax / ARROW_STEP)
	for il in range(-nl, nl + 1):
		var l := il * ARROW_STEP
		var rr := space.r(l)
		# rows along the half circle above the floor, about ARROW_STEP apart
		var nb := maxi(1, roundi(PI * rr / ARROW_STEP))
		for ib in nb:
			var beta := PI * (ib + 0.5) / nb
			var n := Vector3(0.0, cos(beta), sin(beta))
			var F := -space.potential_grad(l, n)
			var e_beta := Vector3(0.0, -sin(beta), cos(beta))
			var f2 := Vector2(F.x, Vector3(F.y, F.z, F.w).dot(e_beta))    # in (along l, along beta)
			var g := f2.length()
			if g < 1e-4:
				continue
			var dir := f2 / g
			var len := ARROW_LENGTH * minf(g, ARROW_MAX_G)
			var head := minf(0.3, 0.6 * len)
			# the outline first, then the arrow over it (the shader puts it a hair nearer the eye)
			_arrow(st, l, beta, rr, dir, len, head, ARROW_RIM, Color(ARROW_RIM_COLOR, 0.0))
			_arrow(st, l, beta, rr, dir, len, head, 0.0, Color(_gravity_color(g), 1.0))
	st.index()          # shared corners once (_scene_mesh)
	return st.commit()


## One arrow at (l, beta) on the surface n.x = 0 (metric dl^2 + r^2 dbeta^2), along dir (in l,
## beta), grown by grow on every side.
static func _arrow(st: SurfaceTool, l: float, beta: float, rr: float, dir: Vector2, len: float, head: float,
		grow: float, color: Color) -> void:
	var side := Vector2(-dir.y, dir.x)
	var back := -0.5 * len - grow
	var neck := 0.5 * len - head
	var sw := ARROW_SHAFT + grow
	var hw := ARROW_HEAD + 2.0 * grow
	var tip := 0.5 * len + 2.0 * grow
	var pts := [back * dir + sw * side, neck * dir + sw * side, neck * dir - sw * side, back * dir - sw * side,
			(neck - grow) * dir + hw * side, tip * dir, (neck - grow) * dir - hw * side]
	for k in [0, 1, 2, 0, 2, 3, 4, 5, 6]:
		var o: Vector2 = pts[k]
		var b2 := beta + o.y / rr
		st.set_color(color)
		st.set_uv(Vector2(l + o.x, 0.0))
		st.add_vertex(Vector3(0.0, cos(b2), sin(b2)))


## look.gdshaderinc's look_gravity: the colour of g, in g.
static func _gravity_color(g: float) -> Color:
	var dark := Color(0.01, 0.0085, 0.0134)
	var yellow := Color(1.0, 0.7106, 0.0196)
	var red := Color(0.8276, 0.0272, 0.0072)
	if g < 1.0:
		return dark.lerp(yellow, g)
	if g < 3.0:
		return yellow.lerp(red, (g - 1.0) * 0.5)
	return red.lerp(Color.WHITE, clampf((g - 3.0) / 7.0, 0.0, 1.0))
