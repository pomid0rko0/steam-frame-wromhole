class_name Renderer
extends Node3D
## What the eyes see. Two kinds of drawing, each where it is cheap:
##
## - The bodies (the balls, the cubes, the hands' balls, the static objects of scene.json) are
##   meshes rasterized by the GPU (shaders/body.gdshader): every vertex is put where the eye sees
##   it along its geodesic, so a body costs per vertex, and per pixel only its plain colouring. A
##   cube filling the view costs no more than the floor it hides.
## - The floor and the sky behind them: a quad over the whole view at the far plane
##   (shaders/sky_floor.gdshader), drawn after the bodies, so the depth test runs it only where no
##   body is. Each pixel's ray goes to the floor or the sky by the fillet's tables and closed forms
##   (shaders/space.gdshaderinc), the same cost whatever the view.
##
## Every point of the space is seen from an eye along one geodesic at most (docs/geometry.md,
## «Картинка»), so a body is drawn once and the floor hides none. Both shaders find each view's eye
## themselves from the head (set_head) and their own matrices: the stereo pair is exact, whatever
## pose the runtime renders with.
##
## Meshes: a body's mesh is fine enough that its straight edges between vertices stay within a
## fraction of a pixel of the true curves; how fine is chosen each frame by its distance and by how
## close it or the head is to the curved zone (_detail). Each body's mesh instance has its own
## material (its centre, axes, size, colour); Godot's culling is off for them (the shader moves the
## vertices). Opaque draws go by render_priority, lower first: the bodies, then the floor and sky.

const BODY := preload("res://shaders/body.gdshader")
const SKY := [preload("res://shaders/sky_floor.gdshader"), preload("res://shaders/sky_floor_gravity.gdshader")]
const ARROWS := preload("res://shaders/arrows.gdshader")
const GRAVITY_VIEWS := ["off", "floor", "floor and arrows"]
const MAX_BALLS := 12           # the toys' balls and both hands'
const MAX_CUBES := 6
const BACK_PRIORITY := 100      # the floor and sky after every body
# a ball's mesh: radial segments (rings half as many) by detail level; a cube's face: segments a side
const BALL_SEGMENTS := [16, 32, 64, 128]
const CUBE_SEGMENTS := [1, 4, 8, 16]
const STATIC_COLORS := {"spheres_A": [Color(0.80, 0.15, 0.10), Color(0.95, 0.75, 0.15), Color(0.75, 0.75, 0.78)],
		"spheres_B": [Color(0.75, 0.15, 0.70), Color(0.15, 0.75, 0.30), Color(0.20, 0.35, 0.85)],
		"pillars_A": [Color(0.85, 0.80, 0.70)], "boxes_B": [Color(0.90, 0.90, 0.95)]}
# the arrows' sheet (the gravity view "floor and arrows"): l from -reach to reach, the angle a
# from 0 to pi, segments of each
const ARROW_SEG := Vector2i(220, 72)

var space: WormholeSpace
var scene: Dictionary
var xr: XRInterface             # null on the desktop
var xr_view: SubViewport        # where XR renders; null on the desktop
var sky := ShaderMaterial.new()
var back: MeshInstance3D        # the floor and the sky
var balls: Array[MeshInstance3D] = []
var cubes: Array[MeshInstance3D] = []
var statics: Array[MeshInstance3D] = []
var static_meshes: Array = []   # per static object: its mesh at each level of detail
var arrows: MeshInstance3D
var ball_meshes: Array[Mesh] = []
var cube_meshes: Array[Mesh] = []
var gravity_view := 0           # 0 off, 1 the floor coloured by gravity, 2 also arrows of its field
var toy_count := 0              # balls and cubes drawn (set_objects)
var head_point := Vector4.ZERO  # the head in R^4 (set_head): each body's detail
var head_l := 0.0
var head_n := Vector3.RIGHT


func _init(p_space: WormholeSpace, p_scene: Dictionary, p_xr: XRInterface, p_xr_view: SubViewport) -> void:
	space = p_space
	scene = p_scene
	xr = p_xr
	xr_view = p_xr_view


## Under the camera: the floor and sky's quad. The bodies go into the play space, the camera's parent.
func _ready() -> void:
	var g := RenderingServer
	g.global_shader_parameter_set(&"sp_rho0", space.rho0)
	g.global_shader_parameter_set(&"sp_R", space.fillet)
	g.global_shader_parameter_set(&"sp_Lc", space.Lc)
	g.global_shader_parameter_set(&"sp_L", space.L)
	g.global_shader_parameter_set(&"sp_Rout", space.Rout)
	var t0 := Time.get_ticks_msec()
	var tabs := space.shader_tables()
	g.global_shader_parameter_set(&"sp_tab", ImageTexture.create_from_image(tabs[0]))
	g.global_shader_parameter_set(&"sp_ptab", ImageTexture.create_from_image(tabs[1]))
	g.global_shader_parameter_set(&"sp_ytab", ImageTexture.create_from_image(tabs[2]))
	print("renderer: the fillet's tables in %d ms" % (Time.get_ticks_msec() - t0))
	upload_gravity()
	sky.shader = SKY[0]
	sky.render_priority = BACK_PRIORITY
	back = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	back.mesh = quad
	back.material_override = sky
	back.extra_cull_margin = 16384.0
	back.position = Vector3(0.0, 0.0, -1.0)
	add_child(back)
	for n in BALL_SEGMENTS:
		var s := SphereMesh.new()
		s.radius = 1.0
		s.height = 2.0
		s.radial_segments = n
		s.rings = n / 2
		ball_meshes.append(s)
	for n in CUBE_SEGMENTS:
		var b := BoxMesh.new()
		b.size = Vector3(2.0, 2.0, 2.0)
		b.subdivide_width = n - 1
		b.subdivide_height = n - 1
		b.subdivide_depth = n - 1
		cube_meshes.append(b)
	var play := get_parent().get_parent()
	for i in MAX_BALLS:
		balls.append(_body(play, 0))
	for i in MAX_CUBES:
		cubes.append(_body(play, 1))
	_add_statics(play)
	arrows = _arrow_sheet()
	play.add_child(arrows)


## A body's mesh instance with its own material, hidden until used.
func _body(parent: Node, kind: int) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var mat := ShaderMaterial.new()
	mat.shader = BODY
	mat.set_shader_parameter(&"kind", kind)
	m.material_override = mat
	m.extra_cull_margin = 16384.0
	m.visible = false
	parent.add_child(m)
	return m


## scene.json's objects: chart meshes of their universes (kind 2: the mesh's vertices are chart
## positions about its centre), each at every level of detail (set_head picks one).
func _add_statics(parent: Node) -> void:
	for key: String in ["spheres_A", "spheres_B", "pillars_A", "boxes_B"]:
		var rows: Array = scene[key]
		for i in rows.size():
			var o: Array = rows[i]
			var m := _body(parent, 2)
			var mat := m.material_override as ShaderMaterial
			var centre := Vector3(o[0], o[1], o[2])
			var size: float = o[3]
			var levels := []
			for lvl in BALL_SEGMENTS.size():
				var n: int = BALL_SEGMENTS[lvl]
				if key.begins_with("spheres"):
					var sm := SphereMesh.new()
					sm.radius = size
					sm.height = 2.0 * size
					sm.radial_segments = n
					sm.rings = n / 2
					levels.append(sm)
				elif key.begins_with("pillars"):
					var c := CylinderMesh.new()
					c.top_radius = o[2]
					c.bottom_radius = o[2]
					c.height = o[3]
					c.radial_segments = n
					c.rings = n / 4          # along its height: the eye's geodesics bend it near the throat
					levels.append(c)
				else:
					var b := BoxMesh.new()
					var k: int = CUBE_SEGMENTS[lvl]
					b.size = Vector3.ONE * 2.0 * size
					b.subdivide_width = k - 1
					b.subdivide_height = k - 1
					b.subdivide_depth = k - 1
					levels.append(b)
			m.set_meta(&"radius", o[2] if key.begins_with("pillars") else size)
			if key.begins_with("pillars"):
				centre = Vector3(o[0], o[1], 0.5 * o[3])
				size = maxf(o[2], 0.5 * o[3])
			var cols: Array = STATIC_COLORS[key]
			var col: Color = cols[mini(i, cols.size() - 1)]
			var side := 1.0 if key.ends_with("A") else -1.0
			mat.set_shader_parameter(&"centre", Vector4(centre.x, centre.y, centre.z, 0.0))
			mat.set_shader_parameter(&"side", side)
			mat.set_shader_parameter(&"size", size)
			mat.set_shader_parameter(&"color", Vector3(col.r, col.g, col.b))
			# its centre in R^4, for its detail
			var p := space.point_from_chart(side, centre)
			m.set_meta(&"r4", space.embed(p[0], p[1]))
			m.mesh = levels[1]
			m.visible = true
			statics.append(m)
			static_meshes.append(levels)


## The surface n.x = 0 through the throat, above the floor, as a grid in (l, a): VERTEX.xy.
func _arrow_sheet() -> MeshInstance3D:
	var reach := space.L + 4.5
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for j in ARROW_SEG.y + 1:
		for i in ARROW_SEG.x + 1:
			verts.append(Vector3(-reach + 2.0 * reach * i / ARROW_SEG.x, PI * j / ARROW_SEG.y, 0.0))
	for j in ARROW_SEG.y:
		for i in ARROW_SEG.x:
			var a := j * (ARROW_SEG.x + 1) + i
			idx.append_array([a, a + 1, a + ARROW_SEG.x + 1, a + 1, a + ARROW_SEG.x + 2, a + ARROW_SEG.x + 1])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var m := MeshInstance3D.new()
	m.mesh = mesh
	var mat := ShaderMaterial.new()
	mat.shader = ARROWS
	m.material_override = mat
	m.extra_cull_margin = 16384.0
	m.visible = false
	return m


## Each frame: the head in the curved space (l, n), its frame [right, up, back] there and its place
## in the play space (the shaders put each eye there); each body's detail.
func set_head(l: float, n: Vector3, hf: Array, head_pos: Vector3) -> void:
	var g := RenderingServer
	g.global_shader_parameter_set(&"head_l", l)
	g.global_shader_parameter_set(&"head_n", n)
	g.global_shader_parameter_set(&"head_f0", hf[0])
	g.global_shader_parameter_set(&"head_f1", hf[1])
	g.global_shader_parameter_set(&"head_f2", hf[2])
	g.global_shader_parameter_set(&"head_pos", head_pos)
	head_point = space.embed(l, n)
	head_l = l
	head_n = n
	for m in balls:
		if m.visible:
			m.mesh = ball_meshes[_detail(m.material_override as ShaderMaterial)]
	for m in cubes:
		if m.visible:
			var mat := m.material_override as ShaderMaterial
			var c: Vector4 = mat.get_shader_parameter(&"centre")
			var size: float = 1.8 * mat.get_shader_parameter(&"size")
			m.mesh = cube_meshes[_detail_at(c, size) if not _straight(c, size) else 0]
	for i in statics.size():
		var m := statics[i]
		if m.visible:
			var mat := m.material_override as ShaderMaterial
			m.mesh = static_meshes[i][_detail_at(m.get_meta(&"r4"), m.get_meta(&"radius"), mat.get_shader_parameter(&"size"))]


## A body's level of detail, 0..3: a ball of n segments sags pi^2 / 2n^2 of its radius between
## them, under half a pixel (about 1 mrad here) with n about 100 sqrt(radius / distance), the levels'
## 16, 32, 64, 128; the distance: in R^4 on the head's side, through the throat (its radii from the
## centre and the cylinder) on the other. The eye's geodesics bend little over a far body's
## extent, so the curved space adds a level only where they bend most: a body in or near the
## curved zone. A cube's or box's face seen
## straight in a flat universe (sp_toward's own straight case: the head and the body on one side,
## the line between them clear of the curved zone) is drawn exactly by one quad.
func _detail(mat: ShaderMaterial) -> int:
	return _detail_at(mat.get_shader_parameter(&"centre"), mat.get_shader_parameter(&"size"))


## The same for a body at the point c of R^4: size its radius (or half size), reach how far it
## reaches from c.
func _detail_at(c: Vector4, size: float, reach := -1.0) -> int:
	reach = size if reach < 0.0 else reach
	var rc := Vector3(c.x, c.y, c.z).length()
	var far := (c - head_point).length()
	if c.w * head_point.w < 0.0:
		far = maxf(far, rc + Vector3(head_point.x, head_point.y, head_point.z).length() + 2.0 * space.Lc)
	var ratio := size / maxf(far - reach, 0.05)
	var lvl := 0 if ratio < 0.025 else (1 if ratio < 0.1 else (2 if ratio < 0.4 else 3))
	return mini(lvl + 1, 3) if rc < space.Rout + reach + 1.0 else lvl


## Whether the head sees the body at c (size its reach) along straight lines of a flat universe.
func _straight(c: Vector4, size: float) -> bool:
	var hp := head_point
	if absf(head_l) < space.L or hp.w * c.w <= 0.0 or absf(absf(c.w) - space.h) > 1e-3:
		return false
	var a := Vector3(hp.x, hp.y, hp.z)
	var dv := Vector3(c.x, c.y, c.z) - a
	var t := clampf(-a.dot(dv) / maxf(dv.length_squared(), 1e-12), 0.0, 1.0)
	return (a + t * dv).length() > space.Rout + size


## Movable balls (pos: centres as points of R^4, col: colour and radius) and cubes (cpos: centres,
## axes: four per cube, its three body axes and the space's normal there over its half size, ccol:
## colour and half size), at most MAX_BALLS and MAX_CUBES.
func set_objects(pos: PackedVector4Array, col: PackedVector4Array, cpos := PackedVector4Array(),
		axes := PackedVector4Array(), ccol := PackedVector4Array()) -> void:
	toy_count = pos.size() + cpos.size()
	for i in MAX_BALLS:
		var m := balls[i]
		m.visible = i < pos.size()
		if not m.visible:
			continue
		var C := pos[i]
		var p := space.point_from_r4(C)
		var l: float = p[0]
		var n: Vector3 = p[1]
		var u1 := WormholeSpace._normal_to(n)
		var u2 := n.cross(u1)
		var mat := m.material_override as ShaderMaterial
		mat.set_shader_parameter(&"centre", C)
		mat.set_shader_parameter(&"ax0", space.embed_vector(l, n, Vector4(1.0, 0.0, 0.0, 0.0)))
		mat.set_shader_parameter(&"ax1", space.embed_vector(l, n, Vector4(0.0, u1.x, u1.y, u1.z)))
		mat.set_shader_parameter(&"ax2", space.embed_vector(l, n, Vector4(0.0, u2.x, u2.y, u2.z)))
		mat.set_shader_parameter(&"ax3", space.normal4(l, n))
		mat.set_shader_parameter(&"size", col[i].w)
		mat.set_shader_parameter(&"color", Vector3(col[i].x, col[i].y, col[i].z))
		if m.mesh == null:
			m.mesh = ball_meshes[_detail(mat)]
	for i in MAX_CUBES:
		var m := cubes[i]
		m.visible = i < cpos.size()
		if not m.visible:
			continue
		var mat := m.material_override as ShaderMaterial
		mat.set_shader_parameter(&"centre", cpos[i])
		for k in 4:
			mat.set_shader_parameter(&"ax%d" % k, axes[4 * i + k].normalized())
		mat.set_shader_parameter(&"size", ccol[i].w)
		mat.set_shader_parameter(&"color", Vector3(ccol[i].x, ccol[i].y, ccol[i].z))
		if m.mesh == null:
			m.mesh = cube_meshes[_detail(mat)]


## The balls drawn now: colour and radius each (tests).
func drawn_balls() -> PackedVector4Array:
	var out := PackedVector4Array()
	for m in balls:
		if m.visible:
			var mat := m.material_override as ShaderMaterial
			var c: Vector3 = mat.get_shader_parameter(&"color")
			out.append(Vector4(c.x, c.y, c.z, mat.get_shader_parameter(&"size")))
	return out


## The static objects shown or not (the stereo check scene takes them away).
func show_statics(on: bool) -> void:
	for m in statics:
		m.visible = on


## How gravity is shown: GRAVITY_VIEWS (docs/gravity.md, «Показ»).
func set_gravity_view(view: int) -> void:
	gravity_view = clampi(view, 0, GRAVITY_VIEWS.size() - 1)
	sky.shader = SKY[mini(gravity_view, 1)]
	arrows.visible = gravity_view == 2
	print("gravity view: ", GRAVITY_VIEWS[gravity_view])


## Gravity for the gravity views: f / r and f' as the shaders evaluate them
## (WormholeSpace.gravity_shader).
func upload_gravity() -> void:
	var gs := space.gravity_shader()
	RenderingServer.global_shader_parameter_set(&"grav_cyl", gs.cyl)
	RenderingServer.global_shader_parameter_set(&"grav_g0", gs.g[0])
	RenderingServer.global_shader_parameter_set(&"grav_g1", gs.g[1])
	RenderingServer.global_shader_parameter_set(&"grav_d0", gs.d[0])
	RenderingServer.global_shader_parameter_set(&"grav_d1", gs.d[1])


## Eye v's frustum by the runtime's projection: the tangents of its sides' angles off the view
## axis, left, right, bottom, top (negative left of and below the axis).
func frustum(v: int) -> Vector4:
	var p := xr.get_projection_for_view(v, 1.0, Main.NEAR, 100.0)
	var across := Vector2(p.z.x - 1.0, p.z.x + 1.0) / p.x.x
	var up := Vector2(p.z.y - 1.0, p.z.y + 1.0) / p.y.y
	return Vector4(across.x, across.y, up.x, up.y)
