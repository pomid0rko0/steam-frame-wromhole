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
const GRAVITY_VIEWS := ["off", "floor", "floor and field lines"]
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
# the gravity view's field lines: on the vertical surface n.x = 0 (through the throat, across chart
# x), from the edge of the region shown (LINE_REACH beyond the curved zone), every LINE_STEP across
# it, along the force down to the floor; arrows on them every ARROW_GAP along the line, each along it;
# the colour the strength (_gravity_color); each with a dark outline, which keeps it seen on the
# floor of the same g
const LINE_REACH := 4.5
const LINE_STEP := 1.0          # m between the lines' starts, across (chart y)
const LINE_DS := 0.2            # m: the steps a line is traced and drawn in
const LINE_MAX_STEPS := 300
const LINE_WIDTH := 0.03        # half a line's width, m
const ARROW_GAP := 1.0          # m along a line between its arrows
const ARROW_LENGTH := 0.24      # m
const ARROW_HALF := 0.12        # half an arrow's width, m
const ARROW_RIM := 0.008        # the outline's width, m
const ARROW_RIM_COLOR := Color(0.02, 0.02, 0.02)
const ARROW_GLOW := 1.15        # an arrow is its g's colour this much brighter (_gravity_color)

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


## The gravity view's field lines with their arrows (docs/gravity.md, «Показ»; the constants
## LINE_* and ARROW_*). Vertices as points of the space: n in the vertex, l in UV.x (body.gdshaderinc,
## ARROWS); each line and arrow twice, its outline (COLOR.a 0) and itself over it (COLOR.a 1).
func _arrow_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lmax := space.L + LINE_REACH
	var R := space.r(lmax)
	var k := int(R / LINE_STEP)
	for side in [1.0, -1.0]:
		for i in range(-k, k + 1):
			var y := i * LINE_STEP
			if absf(y) > R - 0.5 * LINE_STEP:
				continue
			var pts := _field_line(side * lmax, acos(y / R), lmax)
			if pts.size() < 2:
				continue
			_line(st, pts, true)
			_line(st, pts, false)
	st.index()          # shared corners once (_scene_mesh)
	return st.commit()


## The force at (l, beta) of the surface n.x = 0 (metric dl^2 + r^2 dbeta^2): its parts along l and
## along beta (per metre), in g.
func _force(l: float, beta: float) -> Vector2:
	var F := -space.potential_grad(l, Vector3(0.0, cos(beta), sin(beta)))
	return Vector2(F.x, Vector3(F.y, F.z, F.w).dot(Vector3(0.0, -sin(beta), cos(beta))))


## A field line from (l, beta) along the force (RK4 in steps of LINE_DS), to the floor (beta 0 or pi)
## or out of |l| < lmax: its points [l, beta, g].
func _field_line(l: float, beta: float, lmax: float) -> Array:
	var dir := func(ll: float, bb: float) -> Vector2:
		var f := _force(ll, bb)
		var g := f.length()
		return Vector2(f.x, f.y / space.r(ll)) / g if g > 1e-6 else Vector2.ZERO
	var pts := [[l, beta, _force(l, beta).length()]]
	for i in LINE_MAX_STEPS:
		var p := Vector2(l, beta)
		var k1: Vector2 = dir.call(p.x, p.y)
		if k1 == Vector2.ZERO:
			break
		var k2: Vector2 = dir.call(p.x + 0.5 * LINE_DS * k1.x, p.y + 0.5 * LINE_DS * k1.y)
		var k3: Vector2 = dir.call(p.x + 0.5 * LINE_DS * k2.x, p.y + 0.5 * LINE_DS * k2.y)
		var k4: Vector2 = dir.call(p.x + LINE_DS * k3.x, p.y + LINE_DS * k3.y)
		var q := p + LINE_DS / 6.0 * (k1 + 2.0 * k2 + 2.0 * k3 + k4)
		if q.y <= 0.0 or q.y >= PI:
			# onto the floor: the step's part that gets there
			var edge := 0.0 if q.y <= 0.0 else PI
			var t := (edge - p.y) / (q.y - p.y)
			q = p.lerp(q, t)
			q.y = edge
			pts.append([q.x, q.y, _force(q.x, q.y).length()])
			break
		if absf(q.x) > lmax:
			break
		l = q.x
		beta = q.y
		pts.append([l, beta, _force(l, beta).length()])
	return pts


## A line through pts ([l, beta, g]) LINE_WIDTH to each side, with an arrow every ARROW_GAP along
## it, in the colour of g where each point is; rim: its outline instead, ARROW_RIM wider all round.
func _line(st: SurfaceTool, pts: Array, rim: bool) -> void:
	var grow := ARROW_RIM if rim else 0.0
	var w := LINE_WIDTH + grow
	# the strip: two vertices a point
	var prev: Array = []
	for i in pts.size():
		var a: Array = pts[maxi(i - 1, 0)]
		var b: Array = pts[mini(i + 1, pts.size() - 1)]
		var p: Array = pts[i]
		var rr := space.r(p[0])
		var t := Vector2(b[0] - a[0], (b[1] - a[1]) * rr).normalized()
		var side := Vector2(-t.y, t.x)
		var c := Color(ARROW_RIM_COLOR, 0.0) if rim else Color(_gravity_color(p[2]), 1.0)
		var pair := [Vector2(p[0] + w * side.x, p[1] + w * side.y / rr), Vector2(p[0] - w * side.x, p[1] - w * side.y / rr)]
		if not prev.is_empty():
			for q: Vector2 in [prev[0], pair[0], pair[1], prev[0], pair[1], prev[1]]:
				_vertex(st, q, c)
		prev = pair
	# the arrows, each along the line where it stands
	var s := 0.0
	var next := 0.5 * ARROW_GAP
	for i in range(1, pts.size()):
		var a: Array = pts[i - 1]
		var b: Array = pts[i]
		var rr := space.r(0.5 * (a[0] + b[0]))
		var d := Vector2(b[0] - a[0], (b[1] - a[1]) * rr)
		var len := d.length()
		while len > 0.0 and next <= s + len:
			var f := (next - s) / len
			var at := Vector2(lerpf(a[0], b[0], f), lerpf(a[1], b[1], f))
			var t := d / len
			var side := Vector2(-t.y, t.x)
			var c := Color(ARROW_RIM_COLOR, 0.0) if rim else Color(_gravity_color(lerpf(a[2], b[2], f)), 1.0)
			var tip := (0.5 * ARROW_LENGTH + 2.0 * grow) * t
			var back := -(0.5 * ARROW_LENGTH + grow) * t
			for o: Vector2 in [tip, back + (ARROW_HALF + 2.0 * grow) * side, back - (ARROW_HALF + 2.0 * grow) * side]:
				_vertex(st, Vector2(at.x + o.x, at.y + o.y / rr), c)
			next += ARROW_GAP
		s += len


## A vertex of the field lines' mesh at (l, beta) of the surface n.x = 0, kept above the floor (the
## floor hides nothing: what is below it would show through).
static func _vertex(st: SurfaceTool, q: Vector2, c: Color) -> void:
	var b := clampf(q.y, 0.0, PI)
	st.set_color(c)
	st.set_uv(Vector2(q.x, 0.0))
	st.add_vertex(Vector3(0.0, cos(b), sin(b)))


## An arrow's colour at g (in g): look.gdshaderinc's look_grav_colour, brighter by ARROW_GLOW.
static func _gravity_color(g: float) -> Color:
	var t := 10.0 * g if g < 1.0 else 10.0 + 4.342944819 * log(g)
	var u := clampf(t / 10.0, 0.0, 1.0)
	var c := Color(0.03, 0.03, 0.10).lerp(Color(0.45, 0.08, 0.50), u * 2.0) if u < 0.5 \
			else Color(0.45, 0.08, 0.50).lerp(Color(0.95, 0.40, 0.12), u * 2.0 - 1.0)
	c = c.lerp(Color(0.95, 0.80, 0.18), smoothstep(0.85, 1.0, u))
	if t > 10.0:
		var v := clampf((t - 10.0) / 10.0, 0.0, 1.0)
		c = Color(0.95, 0.80, 0.18).lerp(Color(0.95, 0.12, 0.05), v * 2.0) if v < 0.5 \
				else Color(0.95, 0.12, 0.05).lerp(Color.WHITE, v * 2.0 - 1.0)
	return Color(c.r * ARROW_GLOW, c.g * ARROW_GLOW, c.b * ARROW_GLOW)
