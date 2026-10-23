extends Node3D
## Real-time wormhole for VR. Every pixel is ray traced along a geodesic of the wormhole space
## in the shader; this script tracks where the viewer, the hands and the balls are in that
## curved space (balls: ball_world.gd) and handles the controls (button map in the README).
##
## Body model: the feet stay on the floor (the totally geodesic equatorial surface n.z = 0).
## Physical movement in the play space and stick locomotion move the feet along floor
## geodesics, parallel-transporting the play-space axes; snap turns rotate those axes; the
## head sits head-height above the feet along the floor normal. Each eye is derived in the
## shader from that view's own matrices (see shaders/wormhole.gdshader); each hand is placed
## by a geodesic from the head along its play-space offset.

# optozorax's SDF (sphere 0.3, planes +-0.5, union_round 0.1) at 1 unit = 10 m
const THROAT_RADIUS := 3.0
const START_HALF_LENGTH := 5.0
const START_FILLET := 1.0
const HALF_LENGTH_RANGE := Vector2(0.05, 15.0)
const FILLET_RANGE := Vector2(0.05, 2.5)
const GEOMETRY_RATE := 1.5          # metres per second at full stick
const WALK_SPEED := 1.5
const RUN_SPEED := 4.0
const SNAP_ANGLE := deg_to_rad(30.0)
const START_POS := Vector3(10.0, 0.0, 0.0)   # chart A, on the floor
const START_FORWARD := Vector3(-1.0, 0.0, 0.0)
const DESKTOP_HEAD_HEIGHT := 1.6
const MOUSE_SENS := 0.003
# Stereo check (see _add_check): balls in chart A, in front of the start position
const CHECK_BALLS := [Vector3(7.5, -0.5, 1.5), Vector3(8.0, -1.8, 1.1), Vector3(8.3, 1.6, 1.9)]
const CHECK_BALL_RADIUS := 0.3

var space := WormholeSpace.new(THROAT_RADIUS, START_HALF_LENGTH, START_FILLET)
var scene: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://scene.json"))
var world := BallWorld.new(space, scene)
var physics := true             # simulate and draw the balls; the stereo check and tests draw their own
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
var left_hand: XRController3D
var right_hand: XRController3D
var hand_balls: Array = []      # per tracked hand: {l, n, U, radius, tracker}, kinematic spheres
var show_avatar := false        # head and torso as balls (seen in the throat; costly there, see README)
var head_state: Array = []      # [l, n, frame] of the head, this frame
var grip_was := {}
var button_was := {}
var snap_armed := true
var logged_profiles := {}
var input_log_time := 0.0
var overlay: Node3D            # drawn by Godot itself in chart A coordinates; maps chart A -> play


func _ready() -> void:
	xr = XRServer.find_interface(xr_name)
	var host: Node = self
	if xr and xr.is_initialized():
		in_xr = true
		var oxr := xr as OpenXRInterface
		if oxr:
			oxr.pose_recentered.connect(func() -> void: recentered = true)
			# for godot.log: input reaches the app only while the session is focused (an open
			# SteamVR dashboard takes the focus away)
			oxr.session_visible.connect(func() -> void: print("XR session visible (no input focus: dashboard open?)"))
			oxr.session_focussed.connect(func() -> void: print("XR session focused: controller input active"))
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
	left_hand = XRController3D.new()
	left_hand.tracker = &"left_hand"
	origin.add_child(left_hand)
	right_hand = XRController3D.new()
	right_hand.tracker = &"right_hand"
	origin.add_child(right_hand)

	material = ShaderMaterial.new()
	material.shader = load("res://shaders/wormhole.gdshader")
	_upload_geometry()
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
		_spawn_initial_balls()


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
	if in_xr:
		_log_input(delta)
	var moved := _handle_turn_and_reset()
	_handle_geometry(delta)

	var head := camera.transform   # play space (the origin never moves)
	var hz := Vector2(head.origin.x, head.origin.z)
	if recentered:
		prev_head = hz
		recentered = false
		moved = true
	var step := hz - prev_head
	prev_head = hz
	var stick := _move_input()
	if stick.length() > 0.15:
		var fwd := _head_forward_xz()
		var rgt := Vector2(-fwd.y, fwd.x)
		var speed := RUN_SPEED if _run_pressed() else WALK_SPEED
		step += (stick.y * fwd + stick.x * rgt) * speed * delta
		moved = true
	_walk(step)
	if moved:
		# the controls moved the world against the room; physical walking does not
		_update_chart_map()
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
	head_state = hp
	_update_hands(head)
	if physics:
		_handle_toys()
		world.step(delta, hand_balls)
		_upload_balls()


## Writes the controllers' interaction profiles and stick values to godot.log.
func _log_input(delta: float) -> void:
	for hand in [left_hand, right_hand]:
		var tracker := XRServer.get_tracker(hand.tracker) as XRControllerTracker
		var profile: String = tracker.profile if tracker else "(no tracker)"
		if logged_profiles.get(hand.tracker, "") != profile:
			logged_profiles[hand.tracker] = profile
			print(hand.tracker, " interaction profile: ", profile)
	input_log_time -= delta
	var ls := left_hand.get_vector2(&"primary")
	var rs := right_hand.get_vector2(&"primary")
	if input_log_time <= 0.0 and (ls.length() > 0.2 or rs.length() > 0.2):
		input_log_time = 2.0
		print("sticks left ", ls, " right ", rs, " grip ", right_hand.get_float(&"grip"))


const BALL_COLORS := [Color(0.92, 0.25, 0.2), Color(0.2, 0.6, 0.95), Color(0.98, 0.8, 0.2),
		Color(0.3, 0.85, 0.4), Color(0.75, 0.35, 0.9), Color(0.95, 0.55, 0.15)]


## Five balls resting on the floor between the start and the wormhole.
func _spawn_initial_balls() -> void:
	var spots := [Vector2(7.0, -1.5), Vector2(7.0, 0.0), Vector2(7.0, 1.5), Vector2(6.0, -0.75), Vector2(6.0, 0.75)]
	for i in spots.size():
		var rad := 0.25 if i < 3 else 0.35
		var p := space.point_from_chart(1.0, Vector3(spots[i].x, spots[i].y, rad))
		world.add(p[0], p[1], Vector4.ZERO, rad, BALL_COLORS[i % BALL_COLORS.size()])


## Every ball the shader draws: centre as a point of R^4 and radius (chord distance in R^4).
## The balls, the hands, then the avatar's head and torso.
func _upload_balls() -> void:
	var pos := PackedVector4Array()
	var col := PackedVector4Array()
	for b in world.balls:
		pos.append(space.embed(b["l"], b["n"]))
		var c: Color = b["color"]
		col.append(Vector4(c.r, c.g, c.b, b["radius"]))
	for hnd in hand_balls:
		pos.append(space.embed(hnd["l"], hnd["n"]))
		col.append(Vector4(0.95, 0.6, 0.25, hnd["radius"]))
	if show_avatar and head_state.size() > 0:
		pos.append(space.embed(head_state[0], head_state[1]))
		col.append(Vector4(0.85, 0.87, 0.9, 0.11))
		var torso := space.geodesic(head_state[0], head_state[1], -head_state[2][1], 0.5, [])
		pos.append(space.embed(torso[0], torso[1]))
		col.append(Vector4(0.35, 0.42, 0.55, 0.19))
	var count := pos.size()
	while pos.size() < 12:
		pos.append(Vector4.ZERO)
		col.append(Vector4.ZERO)
	material.set_shader_parameter("wh_ball", pos)
	material.set_shader_parameter("wh_ballCol", col)
	material.set_shader_parameter("wh_nBall", count)


## Left X: switch the headset to its next refresh rate (after the highest, the lowest).
func _rate_button() -> void:
	var oxr := xr as OpenXRInterface
	if oxr == null or not _pressed_once("rate", left_hand.is_button_pressed(&"ax_button")):
		return
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


## Hand points on the manifold (geodesic from the head), their velocities, grabbing.
func _update_hands(head: Transform3D) -> void:
	hand_balls.clear()
	for c: XRController3D in [left_hand, right_hand]:
		var xf: Transform3D
		var vel := Vector3.ZERO
		if in_xr:
			if not c.get_has_tracking_data():
				continue
			xf = c.transform
			var pose := c.get_pose()
			if pose:
				vel = pose.linear_velocity
		else:
			var side := -1.0 if c == left_hand else 1.0
			xf = Transform3D(head.basis, head.origin + head.basis * Vector3(0.22 * side, -0.32, -0.38))
		var off := xf.origin - head.origin
		var hp: Array = head_state
		if off.length() > 1e-6:
			var dir := WormholeSpace.combine(head_state[2], off)
			hp = space.geodesic(head_state[0], head_state[1], dir / dir.length(), dir.length(), head_state[2])
		var U := WormholeSpace.combine(hp[2], vel)
		var hand := {"l": hp[0], "n": hp[1], "U": U, "radius": 0.05, "tracker": c.tracker}
		hand_balls.append(hand)
		# grab with grip, release to throw
		var grip := in_xr and c.get_float(&"grip") > 0.6
		var was: bool = grip_was.get(c.tracker, false)
		grip_was[c.tracker] = grip
		if grip and not was:
			var best: Dictionary = {}
			var best_gap := 0.12
			for b in world.balls:
				var g := world.gap(b, hand)
				if g < best_gap:
					best_gap = g
					best = b
			if not best.is_empty():
				best["held"] = c.tracker
		for b in world.balls:
			if b["held"] == c.tracker:
				if grip:
					b["l"] = hand["l"]
					b["n"] = hand["n"]
					b["U"] = U
				else:
					b["held"] = &""


func _pressed_once(key: String, down: bool) -> bool:
	var was: bool = button_was.get(key, false)
	button_was[key] = down
	return down and not was


func _handle_toys() -> void:
	# right B / key F: new ball (at the right hand in VR, thrown forward on the desktop)
	var spawn := _pressed_once("spawn", Input.is_key_pressed(KEY_F) or (in_xr and right_hand.is_button_pressed(&"by_button")))
	if spawn and head_state.size() > 0:
		var col: Color = BALL_COLORS[randi() % BALL_COLORS.size()]
		if in_xr and hand_balls.size() > 0:
			var hnd: Dictionary = hand_balls[hand_balls.size() - 1]
			world.add(hnd["l"], hnd["n"], hnd["U"], 0.25, col)
		else:
			var fwd := WormholeSpace.combine(head_state[2], -camera.transform.basis.z)
			var start := space.geodesic(head_state[0], head_state[1], fwd, 0.6, [fwd])
			world.add(start[0], start[1], 7.0 * start[2][0] + 2.0 * head_state[2][1], 0.25, col)
	# left Y / key T: avatar on/off
	if _pressed_once("avatar", Input.is_key_pressed(KEY_T) or (in_xr and left_hand.is_button_pressed(&"by_button"))):
		show_avatar = not show_avatar


## Throat half-length h (planes at w = +-h) and fillet radius (union_round radius).
## Points keep their distance to the edge of the curved shell, so nothing moves when only h
## changes and the outside world shifts with the mouth when the fillet changes. Chart
## positions of the feet stay put, so the overlay's chart -> play map stays valid.
func set_geometry(half_length: float, fillet_radius: float) -> void:
	var old_L := space.L
	space.set_profile(THROAT_RADIUS, half_length, fillet_radius)
	foot_l = signf(foot_l) * maxf(absf(foot_l) - old_L + space.L, 0.0)
	for b in world.balls:
		b["l"] = signf(b["l"]) * maxf(absf(b["l"]) - old_L + space.L, 0.0)
	_upload_geometry()


func _upload_geometry() -> void:
	material.set_shader_parameter("wh_rho0", space.rho0)
	material.set_shader_parameter("wh_h", space.h)
	material.set_shader_parameter("wh_fillet", space.fillet)
	var grid := overlay.get_node_or_null("Grid") if overlay else null
	if grid:
		grid.material_override.set_shader_parameter("rout", space.Rout)
		grid.material_override.set_shader_parameter("lsh", space.L)


## Right stick up/down: throat length; with the right grip held: fillet radius.
func _handle_geometry(delta: float) -> void:
	var y := float(Input.is_key_pressed(KEY_X)) - float(Input.is_key_pressed(KEY_Z))
	var yr := float(Input.is_key_pressed(KEY_V)) - float(Input.is_key_pressed(KEY_C))
	if in_xr:
		var stick := right_hand.get_vector2(&"primary").y
		if absf(stick) > 0.2:
			if right_hand.get_float(&"grip") > 0.5:
				yr += stick
			else:
				y += stick
	if y == 0.0 and yr == 0.0:
		return
	set_geometry(clampf(space.h + y * GEOMETRY_RATE * delta, HALF_LENGTH_RANGE.x, HALF_LENGTH_RANGE.y),
			clampf(space.fillet + yr * 0.5 * GEOMETRY_RATE * delta, FILLET_RANGE.x, FILLET_RANGE.y))


func _move_input() -> Vector2:
	var v := Vector2.ZERO
	if in_xr:
		v = left_hand.get_vector2(&"primary")
	v.x += float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A))
	v.y += float(Input.is_key_pressed(KEY_W)) - float(Input.is_key_pressed(KEY_S))
	return v.limit_length(1.0)


func _run_pressed() -> bool:
	return Input.is_key_pressed(KEY_SHIFT) or (in_xr and left_hand.get_float(&"trigger") > 0.5)


## Right stick left/right: snap turn. Right A / key R: back to the start. True if either moved
## the viewer against the room.
func _handle_turn_and_reset() -> bool:
	var turn := 0.0
	if in_xr:
		turn = right_hand.get_vector2(&"primary").x
	turn += float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q))
	var moved := false
	if absf(turn) > 0.7 and snap_armed:
		_rotate_frame(signf(turn) * SNAP_ANGLE)
		snap_armed = false
		moved = true
	elif absf(turn) < 0.3:
		snap_armed = true
	if _pressed_once("reset", Input.is_key_pressed(KEY_R) or (in_xr and right_hand.is_button_pressed(&"ax_button"))):
		set_geometry(START_HALF_LENGTH, START_FILLET)
		place(1.0, START_POS, START_FORWARD)
		if physics:
			world.balls.clear()
			_spawn_initial_balls()
	return moved


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
	panel.rate_hint = "X"
	panel.transform = Transform3D(Basis(Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, 1.0), Vector3(1.0, 0.0, 0.0)),
			Vector3(8.5, 0.0, 2.3))
	overlay.add_child(panel)
	_update_chart_map()


## The stereo check. Godot's standard renderer draws green lines on top of what the ray tracer
## draws: on the white lines of the flat floor and as a grid on three red balls. With one eye
## closed, green must lie exactly on white / on red; two separate grids mean wrong stereo.
func _add_check() -> void:
	physics = false                 # the check's red balls take the shader's ball slots
	world.balls.clear()
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
