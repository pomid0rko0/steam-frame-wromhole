extends Node3D
## Real-time wormhole for VR: walking in the room, the left stick walks, the right stick
## turns, smoothly or in 30-degree snaps (button map in the README); a line low in the view shows
## the headset's refresh rate and whether frames keep up, and a menu, opened with the menu button
## and worked with the D-pad and A / B (_menu_input), sets the refresh rate, the render scale,
## foveated rendering and the rest (perf_panel.gd, set_foveation). Gravity through the wormhole, from Laplace's equation on the
## space itself (WormholeSpace.gravity_f): balls roll and bounce in it, cubes slide and stop
## (ball_world.gd). A moment after the start a cube and a ball are thrown, then two balls are
## dropped together: one beside the wormhole, one in the middle of the throat, where gravity is a
## fifth; A (R) puts everything back and does it again. The floor coloured by gravity's strength
## and arrows of its field are shown on request (set_gravity_view; the menu, the D-pad up, G). Every pixel is
## ray traced along a geodesic of the wormhole space in the shader; this script tracks where the
## viewer is in that curved space.
##
## Body model: the feet stay on the floor (the totally geodesic equatorial surface
## n.z = 0). Physical movement in the play space and stick locomotion move the feet along
## floor geodesics, parallel-transporting the play-space axes; stick turns rotate those axes;
## the head sits head-height above the feet along the floor normal. Each eye is derived in
## the shader from that view's own matrices (see shaders/wormhole_view.gdshaderinc).

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
const DESKTOP_HEAD_HEIGHT := 1.6
const MOUSE_SENS := 0.003
# Stereo check (see _add_check): balls in chart A, in front of the start position
const CHECK_BALLS := [Vector3(7.5, -0.5, 1.5), Vector3(8.0, -1.8, 1.1), Vector3(8.3, 1.6, 1.9)]
const CHECK_BALL_RADIUS := 0.3
# and a magenta cube on the floor, turned (chart A centre, half size, yaw)
const CHECK_CUBE := Vector3(6.9, 0.9, 0.3)
const CHECK_CUBE_HALF := 0.3
const CHECK_CUBE_YAW := 0.5
const CHECK_CUBE_COLOR := Color(0.85, 0.1, 0.9)
# present in a build: the stereo check is on (a build for the one-eye check; not in git)
const CHECK_FLAG := "res://check"
# the world's ray tracer, by gravity view (set_gravity_view)
const SHADER_PLAIN := preload("res://shaders/wormhole.gdshader")
const SHADER_GRAVITY := preload("res://shaders/wormhole_gravity.gdshader")    # set_gravity_view 1
const SHADER_ARROWS := preload("res://shaders/wormhole_arrows.gdshader")      # set_gravity_view 2
# the toys' passes (wormhole_toys.gdshaderinc), without and with the arrows over them
const SHADER_TOYS_FLAT := preload("res://shaders/toys_flat.gdshader")
const SHADER_TOYS_FLAT_ARROWS := preload("res://shaders/toys_flat_arrows.gdshader")
const SHADER_TOYS_SHELL := preload("res://shaders/toys_shell.gdshader")
const SHADER_TOYS_SHELL_ARROWS := preload("res://shaders/toys_shell_arrows.gdshader")
# m around a toy's proxy sphere: more than the near plane (camera.near). A ray that meets a toy
# leaves its sphere at least this far beyond the hit, so the sphere's back face, which the pass is
# drawn on, is not clipped away before it.
const PROXY_MARGIN := 0.08
const PROXY_SLACK := 1.02       # the proxy meshes' faces lie inside their sphere (by up to 1.7%): grown by this
const CONE_NEAR := 4.0          # m from the head: a toy closer gets a cone of its own (_update_cones)
const GRAVITY_VIEWS := ["off", "floor", "floor and arrows"]
const FOVEATION_LEVELS := 3          # the runtime's levels: low, medium, high (set_foveation)
# Our own density maps (set_foveation 4 and 5), each eye alike, centred: rings out from where the
# eyes look, [radius, shading width, height in screen pixels]; the radius in each eye's picture,
# its edge at 1 (about 52 degrees). Each step halves the pixels shaded, for a softer edge than
# the runtime's maps: the width first, then the height (own_order 1 swaps them: 1x2, 2x4).
# 4: wide, 5: narrow.
const OWN_MAPS := {
	4: [[0.7, 1, 1], [0.9, 2, 1], [1.15, 2, 2], [99.0, 4, 2]],
	5: [[0.45, 1, 1], [0.65, 2, 1], [0.85, 2, 2], [1.05, 4, 2], [99.0, 4, 4]],
}
const OWN_MAP_SIZE := 64             # texels a side: the driver samples it once per tile anyway
const OWN_MAP_BYTE := {1: 0, 2: 128, 4: 192}     # shading size -> colour byte (_own_map)
# Godot's own density map where the runtime has none (Monado, tests): its strength per level
const OWN_MAP_STRENGTH := [0.5, 1.0, 2.0]
const GAZE_DOT_DIST := 1.5           # m along the gaze: where the gaze dot is drawn

var space := WormholeSpace.new(THROAT_RADIUS, HALF_LENGTH, FILLET)
var scene: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://scene.json"))
var world := BallWorld.new(space, scene)
var physics := true             # simulate and draw the balls and cubes; the stereo check and tests that draw their own turn it off
var throw_toys := true          # the throw and the drop after the start and each reset
var launch_in := -1.0           # seconds until the throw; < 0: none pending
var drop_in := -1.0             # seconds until the two balls are dropped; < 0: none pending
var pixel_angle := 0.0          # wh_pix as last set (_pixel_angle)
var xr: XRInterface
var xr_name := "OpenXR"        # tests use "Native mobile": Godot's own stereo renderer, same multiview path
var in_xr := false

var xr_view: SubViewport       # XR renders here, so the desktop window gets no mirror image
var origin: XROrigin3D
var camera: XRCamera3D
var material: ShaderMaterial    # the world's ray tracer
# The toys (README, «Мячи и кубы»): passes of their own, drawn before the world's ray tracer, each
# writing the depth of its hits (the GPU then skips the world's ray tracer under them):
var toys_flat: MultiMeshInstance3D  # the head's flat universe's toys seen straight, over a sphere round each (play space)
var toys_shell: MeshInstance3D      # what rays meet in and beyond the shell: over a sphere round it, or the whole view
var toys_flat_mat: ShaderMaterial
var toys_shell_mat: ShaderMaterial
var toy_mask := Vector4i.ZERO       # the toys a flat universe's sheet cuts, as bits: x A, y B (set_objects)
var toy_chart: Array = []           # per toy bit (or null): [universe, the chart sphere it is in] (set_objects)
var toy_list: Array = []            # the shell's pass's toys, in its order: [bit, centre (R^4), reach]
var shell_sphere: SphereMesh
var full_view: QuadMesh

# feet on the floor + transported play-space axes [x, y(up), z(back)]
var foot_l: float
var foot_n: Vector3
var frame: Array
var prev_head := Vector2.ZERO
var recentered := false        # the runtime moved the play space: not a step
var desktop_yaw := 0.0
var desktop_pitch := 0.0
var await_pose := false        # XR: place the viewer once head tracking delivers a pose
var show_check := FileAccess.file_exists(CHECK_FLAG)   # the stereo check (see _add_check)
var hands: Array[XRController3D] = []   # left, right (XR only)
var grips: Array[XRController3D] = []   # the same at their grip pose: the hands that grab
# per hand (left, right): where it is in the curved space and what it holds (_update_hands)
var hand_state: Array[Dictionary] = [{}, {}]
var clock := 0.0                # seconds since the start: the hands' and held toys' recent places
var left_hand: XRController3D
var right_hand: XRController3D
var button_was := {}
var smooth_turn := true         # false: 30-degree snaps; a right stick click switches
var snap_armed := true          # the right stick went back to the middle since the last turn
var logged_profiles := {}
var input_log_time := 0.0
var perf: Node3D                # the menu and the frame rate line (perf_panel.gd)
var menu_active := false        # the menu was open this frame: A, B, the D-pad and the left stick are its
var menu_dir := Vector2i.ZERO   # the direction held for it (_menu_direction)
var menu_held := 0.0            # s it has been held: then it repeats
var menu_armed := true          # nothing held since the menu opened (a stick out to walk does not act)
var stick_dir := Vector2i.ZERO  # the left stick as a D-pad, with hysteresis
var bench: Node                 # the speed check, started from the menu (bench.gd)
var hold := false               # the speed check: the feet stay while the head moves, sticks do nothing
var view_pitch := 0.0           # degrees: the view turned up and about the line of sight on top of
var view_roll := 0.0            # the head's own (the speed check; the head stays where it is)
var overlay: Node3D            # drawn by Godot itself in chart A coordinates; maps chart A -> play
var foveation := 0              # 0 off, 1..3: the level (set_foveation)
var split_pass: CompositorEffect     # the 3D scene in a render pass of its own (split_pass.gd)
var own_maps := {}              # OWN_MAPS made into textures, by level * 2 + own_order (_own_map)
var own_order := 0              # our maps' steps: 0 the width first (2x1, 4x2), 1 the height (1x2, 2x4)
var gaze: XRNode3D              # where the eyes look (XR_EXT_eye_gaze_interaction), XR only
var gaze_dot: MeshInstance3D    # drawn where they look, while the panel says so
var balls := 0                  # movable balls and cubes drawn (set_objects)
var gravity_view := 0           # 0 off, 1 the floor coloured by gravity, 2 also arrows of its field
# the speed check's (bench.gd) and the cost model's (tests/emu_dump.gd) hands, at fixed places in
# front of the chest: 0 none, 1 both hands' balls, 2 and a ball held in the right one (_bench_balls)
var bench_hands := 0
var toys_shown := true          # false: the toys' passes are not drawn (the speed check: the world alone)


func _ready() -> void:
	xr = XRServer.find_interface(xr_name)
	var host: Node = self
	if xr and xr.is_initialized():
		in_xr = true
		var oxr := xr as OpenXRInterface
		if oxr:
			# methods, not lambdas: a lambda left connected to the interface corrupted memory at
			# exit (perf_panel.gd)
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

	origin = XROrigin3D.new()
	host.add_child(origin)
	camera = XRCamera3D.new()
	camera.near = 0.05
	split_pass = preload("res://split_pass.gd").new()
	camera.compositor = Compositor.new()
	camera.compositor.compositor_effects = [split_pass]
	origin.add_child(camera)
	if in_xr:
		for t in [&"left_hand", &"right_hand"]:
			var c := XRController3D.new()
			c.tracker = t
			c.pose = &"aim"            # the buttons and sticks are read here
			origin.add_child(c)
			hands.append(c)
			var g := XRController3D.new()
			g.tracker = t
			g.pose = &"grip"           # where the hand holds the controller: what it grabs with
			origin.add_child(g)
			grips.append(g)
		left_hand = hands[0]
		right_hand = hands[1]
		# the eyes' gaze, from SteamVR's eye tracking: logged with the panel's lines, and a dot
		# drawn there on request (the panel), to see whether the sharp middle of the foveation
		# follows it
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

	material = ShaderMaterial.new()
	material.shader = SHADER_PLAIN
	toys_flat_mat = ShaderMaterial.new()
	toys_flat_mat.shader = SHADER_TOYS_FLAT
	toys_flat_mat.render_priority = -2
	toys_shell_mat = ShaderMaterial.new()
	toys_shell_mat.shader = SHADER_TOYS_SHELL
	toys_shell_mat.render_priority = -1
	_param("wh_rho0", space.rho0)
	_param("wh_h", space.h)
	_param("wh_fillet", space.fillet)
	_upload_fillet_table()
	_upload_gravity()
	_upload_scene()
	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(2.0, 2.0)
	quad.mesh = mesh
	quad.material_override = material
	quad.extra_cull_margin = 16384.0
	quad.position = Vector3(0.0, 0.0, -1.0)
	camera.add_child(quad)
	_add_toy_draws()

	if not in_xr:
		camera.position = Vector3(0.0, DESKTOP_HEAD_HEIGHT, 0.0)
	place(1.0, START_POS, START_FORWARD)
	_build_overlay()
	if show_check:
		_add_check()
	elif physics:
		_spawn_toys()
		_upload_toys()


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
	_face_head()
	_forget_motion()


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
	_forget_motion()
	view_pitch = pitch
	view_roll = roll


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


## Turn the frame so that the head's current yaw looks along its forward (play-space forward
## is -Z), and take the head's place in the room from here.
func _face_head() -> void:
	var hf := _head_forward_xz()
	_rotate_frame(-atan2(hf.x, -hf.y))
	prev_head = Vector2(camera.position.x, camera.position.z)
	_update_chart_map()


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
	_forget_motion()


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
	# stick motion over at most 0.1 s: a long frame (back from the SteamVR dashboard) is no leap
	var dt := minf(delta, 0.1)
	menu_active = _menu_input(dt)
	var moved := false if hold else _handle_turn_and_reset(dt)
	# the D-pad up, left or right (left Y on other controllers) / G: the next gravity view (not
	# during the speed check: it times what it set up)
	var grav_down := Input.is_key_pressed(KEY_G)
	if in_xr:
		for b in [&"by_button", &"dpad_up", &"dpad_left", &"dpad_right"]:
			grav_down = grav_down or left_hand.is_button_pressed(b)
	if _pressed_once("gravity", grav_down) and not hold and not menu_active:
		set_gravity_view((gravity_view + 1) % GRAVITY_VIEWS.size())

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
	# a pixel's angle (the cubes' edge lines, the arrows' soft edges) follows the render scale
	var pix := _pixel_angle()
	if pix != pixel_angle:
		pixel_angle = pix
		_param("wh_pix", pix)
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
	_param("head_l", hp[0])
	_param("head_n", hp[1])
	_param("head_f", PackedVector4Array(hf))
	_param("head_pos", head.origin)
	clock += delta
	# the free toys up to this frame (pushed by the hands where they were), then the hands and
	# what they hold to this frame: a toy let go now starts from where the hand has it
	_toys(delta)
	_update_hands(hp, head)
	if physics:
		_upload_toys(hp)
	_update_toy_draws(hp[0], hp[1], hf, head.origin)


func _on_recentered() -> void:
	recentered = true


func _on_session_visible() -> void:
	print("XR session visible (no input focus: dashboard open?)")


func _on_session_focussed() -> void:
	print("XR session focused: controller input active")


## Writes the controllers' interaction profiles and stick values to godot.log.
func _log_input(delta: float) -> void:
	for hand: XRController3D in [left_hand, right_hand]:
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
		print("sticks left ", ls, " right ", rs)


func _pressed_once(key: String, down: bool) -> bool:
	var was: bool = button_was.get(key, false)
	button_was[key] = down
	return down and not was


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


# ---------------------------------------------------------------- the menu
const MENU_REPEAT_AFTER := 0.4      # s a direction is held before it repeats
const MENU_REPEAT := 0.12           # s between repeats


## The menu (perf_panel.gd). Menu on the right controller or View on the left (the Steam Frame's
## own profile; Touch: the left menu button), or a click of the left stick (every profile: the
## KHR generic one, as the Frame's controllers came before this map had theirs, has no menu
## button), M on the desktop, opens and closes it. While it is open: the D-pad or the left stick
## (arrow keys) up and down picks a row, left and right change its value, held they repeat; A
## (Enter) presses, B (Backspace) closes. True if the menu was open at any point of this frame:
## then those buttons and the left stick do nothing else (a B that closes it makes no ball).
func _menu_input(dt: float) -> bool:
	if perf == null:
		return false
	var was_open: bool = perf.open
	var toggle := Input.is_key_pressed(KEY_M)
	var a := Input.is_key_pressed(KEY_ENTER)
	var b := Input.is_key_pressed(KEY_BACKSPACE)
	if in_xr:
		toggle = toggle or left_hand.is_button_pressed(&"menu_button") or right_hand.is_button_pressed(&"menu_button") \
				or left_hand.is_button_pressed(&"primary_click")
		a = a or right_hand.is_button_pressed(&"ax_button")
		b = b or right_hand.is_button_pressed(&"by_button")
	var dir := _menu_direction()
	if _pressed_once("menu", toggle):
		perf.toggle()
		menu_armed = false      # what is held now (the stick out to walk) waits to be let go
	var pressed_a := _pressed_once("menu_a", a)
	var pressed_b := _pressed_once("menu_b", b)
	if perf.open and was_open:
		if not menu_armed:
			menu_armed = dir == Vector2i.ZERO
		elif dir != Vector2i.ZERO:
			var fire := dir != menu_dir
			menu_held = 0.0 if fire else menu_held + dt
			if menu_held >= MENU_REPEAT_AFTER:
				menu_held -= MENU_REPEAT
				fire = true
			if fire:
				if dir.y != 0:
					perf.move(dir.y)
				else:
					perf.change(dir.x)
				_tick(left_hand)
		if pressed_a:
			perf.press()
			_tick(right_hand)
		elif pressed_b:
			perf.back()
			_tick(right_hand)
	menu_dir = dir
	return was_open or perf.open


## The direction held for the menu: the D-pad or arrow keys, else the left stick as a D-pad (out
## past 0.6 along its main axis, let go under 0.3); y down is +1 (the next row).
func _menu_direction() -> Vector2i:
	var d := Vector2i(int(Input.is_key_pressed(KEY_RIGHT)) - int(Input.is_key_pressed(KEY_LEFT)),
			int(Input.is_key_pressed(KEY_DOWN)) - int(Input.is_key_pressed(KEY_UP)))
	if in_xr:
		d += Vector2i(int(left_hand.is_button_pressed(&"dpad_right")) - int(left_hand.is_button_pressed(&"dpad_left")),
				int(left_hand.is_button_pressed(&"dpad_down")) - int(left_hand.is_button_pressed(&"dpad_up")))
		var s := left_hand.get_vector2(&"primary")
		if s.length() > 0.6:
			stick_dir = Vector2i(0, -int(signf(s.y))) if absf(s.y) >= absf(s.x) else Vector2i(int(signf(s.x)), 0)
		elif s.length() < 0.3:
			stick_dir = Vector2i.ZERO
		if d == Vector2i.ZERO:
			d = stick_dir
	d = d.clamp(Vector2i(-1, -1), Vector2i(1, 1))
	return Vector2i(0, d.y) if d.y != 0 else d


## A light tick in the hand that pressed something in the menu.
func _tick(hand: XRController3D) -> void:
	if in_xr and hand:
		hand.trigger_haptic_pulse(&"haptic", 0.0, 0.25, 0.015, 0.0)


## Turns smoothly or in 30-degree snaps (the right stick's click switches, as does the menu).
func set_smooth_turn(on: bool) -> void:
	smooth_turn = on
	print("right stick turns ", "smoothly" if smooth_turn else "in 30-degree snaps")
	if perf:
		perf.refresh()


## Right stick left/right (Q / E): turn around the head, smoothly (speed follows the stick) or
## in 30-degree snaps; a right stick click (Tab) switches between the two. Right A (R): back to
## the start (not while the menu is open: A is its). True if any of it moved the viewer against
## the room.
func _handle_turn_and_reset(delta: float) -> bool:
	var turn := 0.0
	var mode_down := Input.is_key_pressed(KEY_TAB)
	if in_xr:
		turn = right_hand.get_vector2(&"primary").x
		mode_down = mode_down or right_hand.is_button_pressed(&"primary_click")
	turn = clampf(turn + float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q)), -1.0, 1.0)
	if _pressed_once("turn_mode", mode_down):
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
		_forget_motion()            # the hands jump with the world: no throw
		snap_armed = false
		moved = true
	elif absf(turn) < 0.3:
		snap_armed = true
	if _pressed_once("reset", Input.is_key_pressed(KEY_R) or (in_xr and right_hand.is_button_pressed(&"ax_button"))) and not menu_active:
		place(1.0, START_POS, START_FORWARD)    # also redoes the chart -> play map
		if physics:
			_spawn_toys()
			print("toys: back in place, throwing again")
	return moved


# ---------------------------------------------------------------- the toys
const BALL_COLORS := [Color(0.92, 0.25, 0.2), Color(0.2, 0.6, 0.95), Color(0.98, 0.8, 0.2),
		Color(0.3, 0.85, 0.4), Color(0.75, 0.35, 0.9), Color(0.95, 0.55, 0.15)]
const CUBE_COLORS := [Color(0.93, 0.93, 0.88), Color(0.95, 0.45, 0.55), Color(0.35, 0.8, 0.75),
		Color(0.95, 0.7, 0.3), Color(0.55, 0.6, 0.95), Color(0.6, 0.85, 0.35)]
const LAUNCH_DELAY := 1.5
const DROP_DELAY := 6.5         # after the thrown ball has rolled through the throat
const DROP_HEIGHT := 2.0
const DROP_COLOR := Color(0.95, 0.95, 0.97)
const DROP_SPOT_A := Vector3(4.5, 4.2, DROP_HEIGHT)   # to the right of the wormhole
const DROP_RADIUS := 0.35


## The throw and the drop when due, the physics. Not during the speed check: it times the same
## scene at every pose.
func _toys(delta: float) -> void:
	if not physics or await_pose or hold:
		return
	if launch_in >= 0.0:
		launch_in -= delta
		if launch_in < 0.0:
			_throw()
	if drop_in >= 0.0:
		drop_in -= delta
		if drop_in < 0.0:
			_drop()
	world.step(delta, _hand_balls())


## Everything back in place: the balls and cubes at rest, the throw LAUNCH_DELAY s later, the
## drop DROP_DELAY s later.
func _spawn_toys() -> void:
	for st in hand_state:
		st.erase("held")
	world.balls.clear()
	world.cubes.clear()
	var spots := [Vector2(7.0, -1.5), Vector2(7.0, 0.0), Vector2(7.0, 1.5), Vector2(6.0, -0.75), Vector2(6.0, 0.75)]
	for i in spots.size():
		var rad := 0.25 if i < 3 else 0.35
		var p := space.point_from_chart(1.0, Vector3(spots[i].x, spots[i].y, rad))
		world.add(p[0], p[1], Vector4.ZERO, rad, BALL_COLORS[i % BALL_COLORS.size()])
	_cube_on_floor(Vector2(5.4, -2.5), 0.3, 0.35, CUBE_COLORS[0])
	_cube_on_floor(Vector2(6.2, 3.6), 0.25, -0.5, CUBE_COLORS[2])
	_cube_in_throat(0.8, -0.45, 0.3, CUBE_COLORS[5])
	launch_in = LAUNCH_DELAY if throw_toys else -1.0
	drop_in = DROP_DELAY if throw_toys else -1.0


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
	# fast enough to climb out of the throat's well into B against the rolling and the air's drag
	world.add(q[0], q[1], WormholeSpace.vector_from_chart(1.0, q[1], Vector3(-5.4, -0.36, 1.8)), 0.25, BALL_COLORS[5])
	print("toys: thrown")


## The demo as it comes to rest: everything back in place, the throw and the drop at once, and 12 s of
## motion, all at once (the speed check and the cost model time the frame with the toys there).
func settle_demo() -> void:
	_spawn_toys()
	launch_in = -1.0
	drop_in = -1.0
	_throw()
	_drop()
	for k in 12 * 60:
		world.step(1.0 / 60.0, [])


## Two white balls let go at the same moment from the same height: one beside the wormhole,
## where gravity is ordinary, and one in the middle of the throat, where it is about a fifth of
## that. The second is straight ahead in the throat (azimuth 0): from the start it is seen in the
## middle of the wormhole against universe B's sky, and falls and bounces in slow motion.
func _drop() -> void:
	var p := space.point_from_chart(1.0, DROP_SPOT_A)
	world.add(p[0], p[1], Vector4.ZERO, DROP_RADIUS, DROP_COLOR)
	world.add(0.0, throat_point(0.0, DROP_HEIGHT), Vector4.ZERO, DROP_RADIUS, DROP_COLOR)
	print("toys: two balls dropped")


## The direction n at height H = r(0) n.z above the floor in the middle of the throat, at azimuth phi.
func throat_point(phi: float, height: float) -> Vector3:
	var z := height / space.r(0.0)
	return Vector3(cos(phi) * sqrt(1.0 - z * z), sin(phi) * sqrt(1.0 - z * z), z)


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


## The balls and cubes for the shader: a ball's centre as a point of R^4 and its radius (chord
## distance in R^4), then the hands' balls (and the speed check's, from the head's point and frame
## hp); a cube's 4D box (centre, four axes over the half size) and colour.
func _upload_toys(hp := []) -> void:
	var pos := PackedVector4Array()
	var col := PackedVector4Array()
	for b in world.balls:
		pos.append(space.embed(b["l"], b["n"]))
		var c: Color = b["color"]
		col.append(Vector4(c.r, c.g, c.b, b["radius"]))
	for st in hand_state:
		if st.get("on", false):
			pos.append(space.embed(st["l"], st["n"]))
			var c: Color = HAND_COLOR_READY if st["ready"] else HAND_COLOR
			col.append(Vector4(c.r, c.g, c.b, HAND_RADIUS))
	if bench_hands > 0 and not hp.is_empty():
		for b in _bench_balls(hp):
			pos.append(b[0])
			col.append(b[1])
	var cpos := PackedVector4Array()
	var axes := PackedVector4Array()
	var ccol := PackedVector4Array()
	for c in world.cubes:
		var box := world.box4(c)
		var half: float = c["half"]
		cpos.append(box[0])
		for k in 4:
			axes.append(box[1 + k] / half)
		var cc: Color = c["color"]
		ccol.append(Vector4(cc.r, cc.g, cc.b, half))
	set_objects(pos, col, cpos, axes, ccol)


## The speed check's hands (bench_hands): both hands' balls 22 cm to either side of the chest, 35 cm
## below the head and 30 cm ahead, and with bench_hands 2 a ball of 25 cm held 30 cm ahead of the
## right one, placed from the head (hp: its point and frame) as _update_hands places the hands:
## what a frame costs with a ball held in front, wherever the head is.
func _bench_balls(hp: Array) -> Array:
	var out := []
	for k in 2:
		var off := Vector3(0.22 if k == 1 else -0.22, -0.35, -0.3)
		var dir := WormholeSpace.combine(hp[2], off)
		var at: Array = space.geodesic(hp[0], hp[1], dir / dir.length(), dir.length(), hp[2])
		out.append([space.embed(at[0], at[1]), Vector4(HAND_COLOR.r, HAND_COLOR.g, HAND_COLOR.b, HAND_RADIUS)])
		if k == 1 and bench_hands == 2:
			var g: Array = space.geodesic(at[0], at[1], -at[2][2], 0.3, at[2])
			out.append([space.embed(g[0], g[1]), Vector4(0.95, 0.95, 0.97, 0.25)])
	return out


# ---------------------------------------------------------------- the hands
const HAND_RADIUS := 0.04        # m: the ball drawn at each hand's grip; it pushes the toys
const GRAB_REACH := 0.12         # m from the hand's centre to a toy's surface: the grip takes it
const GRIP_ON := 0.7             # the grip's value that grabs, and the one below which it lets
const GRIP_OFF := 0.45           # go: apart, so a half-closed hand does not grab and drop by turns
const HAND_COLOR := Color(0.55, 0.62, 0.75)
const HAND_COLOR_READY := Color(0.35, 0.95, 0.5)   # a toy within reach, or held
const VELOCITY_WINDOW := 0.06    # s of recent places a velocity is taken from (_velocity)
const STALE := 0.1               # s: places older than this give no velocity (tracking lost)
const MAX_THROW_SPEED := 25.0    # m/s: a tracking glitch at the release flings nothing farther
const MAX_THROW_SPIN := 40.0     # rad/s
const SET_DOWN_SPEED := 0.15     # m/s and rad/s: a hand slower than this, turning slower than
const SET_DOWN_SPIN := 1.0       # this, sets its toy down at rest
const NEW_BALL_RADIUS := 0.2     # right B: a new ball in the right hand
const NEW_CUBE_HALF := 0.15      # left X: a new cube in the left hand


## Each hand in the curved space: the geodesic from the head along the hand's offset in the room
## (as the shader places each eye), with the room's axes carried along it, the hand's own axes
## from its pose there, its velocity from its recent places. The grip grabs the nearest toy within
## reach, carries it and lets it go with the hand's motion (_take, _carry, _release); right B and
## the D-pad down (left X on other controllers) put a new ball or cube in the hand, not while the
## menu is open (they are its). Nothing during the speed check (it times the same scene at every
## pose; the hands are not drawn then).
func _update_hands(hp: Array, head: Transform3D) -> void:
	if not in_xr:
		return
	var new_ball := _pressed_once("new_ball", right_hand.is_button_pressed(&"by_button")) and not menu_active
	var new_cube := _pressed_once("new_cube", left_hand.is_button_pressed(&"ax_button")
			or left_hand.is_button_pressed(&"dpad_down")) and not menu_active
	for i in grips.size():
		var c := grips[i]
		var st := hand_state[i]
		st["on"] = false
		if hold or await_pose or not physics:
			continue
		if c.get_has_tracking_data():
			var xf := c.transform
			var off := xf.origin - head.origin
			var at := hp
			if off.length() > 1e-6:
				var dir := WormholeSpace.combine(hp[2], off)
				at = space.geodesic(hp[0], hp[1], dir / dir.length(), dir.length(), hp[2])
			var b := xf.basis.orthonormalized()
			st["l"] = at[0]
			st["n"] = at[1]
			st["F"] = [WormholeSpace.combine(at[2], b.x), WormholeSpace.combine(at[2], b.y),
					WormholeSpace.combine(at[2], b.z)]
			_remember(st, "hist", [clock, at[0], at[1]])
			st["U"] = _velocity(st["hist"])[0]
			st["on"] = true
		# the held toy where the hand is now, also in the frame it lets go
		if st.has("held") and st["on"]:
			_carry(i)
		# the grip, with a gap between grabbing and letting go
		var g := c.get_float(&"grip")
		var was: bool = st.get("grip", false)
		var grip := g > GRIP_OFF if was else g > GRIP_ON
		st["grip"] = grip
		if grip and not was and st["on"]:
			var toy := _nearest(i)
			if not toy.is_empty():
				_take(i, toy)
		elif was and not grip:
			_release(i)
		if st["on"] and ((i == 1 and new_ball) or (i == 0 and new_cube)):
			_new_toy(i, i == 0)
		var ready: bool = st.has("held") or (st["on"] and not _nearest(i).is_empty())
		if ready and not st.get("ready", false) and not st.has("held"):
			c.trigger_haptic_pulse(&"haptic", 0.0, 0.15, 0.02, 0.0)    # a tick: within reach
		st["ready"] = ready


## The hands as kinematic balls for the physics: they push the toys.
func _hand_balls() -> Array:
	var out := []
	for i in grips.size():
		var st := hand_state[i]
		if st.get("on", false):
			out.append({"l": st["l"], "n": st["n"], "U": st["U"], "radius": HAND_RADIUS,
					"tracker": grips[i].tracker})
	return out


## The toy nearest to hand i's centre within GRAB_REACH of its surface (not one it holds), or {}.
func _nearest(i: int) -> Dictionary:
	var st := hand_state[i]
	var P := space.embed(st["l"], st["n"])
	var best := {}
	var best_d := GRAB_REACH
	for b in world.balls + world.cubes:
		if b["held"] == grips[i].tracker:
			continue
		var d := world.distance_to(b, P)
		if d < best_d:
			best_d = d
			best = b
	return best


## Hand i takes the toy where it is: from now on it keeps its place and its turn against the
## hand, as an offset in the hand's axes (the geodesic from the hand that reaches it) and, for a
## cube, its axes in the hand's axes carried there. Taken from the other hand, that one lets go.
func _take(i: int, toy: Dictionary) -> void:
	var st := hand_state[i]
	var other := hand_state[1 - i]
	if other.has("held") and is_same(other["held"], toy):
		other.erase("held")
	_release(i)
	toy["held"] = grips[i].tracker
	toy.erase("ghost")
	var D := space.toward(st["l"], st["n"], toy["l"], toy["n"])
	var F: Array = st["F"]
	st["held"] = toy
	st["off"] = BallWorld.to_body(F, D)
	st["thist"] = []
	if toy.has("F"):
		var at := _hold_point(st)
		var rel := []
		for A: Vector4 in toy["F"]:
			rel.append(BallWorld.to_body(at[2], A))
		st["rel"] = rel
	grips[i].trigger_haptic_pulse(&"haptic", 0.0, 0.6, 0.06, 0.0)
	print("grab: %s hand takes a %s (%.2f m from the hand)" % [_hand_name(i),
			"cube" if toy.has("F") else "ball", D.length()])


## Where hand st holds its toy: the end of the geodesic of its offset, with the hand's axes there.
func _hold_point(st: Dictionary) -> Array:
	var D := WormholeSpace.combine(st["F"], st["off"])
	if D.length() < 1e-7:
		return [st["l"], st["n"], st["F"]]
	return space.geodesic(st["l"], st["n"], D / D.length(), D.length(), st["F"])


## The held toy follows hand i; its velocity (and a cube's spin) from its recent places: what it
## pushes others with, and what it flies off with.
func _carry(i: int) -> void:
	var st := hand_state[i]
	var toy: Dictionary = st["held"]
	var at := _hold_point(st)
	toy["l"] = at[0]
	toy["n"] = at[1]
	var F := []
	if toy.has("F"):
		var rel: Array = st["rel"]
		F = WormholeSpace.orthonormalize([WormholeSpace.combine(at[2], rel[0]),
				WormholeSpace.combine(at[2], rel[1]), WormholeSpace.combine(at[2], rel[2])])
		toy["F"] = F
	_remember(st, "thist", [clock, at[0], at[1], F])
	var v := _velocity(st["thist"])
	toy["U"] = v[0]
	if toy.has("F"):
		toy["w"] = v[1]


## Hand i lets its toy go: it flies off with the hand's velocity and turns as the hand turned. Not
## with its own velocity in the hand: held off the hand (half a metre to a big ball's centre), it
## also moved with the turn of the wrist times that lever, and a flick of the wrist threw it at
## 15-20 m/s (the headset's log).
func _release(i: int) -> void:
	var st := hand_state[i]
	if not st.has("held"):
		return
	var toy: Dictionary = st["held"]
	st.erase("held")
	toy["held"] = &""
	var v := _velocity(st.get("thist", []))
	var U: Vector4 = _velocity(st.get("hist", []))[0]
	var D := WormholeSpace.combine(st["F"], st["off"])
	if D.length() > 1e-7 and U != Vector4.ZERO:
		U = space.geodesic(st["l"], st["n"], D / D.length(), D.length(), [U])[2][0]    # carried to the toy
	if U.length() > MAX_THROW_SPEED:
		U *= MAX_THROW_SPEED / U.length()
	# a hand held still sets its toy down at rest: the tracking's tremble would push it
	var gentle := U.length() < SET_DOWN_SPEED and (v[1] as Vector3).length() < SET_DOWN_SPIN
	toy["U"] = Vector4.ZERO if gentle else U
	if toy.has("F"):
		toy["w"] = Vector3.ZERO if gentle else (v[1] as Vector3).limit_length(MAX_THROW_SPIN)
		toy["still"] = 0.0
	toy["ghost"] = grips[i].tracker      # this hand does not push it until they are apart
	print("%s: %s hand lets a %s go at %.2f m/s%s" % ["set down" if gentle else "throw", _hand_name(i),
			"cube" if toy.has("F") else "ball", toy["U"].length(),
			(", spin %.1f rad/s" % toy["w"].length()) if toy.has("F") else ""])


## A new ball (right B) or cube (left X) just in front of hand i, moving with it: held if the grip
## is closed and the hand holds nothing else. The oldest toy goes if there are too many
## (BallWorld.MAX_BALLS, MAX_CUBES), never a held one.
func _new_toy(i: int, cube: bool) -> void:
	var st := hand_state[i]
	if st.has("held"):
		return
	var size := NEW_CUBE_HALF if cube else NEW_BALL_RADIUS
	var F: Array = st["F"]
	# 1 cm from the hand's ball: not touching it
	var at := space.geodesic(st["l"], st["n"], -F[2], size + HAND_RADIUS + 0.01, F + [st["U"]])
	var toy: Dictionary
	if cube:
		toy = world.add_cube(at[0], at[1], at[2][3], at[2].slice(0, 3), Vector3.ZERO, size,
				CUBE_COLORS[randi() % CUBE_COLORS.size()])
	else:
		toy = world.add(at[0], at[1], at[2][3], size, BALL_COLORS[randi() % BALL_COLORS.size()])
	print("new %s in the %s hand" % ["cube" if cube else "ball", _hand_name(i)])
	if st["grip"]:
		_take(i, toy)


## The viewer was put somewhere else: the hands' and held toys' places before are no motion.
func _forget_motion() -> void:
	for st in hand_state:
		st.erase("hist")
		st.erase("thist")


func _hand_name(i: int) -> String:
	return "left" if i == 0 else "right"


## Adds a sample [t, ...] to st[key], keeping the newest one at least VELOCITY_WINDOW old and the
## ones after it.
func _remember(st: Dictionary, key: String, sample: Array) -> void:
	var hist: Array = st.get(key, [])
	hist.append(sample)
	while hist.size() > 2 and sample[0] - hist[1][0] >= VELOCITY_WINDOW:
		hist.pop_front()
	st[key] = hist


## A body's velocity from its recent places (hist: [t, l, n] or [t, l, n, F], the newest last):
## [the tangent velocity at the newest place, and with axes F the angular velocity in the newest
## body coordinates]. The derivative at the newest of the parabola through it, the oldest kept
## (about VELOCITY_WINDOW back) and the one half way: an average over the window would lag the
## hand by half of it, and a throw, which is an arc, would leave in the wrong direction. Each
## place is seen from the newest one (the chord of R^4 there), each turn as the axes carried
## there along the chord.
func _velocity(hist: Array) -> Array:
	var none := [Vector4.ZERO, Vector3.ZERO]
	var m := hist.size()
	if m < 2 or clock - hist[m - 1][0] > STALE:
		return none
	var s0: Array = hist[m - 1]
	var t0: float = s0[0]
	if t0 - hist[0][0] < 1e-3:
		return none
	var E0 := space.embed(s0[1], s0[2])
	var picks := [0]
	var weights := [1.0 / (hist[0][0] - t0)]
	if m > 2:
		# the one nearest half way
		var k1 := 1
		var mid: float = 0.5 * (t0 + hist[0][0])
		for k in range(1, m - 1):
			if absf(hist[k][0] - mid) < absf(hist[k1][0] - mid):
				k1 = k
		var t1: float = hist[k1][0]
		var t2: float = hist[0][0]
		picks = [k1, 0]
		weights = [(t0 - t2) / ((t1 - t0) * (t1 - t2)), (t0 - t1) / ((t2 - t0) * (t2 - t1))]
	var U := Vector4.ZERO
	var w := Vector3.ZERO
	var spin: bool = s0.size() > 3 and not s0[3].is_empty()
	for j in picks.size():
		var s: Array = hist[picks[j]]
		var Ek := space.embed(s[1], s[2])
		U += weights[j] * space.project(s0[1], s0[2], Ek - E0)
		if spin:
			# the axes then, carried here: their turn to the axes now, as a rotation vector
			var Fk: Array = s[3]
			var D := space.project(s[1], s[2], E0 - Ek)
			if D.length() > 1e-7:
				Fk = space.geodesic(s[1], s[2], D / D.length(), (E0 - Ek).length(), Fk)[2]
			var F0: Array = s0[3]
			var G := Basis(BallWorld.to_body(F0, Fk[0]), BallWorld.to_body(F0, Fk[1]), BallWorld.to_body(F0, Fk[2]))
			w += weights[j] * _rotation_vector(G.orthonormalized().get_rotation_quaternion())
	return [U, w]


static func _rotation_vector(q: Quaternion) -> Vector3:
	if q.w < 0.0:
		q = -q
	var v := Vector3(q.x, q.y, q.z)
	var s := v.length()
	if s < 1e-9:
		return 2.0 * v
	return v * (2.0 * atan2(s, q.w) / s)


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


func _rotate_frame(angle: float) -> void:
	# positive angle turns the view to the right
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


## The node for things Godot draws itself among the ray-traced ones, placed in chart A
## coordinates (the stereo check), and the menu with the frame rate line, which follow the head in
## the room.
func _build_overlay() -> void:
	overlay = Node3D.new()
	origin.add_child(overlay)
	perf = preload("res://perf_panel.gd").new()
	perf.name = "Perf"
	perf.target = xr_view if in_xr else get_viewport()
	perf.xr = xr as OpenXRInterface if in_xr else null
	perf.viewer = self
	perf.head = camera
	bench = preload("res://bench.gd").new()
	bench.main = self
	bench.panel = perf
	add_child(bench)
	origin.add_child(perf)
	_update_chart_map()


## The stereo check. Godot's standard renderer draws green lines on top of what the ray tracer
## draws: on the white lines of the flat floor, as a grid on three red balls and along the edges
## of a magenta cube. With one eye closed, green must lie exactly on white / on red / on the cube's
## dark edges; two separate grids mean wrong stereo.
func _add_check() -> void:
	physics = false                 # the check's red balls take the shader's ball slots
	var floor_mat := ShaderMaterial.new()
	floor_mat.shader = load("res://shaders/check_grid.gdshader")
	floor_mat.set_shader_parameter("rout", space.Rout)
	floor_mat.set_shader_parameter("lsh", space.L)
	floor_mat.render_priority = 10
	var bl := PackedVector4Array()
	for c in CHECK_BALLS:
		bl.append(Vector4(c.x, c.y, c.z, CHECK_BALL_RADIUS))
	floor_mat.set_shader_parameter("balls", bl)
	floor_mat.set_shader_parameter("cube", Vector4(CHECK_CUBE.x, CHECK_CUBE.y, CHECK_CUBE.z, sqrt(3.0) * CHECK_CUBE_HALF))
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
	# the cube: Godot draws its edges green, the ray tracer the 4D box of sheet A (axes over the half size)
	var yaw := CHECK_CUBE_YAW
	var box := MeshInstance3D.new()
	box.name = "Cube"
	box.mesh = BoxMesh.new()
	box.mesh.size = Vector3.ONE * 2.0 * CHECK_CUBE_HALF
	box.material_override = ShaderMaterial.new()
	box.material_override.shader = load("res://shaders/check_cube.gdshader")
	box.material_override.set_shader_parameter("half", CHECK_CUBE_HALF)
	box.material_override.render_priority = 11
	box.transform = Transform3D(Basis(Vector3(0.0, 0.0, 1.0), yaw), CHECK_CUBE)
	overlay.add_child(box)
	var axes := PackedVector4Array([Vector4(cos(yaw), sin(yaw), 0.0, 0.0), Vector4(-sin(yaw), cos(yaw), 0.0, 0.0),
			Vector4(0.0, 0.0, 1.0, 0.0), Vector4(0.0, 0.0, 0.0, 1.0)])
	for k in 4:
		axes[k] /= CHECK_CUBE_HALF
	var cc := CHECK_CUBE_COLOR
	set_objects(pos, col, PackedVector4Array([Vector4(CHECK_CUBE.x, CHECK_CUBE.y, CHECK_CUBE.z, space.h)]), axes,
			PackedVector4Array([Vector4(cc.r, cc.g, cc.b, CHECK_CUBE_HALF)]))
	# no other objects: Godot's floor lines would be drawn over them where the floor is hidden
	var none_sph := PackedVector4Array()
	var none_pil := PackedVector4Array()
	var none_box := PackedVector4Array()
	for i in 6:
		none_sph.append(Vector4(0.0, 0.0, -100.0, 0.5))      # below the floor
	for i in 4:
		none_pil.append(Vector4(0.0, 0.0, 0.001, -1.0))       # no height
		none_box.append(Vector4(0.0, 0.0, -100.0, 0.5))
	_param("wh_sph", none_sph)
	_param("wh_pil", none_pil)
	_param("wh_box", none_box)


## Foveated rendering: the edges of each eye's picture are rendered coarser. level 0 is off,
## 1..3 the runtime's density map at its level low, medium, high, 4 and 5 our own (OWN_MAPS);
## split: the 3D scene in a render pass of its own without a density map (the speed check times
## that alone).
##
## On the Steam Frame the runtime's density map is SteamVR's (XR_FB_foveation). SteamVR tracks the
## eyes and hands Godot each frame where each eye looks (XR_META_foveation_eye_tracked; Godot 4.7.2
## asks only with the eye gaze extension on, project.godot), and Godot hands the driver offsets
## that move the density map there (VK_QCOM_fragment_density_map_offset), whichever map it is: so
## our own maps follow the eyes too. They are centred in each eye's picture, where SteamVR's are
## (the offsets are taken from the picture's centre). The GPU driver renders each tile at the
## map's density there, only in tiles: hence split_pass.gd. The swapchain gets SteamVR's map when
## it is created, so project.godot asks for the high level and "off" is the viewport's density
## map taken away (vrs_mode), not the runtime's level 0. Without the runtime's map (Monado,
## Godot's "Native mobile") levels 1..3 are Godot's own, round each eye's centre.
##
## The ray tracer stays exact under it: each pixel's ray is interpolated from the screen's
## corners (shaders/wormhole_view.gdshaderinc), and a coarse pixel gets the ray through its
## centre, as Godot's own geometry does. Nothing in it reads the pixel's screen position.
func set_foveation(level: int, split := false) -> void:
	foveation = clampi(level, 0, 5)
	var target: Viewport = xr_view if xr_view else get_viewport()
	var mode := Viewport.VRS_DISABLED
	if OWN_MAPS.has(foveation):
		mode = Viewport.VRS_TEXTURE
		# a texture array, a layer per eye: Viewport.vrs_texture takes a Texture2D only. Copied
		# into the driver's map every frame: a copy made once is lost when the buffers are made again
		target.vrs_update_mode = Viewport.VRS_UPDATE_ALWAYS
		RenderingServer.viewport_set_vrs_texture(target.get_viewport_rid(), _own_map(foveation).get_rid())
	elif foveation > 0:
		mode = Viewport.VRS_XR
	if target.vrs_mode != mode:
		target.vrs_mode = mode      # the 3D buffers are made again: not every call
	split_pass.enabled = foveation > 0 or split
	if foveation == 0 or OWN_MAPS.has(foveation) or xr == null:
		return
	var oxr := xr as OpenXRInterface
	if oxr and oxr.is_foveation_supported():
		oxr.foveation_level = foveation
	elif "vrs_strength" in xr:
		xr.set("vrs_strength", OWN_MAP_STRENGTH[foveation - 1])


## One of OWN_MAPS as a density map Godot takes (Viewport.vrs_texture's colours: red and green
## the shading width and height), a layer per eye. Godot makes a colour c into the density 1 - c,
## and the driver a density d into a size 1/d rounded down to a power of two: hence 192, not 0.75
## (191/255 would come out 3.98, so 2).
func _own_map(level: int) -> Texture2DArray:
	var key := level * 2 + own_order
	if own_maps.has(key):
		return own_maps[key]
	var img := Image.create(OWN_MAP_SIZE, OWN_MAP_SIZE, false, Image.FORMAT_RG8)
	for y in OWN_MAP_SIZE:
		for x in OWN_MAP_SIZE:
			var r := Vector2((x + 0.5) * 2.0 / OWN_MAP_SIZE - 1.0, (y + 0.5) * 2.0 / OWN_MAP_SIZE - 1.0).length()
			for ring: Array in OWN_MAPS[level]:
				if r < ring[0]:
					var w: int = ring[1] if own_order == 0 else ring[2]
					var h: int = ring[2] if own_order == 0 else ring[1]
					img.set_pixel(x, y, Color8(OWN_MAP_BYTE[w], OWN_MAP_BYTE[h], 0))
					break
	var tex := Texture2DArray.new()
	tex.create_from_images([img, img])
	own_maps[key] = tex
	return tex


## Our maps' order of steps: 0 the width first (1x1, 2x1, 2x2, 4x2, 4x4), 1 the height first
## (1x1, 1x2, 2x2, 2x4, 4x4). At once if one of them is on.
func set_own_order(order: int) -> void:
	own_order = clampi(order, 0, 1)
	if OWN_MAPS.has(foveation):
		set_foveation(foveation)


## Movable balls: centres as points of R^4 (xyz, w), colours as (rgb, radius), at most 12.
func set_balls(pos: PackedVector4Array, col: PackedVector4Array) -> void:
	set_objects(pos, col, PackedVector4Array(), PackedVector4Array(), PackedVector4Array())


## Movable balls (as set_balls) and cubes, at most 6: a cube's 4D box of R^4, cut by the space as
## a box of a 4D SDF scene: centre as a point of R^4 (cpos), four orthonormal axes divided by the
## half size (axes: three body axes tangent to the space, then its normal; four per cube),
## (rgb, half size) (ccol). The toys' passes get each cube's axes and then dot(centre, axis) for
## the four, five vectors per cube (wormhole_toys.gdshaderinc). Ball i is bit i, cube i bit 16 + i:
## the flat pass draws the toys a flat universe's sheet cuts (toy_mask, toy_chart), the shell's
## pass gets the list of every toy within reach of the shell or of a sheet, each with the l window
## of its points' meridian and the flat universe it is in (wht_toy, wht_win: wht_near).
func set_objects(pos: PackedVector4Array, col: PackedVector4Array, cpos: PackedVector4Array,
		axes: PackedVector4Array, ccol: PackedVector4Array) -> void:
	var n := pos.size()
	var nc := cpos.size()
	var fb := PackedVector4Array()     # the sphere a flat sheet cuts from a ball, in that chart
	var mask := Vector4i.ZERO
	toy_chart = []
	toy_chart.resize(32)
	toy_list = []
	var lt := PackedVector4Array()
	var lw := PackedVector4Array()
	for i in n:
		var C := pos[i]
		var rad := col[i].w
		var side := 1.0 if C.w > 0.0 else -1.0
		var dw := C.w - side * space.h
		var r2 := rad * rad - dw * dw
		fb.append(Vector4(side * C.x, C.y, C.z, r2) if r2 > 0.0 else Vector4(0.0, 0.0, 0.0, -1.0))
		if r2 > 0.0:
			if side > 0.0:
				mask.x |= 1 << i
			else:
				mask.y |= 1 << i
			toy_chart[i] = [side, Vector4(side * C.x, C.y, C.z, sqrt(r2))]
		_list_toy(i, C, rad, side if r2 > 0.0 else 0.0, lt, lw)
	var ax := PackedVector4Array()
	for i in nc:
		var C := cpos[i]
		var reach := 2.0 * ccol[i].w    # its half diagonal
		var o := Vector4.ZERO
		for k in 4:
			ax.append(axes[4 * i + k])
			o[k] = C.dot(axes[4 * i + k])
		ax.append(o)
		var side := 1.0 if C.w > 0.0 else -1.0
		var cut := absf(C.w - side * space.h) < reach
		if cut:
			if side > 0.0:
				mask.x |= 1 << (16 + i)
			else:
				mask.y |= 1 << (16 + i)
			toy_chart[16 + i] = [side, Vector4(side * C.x, C.y, C.z, reach)]
		_list_toy(16 + i, C, reach, side if cut else 0.0, lt, lw)
	var p := pos.duplicate()
	var c := col.duplicate()
	while p.size() < 12:
		p.append(Vector4.ZERO)
		c.append(Vector4.ZERO)
		fb.append(Vector4(0.0, 0.0, 0.0, -1.0))
	var cp := cpos.duplicate()
	var cc := ccol.duplicate()
	while cp.size() < 6:
		cp.append(Vector4.ZERO)
		cc.append(Vector4.ZERO)
	while ax.size() < 30:
		ax.append(Vector4.ZERO)
	# the list in groups of four (wht_near): each column a vec4 per group
	var ng := (lt.size() + 3) / 4
	var cols := []
	for q in 7:
		var column := PackedVector4Array()
		column.resize(5)
		cols.append(column)
	var bits := PackedInt32Array()
	bits.resize(20)
	for k in 20:
		var g := k / 4
		var j := k % 4
		var t := lt[k] if k < lt.size() else Vector4(0.0, 0.0, 0.0, -1.0)
		var w := lw[k] if k < lw.size() else Vector4(1.0, -1.0, 0.0, 0.0)
		var vals := [t.x, t.y, t.z, t.w * t.w if t.w > 0.0 else -1.0, w.x, w.y, w.z]
		for q in 7:
			var v: Vector4 = cols[q][g]
			v[j] = vals[q]
			cols[q][g] = v
		bits[k] = int(w.w)
	balls = n + nc
	toy_mask = mask
	for m in [toys_flat_mat, toys_shell_mat]:
		m.set_shader_parameter("wh_ball", p)
		m.set_shader_parameter("wh_ballCol", c)
		m.set_shader_parameter("wh_nBall", n)
		m.set_shader_parameter("wh_fball", fb)
		m.set_shader_parameter("wh_cube", cp)
		m.set_shader_parameter("wh_cubeE", ax)
		m.set_shader_parameter("wh_cubeCol", cc)
		m.set_shader_parameter("wh_nCube", nc)
	var names := ["wht_cx", "wht_cy", "wht_cz", "wht_r2", "wht_lo", "wht_hi", "wht_fs"]
	for q in 7:
		toys_shell_mat.set_shader_parameter(names[q], cols[q])
	toys_shell_mat.set_shader_parameter("wht_bit", bits)
	toys_shell_mat.set_shader_parameter("wht_nGroup", ng)


## A toy of the shell's pass's list (set_objects), if a ray in or through the shell can meet it:
## within reach of the shell (then its meridian's l window), or cut by a flat universe's sheet
## (side: that universe, else 0). toy_list keeps [bit, centre, reach] for the cones.
func _list_toy(bit: int, C: Vector4, reach: float, side: float, lt: PackedVector4Array, lw: PackedVector4Array) -> void:
	var rr := Vector3(C.x, C.y, C.z).length()
	var curved := rr - reach < space.Rout
	if not curved and side == 0.0:
		return
	var win := space.meridian_window(rr, C.w, reach) if curved else Vector2(1.0, -1.0)
	lt.append(Vector4(C.x, C.y, C.z, reach))
	lw.append(Vector4(win.x, win.y, side, float(bit)))
	toy_list.append([bit, C, reach])


## How gravity is shown (README, «Гравитация через червоточину»): 0 not at all, 1 the floor
## coloured by its strength (optozorax's palette: dark is none, yellow 1 g), 2 also arrows of the
## field on the vertical surface through the wormhole that faces the start (x = 0 in both
## universes, through the throat). The world's ray tracers of their own (wormhole_gravity.gdshader,
## wormhole_arrows.gdshader); with the arrows the toys' passes draw them over the toys too.
func set_gravity_view(view: int) -> void:
	gravity_view = clampi(view, 0, GRAVITY_VIEWS.size() - 1)
	_param("wh_pix", _pixel_angle())
	material.shader = [SHADER_PLAIN, SHADER_GRAVITY, SHADER_ARROWS][gravity_view]
	toys_flat_mat.shader = SHADER_TOYS_FLAT_ARROWS if gravity_view == 2 else SHADER_TOYS_FLAT
	toys_shell_mat.shader = SHADER_TOYS_SHELL_ARROWS if gravity_view == 2 else SHADER_TOYS_SHELL
	if perf:
		perf.refresh()
	print("gravity view: ", GRAVITY_VIEWS[gravity_view])


## A uniform of the world, which the world's ray tracer and the toys' passes read.
func _param(name: StringName, value: Variant) -> void:
	material.set_shader_parameter(name, value)
	toys_flat_mat.set_shader_parameter(name, value)
	toys_shell_mat.set_shader_parameter(name, value)


## The toys' draws (wormhole_toys.gdshaderinc), drawn before the world's ray tracer (render priority
## -2, -1 against 0), each pixel's fragment on a back face. A ray from an eye in a flat universe goes
## straight until it enters the shell or ends: it meets one of that universe's toys there only
## through the toy's bounding sphere, and anything else only through the shell. So the flat pass is
## drawn over a sphere round each of the head's universe's toys, PROXY_MARGIN larger, and the
## shell's pass over a sphere round the shell; with the head in the curved region, where no chart
## maps it to the room, the shell's pass covers the whole view.
func _add_toy_draws() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 32
	sphere.rings = 16
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true          # the toy's bit
	mm.mesh = sphere
	mm.instance_count = 12 + 6
	mm.visible_instance_count = 0
	toys_flat = MultiMeshInstance3D.new()
	toys_flat.multimesh = mm
	toys_flat.material_override = toys_flat_mat
	toys_flat.extra_cull_margin = 16384.0
	toys_flat.visible = false
	origin.add_child(toys_flat)
	shell_sphere = SphereMesh.new()
	shell_sphere.radius = 1.0
	shell_sphere.height = 2.0
	# coarse: every vertex of the shell's pass works out the near toys' cones (toys_view.gdshaderinc);
	# its faces lie inside the sphere by up to 1.7%, within PROXY_SLACK
	shell_sphere.radial_segments = 24
	shell_sphere.rings = 12
	full_view = QuadMesh.new()
	full_view.size = Vector2(2.0, 2.0)
	# put straight into clip space (POSITION = VERTEX.xy, toys_view.gdshaderinc), the quad is wound as a
	# back face, as the faces of the proxy sphere it stands in for are (the pass culls front faces)
	toys_shell = MeshInstance3D.new()
	toys_shell.mesh = shell_sphere
	toys_shell.material_override = toys_shell_mat
	toys_shell.extra_cull_margin = 16384.0
	toys_shell.visible = false
	origin.add_child(toys_shell)


## Each frame: the proxies placed in the room from where the head is (as the ray tracer places
## the eyes: in a flat universe the play-space offset from the head along the head's frame), or
## the whole view.
func _update_toy_draws(l: float, n: Vector3, hf: Array, head_pos: Vector3) -> void:
	_update_cones(l, n)
	var on := balls > 0 and toys_shown
	toys_shell.visible = on
	var flat := on and absf(l) > space.L
	toys_flat.visible = flat
	toys_shell.mesh = shell_sphere if flat or not on else full_view
	toys_shell_mat.set_shader_parameter("wht_full", not flat)
	if not flat:
		return
	var side := 1.0 if l > 0.0 else -1.0
	var to_play := chart_to_play(l, n, hf, head_pos)
	toys_flat_mat.set_shader_parameter("wht_toChart", Projection(to_play.affine_inverse()))
	toys_flat_mat.set_shader_parameter("wht_side", side)
	var s := shell_proxy()
	toys_shell.transform = Transform3D(Basis.from_scale(Vector3.ONE * s.w), to_play * Vector3(s.x, s.y, s.z))
	var mm := toys_flat.multimesh
	var count := 0
	for bit in toy_proxies(side):
		var c: Vector4 = toy_chart[bit][1]
		var r := (c.w + PROXY_MARGIN) * PROXY_SLACK
		mm.set_instance_transform(count, Transform3D(Basis.from_scale(Vector3(r, r, r)), to_play * Vector3(c.x, c.y, c.z)))
		mm.set_instance_custom_data(count, Color(float(bit), 0.0, 0.0, 0.0))
		count += 1
	mm.visible_instance_count = count


## The toys near the head (at l, n), up to four, nearest first: the shell's pass's vertex stage
## gives each the cone of directions from each eye that can meet it (wht_coneAt in
## wormhole_toys.gdshaderinc, exact up to a geodesic distance of 0.45 pi rho0: ref/cull.py), and a
## ray outside it skips it. A ball held near the eye inside the shell is otherwise searched by every
## ray whose plane passes near it, most of the view.
func _update_cones(l: float, n: Vector3) -> void:
	var H := space.embed(l, n)
	var near := []
	for k in toy_list.size():
		var t: Array = toy_list[k]
		var dd: float = (t[1] - H).length() - t[2]
		if dd < CONE_NEAR:
			near.append([dd, k])
	near.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var cones := PackedVector4Array()
	var cr := Vector4.ZERO
	var ci := Vector4i(-1, -1, -1, -1)
	for j in 4:
		if j < near.size():
			var k: int = near[j][1]
			var t: Array = toy_list[k]
			var pn := space.point_of(t[1])
			var cn: Vector3 = pn[1]
			cones.append(Vector4(cn.x, cn.y, cn.z, pn[0]))
			cr[j] = t[2]
			ci[j] = k
		else:
			cones.append(Vector4(1.0, 0.0, 0.0, 0.0))
	toys_shell_mat.set_shader_parameter("wht_cone", cones)
	toys_shell_mat.set_shader_parameter("wht_coneR", cr)
	toys_shell_mat.set_shader_parameter("wht_coneIdx", ci)


## With the head in a flat universe (at l, n, its play axes hf, at head_pos in the room): its chart ->
## play space, a rigid motion (a mirror in universe B, whose chart is mirrored).
func chart_to_play(l: float, n: Vector3, hf: Array, head_pos: Vector3) -> Transform3D:
	var side := 1.0 if l > 0.0 else -1.0
	var ch := space.chart_position(l, n)
	# the chart directions of the play axes (the head's frame, as (U_l, u))
	var v := []
	for k in 3:
		var U: Vector4 = hf[k]
		var d := side * U.x * n + Vector3(U.y, U.z, U.w)
		if side < 0.0:
			d.x = -d.x
		v.append(d)
	# chart -> play: head_pos + (d . v_k)_k for d = X - ch
	var B := Basis(v[0], v[1], v[2]).transposed()
	return Transform3D(B, head_pos - B * ch)


## The bits of the toys of universe side, which the flat pass draws with the head there.
func toy_proxies(side: float) -> Array:
	var out := []
	var m := toy_mask.x if side > 0.0 else toy_mask.y
	for bit in 32:
		if m & (1 << bit):
			out.append(bit)
	return out


## The shell's proxy sphere in a flat universe's chart (centre, the mesh's radius).
func shell_proxy() -> Vector4:
	return Vector4(0.0, 0.0, 0.0, space.Rout * PROXY_SLACK)


## A pixel's angle in the middle of the view, radians (soft edges of the gravity arrows and the
## cubes' edge lines): the headset's field of view is about 104 degrees up and down.
func _pixel_angle() -> float:
	var h := float(get_viewport().get_visible_rect().size.y)
	var fov := deg_to_rad(camera.fov)
	if in_xr:
		h = xr.get_render_target_size().y * xr_view.scaling_3d_scale
		fov = deg_to_rad(104.0)
	return 2.0 * tan(0.5 * fov) / maxf(h, 1.0)


## Gravity for the gravity view's ray tracer: f / r and f' as the shader evaluates them
## (WormholeSpace.gravity_shader). A change of the throat's shape needs them again.
func _upload_gravity() -> void:
	var g := space.gravity_shader()
	_param("grav_cyl", g.cyl)
	_param("grav_g", PackedVector4Array(g.g))
	_param("grav_d", PackedVector4Array(g.d))
	_param("wh_pix", _pixel_angle())


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


## The ray tracer's fillet polynomials by impact parameter (WormholeSpace.fillet_table). A change
## of the throat's shape needs them again.
func _upload_fillet_table() -> void:
	var tab := space.fillet_table()
	_param("wh_tab", ImageTexture.create_from_image(tab.image))
	_param("wh_tabLo", tab.lo)
	_param("wh_tabInv", tab.inv)
	_param("wh_tabReg", tab.reg)


## Static objects come from scene.json, the same file the tests read.
func _upload_scene() -> void:
	var to_v4 := func(rows: Array) -> PackedVector4Array:
		var out := PackedVector4Array()
		for r in rows:
			out.append(Vector4(r[0], r[1], r[2], r[3]))
		return out
	_param("wh_sph", to_v4.call(scene["spheres_A"] + scene["spheres_B"]))
	_param("wh_pil", to_v4.call(scene["pillars_A"]))
	_param("wh_box", to_v4.call(scene["boxes_B"]))
	_param("wh_nBall", 0)
