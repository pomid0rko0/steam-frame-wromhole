extends Node3D
## Real-time wormhole for VR: walking in the room is the only way to move; balls roll and
## bounce through the wormhole, cubes slide and stop (ball_world.gd). A moment after the start a
## cube and a ball are thrown; A on the right controller (R on the keyboard) puts everything back
## and throws again. Every pixel is ray traced along a geodesic of the wormhole space in the
## shader; this script tracks where the viewer, the balls and the cubes are in that curved space.
##
## Body model: the feet stay on the floor (the totally geodesic equatorial surface
## n.z = 0). Physical movement in the play space moves the feet along floor geodesics,
## parallel-transporting the play-space axes; the head sits head-height above the feet
## along the floor normal. Each eye is derived in the shader from that view's own
## matrices (see shaders/wormhole.gdshader).

# optozorax's SDF (sphere 0.3, planes +-0.5, union_round 0.1) at 1 unit = 10 m
const THROAT_RADIUS := 3.0
const HALF_LENGTH := 5.0
const FILLET := 1.0
const START_POS := Vector3(10.0, 0.0, 0.0)   # chart A, on the floor
const START_FORWARD := Vector3(-1.0, 0.0, 0.0)
const DESKTOP_HEAD_HEIGHT := 1.6
const MOUSE_SENS := 0.003
# Stereo check (see _add_check): balls in chart A, in front of the start position
const CHECK_BALLS := [Vector3(7.5, -0.5, 1.5), Vector3(8.0, -1.8, 1.1), Vector3(8.3, 1.6, 1.9)]
const CHECK_BALL_RADIUS := 0.3

var space := WormholeSpace.new(THROAT_RADIUS, HALF_LENGTH, FILLET)
var scene: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://scene.json"))
var world := BallWorld.new(space, scene)
var physics := true             # simulate and draw balls and cubes; the stereo check and tests draw their own
var throw_toys := true          # throw a cube and a ball LAUNCH_DELAY s after the start and each reset
var launch_in := -1.0           # seconds until the throw; < 0: none pending
var right_hand: XRController3D
var reset_was := false
var xr: XRInterface
var xr_name := "OpenXR"        # tests use "Native mobile": Godot's own stereo renderer, same multiview path
var in_xr := false

var xr_view: SubViewport       # XR renders here, so the desktop window gets no mirror image
var origin: XROrigin3D
var camera: XRCamera3D
var material: ShaderMaterial

# feet on the floor + transported play-space axes [x, y(up), z(back)]
var foot_l: float
var foot_n: Vector3
var frame: Array
var prev_head := Vector2.ZERO
var recentered := false        # the runtime moved the play space: not a step
var desktop_yaw := 0.0
var desktop_pitch := 0.0
var await_pose := false        # XR: place the viewer once head tracking delivers a pose
var show_check := false         # the stereo check (see _add_check)
var overlay: Node3D            # drawn by Godot itself in chart A coordinates; maps chart A -> play


func _ready() -> void:
	xr = XRServer.find_interface(xr_name)
	var host: Node = self
	if xr and xr.is_initialized():
		in_xr = true
		var oxr := xr as OpenXRInterface
		if oxr:
			oxr.pose_recentered.connect(func() -> void: recentered = true)
		await_pose = true
		# Render XR from a SubViewport. With XR on the root viewport Godot also mirrors the left
		# eye into the desktop window, and SteamVR may show that window on a virtual screen
		# inside the headset. The window shows a notice instead.
		xr_view = SubViewport.new()
		xr_view.use_xr = true
		xr_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(xr_view)
		host = xr_view
		_add_window_notice()

	origin = XROrigin3D.new()
	host.add_child(origin)
	camera = XRCamera3D.new()
	camera.near = 0.05
	origin.add_child(camera)
	right_hand = XRController3D.new()
	right_hand.tracker = &"right_hand"
	origin.add_child(right_hand)

	material = ShaderMaterial.new()
	material.shader = load("res://shaders/wormhole.gdshader")
	material.set_shader_parameter("wh_rho0", space.rho0)
	material.set_shader_parameter("wh_h", space.h)
	material.set_shader_parameter("wh_fillet", space.fillet)
	_upload_scene()
	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(2.0, 2.0)
	quad.mesh = mesh
	quad.material_override = material
	quad.extra_cull_margin = 16384.0
	quad.position = Vector3(0.0, 0.0, -1.0)
	camera.add_child(quad)

	if not in_xr:
		camera.position = Vector3(0.0, DESKTOP_HEAD_HEIGHT, 0.0)
	place(1.0, START_POS, START_FORWARD)
	_build_overlay()
	if show_check:
		_add_check()
	if physics:
		_spawn_toys()


## Put the feet at chart position pos (z = 0) on the given side, looking along forward.
func place(side: float, pos: Vector3, forward: Vector3) -> void:
	var p := space.point_from_chart(side, Vector3(pos.x, pos.y, 0.0))
	foot_l = p[0]
	foot_n = p[1]
	var f := Vector3(forward.x, forward.y, 0.0).normalized()
	var up := Vector3(0.0, 0.0, 1.0)
	var back := -f
	var right := up.cross(back)
	frame = [WormholeSpace.vector_from_chart(side, foot_n, right),
			WormholeSpace.vector_from_chart(side, foot_n, up),
			WormholeSpace.vector_from_chart(side, foot_n, back)]
	# play-space forward is -Z; undo the current head yaw so the view starts along `forward`
	var hf := _head_forward_xz()
	_rotate_frame(-atan2(hf.x, -hf.y))
	prev_head = Vector2(camera.position.x, camera.position.z)
	_update_chart_map()


func _unhandled_input(event: InputEvent) -> void:
	if in_xr:
		return
	if event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		desktop_yaw -= event.relative.x * MOUSE_SENS
		desktop_pitch = clampf(desktop_pitch - event.relative.y * MOUSE_SENS, -1.5, 1.5)
		camera.basis = Basis.from_euler(Vector3(desktop_pitch, desktop_yaw, 0.0))


func _process(delta: float) -> void:
	if await_pose and not camera.transform.is_equal_approx(Transform3D.IDENTITY):
		# the first tracked pose: face the start direction from where the head actually is
		await_pose = false
		place(1.0, START_POS, START_FORWARD)
	var head := camera.transform   # play space (the origin never moves)
	var hz := Vector2(head.origin.x, head.origin.z)
	if recentered:
		prev_head = hz
		recentered = false
		_update_chart_map()
	_walk(hz - prev_head)
	prev_head = hz
	if overlay:
		# the chart -> play map only exists with the feet in the flat part
		overlay.visible = foot_l > space.L

	# head above the feet along the floor normal; the shader moves from the head to each eye
	var hp := space.geodesic(foot_l, foot_n, frame[1], maxf(head.origin.y, 0.05), frame)
	material.set_shader_parameter("head_l", hp[0])
	material.set_shader_parameter("head_n", hp[1])
	material.set_shader_parameter("head_f", PackedVector4Array(hp[2]))
	material.set_shader_parameter("head_pos", head.origin)
	var reset := Input.is_key_pressed(KEY_R) or (in_xr and right_hand.is_button_pressed(&"ax_button"))
	if reset and not reset_was and physics:
		_spawn_toys()
		print("toys: back in place, throwing again")
	reset_was = reset
	if physics and not await_pose:
		if launch_in >= 0.0:
			launch_in -= delta
			if launch_in < 0.0:
				_throw()
		world.step(delta, [])
	if physics:
		_upload_balls()
		_upload_cubes()


const BALL_COLORS := [Color(0.92, 0.25, 0.2), Color(0.2, 0.6, 0.95), Color(0.98, 0.8, 0.2),
		Color(0.3, 0.85, 0.4), Color(0.75, 0.35, 0.9), Color(0.95, 0.55, 0.15)]


const CUBE_COLORS := [Color(0.93, 0.93, 0.88), Color(0.95, 0.45, 0.55), Color(0.35, 0.8, 0.75),
		Color(0.95, 0.7, 0.3), Color(0.55, 0.6, 0.95), Color(0.6, 0.85, 0.35)]
const LAUNCH_DELAY := 1.5


## Everything back in place: the balls and cubes at rest, the throw LAUNCH_DELAY s later.
func _spawn_toys() -> void:
	world.balls.clear()
	world.cubes.clear()
	_spawn_initial_balls()
	_cube_on_floor(Vector2(5.4, -2.5), 0.3, 0.35, CUBE_COLORS[0])
	_cube_on_floor(Vector2(6.2, 3.6), 0.25, -0.5, CUBE_COLORS[2])
	_cube_in_throat(0.8, -0.45, 0.3, CUBE_COLORS[5])
	launch_in = LAUNCH_DELAY if throw_toys else -1.0


## From chest height in front of the start: a tumbling cube that lands to the left of the balls
## and slides to a stop, and a ball that bounces, rolls on and goes through to universe B.
func _throw() -> void:
	var p := space.point_from_chart(1.0, Vector3(9.0, -1.9, 1.4))
	var b := Basis.from_euler(Vector3(0.4, 0.3, 0.2))
	var F := []
	for ax in [b.x, b.y, b.z]:
		F.append(WormholeSpace.vector_from_chart(1.0, p[1], ax))
	world.add_cube(p[0], p[1], WormholeSpace.vector_from_chart(1.0, p[1], Vector3(-2.8, -0.55, 1.0)),
			F, Vector3(2.5, -3.0, 1.5), 0.25, CUBE_COLORS[1])
	var q := space.point_from_chart(1.0, Vector3(9.0, 2.4, 1.4))
	world.add(q[0], q[1], WormholeSpace.vector_from_chart(1.0, q[1], Vector3(-3.0, -0.2, 1.0)), 0.25, BALL_COLORS[5])
	print("toys: thrown")


## A cube resting on the floor of universe A at chart position pos, turned by yaw.
func _cube_on_floor(pos: Vector2, half: float, yaw: float, color: Color) -> Dictionary:
	var p := space.point_from_chart(1.0, Vector3(pos.x, pos.y, half))
	var F := []
	for ax in [Vector3(cos(yaw), sin(yaw), 0.0), Vector3(-sin(yaw), cos(yaw), 0.0), Vector3(0.0, 0.0, 1.0)]:
		F.append(WormholeSpace.vector_from_chart(1.0, p[1], ax))
	return world.add_cube(p[0], p[1], Vector4.ZERO, F, Vector3.ZERO, half, color)


## A cube resting on the floor inside the throat, at l and azimuth phi.
func _cube_in_throat(l: float, phi: float, half: float, color: Color) -> Dictionary:
	var z := half / space.r(l)
	var n := Vector3(cos(phi) * sqrt(1.0 - z * z), sin(phi) * sqrt(1.0 - z * z), z)
	var up := space.height_grad(l, n).normalized()
	var across := WormholeSpace.tangent(n, Vector4(0.0, -sin(phi), cos(phi), 0.0))
	return world.add_cube(l, n, Vector4.ZERO, [Vector4(1.0, 0.0, 0.0, 0.0), up, across], Vector3.ZERO, half, color)


## Five balls resting on the floor between the start and the wormhole.
func _spawn_initial_balls() -> void:
	var spots := [Vector2(7.0, -1.5), Vector2(7.0, 0.0), Vector2(7.0, 1.5), Vector2(6.0, -0.75), Vector2(6.0, 0.75)]
	for i in spots.size():
		var rad := 0.25 if i < 3 else 0.35
		var p := space.point_from_chart(1.0, Vector3(spots[i].x, spots[i].y, rad))
		world.add(p[0], p[1], Vector4.ZERO, rad, BALL_COLORS[i % BALL_COLORS.size()])


## Every ball the shader draws: centre as a point of R^4 and radius (chord distance in R^4).
func _upload_balls() -> void:
	var pos := PackedVector4Array()
	var col := PackedVector4Array()
	for b in world.balls:
		pos.append(space.embed(b["l"], b["n"]))
		var c: Color = b["color"]
		col.append(Vector4(c.r, c.g, c.b, b["radius"]))
	var count := pos.size()
	while pos.size() < 12:
		pos.append(Vector4.ZERO)
		col.append(Vector4.ZERO)
	material.set_shader_parameter("wh_ball", pos)
	material.set_shader_parameter("wh_ballCol", col)
	material.set_shader_parameter("wh_nBall", count)


## Every cube the shader draws: its 4D box (centre, four axes over the half size) and colour.
func _upload_cubes() -> void:
	var pos := PackedVector4Array()
	var axes := PackedVector4Array()
	var col := PackedVector4Array()
	for c in world.cubes:
		var box := world.box4(c)
		var half: float = c["half"]
		pos.append(box[0])
		for k in 4:
			axes.append(box[1 + k] / half)
		var cc: Color = c["color"]
		col.append(Vector4(cc.r, cc.g, cc.b, half))
	var count := pos.size()
	while pos.size() < 6:
		pos.append(Vector4.ZERO)
		col.append(Vector4.ZERO)
	while axes.size() < 24:
		axes.append(Vector4.ZERO)
	material.set_shader_parameter("wh_cube", pos)
	material.set_shader_parameter("wh_cubeE", axes)
	material.set_shader_parameter("wh_cubeCol", col)
	material.set_shader_parameter("wh_nCube", count)


## Move the feet along the floor by a play-space displacement (x, z).
func _walk(step: Vector2) -> void:
	var T: Vector4 = step.x * frame[0] + step.y * frame[2]
	var dist := T.length()
	if dist < 1e-7:
		return
	var res := space.geodesic(foot_l, foot_n, T / dist, dist, frame)
	foot_l = res[0]
	# stay exactly on the floor surface: n.z = 0, up = +z (removes round-off only)
	foot_n = Vector3(res[1].x, res[1].y, 0.0).normalized()
	var fx: Vector4 = WormholeSpace.tangent(foot_n, Vector4(res[2][0].x, res[2][0].y, res[2][0].z, 0.0))
	var fz: Vector4 = WormholeSpace.tangent(foot_n, Vector4(res[2][2].x, res[2][2].y, res[2][2].z, 0.0))
	frame = WormholeSpace.orthonormalize([fx, Vector4(0.0, 0.0, 0.0, 1.0), fz])


func _rotate_frame(angle: float) -> void:
	# positive angle turns the view to the right
	var c := cos(angle)
	var s := sin(angle)
	var fx: Vector4 = frame[0]
	var fz: Vector4 = frame[2]
	frame = [c * fx + s * fz, frame[1], c * fz - s * fx]


func _head_forward_xz() -> Vector2:
	var f := -camera.transform.basis.z
	var v := Vector2(f.x, f.z)
	return v.normalized() if v.length() > 1e-4 else Vector2(0.0, -1.0)


## The node for things Godot draws itself among the ray-traced ones, placed in chart A
## coordinates (the stereo check).
func _build_overlay() -> void:
	overlay = Node3D.new()
	origin.add_child(overlay)
	_update_chart_map()


## The stereo check. Godot's standard renderer draws green lines on top of what the ray tracer
## draws: on the white lines of the flat floor and as a grid on three red balls. With one eye
## closed, green must lie exactly on white / on red; two separate grids mean wrong stereo.
func _add_check() -> void:
	physics = false                 # the check's red balls take the shader's ball slots
	world.balls.clear()
	world.cubes.clear()
	var floor_mat := ShaderMaterial.new()
	floor_mat.shader = load("res://shaders/check_grid.gdshader")
	floor_mat.set_shader_parameter("rout", space.Rout)
	floor_mat.set_shader_parameter("lsh", space.L)
	floor_mat.render_priority = 10
	var bl := PackedVector4Array()
	for c in CHECK_BALLS:
		bl.append(Vector4(c.x, c.y, c.z, CHECK_BALL_RADIUS))
	floor_mat.set_shader_parameter("balls", bl)
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
	for c in CHECK_BALLS:
		pos.append(Vector4(c.x, c.y, c.z, space.h))     # R^4 point of sheet A
		col.append(Vector4(0.85, 0.08, 0.06, CHECK_BALL_RADIUS))
		var s := SphereMesh.new()
		s.radius = CHECK_BALL_RADIUS
		s.height = 2.0 * CHECK_BALL_RADIUS
		s.radial_segments = 48       # outline within 0.7 mm of a true sphere
		s.rings = 24
		var m := MeshInstance3D.new()
		m.name = "Ball%d" % pos.size()
		m.mesh = s
		m.material_override = ball_mat
		m.position = c
		overlay.add_child(m)
	while pos.size() < 12:
		pos.append(Vector4.ZERO)
		col.append(Vector4.ZERO)
	material.set_shader_parameter("wh_ball", pos)
	material.set_shader_parameter("wh_ballCol", col)
	material.set_shader_parameter("wh_nBall", CHECK_BALLS.size())
	# no other objects: Godot's floor lines would be drawn over them where the floor is hidden
	var none_sph := PackedVector4Array()
	var none_pil := PackedVector4Array()
	var none_box := PackedVector4Array()
	for i in 6:
		none_sph.append(Vector4(0.0, 0.0, -100.0, 0.5))      # below the floor
	for i in 4:
		none_pil.append(Vector4(0.0, 0.0, 0.001, -1.0))       # no height
		none_box.append(Vector4(0.0, 0.0, -100.0, 0.5))
	material.set_shader_parameter("wh_sph", none_sph)
	material.set_shader_parameter("wh_pil", none_pil)
	material.set_shader_parameter("wh_box", none_box)


## With the feet in the flat part of sheet A, chart coordinates and the play space differ by a
## rigid motion. It is computed once, from where the feet are placed (and again after a recentre
## of the play space), and then left alone: the overlay is fixed to the room, so if the
## ray-traced world drifted against the room while walking or turning, the stereo check's green
## lines would part from it.
func _update_chart_map() -> void:
	if overlay == null or foot_l <= space.L:
		return
	var fc := space.chart_position(foot_l, foot_n)
	var to_chart := func(U: Vector4) -> Vector3:
		return (U.x * foot_n + Vector3(U.y, U.z, U.w)).normalized()
	# columns: where play x, y, z point in the chart
	var B := Basis(to_chart.call(frame[0]), Vector3(0.0, 0.0, 1.0), to_chart.call(frame[2]))
	var Bt := B.transposed()
	overlay.transform = Transform3D(Bt, Vector3(prev_head.x, 0.0, prev_head.y) - Bt * fc)


func _add_window_notice() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.08)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(bg)
	var label := Label.new()
	label.text = "Wormhole VR is running in the headset.\nIf this screen floats in front of you in VR, close it with the Steam button.\n\nWormhole VR работает в шлеме.\nЕсли этот экран висит перед вами в VR, закройте его кнопкой Steam."
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.add_theme_font_size_override("font_size", 28)
	layer.add_child(label)


## Static objects come from scene.json, the same file the tests read.
func _upload_scene() -> void:
	var to_v4 := func(rows: Array) -> PackedVector4Array:
		var out := PackedVector4Array()
		for r in rows:
			out.append(Vector4(r[0], r[1], r[2], r[3]))
		return out
	material.set_shader_parameter("wh_sph", to_v4.call(scene["spheres_A"] + scene["spheres_B"]))
	material.set_shader_parameter("wh_pil", to_v4.call(scene["pillars_A"]))
	material.set_shader_parameter("wh_box", to_v4.call(scene["boxes_B"]))
	material.set_shader_parameter("wh_nBall", 0)
