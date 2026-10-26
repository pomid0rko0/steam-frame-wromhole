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
# the ray tracer without movable balls, and with them (set_balls)
const SHADER_PLAIN := preload("res://shaders/wormhole.gdshader")
const SHADER_BALLS := preload("res://shaders/wormhole_balls.gdshader")
const SHADER_GRAVITY := preload("res://shaders/wormhole_gravity.gdshader")    # set_gravity_view 1
const SHADER_ARROWS := preload("res://shaders/wormhole_arrows.gdshader")      # set_gravity_view 2
const SHADER_BALLS_GRAVITY := preload("res://shaders/wormhole_balls_gravity.gdshader")   # with balls
const SHADER_BALLS_ARROWS := preload("res://shaders/wormhole_balls_arrows.gdshader")
# the pixels whose rays may meet a toy (_update_proxies), and all of them
const SHADER_MARK := preload("res://shaders/stencil_mark.gdshader")
const SHADER_MARK_ALL := preload("res://shaders/stencil_mark_all.gdshader")
# m around each sphere: more than the near plane (camera.near). A ray that meets a toy inside its
# sphere leaves the sphere at least this far beyond the hit, so it is marked even where the near
# plane clips the sphere's near side.
const PROXY_MARGIN := 0.08
const PROXY_SLACK := 1.02       # the proxy mesh's faces lie inside its sphere (by 0.4%): grown by this
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
var toys_drawn := -1            # balls and cubes the shader was last given (_upload_toys)
var pixel_angle := 0.0          # wh_pix as last set (_pixel_angle)
var xr: XRInterface
var xr_name := "OpenXR"        # tests use "Native mobile": Godot's own stereo renderer, same multiview path
var in_xr := false

var xr_view: SubViewport       # XR renders here, so the desktop window gets no mirror image
var origin: XROrigin3D
var camera: XRCamera3D
var material: ShaderMaterial    # the ray tracer: with the toys where there are any, else the plain one
# With toys, the plain ray tracer draws where no ray can meet one (a quad of its own, its stencil
# test the other way): the one with toys holds more registers and costs more even where it finds
# nothing (README, «Мячи и кубы»).
var plain_material: ShaderMaterial
var plain_quad: MeshInstance3D
var proxies: MultiMeshInstance3D    # spheres around the shell and this universe's toys (play space)
var mark_all: MeshInstance3D        # the whole view instead
# how the toys' ray tracer is given its pixels: TOYS_SPLIT by the stencil (the plain one elsewhere),
# TOYS_WHOLE the whole view marked, TOYS_BARE no stencil at all (for a ray tracer without the
# stencil test: other sources' in the speed check)
enum {TOYS_BARE, TOYS_WHOLE, TOYS_SPLIT}
var toy_mode := TOYS_SPLIT
var toy_spheres := [PackedVector4Array(), PackedVector4Array()]   # per universe A, B: the toys' chart spheres

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
# per hand (left, right): where it is in the curved space and what it holds (_track_hands, _use_hands)
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
var balls := 0                  # movable balls and cubes in the ray tracer (set_balls, _upload_toys)
var gravity_view := 0           # 0 off, 1 the floor coloured by gravity, 2 also arrows of its field


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
	plain_material = ShaderMaterial.new()       # its shader only with toys (_pick_shader)
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
	_add_proxies()

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
	# the hands where they are this frame, with where they want what they hold, then the toys up
	# to this frame, pulled there by the hands' finite strength, then what the grips do: a toy let
	# go flies on from where this frame's pull left it
	_track_hands(hp, head)
	_toys(delta)
	_use_hands()
	if physics:
		_upload_toys()
	_update_proxies(hp[0], hp[1], hf, head.origin)


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
# a crate too heavy for one hand (18 kg: BallWorld.HAND_FORCE lifts 15), to the left of the start:
# two hands at its sides lift it
const CRATE_HALF := 0.45
const CRATE_SPOT := Vector2(9.3, -3.0)
const CRATE_YAW := 0.25
const CRATE_COLOR := Color(0.62, 0.44, 0.26)


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
	_cube_on_floor(CRATE_SPOT, CRATE_HALF, CRATE_YAW, CRATE_COLOR)
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
## distance in R^4), then the hands' balls; a cube's 4D box (centre, four axes over the half
## size) and colour.
func _upload_toys() -> void:
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


# ---------------------------------------------------------------- the hands
const HAND_RADIUS := 0.04        # m: the ball drawn at each hand's grip; it pushes the toys
const GRAB_REACH := 0.12         # m from the hand's centre to a toy's surface: the grip takes it
const GRIP_ON := 0.7             # the grip's value that grabs, and the one below which it lets
const GRIP_OFF := 0.45           # go: apart, so a half-closed hand does not grab and drop by turns
const HAND_COLOR := Color(0.55, 0.62, 0.75)
const HAND_COLOR_READY := Color(0.35, 0.95, 0.5)   # a toy within reach, or held
const VELOCITY_WINDOW := 0.06    # s of recent places a velocity is taken from (_velocity)
const STALE := 0.1               # s: places older than this give no velocity (tracking lost)
const HAND_JUMP := 0.25          # m in a frame (18 m/s at 72 Hz): a hand that jumps farther, or comes
								 # back after it lost its tracking, has no motion before (a glitch)
const SET_DOWN_SPEED := 0.15     # m/s and rad/s: a toy let go slower than this, turning slower
const SET_DOWN_SPIN := 1.0       # than this, is set down at rest
const NEW_BALL_RADIUS := 0.2     # right B: a new ball in the right hand
const NEW_CUBE_HALF := 0.15      # left X: a new cube in the left hand


## Each hand in the curved space: the geodesic from the head along the hand's offset in the room
## (as the shader places each eye), with the room's axes carried along it, the hand's own axes
## from its pose there, its velocity, spin and acceleration from its recent places; and where it
## wants what it holds (_aim), which the physics then pulls there with a hand's finite strength
## (BallWorld, holding). Nothing during the speed check (it times the same scene at every pose; the
## hands are not drawn then).
func _track_hands(hp: Array, head: Transform3D) -> void:
	if not in_xr:
		return
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
			var was_at: Vector4 = space.embed(st["l"], st["n"]) if st.get("tracked", false) else Vector4.INF
			if not (space.embed(at[0], at[1]) - was_at).length() < HAND_JUMP:
				st.erase("hist")
			st["l"] = at[0]
			st["n"] = at[1]
			st["F"] = [WormholeSpace.combine(at[2], b.x), WormholeSpace.combine(at[2], b.y),
					WormholeSpace.combine(at[2], b.z)]
			_remember(st, "hist", [clock, at[0], at[1], st["F"]])
			var motion := _velocity(st["hist"])
			st["U"] = motion[0]
			st["w"] = motion[1]
			st["acc"] = motion[2]
			st["on"] = true
		st["tracked"] = st["on"]
		# where the hand wants its toy now; the viewer moved: it jumps with the hand
		if st.has("held"):
			_aim(i)
			if st["on"] and st.get("snap", false):
				world.snap(st["held"], c.tracker)
		if st["on"]:
			st.erase("snap")


## The grips: each grabs the nearest toy within reach (the other hand may hold it too) and lets it
## go (_take, _release); right B and the D-pad down (left X on other controllers) put a new ball or
## cube in the hand, not while the menu is open (they are its). After the physics' step: a toy let
## go flies on from where the hand's pull had it this frame.
func _use_hands() -> void:
	if not in_xr:
		return
	var new_ball := _pressed_once("new_ball", right_hand.is_button_pressed(&"by_button")) and not menu_active
	var new_cube := _pressed_once("new_cube", left_hand.is_button_pressed(&"ax_button")
			or left_hand.is_button_pressed(&"dpad_down")) and not menu_active
	for i in grips.size():
		var c := grips[i]
		var st := hand_state[i]
		if hold or await_pose or not physics:
			continue
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
		if b["holds"].has(grips[i].tracker):
			continue
		var d := world.distance_to(b, P)
		if d < best_d:
			best_d = d
			best = b
	return best


## Hand i takes the toy where it is: from now on it wants it at that place and turn against the
## hand, an offset in the hand's axes (the geodesic from the hand that reaches it) and the toy's
## axes in the hand's axes carried there, and holds it at the toy's point where the hand's centre
## is (BallWorld.take). Held by the other hand too, both hold it.
func _take(i: int, toy: Dictionary) -> void:
	var st := hand_state[i]
	_release(i)
	var D := space.toward(st["l"], st["n"], toy["l"], toy["n"])
	st["held"] = toy
	st["off"] = BallWorld.to_body(st["F"], D)
	var at := _hold_point(st)
	# a ball gets axes while held: the hand's, carried to it (or those the other hand gave it)
	var axes: Array = toy["F"] if toy.has("F") else toy.get("hF", at[2])
	var rel := []
	for A: Vector4 in axes:
		rel.append(BallWorld.to_body(at[2], A))
	st["rel"] = rel
	# the hand's centre seen from the toy's: back along the offset, in the toy's axes
	world.take(toy, grips[i].tracker, BallWorld.to_body(axes, WormholeSpace.combine(at[2], -st["off"])), at[2])
	_aim(i)
	grips[i].trigger_haptic_pulse(&"haptic", 0.0, 0.6, 0.06, 0.0)
	print("grab: %s hand takes a %s (%.2f m from the hand, %.1f kg)%s" % [_hand_name(i),
			"cube" if toy.has("F") else "ball", D.length(), BallWorld.mass_kg(toy),
			", with the other hand" if toy["holds"].size() > 1 else ""])


## Where hand st holds its toy: the end of the geodesic of its offset, with the hand's axes there
## (and the vectors in extra carried along).
func _hold_point(st: Dictionary, extra := []) -> Array:
	var D := WormholeSpace.combine(st["F"], st["off"])
	var carried: Array = st["F"] + extra
	if D.length() < 1e-7:
		return [st["l"], st["n"], carried]
	return space.geodesic(st["l"], st["n"], D / D.length(), D.length(), carried)


## Where hand i wants its toy (BallWorld.aim): at its offset, turned as it was against the hand,
## moving as it would if the hand carried it: the hand's velocity carried there plus the hand's
## spin times the offset. A hand without tracking wants it where it last did, at rest. The hand's
## acceleration goes with it (the physics' substeps are before the frame: where the hand was then).
func _aim(i: int) -> void:
	var st := hand_state[i]
	var toy: Dictionary = st["held"]
	var tracker: StringName = grips[i].tracker
	if not st["on"]:
		var h: Dictionary = toy["holds"][tracker]
		world.aim(toy, tracker, h["l"], h["n"], h["A"], Vector4.ZERO, Vector4.ZERO, Vector4.ZERO)
		return
	var U: Vector4 = st.get("U", Vector4.ZERO)
	var w: Vector3 = st.get("w", Vector3.ZERO)
	var at := _hold_point(st, [U, st.get("acc", Vector4.ZERO)])
	var hf: Array = at[2].slice(0, 3)
	var rel: Array = st["rel"]
	world.aim(toy, tracker, at[0], at[1], [WormholeSpace.combine(hf, rel[0]),
			WormholeSpace.combine(hf, rel[1]), WormholeSpace.combine(hf, rel[2])],
			at[2][3] + WormholeSpace.combine(hf, w.cross(st["off"])), WormholeSpace.combine(hf, w), at[2][4])


## Hand i lets its toy go: it flies on as it moves (the hand's finite strength gave it that motion);
## slower than SET_DOWN_SPEED and SET_DOWN_SPIN it is set down at rest (the tracking's tremble
## would push it). Held by the other hand too, that one keeps it.
func _release(i: int) -> void:
	var st := hand_state[i]
	if not st.has("held"):
		return
	var toy: Dictionary = st["held"]
	st.erase("held")
	world.let_go(toy, grips[i].tracker)
	toy["ghost"] = grips[i].tracker      # this hand does not push it until they are apart
	if not toy["holds"].is_empty():
		print("let go: %s hand, the other hand holds the %s" % [_hand_name(i), "cube" if toy.has("F") else "ball"])
		return
	var U: Vector4 = toy["U"]
	var spin: Vector3 = toy["w"] if toy.has("F") else Vector3.ZERO
	var gentle := U.length() < SET_DOWN_SPEED and spin.length() < SET_DOWN_SPIN
	if gentle:
		toy["U"] = Vector4.ZERO
		if toy.has("F"):
			toy["w"] = Vector3.ZERO
	if toy.has("F"):
		toy["still"] = 0.0
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


## The viewer was put somewhere else: the hands' places before are no motion, and what they hold
## jumps with them (snap, at the next tracked frame).
func _forget_motion() -> void:
	for st in hand_state:
		st.erase("hist")
		st["snap"] = true


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
## [the tangent velocity at the newest place, with axes F the angular velocity in the newest body
## coordinates, and the acceleration there]. The derivatives at the newest of the parabola through
## it, the oldest kept (about VELOCITY_WINDOW back) and the one half way: an average over the window
## would lag the hand by half of it, and a throw, which is an arc, would leave in the wrong
## direction. Each place is seen from the newest one (the chord of R^4 there), each turn as the
## axes carried there along the chord.
func _velocity(hist: Array) -> Array:
	var none := [Vector4.ZERO, Vector3.ZERO, Vector4.ZERO]
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
	var second := [0.0]
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
		second = [2.0 / ((t1 - t0) * (t1 - t2)), 2.0 / ((t2 - t0) * (t2 - t1))]
	var U := Vector4.ZERO
	var acc := Vector4.ZERO
	var w := Vector3.ZERO
	var spin: bool = s0.size() > 3 and not s0[3].is_empty()
	for j in picks.size():
		var s: Array = hist[picks[j]]
		var Ek := space.embed(s[1], s[2])
		var D := space.project(s0[1], s0[2], Ek - E0)
		U += weights[j] * D
		acc += second[j] * D
		if spin:
			# the axes then, carried here: their turn to the axes now, as a rotation vector
			var Fk: Array = s[3]
			var back := space.project(s[1], s[2], E0 - Ek)
			if back.length() > 1e-7:
				Fk = space.geodesic(s[1], s[2], back / back.length(), (E0 - Ek).length(), Fk)[2]
			var F0: Array = s0[3]
			var G := Basis(BallWorld.to_body(F0, Fk[0]), BallWorld.to_body(F0, Fk[1]), BallWorld.to_body(F0, Fk[2]))
			w += weights[j] * _rotation_vector(G.orthonormalized().get_rotation_quaternion())
	return [U, w, acc]


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


## Movable balls in the ray tracer: centres as points of R^4 (xyz, w), colours as (rgb, radius),
## at most 12. Without balls the ray tracer is a separate shader that leaves their code out: it
## needs registers even where no ray runs it, and the GPU then runs fewer pixels at once. The
## shader is chosen here, so set the balls at the start: changing it later costs a hitch while the
## GPU compiles the other one.
func set_balls(pos: PackedVector4Array, col: PackedVector4Array) -> void:
	set_objects(pos, col, PackedVector4Array(), PackedVector4Array(), PackedVector4Array())


## Movable balls (as set_balls) and cubes, at most 6: a cube's 4D box of R^4, cut by the space as
## a box of a 4D SDF scene: centre as a point of R^4 (cpos), four orthonormal axes divided by the
## half size (axes: three body axes tangent to the space, then its normal; four per cube),
## (rgb, half size) (ccol). The shader with balls draws both; it gets each cube's axes and then
## dot(centre, axis) for the four, five vectors per cube (wormhole_core.gdshaderinc).
## The shader gets them sorted by where they are (region_order): the flat universes' rays and the
## shell's look only at their own.
func set_objects(pos: PackedVector4Array, col: PackedVector4Array, cpos: PackedVector4Array,
		axes: PackedVector4Array, ccol: PackedVector4Array) -> void:
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
	while p.size() < 12:
		p.append(Vector4.ZERO)
		c.append(Vector4.ZERO)
		fb.append(Vector4(0.0, 0.0, 0.0, -1.0))
	while cp.size() < 6:
		cp.append(Vector4.ZERO)
		cc.append(Vector4.ZERO)
	while ax.size() < 30:
		ax.append(Vector4.ZERO)
	balls = n + nc
	if (balls > 0) != (toys_drawn > 0):
		_pick_shader()                 # only when it changes: a new shader is a hitch
	toys_drawn = balls
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
	# each universe's toys as spheres in its chart (the stencil's proxies, _update_proxies)
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
	# diagonal 2 half)
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
	# order: balls A, balls B, cubes A, cubes B
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


## How gravity is shown (README, «Гравитация через червоточину»): 0 not at all, 1 the floor
## coloured by its strength (optozorax's palette: dark is none, yellow 1 g), 2 also arrows of the
## field on the vertical surface through the wormhole that faces the start (x = 0 in both
## universes, through the throat). Ray tracers of their own (wormhole_gravity.gdshader,
## wormhole_arrows.gdshader, and with movable balls and cubes wormhole_balls_gravity.gdshader,
## wormhole_balls_arrows.gdshader).
func set_gravity_view(view: int) -> void:
	gravity_view = clampi(view, 0, GRAVITY_VIEWS.size() - 1)
	_param("wh_pix", _pixel_angle())
	_pick_shader()
	if perf:
		perf.refresh()
	print("gravity view: ", GRAVITY_VIEWS[gravity_view])


## The ray tracer for what is on: the gravity view, movable balls, or neither. With balls, the
## plain one of the same view draws where none can be seen.
func _pick_shader() -> void:
	var plain: Shader = [SHADER_PLAIN, SHADER_GRAVITY, SHADER_ARROWS][gravity_view]
	if balls > 0:
		material.shader = [SHADER_BALLS, SHADER_BALLS_GRAVITY, SHADER_BALLS_ARROWS][gravity_view]
		plain_material.shader = plain
		if plain_quad == null:
			# made once there are toys: an unused ray tracer would be compiled all the same
			plain_quad = MeshInstance3D.new()
			var q := QuadMesh.new()
			q.size = Vector2(2.0, 2.0)
			plain_quad.mesh = q
			plain_quad.material_override = plain_material
			plain_quad.extra_cull_margin = 16384.0
			plain_quad.position = Vector3(0.0, 0.0, -1.0)
			camera.add_child(plain_quad)
	else:
		material.shader = plain


## A uniform both ray tracers read.
func _param(name: StringName, value: Variant) -> void:
	material.set_shader_parameter(name, value)
	plain_material.set_shader_parameter(name, value)


## The stencil's proxies (stencil_mark.gdshader): drawn before the ray tracers (render priority
## -1), they mark the pixels whose rays may meet a movable ball or cube. A ray from an eye in a
## flat universe goes straight until it enters the shell or ends: it meets one of that universe's
## toys only through the toy's bounding sphere, and anything else only through the shell. So
## spheres around the shell and around this universe's toys, PROXY_MARGIN larger (an eye just
## inside one, where the near plane clips its near side, still has its far side), drawn from both
## sides (an eye inside a sphere sees its inside). With the head in the curved region there is no
## chart to place them in: the whole view is marked.
func _add_proxies() -> void:
	var mark := ShaderMaterial.new()
	mark.shader = SHADER_MARK
	mark.render_priority = -1
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 48
	sphere.rings = 24
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = sphere
	mm.instance_count = 1 + 12 + 6
	mm.visible_instance_count = 0
	proxies = MultiMeshInstance3D.new()
	proxies.multimesh = mm
	proxies.material_override = mark
	proxies.extra_cull_margin = 16384.0
	proxies.visible = false
	origin.add_child(proxies)
	var all := ShaderMaterial.new()
	all.shader = SHADER_MARK_ALL
	all.render_priority = -1
	mark_all = MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(2.0, 2.0)
	mark_all.mesh = q
	mark_all.material_override = all
	mark_all.extra_cull_margin = 16384.0
	mark_all.position = Vector3(0.0, 0.0, -1.0)
	mark_all.visible = false
	camera.add_child(mark_all)


## Each frame: the proxies placed in the room from where the head is (as the ray tracer places
## the eyes: in a flat universe the play-space offset from the head along the head's frame), or
## the whole view marked.
func _update_proxies(l: float, n: Vector3, hf: Array, head_pos: Vector3) -> void:
	var split := balls > 0 and toy_mode == TOYS_SPLIT and absf(l) > space.L
	proxies.visible = split
	if plain_quad:
		plain_quad.visible = split
	mark_all.visible = balls > 0 and not split and toy_mode != TOYS_BARE
	if not split:
		return
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
	var to_play := Transform3D(B, head_pos - B * ch)
	var mm := proxies.multimesh
	var count := 0
	for s in proxy_spheres(l):
		mm.set_instance_transform(count, to_play * Transform3D(Basis.from_scale(Vector3(s.w, s.w, s.w)), Vector3(s.x, s.y, s.z)))
		count += 1
	mm.visible_instance_count = count


## The proxies as spheres in the chart of the universe at l (centre, the mesh's radius: with the
## margin and the slack): the
## shell and that universe's toys; none where the whole view is marked (tools/adreno_cost.py
## --split models the split with them).
func proxy_spheres(l: float) -> PackedVector4Array:
	var out := PackedVector4Array()
	if balls == 0 or toy_mode != TOYS_SPLIT or absf(l) <= space.L:
		return out
	out.append(Vector4(0.0, 0.0, 0.0, (space.Rout + PROXY_MARGIN) * PROXY_SLACK))
	for s in toy_spheres[0 if l > 0.0 else 1]:
		out.append(Vector4(s.x, s.y, s.z, (s.w + PROXY_MARGIN) * PROXY_SLACK))
	return out


## How the ray tracer with toys gets its pixels (toy_mode; the speed check times each).
func set_toy_mode(mode: int) -> void:
	toy_mode = mode


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
