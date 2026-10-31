class_name CheckScene
extends RefCounted
## The stereo check: Godot's standard renderer draws green lines on top of what the renderer
## draws (what, and how to read it: README.md, the one-eye check). Godot's geometry is placed in
## chart A coordinates under main's overlay, which main._update_chart_map places (when: its
## comment): if the ray-traced world drifted against the room, green would part from it.

# the balls in chart A, in front of main.START_POS; shaders/check_grid.gdshader's balls[]
# holds as many (build asserts it)
const BALLS := [Vector3(7.5, -0.5, 1.5), Vector3(8.0, -1.8, 1.1), Vector3(8.3, 1.6, 1.9)]
const BALL_RADIUS := 0.3
const BALL_COLOR := Color(0.85, 0.08, 0.06)
# and a magenta cube on the floor, turned (half size, chart A centre, yaw)
const CUBE_HALF := 0.3
const CUBE := Vector3(6.9, 0.9, CUBE_HALF)
const CUBE_YAW := 0.5
const CUBE_COLOR := Color(0.85, 0.1, 0.9)


## Godot's green lines under overlay (nodes Grid, Ball1.., Cube), the red balls and the cube to the
## renderer, and the scene's static objects taken away: Godot's floor lines would be drawn over
## them where the floor is hidden.
static func build(overlay: Node3D, space: WormholeSpace, renderer: Renderer) -> void:
	var floor_mat := ShaderMaterial.new()
	floor_mat.shader = load("res://shaders/check_grid.gdshader")
	assert(floor_mat.shader.code.contains("balls[%d]" % BALLS.size()), "check_grid.gdshader's balls[] holds BALLS")
	floor_mat.set_shader_parameter("rout", space.Rout)
	floor_mat.set_shader_parameter("lsh", space.L)
	floor_mat.render_priority = 10
	var bl := PackedVector4Array()
	for c in BALLS:
		bl.append(Vector4(c.x, c.y, c.z, BALL_RADIUS))
	floor_mat.set_shader_parameter("balls", bl)
	floor_mat.set_shader_parameter("cube", Vector4(CUBE.x, CUBE.y, CUBE.z, sqrt(3.0) * CUBE_HALF))
	var plane := PlaneMesh.new()
	plane.orientation = PlaneMesh.FACE_Z
	plane.size = Vector2(60.0, 60.0)
	var grid := MeshInstance3D.new()
	grid.name = "Grid"
	grid.mesh = plane
	grid.material_override = floor_mat
	grid.position = Vector3(0.0, 0.0, 0.002)
	overlay.add_child(grid)

	var ball_mat := ShaderMaterial.new()
	ball_mat.shader = load("res://shaders/check_ball.gdshader")
	ball_mat.render_priority = 11
	var pos := PackedVector4Array()
	var col := PackedVector4Array()
	for c in BALLS:
		pos.append(Vector4(c.x, c.y, c.z, space.h))     # R^4 point of sheet A
		col.append(Vector4(BALL_COLOR.r, BALL_COLOR.g, BALL_COLOR.b, BALL_RADIUS))
		var s := SphereMesh.new()
		s.radius = BALL_RADIUS
		s.height = 2.0 * BALL_RADIUS
		s.radial_segments = 64
		s.rings = 32
		var m := MeshInstance3D.new()
		m.name = "Ball%d" % pos.size()
		m.mesh = s
		m.material_override = ball_mat
		m.position = c
		overlay.add_child(m)
	# the cube: Godot draws its edges green, the renderer its 4D box (axes over the half size)
	var box := MeshInstance3D.new()
	box.name = "Cube"
	box.mesh = BoxMesh.new()
	box.mesh.size = Vector3.ONE * 2.0 * CUBE_HALF
	box.material_override = ShaderMaterial.new()
	box.material_override.shader = load("res://shaders/check_cube.gdshader")
	box.material_override.set_shader_parameter("half", CUBE_HALF)
	box.material_override.render_priority = 11
	box.transform = Transform3D(Basis(Vector3(0.0, 0.0, 1.0), CUBE_YAW), CUBE)
	overlay.add_child(box)
	var axes := PackedVector4Array([Vector4(cos(CUBE_YAW), sin(CUBE_YAW), 0.0, 0.0),
			Vector4(-sin(CUBE_YAW), cos(CUBE_YAW), 0.0, 0.0), Vector4(0.0, 0.0, 1.0, 0.0), Vector4(0.0, 0.0, 0.0, 1.0)])
	for k in 4:
		axes[k] /= CUBE_HALF
	renderer.set_objects(pos, col, PackedVector4Array([Vector4(CUBE.x, CUBE.y, CUBE.z, space.h)]), axes,
			PackedVector4Array([Vector4(CUBE_COLOR.r, CUBE_COLOR.g, CUBE_COLOR.b, CUBE_HALF)]))
	renderer.show_statics(false)


## The pictures of the stereo test draw only parts of it (tests/multiview_check.gd): the overlay's
## children whose names start with one of these.
static func show_only(overlay: Node3D, names: Array) -> void:
	for c in overlay.get_children():
		c.visible = names.any(func(n: String) -> bool: return String(c.name).begins_with(n))
