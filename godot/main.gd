extends Node3D
## Real-time wormhole for VR (README.md, docs/). Every pixel is ray traced along a geodesic of
## the wormhole space in the shader (tracer.gd); this script builds the scene and tracks where the
## viewer is in that curved space: walking in the room, the left stick walks, the right stick
## turns, smoothly or in 30-degree snaps, A goes back to the start (README.md, «Управление»).
##
## Body model: the feet stay on the floor (the totally geodesic equatorial surface n.z = 0).
## Physical movement in the play space and stick locomotion move the feet along floor geodesics,
## parallel-transporting the play-space axes; stick turns rotate those axes; the head sits
## head-height above the feet along the floor normal. Each eye is derived in the shader from that
## view's own matrices (shaders/wormhole_view.gdshaderinc).
##
## The parts: the ray tracer (tracer.gd), the demo's balls and cubes in gravity through the
## wormhole (toys.gd, ball_world.gd), the hands that grab and throw them (hands.gd), foveated
## rendering (foveation.gd), the menu and the line under it (menu.gd) with the measured frame rate
## (frame_rate.gd), the speed check (bench.gd) and the stereo check scene (check_scene.gd). Each
## frame (_process): the menu takes its buttons, then the turn, the reset and the gravity view's
## button, the walk, the free toys (pushed by the hands where they were), the hands and what they
## hold, and last the toys and the head to the ray tracer: a toy let go now starts from the hand.

# optozorax's SDF (sphere 0.3, planes +-0.5, union_round 0.1) at 1 unit = 10 m
const THROAT_RADIUS := 3.0
const HALF_LENGTH := 5.0
const FILLET := 1.0
const WALK_SPEED := 1.5             # metres per second at full stick
const RUN_SPEED := 4.0
const STICK_DEAD_ZONE := 0.15
const SNAP_ANGLE := deg_to_rad(30.0)
const SMOOTH_TURN_SPEED := deg_to_rad(90.0)   # per second at full stick
const START_POS := Vector3(10.0, 0.0, 0.0)   # chart A, on the floor
const START_FORWARD := Vector3(-1.0, 0.0, 0.0)
const NEAR := 0.05                  # m: the camera's near plane (less than Tracer.PROXY_MARGIN)
const DESKTOP_HEAD_HEIGHT := 1.6
const MOUSE_SENS := 0.003
const CHECK_FLAG := "res://check"   # present in a build: the stereo check scene is on (not in git)
const GAZE_DOT_DIST := 1.5          # m along the gaze: where the gaze dot is drawn

var space := WormholeSpace.new(THROAT_RADIUS, HALF_LENGTH, FILLET)
var scene: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://scene.json"))
var toys := Toys.new(space, scene)
var hands := Hands.new(space, toys.world)
var xr_name := "OpenXR"         # tests: "FakeHMD" (tests/fake_hmd.gd), "Native mobile", "none" (the desktop)
var show_check := FileAccess.file_exists(CHECK_FLAG)
var xr: XRInterface
var in_xr := false
var xr_view: SubViewport        # XR renders here, so the desktop window gets no mirror image
var origin: XROrigin3D
var camera: XRCamera3D
var tracer: Tracer
var foveation: Foveation
var rate: FrameRate
var menu: Menu
var bench: Bench
var overlay: Node3D             # the stereo check's: drawn by Godot in chart A coordinates, fixed to the room
var left_hand: XRController3D   # at their aim pose: the buttons and sticks (XR only)
var right_hand: XRController3D
var gaze: XRNode3D              # where the eyes look (XR_EXT_eye_gaze_interaction), XR only
var gaze_dot: MeshInstance3D    # drawn where they look, if the menu says so
# feet on the floor + transported play-space axes [x, y(up), z(back)]
var foot_l: float
var foot_n: Vector3
var frame: Array
var prev_head := Vector2.ZERO
var recentered := false         # the runtime moved the play space: not a step
var await_pose := false         # XR: place the viewer once head tracking delivers a pose
var hold := false               # the speed check: the feet stay while the head moves, sticks, A and the hands do nothing
var view_pitch := 0.0           # degrees: the view turned up and about the line of sight on top of
var view_roll := 0.0            # the head's own (the speed check; the head stays where it is)
var desktop_yaw := 0.0
var desktop_pitch := 0.0
var smooth_turn := true         # false: 30-degree snaps; a right stick click switches
var snap_armed := true          # the right stick went back to the middle since the last turn
var menu_active := false        # the menu was open this frame: A, B, the D-pad and the left stick are its
var was := {}                   # buttons down last frame (_pressed)
var logged_profiles := {}


func _ready() -> void:
	xr = XRServer.find_interface(xr_name)
	var host: Node = self
	if xr and xr.is_initialized():
		in_xr = true
		var oxr := xr as OpenXRInterface
		if oxr:
			# methods, not lambdas: a lambda left connected to the interface corrupted memory at exit
			oxr.pose_recentered.connect(_on_recentered)
			# for godot.log: input reaches the app only while the session is focused (an open
			# SteamVR dashboard takes the focus away)
			oxr.session_visible.connect(_on_session_visible)
			oxr.session_focussed.connect(_on_session_focussed)
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
	else:
		xr = null
	var target: Viewport = xr_view if in_xr else get_viewport()
	foveation = Foveation.new(target, xr)

	origin = XROrigin3D.new()
	host.add_child(origin)
	camera = XRCamera3D.new()
	camera.near = NEAR
	camera.compositor = Compositor.new()
	camera.compositor.compositor_effects = [foveation.split_pass]
	origin.add_child(camera)
	if in_xr:
		_add_controllers()
	else:
		camera.position = Vector3(0.0, DESKTOP_HEAD_HEIGHT, 0.0)
	tracer = Tracer.new(space, scene, xr, xr_view)
	camera.add_child(tracer)

	rate = FrameRate.new()
	rate.main = self
	rate.target = target
	rate.xr = xr as OpenXRInterface
	add_child(rate)
	bench = Bench.new()
	bench.main = self
	menu = Menu.new()
	menu.main = self
	menu.rate = rate
	menu.target = target
	menu.xr = xr as OpenXRInterface
	menu.head = camera
	bench.menu = menu
	add_child(bench)                # first: the menu's last row asks it what it compares
	origin.add_child(menu)

	place(START_POS, START_FORWARD)
	if show_check:
		toys.enabled = false            # the check's red balls take the shader's ball slots
		overlay = Node3D.new()
		origin.add_child(overlay)
		CheckScene.build(overlay, space, tracer)
		_update_chart_map()
	elif toys.enabled:
		toys.spawn()
		draw_toys()


## The controllers, at their aim pose (the buttons and sticks) and at their grip pose (the hands),
## and the eyes' gaze with its dot.
func _add_controllers() -> void:
	for t in [&"left_hand", &"right_hand"]:
		var c := XRController3D.new()
		c.tracker = t
		c.pose = &"aim"
		origin.add_child(c)
		var g := XRController3D.new()
		g.tracker = t
		g.pose = &"grip"           # where the hand holds the controller: what it grabs with
		origin.add_child(g)
		hands.grips.append(g)
		if t == &"left_hand":
			left_hand = c
		else:
			right_hand = c
	# the eyes' gaze, from SteamVR's eye tracking: in the log's lines, and a dot drawn there on
	# request (the menu), to see whether the sharp middle of the foveation follows it
	gaze = XRNode3D.new()
	gaze.tracker = &"/user/eyes_ext"
	gaze.pose = &"eye_gaze_pose"
	origin.add_child(gaze)
	gaze_dot = MeshInstance3D.new()
	var dot := SphereMesh.new()
	dot.radius = 0.006
	dot.height = 0.012
	gaze_dot.mesh = dot
	var dot_mat := StandardMaterial3D.new()
	dot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dot_mat.albedo_color = Color(1.0, 0.15, 0.9)
	dot_mat.no_depth_test = true
	dot_mat.render_priority = 24
	gaze_dot.material_override = dot_mat
	gaze_dot.visible = false
	origin.add_child(gaze_dot)


func _process(delta: float) -> void:
	if await_pose and not camera.transform.is_equal_approx(Transform3D.IDENTITY):
		# the first tracked pose: face the start direction from where the head actually is
		await_pose = false
		place(START_POS, START_FORWARD)
	if in_xr:
		_log_profiles()
	# stick motion over at most 0.1 s: a long frame (back from the SteamVR dashboard) is no leap
	var dt := minf(delta, 0.1)
	menu_active = menu.handle_input(dt)
	var moved := false if hold else _turn_and_reset(dt)
	# the D-pad up, left or right (left Y on other controllers) / G: the next gravity view (not
	# during the speed check: it times what it set up)
	var grav_down := Input.is_key_pressed(KEY_G)
	if in_xr:
		for b in [&"by_button", &"dpad_up", &"dpad_left", &"dpad_right"]:
			grav_down = grav_down or left_hand.is_button_pressed(b)
	if _pressed("gravity", grav_down) and not hold and not menu_active:
		set_gravity_view((tracer.gravity_view + 1) % Tracer.GRAVITY_VIEWS.size())

	var head := camera.transform   # play space (the origin never moves)
	var hz := Vector2(head.origin.x, head.origin.z)
	if recentered:
		prev_head = hz
		recentered = false
		moved = true
	var step := hz - prev_head
	prev_head = hz
	var stick := Vector2.ZERO if hold or menu_active else _move_input()
	if stick.length() > STICK_DEAD_ZONE:
		# along the stick, relative to where the head looks
		var fwd := _head_forward_xz()
		var rgt := Vector2(-fwd.y, fwd.x)
		var speed := RUN_SPEED if _run_pressed() else WALK_SPEED
		step += (stick.y * fwd + stick.x * rgt) * speed * dt
		moved = true
	if not hold:
		_walk(step)
	if moved:
		# the controls moved the world against the room; physical walking does not
		_update_chart_map()
	if gaze_dot and gaze_dot.visible:
		gaze_dot.position = gaze.transform.origin - gaze.transform.basis.z * GAZE_DOT_DIST
	if overlay:
		# the chart -> play map only exists with the feet in the flat part
		overlay.visible = foot_l > space.L

	# head above the feet along the floor normal; the shader moves from the head to each eye
	var hp := space.geodesic(foot_l, foot_n, frame[1], maxf(head.origin.y, 0.05), frame)
	var hf: Array = hp[2]
	if view_pitch != 0.0 or view_roll != 0.0:
		hf = _tilt(hf, deg_to_rad(view_pitch), deg_to_rad(view_roll))
	# the free toys up to this frame (pushed by the hands where they were), then the hands and
	# what they hold to this frame: a toy let go now starts from where the hand has it. Nothing
	# during the speed check: it times the same scene at every pose.
	var active := toys.enabled and not await_pose and not hold
	if active:
		toys.step(delta, hands.balls())
	var new_ball := in_xr and _pressed("new_ball", right_hand.is_button_pressed(&"by_button")) and not menu_active
	var new_cube := in_xr and _pressed("new_cube", left_hand.is_button_pressed(&"ax_button")
			or left_hand.is_button_pressed(&"dpad_down")) and not menu_active
	hands.update(delta, hp, head, active, new_ball, new_cube)
	if toys.enabled:
		draw_toys()
	tracer.set_head(hp[0], hp[1], hf, head.origin)


## The toys and the hands to the ray tracer.
func draw_toys() -> void:
	toys.draw(tracer, hands.drawn())


## Put the feet at chart A position pos (z = 0), looking along forward.
func place(pos: Vector3, forward: Vector3) -> void:
	var p := space.point_from_chart(1.0, Vector3(pos.x, pos.y, 0.0))
	foot_l = p[0]
	foot_n = p[1]
	var f := Vector3(forward.x, forward.y, 0.0).normalized()
	var up := Vector3(0.0, 0.0, 1.0)
	var back := -f
	var right := up.cross(back)
	frame = [WormholeSpace.vector_from_chart(1.0, foot_n, right),
			WormholeSpace.vector_from_chart(1.0, foot_n, up),
			WormholeSpace.vector_from_chart(1.0, foot_n, back)]
	_face_head()
	hands.forget_motion()


## Put the feet at l on the axis through the throat (n = +x), looking yaw degrees to the right of
## the throat (the head's own yaw is taken out), and turn the view pitch degrees up and roll
## degrees about the line of sight (right side down) on top of the head's own: the speed check.
func place_on_axis(l: float, yaw := 0.0, pitch := 0.0, roll := 0.0) -> void:
	foot_l = l
	foot_n = Vector3(1.0, 0.0, 0.0)
	# right, up, back as (U_l, u): facing the throat, back is +l and right is +y of chart A
	frame = [Vector4(0.0, 0.0, 1.0, 0.0), Vector4(0.0, 0.0, 0.0, 1.0), Vector4(1.0, 0.0, 0.0, 0.0)]
	_rotate_frame(deg_to_rad(yaw))
	_face_head()
	hands.forget_motion()
	view_pitch = pitch
	view_roll = roll


## Where the feet are and the frame there, to come back to (set_pose).
func get_pose() -> Array:
	return [foot_l, foot_n, frame.duplicate()]


func set_pose(p: Array) -> void:
	foot_l = p[0]
	foot_n = p[1]
	frame = p[2].duplicate()
	view_pitch = 0.0
	view_roll = 0.0
	prev_head = Vector2(camera.position.x, camera.position.z)
	_update_chart_map()
	hands.forget_motion()


## Where the head looks: degrees from the direction to the throat along the floor, and degrees up.
func look_angles() -> Vector2:
	var f := -camera.transform.basis.z
	var T: Vector4 = f.x * frame[0] + f.z * frame[2]     # along the floor, as (U_l, u)
	var toward := -1.0 if foot_l > 0.0 else 1.0          # the throat is where |l| decreases
	var h := T.length()
	var yaw := rad_to_deg(acos(clampf(toward * T.x / h, -1.0, 1.0))) if h > 1e-6 else 0.0
	return Vector2(yaw, rad_to_deg(asin(clampf(f.y, -1.0, 1.0))))


## Where the eyes look against where the head looks: degrees right and up, or null while there
## is no gaze (no eye tracking, or it lost the eyes).
func gaze_angles() -> Variant:
	if gaze == null or not gaze.get_has_tracking_data():
		return null
	var d: Vector3 = camera.transform.basis.inverse() * -gaze.transform.basis.z
	return Vector2(rad_to_deg(atan2(d.x, -d.z)), rad_to_deg(asin(clampf(d.y, -1.0, 1.0))))


## The same for the log.
func gaze_text() -> String:
	var g: Variant = gaze_angles()
	return "none" if g == null else "%.0f deg right %.0f deg up" % [g.x, g.y]


## How gravity is shown (Tracer.set_gravity_view): the menu's row, the D-pad up, G.
func set_gravity_view(view: int) -> void:
	tracer.set_gravity_view(view)
	menu.refresh()


## Turns smoothly or in 30-degree snaps (the right stick's click switches, as does the menu).
func set_smooth_turn(on: bool) -> void:
	smooth_turn = on
	print("right stick turns ", "smoothly" if smooth_turn else "in 30-degree snaps")
	menu.refresh()


## Turn the frame so that the head's current yaw looks along its forward (play-space forward
## is -Z), and take the head's place in the room from here.
func _face_head() -> void:
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


func _on_recentered() -> void:
	recentered = true


func _on_session_visible() -> void:
	print("XR session visible (no input focus: dashboard open?)")


func _on_session_focussed() -> void:
	print("XR session focused: controller input active")


## The controllers' interaction profiles, to godot.log when they change: which bindings the
## runtime took (docs/steam-frame.md, «Что надо знать о SteamVR на шлеме»).
func _log_profiles() -> void:
	for hand: XRController3D in [left_hand, right_hand]:
		var tracker := XRServer.get_tracker(hand.tracker) as XRControllerTracker
		var profile: String = tracker.profile if tracker else "(no tracker)"
		if logged_profiles.get(hand.tracker, "") != profile:
			logged_profiles[hand.tracker] = profile
			print(hand.tracker, " interaction profile: ", profile)


func _pressed(key: String, down: bool) -> bool:
	var before: bool = was.get(key, false)
	was[key] = down
	return down and not before


## Left stick / WASD: x right, y forward.
func _move_input() -> Vector2:
	var v := Vector2.ZERO
	if in_xr:
		v = left_hand.get_vector2(&"primary")
	v.x += float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A))
	v.y += float(Input.is_key_pressed(KEY_W)) - float(Input.is_key_pressed(KEY_S))
	return v.limit_length(1.0)


## Left trigger / Shift.
func _run_pressed() -> bool:
	if Input.is_key_pressed(KEY_SHIFT):
		return true
	return in_xr and left_hand.get_float(&"trigger") > 0.5


## Right stick left/right (Q / E): turn around the head, smoothly (speed follows the stick) or
## in 30-degree snaps; a right stick click (Tab) switches between the two. Right A (R): back to
## the start, the toys back in place and the hands empty (not while the menu is open: A is its).
## True if any of it moved the viewer against the room.
func _turn_and_reset(delta: float) -> bool:
	var turn := 0.0
	var mode_down := Input.is_key_pressed(KEY_TAB)
	if in_xr:
		turn = right_hand.get_vector2(&"primary").x
		mode_down = mode_down or right_hand.is_button_pressed(&"primary_click")
	turn = clampf(turn + float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q)), -1.0, 1.0)
	if _pressed("turn_mode", mode_down):
		set_smooth_turn(not smooth_turn)
	var moved := false
	if smooth_turn:
		if absf(turn) > STICK_DEAD_ZONE:
			# from zero at the dead zone's edge to full speed at full stick
			var amount := (absf(turn) - STICK_DEAD_ZONE) / (1.0 - STICK_DEAD_ZONE)
			_rotate_frame(signf(turn) * amount * SMOOTH_TURN_SPEED * delta)
			moved = true
		# a switch to snaps while the stick is out waits for it to come back first
		snap_armed = absf(turn) < 0.3
	elif absf(turn) > 0.7 and snap_armed:
		_rotate_frame(signf(turn) * SNAP_ANGLE)
		hands.forget_motion()           # the hands jump with the world: no throw
		snap_armed = false
		moved = true
	elif absf(turn) < 0.3:
		snap_armed = true
	if _pressed("reset", Input.is_key_pressed(KEY_R) or (in_xr and right_hand.is_button_pressed(&"ax_button"))) and not menu_active:
		place(START_POS, START_FORWARD)    # also redoes the chart -> play map
		if toys.enabled:
			hands.empty()
			toys.spawn()
			print("toys: back in place, throwing again")
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


## The head's frame [right, up, back] turned pitch up, then roll about the line of sight.
static func _tilt(f: Array, pitch: float, roll: float) -> Array:
	var c := cos(pitch)
	var s := sin(pitch)
	var up: Vector4 = c * f[1] + s * f[2]
	var back: Vector4 = c * f[2] - s * f[1]
	var cr := cos(roll)
	var sr := sin(roll)
	return [cr * f[0] + sr * up, cr * up - sr * f[0], back]


## Turn the frame about the floor's normal; a positive angle turns the view to the right.
func _rotate_frame(angle: float) -> void:
	var c := cos(angle)
	var s := sin(angle)
	var fx: Vector4 = frame[0]
	var fz: Vector4 = frame[2]
	# a smooth turn rotates a little every frame: keep round-off from adding up
	frame = WormholeSpace.orthonormalize([c * fx + s * fz, frame[1], c * fz - s * fx])


func _head_forward_xz() -> Vector2:
	var f := -camera.transform.basis.z
	var v := Vector2(f.x, f.z)
	return v.normalized() if v.length() > 1e-4 else Vector2(0.0, -1.0)


## With the feet in the flat part of sheet A, chart coordinates and the play space differ by a
## rigid motion: computed where the feet are placed and after a recentre of the play space, a stick
## step or turn, and left alone while one walks and turns in the room. The stereo check's overlay
## is fixed to the room by it, so if the ray-traced world drifted against the room, its green
## lines would part from it.
func _update_chart_map() -> void:
	if overlay == null or foot_l <= space.L:
		return
	var fc := space.chart_position(foot_l, foot_n)
	# columns: where play x, y, z point in the chart
	var B := Basis(WormholeSpace.vector_to_chart(1.0, foot_n, frame[0]).normalized(), Vector3(0.0, 0.0, 1.0),
			WormholeSpace.vector_to_chart(1.0, foot_n, frame[2]).normalized())
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
