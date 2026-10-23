extends Node3D
## Real-time wormhole for VR: head tracking (physical walking), no stick locomotion, no objects
## to play with; either trigger steps the headset's refresh rate, shown on a panel. Every pixel
## is ray traced along a geodesic of the wormhole space in the shader; this script tracks
## where the viewer is in that curved space.
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
var hands: Array[XRController3D] = []
var trigger_down := false       # a press of either trigger steps the headset's refresh rate
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
	if in_xr:
		for t in [&"left_hand", &"right_hand"]:
			var c := XRController3D.new()
			c.tracker = t
			origin.add_child(c)
			hands.append(c)

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


func _process(_delta: float) -> void:
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
	_rate_button()
	if overlay:
		# the chart -> play map only exists with the feet in the flat part
		overlay.visible = foot_l > space.L

	# head above the feet along the floor normal; the shader moves from the head to each eye
	var hp := space.geodesic(foot_l, foot_n, frame[1], maxf(head.origin.y, 0.05), frame)
	material.set_shader_parameter("head_l", hp[0])
	material.set_shader_parameter("head_n", hp[1])
	material.set_shader_parameter("head_f", PackedVector4Array(hp[2]))
	material.set_shader_parameter("head_pos", head.origin)


## Either trigger: switch the headset to its next refresh rate (after the highest, the lowest).
func _rate_button() -> void:
	var oxr := xr as OpenXRInterface
	if oxr == null:
		return
	var v := 0.0
	for c in hands:
		v = maxf(v, c.get_float(&"trigger"))
	if trigger_down:
		trigger_down = v > 0.3
		return
	if v < 0.7:
		return
	trigger_down = true
	var rates: Array = oxr.get_available_display_refresh_rates()
	if not rates.is_empty():
		oxr.display_refresh_rate = next_rate(rates, oxr.display_refresh_rate)


## The next rate above current, or the lowest after the highest.
static func next_rate(rates: Array, current: float) -> float:
	var sorted := rates.duplicate()
	sorted.sort()
	for r in sorted:
		if r > current + 0.5:
			return r
	return sorted[0]


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


## Things Godot draws itself among the ray-traced ones, placed in chart A coordinates: the
## frame rate panel, 1.5 m straight ahead of the start and above the wormhole, facing it.
func _build_overlay() -> void:
	overlay = Node3D.new()
	origin.add_child(overlay)
	var panel: Label3D = preload("res://perf_panel.gd").new()
	panel.name = "Perf"
	panel.target = xr_view if in_xr else get_viewport()
	panel.xr = xr as OpenXRInterface if in_xr else null
	panel.transform = Transform3D(Basis(Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, 1.0), Vector3(1.0, 0.0, 0.0)),
			Vector3(8.5, 0.0, 2.3))
	overlay.add_child(panel)
	_update_chart_map()


## The stereo check. Godot's standard renderer draws green lines on top of what the ray tracer
## draws: on the white lines of the flat floor and as a grid on three red balls. With one eye
## closed, green must lie exactly on white / on red; two separate grids mean wrong stereo.
func _add_check() -> void:
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
