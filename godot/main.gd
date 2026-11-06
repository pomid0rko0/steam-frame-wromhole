class_name Main
extends Node3D
## Real-time wormhole for VR (README.md, docs/). The throat hangs LIFT over the floor; the renderer
## (renderer.gd) draws every image of each body along the geodesics of the wormhole space, the
## curved zone as a lens per pixel; this script builds the scene and moves the viewer through that
## curved space: walking in the room, with the sticks along the floor and flying off it as a ship
## (the buttons: README.md, «Управление»).
##
## The viewer's body (viewer.gd): the room's floor under the head and the room's axes there, on the
## floor or flying; physical movement in the room, the sticks and the triggers move it along
## geodesics, carrying the axes; stick turns rotate them about up, and flying pitch and roll them
## about the head; the head is its height in the room along up. Each eye is derived in the shaders
## from that view's own matrices (shaders/geo.gdshaderinc, geo_eye).
##
## The parts: the space's geometry (wormhole_space.gd), the viewer's body (viewer.gd), the renderer
## (renderer.gd), the demo's balls and cubes in gravity through the wormhole (toys.gd,
## ball_world.gd), the hands that grab, throw and pull them (hands.gd), the zone bodies' meshes and
## the field lines' places in the view once a frame (zone_sections.gd), foveated rendering
## (foveation.gd), the menu and the line under it (menu.gd) with the measured frame rate
## (frame_rate.gd, rate_meter.gd), the speed check (bench.gd) and the stereo check scene
## (check_scene.gd). Each frame (_process): the menu takes its buttons,
## then the turn, the reset and the gravity view's button, the body's motion (_locomotion), the free
## toys (pushed by the hands where they were), the hands and what they hold, and last the toys and
## the head to the renderer: a toy let go now starts from the hand. Godot then draws the frame on its
## render thread (render_thread) while this goes on with the next one: what the GPU's passes take
## from a frame goes to them queued with it (foveation.gd's top, «Threads»), never straight.
##
## A new button: while the menu is open (menu_active, also the frame that closes it) its buttons,
## and those that open it (README.md, «Управление»), are the menu's; during the speed check (hold)
## the body stays, and the sticks, A, the gravity view's button, the hands and the toys do nothing. A
## new action goes into openxr_action_map.tres and tests/util.gd alike (BINDINGS per profile, POSES
## or STICKS for one every controller has; the tests compare them exactly), in the Frame's profile
## with Valve's paths. Jumps of the viewer (place, set_pose, a snap turn, a recentre, a landing) call
## hands.forget_motion, or the jump would be a throw.
##
## The controllers. Valve's page «Steam Frame Input»
## (https://partner.steamgames.com/doc/steamhardware/steamframe/input) lists the Frame's paths: left
## dpad_up/down/left/right, view, system, bumper; right a, b, x, y, menu, system, bumper; both
## squeeze, trigger, thumbstick, grip/pose, aim/pose, output/haptic. SteamVR takes the Frame's
## profile if the app offers it, else the generic one, else Touch remapped (Touch's menu is View,
## its upper button all three upper buttons). One path a runtime rejects drops the whole profile
## (Monado rejects grip_surface/pose on Touch). Which profile SteamVR gave is in the log
## (_log_profiles): in the headset it is our Frame profile.

# the video's throat (docs/geometry.md, «Пространство»); its cylinder's length the menu changes
# (set_length) and keeps for the next start
const THROAT_RADIUS := 3.0
const HALF_LENGTH := 5.0
const FILLET := 1.0
const LENGTH := 2.0 * (HALF_LENGTH - FILLET)   # m: the video's cylinder
const LIFT := 5.0                   # m: the throat's centre above the floor (above the curved zone's radius, 4 m)
const WALK_SPEED := 1.5             # metres per second at full stick
const RUN_SPEED := 4.0
const FLY_SPEED := 4.0              # flying: metres per second at full stick or trigger
const STICK_DEAD_ZONE := 0.15
const SNAP_ANGLE := deg_to_rad(30.0)
const SMOOTH_TURN_SPEED := deg_to_rad(90.0)   # per second at full stick
const TILT_SPEED := deg_to_rad(60.0)   # flying: pitch per second at full stick, roll with a bumper held
const START_POS := Vector3(10.0, 0.0, 0.0)   # chart A, on the floor
const START_FORWARD := Vector3(-1.0, 0.0, 0.0)
const NEAR := 0.01                  # m: the camera's near plane: what comes closer to an eye is cut
const FAR := 4000.0                 # m: the far plane (far over near well under float32's 1e7, or Godot can't
                                    # read it back from the projection); the tail's deeper images: zone_tail
const DESKTOP_HEAD_HEIGHT := 1.6
const MOUSE_SENS := 0.003
const GAZE_DOT_DIST := 1.5          # m along the gaze: where the gaze dot is drawn
const GAZE_HOLD := 0.5              # s the foveation's fovea stays where the eyes last looked while they are not tracked (a blink)

var space := WormholeSpace.new(THROAT_RADIUS, HALF_LENGTH, FILLET, LIFT)
var viewer := Viewer.new(space)
var scene: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://scene.json"))
var toys := Toys.new(space, scene)
var hands := Hands.new(space, toys.world)
var xr_name := "OpenXR"         # tests: "FakeHMD" (tests/fake_hmd.gd), "Native mobile", "none" (the desktop)
var show_check := OS.has_feature("check")   # the export preset for the one-eye check (tools/export.sh --check)
var xr: XRInterface
var in_xr := false
var xr_view: SubViewport        # XR renders here, so the desktop window gets no mirror image
var origin: XROrigin3D
var camera: XRCamera3D
var renderer: Renderer
var foveation: Foveation
var rate: FrameRate
var menu: Menu
var bench: Bench
var overlay: Node3D             # the stereo check's Godot geometry in chart A (_update_chart_map)
var chart_map_stale := false    # the body was where there is no chart map: made again once out
var left_hand: XRController3D   # at their aim pose: the buttons and sticks (XR only)
var right_hand: XRController3D
var gaze: XRNode3D              # where the eyes look (XR_EXT_eye_gaze_interaction), XR only
var gaze_dot: MeshInstance3D    # drawn where they look, if the menu says so
var gaze_dir := Vector3.FORWARD # where they look in the head's space, for the foveation's fovea
var gaze_lost := INF            # s since they were last tracked
var prev_head := Vector2.ZERO
var recentered := false         # the runtime moved the play space: not a step
var await_pose := false         # XR: place the viewer once head tracking delivers a pose
var hold := false               # the speed check holds the viewer (what does nothing then: this file's top)
var view_pitch := 0.0           # degrees: the view turned up and about the line of sight on top of
var view_roll := 0.0            # the head's own (the speed check; the head stays where it is)
var desktop_yaw := 0.0
var desktop_pitch := 0.0
var smooth_turn := true         # false: snaps of SNAP_ANGLE
var snap_armed := true          # the right stick went back to the middle since the last turn
var roll_armed := true          # the bumpers let go since the last roll in snaps
var menu_active := false        # the menu was open this frame: its buttons are its (Menu.handle_input)
var tilting := false            # flying, pitched or rolled this frame (_turns_and_reset)
var was := {}                   # buttons down last frame (_pressed)
var logged_profiles := {}
var scripts_ms := 0.0           # ms the last _process took (frame_rate.gd's lines about late frames)
# Godot renders on a thread of its own (project.godot's thread model "Separate", or as the menu last
# chose it for this start: Menu.set_render_thread), the main thread meanwhile on the next frame;
# else on the main thread after the scripts. Known from the first call on the render thread.
var render_thread := false
# and its parts, PARTS, ms; when it started (Time.get_ticks_usec)
const PARTS := ["input and motion", "head", "toys", "hands", "drawing", "to the shaders"]
var parts_ms := PackedFloat32Array([0, 0, 0, 0, 0, 0])
var started_us := 0
# the first frames are drawn without foveation and with it (Foveation.set_level), then with the
# menu's: its pipelines compile while the app starts, not at the first switch in the menu (a stall
# on the Frame, and SteamVR at half rate after it); Renderer does the same for the gravity views
const WARM_FOVEATION := [0, 1]
var warm := 0                   # frames of it done
var _head_pose: Array = [0.0, Vector3.RIGHT, []]   # the head this frame: [l, n, frame] (the speed check's cube)


func _ready() -> void:
	# which build this is (tools/export.sh writes it into the export)
	var build: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://build.json")) \
			if FileAccess.file_exists("res://build.json") else null
	print("build: ", build.get("commit", "?") if build is Dictionary else "the source, not an export")
	RenderingServer.call_on_render_thread(_on_render_thread.bind(OS.get_main_thread_id()))
	xr = XRServer.find_interface(xr_name)
	var host: Node = self
	if xr and xr.is_initialized():
		in_xr = true
		var oxr := xr as OpenXRInterface
		if oxr:
			# methods, not lambdas: a lambda left connected to the interface corrupts memory at exit (Monado)
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
	space.set_length(Menu.saved_length(LENGTH))
	print("throat: ", length_text())

	origin = XROrigin3D.new()
	host.add_child(origin)
	camera = XRCamera3D.new()
	camera.near = NEAR
	camera.far = FAR
	camera.compositor = Compositor.new()
	origin.add_child(camera)
	if in_xr:
		_add_controllers()
	else:
		camera.position = Vector3(0.0, DESKTOP_HEAD_HEIGHT, 0.0)
	renderer = Renderer.new(space, scene, xr, xr_view)
	camera.add_child(renderer)
	foveation = renderer.foveation
	foveation.target = target
	camera.compositor.compositor_effects = [foveation, renderer.zone_sections]

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
	menu.xr = xr as OpenXRInterface
	menu.head = camera
	bench.menu = menu
	add_child(bench)                # first: the menu asks it what it compares
	origin.add_child(menu)

	place(START_POS, START_FORWARD)
	if show_check:
		toys.enabled = false            # the check's red balls take the shader's ball slots
		overlay = Node3D.new()
		origin.add_child(overlay)
		CheckScene.build(overlay, space, renderer)
		_update_chart_map()
	elif toys.enabled:
		toys.spawn()
		draw_toys()


func _notification(what: int) -> void:
	# freed (the tests start the app again): first the render thread done with all it was given, the
	# calls queued to the parts below too (foveation.gd's top, «Threads»), before they go
	if what == NOTIFICATION_PREDELETE:
		RenderingServer.force_sync()


## On the render thread, once: whether it is the main one.
func _on_render_thread(main_id: int) -> void:
	render_thread = OS.get_thread_caller_id() != main_id
	print("render thread: ", "of its own" if render_thread else "the main one")


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
		hands.add(g, c)
		if t == &"left_hand":
			left_hand = c
		else:
			right_hand = c
	# the eyes' gaze, from SteamVR's eye tracking: in the log's lines, and a dot drawn there on
	# request (the menu), to see whether the foveation's fovea follows it
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
	var t0 := Time.get_ticks_usec()
	started_us = t0
	if await_pose and not camera.transform.is_equal_approx(Transform3D.IDENTITY):
		# the first tracked pose: face the start direction from where the head actually is
		await_pose = false
		place(START_POS, START_FORWARD)
	if in_xr:
		_log_profiles()
		if warm <= WARM_FOVEATION.size():
			foveation.set_level(WARM_FOVEATION[warm] if warm < WARM_FOVEATION.size() else menu.foveation)
			warm += 1
	# stick motion over at most 0.1 s: a long frame (back from the SteamVR dashboard) is no leap
	var dt := minf(delta, 0.1)
	menu_active = menu.handle_input(dt)
	var moved := false if hold else _turns_and_reset(dt, camera.transform.origin.y)
	# its button (README.md, «Управление») / G: the next gravity view (not during the speed check:
	# it times what it set up)
	var grav_down := Input.is_key_pressed(KEY_G)
	if in_xr:
		for b in [&"by_button", &"dpad_up", &"dpad_left", &"dpad_right"]:
			grav_down = grav_down or left_hand.is_button_pressed(b)
	if _pressed("gravity", grav_down) and not hold and not menu_active:
		set_gravity_view((renderer.gravity_view + 1) % Renderer.GRAVITY_VIEWS.size())

	var head := camera.transform   # play space (the origin never moves)
	var hz := Vector2(head.origin.x, head.origin.z)
	if recentered:
		prev_head = hz
		recentered = false
		moved = true
		hands.forget_motion()
	var step := hz - prev_head
	prev_head = hz
	if not hold and _locomotion(step, dt, head.origin.y):
		moved = true
	if moved:
		# the controls or a recentre moved the world against the room; physical walking does not
		_update_chart_map()
	if gaze_dot and gaze_dot.visible:
		gaze_dot.position = gaze.transform.origin - gaze.transform.basis.z * GAZE_DOT_DIST
	# the foveation's fovea where the eyes look, in the head's space; without eye tracking ahead
	if gaze and gaze.get_has_tracking_data():
		gaze_dir = camera.transform.basis.inverse() * -gaze.transform.basis.z
		gaze_lost = 0.0
	else:
		gaze_lost += delta
		if gaze_lost > GAZE_HOLD:
			gaze_dir = Vector3.FORWARD
	foveation.set_gaze(gaze_dir, gaze_lost <= GAZE_HOLD)

	# the head along up from the feet; the shader moves from the head to each eye
	var t1 := Time.get_ticks_usec()
	var hp := viewer.head(head.origin.y)
	if overlay:
		# the chart -> play map only exists with the feet in the flat part of sheet A, and Godot's
		# geometry is seen right only from there: the head there too
		var shown: bool = viewer.l > space.L and hp[0] > space.L
		if not shown:
			chart_map_stale = true
		elif chart_map_stale:
			_update_chart_map()
		overlay.visible = shown
	var hf: Array = hp[2]
	if view_pitch != 0.0 or view_roll != 0.0:
		hf = Viewer.tilt(hf, deg_to_rad(view_pitch), deg_to_rad(view_roll), _head_forward_xz())
	_head_pose = [hp[0], hp[1], hf]
	# in the order the top of this file gives; nothing during the speed check: it times the same
	# scene at every pose
	var active := toys.enabled and not await_pose and not hold
	var t2 := Time.get_ticks_usec()
	if active:
		toys.step(delta, hands.balls())
	var t3 := Time.get_ticks_usec()
	var new_ball := in_xr and _pressed("new_ball", right_hand.is_button_pressed(&"by_button")) and not menu_active
	var new_cube := in_xr and _pressed("new_cube", left_hand.is_button_pressed(&"ax_button")
			or left_hand.is_button_pressed(&"dpad_down")) and not menu_active
	hands.update(delta, hp, head, active, new_ball, new_cube)
	var t4 := Time.get_ticks_usec()
	if toys.enabled:
		draw_toys()
	var t5 := Time.get_ticks_usec()
	renderer.set_head(hp[0], hp[1], hf, head.origin)
	var t6 := Time.get_ticks_usec()
	scripts_ms = (t6 - t0) / 1000.0
	var stamps := [t0, t1, t2, t3, t4, t5, t6]
	for i in PARTS.size():
		parts_ms[i] = (stamps[i + 1] - stamps[i]) / 1000.0


func draw_toys() -> void:
	toys.draw(renderer, hands.drawn(), bench.extras(_head_pose, camera.transform.basis), hands.lit())
	var b := hands.beams()
	for i in b.size():
		renderer.set_beam(i, b[i][0], b[i][1], b[i][2])


## Stand on the floor of universe side (+1 A, -1 B) at chart position pos (its z ignored), looking
## along forward (its part along the floor), the view turned pitch degrees up and roll degrees about
## the line of sight (right side up) on top of the head's own (the speed check).
func place(pos: Vector3, forward: Vector3, side := 1.0, pitch := 0.0, roll := 0.0) -> void:
	var f := Vector3(forward.x, forward.y, 0.0).normalized()
	viewer.stand_at(side, Vector2(pos.x, pos.y), Vector3(0.0, 0.0, 1.0).cross(-f), -f)
	_face_head()
	hands.forget_motion()
	view_pitch = pitch
	view_roll = roll


## Fly, at rest, with the head at l on the axis through the throat's centre (n = +x: in chart A the
## line (x, 0, LIFT), in chart B (-x, 0, LIFT)), the room upright in chart A's axes, looking yaw
## degrees to the right of the direction of falling l (toward the throat at l > 0, away from it at
## l < 0; the head's own yaw is taken out); the view turned pitch degrees up and roll degrees about
## the line of sight (right side up) on top of the head's own: the speed check. Along the axis the
## room's axes stay as they are (a radial path carries every vector as it is, in (U_l, u)), so it
## is upright in chart B too.
func place_on_axis(l: float, yaw := 0.0, pitch := 0.0, roll := 0.0) -> void:
	# right, up, back as (U_l, u): back is +l (facing the throat at l > 0), right is +y of chart A
	viewer.fly_at(l, Vector3(1.0, 0.0, 0.0),
			[Vector4(0.0, 0.0, 1.0, 0.0), Vector4(0.0, 0.0, 0.0, 1.0), Vector4(1.0, 0.0, 0.0, 0.0)], camera.transform.origin.y)
	viewer.turn(deg_to_rad(yaw))
	_face_head()
	hands.forget_motion()
	view_pitch = pitch
	view_roll = roll


## Where the body is (Viewer.get_state: the feet, the frame there, ...), to come back to (set_pose).
func get_pose() -> Array:
	return viewer.get_state()


func set_pose(p: Array) -> void:
	viewer.set_state(p)
	view_pitch = 0.0
	view_roll = 0.0
	prev_head = Vector2(camera.position.x, camera.position.z)
	_update_chart_map()
	hands.forget_motion()


## Where the head looks: degrees from the direction to the throat's centre (falling |l| at the
## head) along the room's floor, and degrees up in the room.
func look_angles() -> Vector2:
	var f := -camera.transform.basis.z
	var hf: Array = _head_pose[2]
	if hf.is_empty():
		return Vector2.ZERO
	var T: Vector4 = f.x * hf[0] + f.z * hf[2]          # along the room's floor, as (U_l, u)
	var R := Vector4(-1.0 if _head_pose[0] > 0.0 else 1.0, 0.0, 0.0, 0.0)
	R -= R.dot(hf[1]) * (hf[1] as Vector4)               # along the room's floor too
	var c := T.length() * R.length()
	var yaw := rad_to_deg(acos(clampf(T.dot(R) / c, -1.0, 1.0))) if c > 1e-6 else 0.0
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


## What is before the eyes, for the log's lines about frames: the head's height and roll, standing
## or flying (the feet's height over the floor), the bodies drawn and the nearest one: its distance
## from the head to its centre (the chord of R^4: no
## longer than the geodesic, a few per cent shorter at most at 1 m, where the space bends tightest)
## and its direction from where the head looks; the settings that change what a frame draws.
func view_text() -> String:
	var b := camera.transform.basis
	var hf: Array = _head_pose[2]
	var out := "head %.2f m up, right side %.0f deg up; %s; drawn %d balls, %d cubes (in the curved zone %d balls, %d cubes)" % [camera.transform.origin.y,
			rad_to_deg(asin(clampf(b.x.y, -1.0, 1.0))), "standing" if viewer.standing else "flying, the feet %.2f m over the floor" % viewer.height(),
			renderer.ball_col.size(), renderer.toy_count - renderer.ball_col.size(), renderer.zone_count.x, renderer.zone_count.y]
	if not hf.is_empty() and not renderer.bodies.is_empty():
		var P := space.embed(_head_pose[0], _head_pose[1])
		var N := space.normal4(_head_pose[0], _head_pose[1])
		var near: Array = renderer.bodies[0]
		for body: Array in renderer.bodies:
			if (body[1] - P).length() < (near[1] - P).length():
				near = body
		var V: Vector4 = near[1] - P
		var Vt := V - V.dot(N) * N
		var to := func(v: Vector3) -> Vector4: return v.x * hf[0] + v.y * hf[1] + v.z * hf[2]
		var x: float = Vt.dot(to.call(b.x))
		var y: float = Vt.dot(to.call(b.y))
		var z: float = Vt.dot(to.call(-b.z))
		out += "; nearest: %s of %s %.2f m at %.2f m from the head to its centre, %.0f deg right %.0f deg up of the view" % [
				near[0], "radius" if near[0] == "ball" else "half size", near[2], V.length(),
				rad_to_deg(atan2(x, z)), rad_to_deg(atan2(y, Vector2(x, z).length()))]
	var target: Viewport = xr_view if in_xr else get_viewport()
	var px := Vector2i(target.get_visible_rect().size)
	return out + "; gravity view %d, foveation %d, picture %dx%d, menu %s" % [renderer.gravity_view,
			foveation.level, px.x, px.y, "open" if menu.open else "closed"]


func set_gravity_view(view: int) -> void:
	renderer.set_gravity_view(view)
	menu.refresh()


## Flying with nothing pushed: fall (with gravity) or hover (Viewer.gravity); say: also on the line
## below (a button, not the menu).
func set_fall(on: bool, say := false) -> void:
	viewer.gravity = on
	print("flying, nothing pushed: ", "falls" if on else "hovers")
	menu.refresh()
	if say:
		menu.notice("полёт: " + Menu.FALLS[0 if on else 1])


## The throat's cylinder's length, m (WormholeSpace.set_length), each frame the menu's row changes
## it: what stands in the space goes with its part of it (WormholeSpace.carried_l), the body and the
## toys (their velocities and axes as they were); a toy being pulled is let be, the hands' motion
## forgotten; the stereo check's scene, built of points of R^4, is built again.
func set_length(cylinder: float) -> void:
	var Lc0 := space.Lc
	space.set_length(cylinder)
	if space.Lc == Lc0:
		return
	var st := viewer.get_state()
	st[0] = space.carried_l(st[0], Lc0)
	viewer.set_state(st)
	for b in toys.world.balls:
		b.l = space.carried_l(b.l, Lc0)
	for c in toys.world.cubes:
		c.l = space.carried_l(c.l, Lc0)
	hands.drop_pulls()
	hands.forget_motion()
	renderer.set_length()
	if overlay:
		for c in overlay.get_children():
			c.free()
		CheckScene.build(overlay, space, renderer)
	elif toys.enabled:
		draw_toys()
	_update_chart_map()


func length_text() -> String:
	return "cylinder %.2f m, the curved zone %.2f m through, worlds %.2f m apart in R^4" \
			% [2.0 * space.Lc, 2.0 * space.L, 2.0 * space.h]


func set_smooth_turn(on: bool) -> void:
	smooth_turn = on
	print("right stick turns ", "smoothly" if smooth_turn else "in %d-degree snaps" % roundi(rad_to_deg(SNAP_ANGLE)))
	menu.refresh()


## Turn the frame so that the head's current yaw looks along its forward (play-space forward
## is -Z), and take the head's place in the room from here.
func _face_head() -> void:
	var hf := _head_forward_xz()
	viewer.turn(-atan2(hf.x, -hf.y))
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
## runtime took (the controllers: the top of this file).
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


## Right trigger up, left down / Space and C: along the room's up.
func _climb_input() -> float:
	var c := float(Input.is_key_pressed(KEY_SPACE)) - float(Input.is_key_pressed(KEY_C))
	if in_xr:
		c += right_hand.get_float(&"trigger") - left_hand.get_float(&"trigger")
	return clampf(c, -1.0, 1.0)


## Left trigger / Shift (walking only: flying, the left trigger goes down).
func _run_pressed() -> bool:
	if Input.is_key_pressed(KEY_SHIFT):
		return true
	return in_xr and left_hand.get_float(&"trigger") > 0.5


## The turns and the reset (README.md, «Управление»): the right stick across turns (yaw); flying, the
## room also pitches (the right stick up and down) and rolls (the bumpers) about the head (Viewer.
## tilt_at_head; height: the head's in the room), smoothly or in snaps as the turns go. True if a
## turn moved the view against the room (the reset redoes the chart map itself); tilting: pitched or
## rolled this frame (no turning upright then).
func _turns_and_reset(delta: float, height: float) -> bool:
	var s := Vector2.ZERO           # right stick: x yaw, y pitch
	var roll := float(Input.is_key_pressed(KEY_L)) - float(Input.is_key_pressed(KEY_J))   # to the right
	var fall_down := Input.is_key_pressed(KEY_F)
	if in_xr:
		s = right_hand.get_vector2(&"primary")
		roll += float(right_hand.is_button_pressed(&"bumper")) - float(left_hand.is_button_pressed(&"bumper"))
		fall_down = fall_down or right_hand.is_button_pressed(&"primary_click")
	s.x = clampf(s.x + float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q)), -1.0, 1.0)
	s.y = clampf(s.y + float(Input.is_key_pressed(KEY_I)) - float(Input.is_key_pressed(KEY_K)), -1.0, 1.0)
	roll = clampf(roll, -1.0, 1.0)
	if viewer.standing:
		s.y = 0.0
		roll = 0.0
	if _pressed("turn_mode", Input.is_key_pressed(KEY_TAB)):
		set_smooth_turn(not smooth_turn)
	if _pressed("fall", fall_down):
		set_fall(not viewer.gravity, true)
		if in_xr:
			Menu._tick(right_hand)
	var moved := false
	tilting = false
	var fwd := _head_forward_xz()
	if smooth_turn:
		# from zero at the dead zone's edge to full speed at full stick
		var a := Vector2(maxf(absf(s.x) - STICK_DEAD_ZONE, 0.0), maxf(absf(s.y) - STICK_DEAD_ZONE, 0.0)) / (1.0 - STICK_DEAD_ZONE)
		if a.x > 0.0:
			viewer.turn(signf(s.x) * a.x * SMOOTH_TURN_SPEED * delta)
			moved = true
		if a.y > 0.0 or roll != 0.0:
			viewer.tilt_at_head(height, signf(s.y) * a.y * TILT_SPEED * delta, -roll * TILT_SPEED * delta, fwd)
			moved = true
			tilting = true
		# a switch to snaps while the stick is out waits for it to come back first
		snap_armed = s.length() < 0.3
		roll_armed = roll == 0.0
	else:
		# the stick's main axis: one snap per push
		if snap_armed and s.length() > 0.7:
			if absf(s.x) >= absf(s.y):
				viewer.turn(signf(s.x) * SNAP_ANGLE)
			else:
				viewer.tilt_at_head(height, signf(s.y) * SNAP_ANGLE, 0.0, fwd)
				tilting = true
			hands.forget_motion()           # the hands jump with the world: no throw
			snap_armed = false
			moved = true
		elif s.length() < 0.3:
			snap_armed = true
		if roll_armed and roll != 0.0:
			viewer.tilt_at_head(height, 0.0, -roll * SNAP_ANGLE, fwd)
			hands.forget_motion()
			roll_armed = false
			moved = true
			tilting = true
		elif roll == 0.0:
			roll_armed = true
	if _pressed("reset", Input.is_key_pressed(KEY_R) or (in_xr and right_hand.is_button_pressed(&"ax_button"))) and not menu_active:
		place(START_POS, START_FORWARD)    # also redoes the chart -> play map
		if toys.enabled:
			hands.empty()
			toys.spawn()
			print("toys: back in place", ", throwing again" if toys.demo else "")
	return moved


## The body's motion this frame (viewer.gd): the head's step in the room (x, z), then the sticks
## and triggers (README.md, «Управление»): the left stick along the room's floor where the head
## looks (walking or flying), the triggers along the room's up (the right one up takes off); nothing
## pushed, flying, the body coasts (falls or hovers); with gravity it turns upright unless the turns
## tilted it (tilting); the head is kept out of the floor and the feet land on it. height: the head's
## in the room. True if the sticks, a fall or a landing moved the world against the room.
func _locomotion(step: Vector2, dt: float, height: float) -> bool:
	viewer.step_room(step, height)
	var stick := Vector2.ZERO if menu_active else _move_input()
	var climb := _climb_input()     # not the menu's (as the turns)
	var speed := FLY_SPEED if not viewer.standing else (RUN_SPEED if _run_pressed() else WALK_SPEED)
	var v := Vector3.ZERO           # in the room
	if stick.length() > STICK_DEAD_ZONE:
		var fwd := _head_forward_xz()
		v += (stick.y * Vector3(fwd.x, 0.0, fwd.y) + stick.x * Vector3(-fwd.y, 0.0, fwd.x)) * speed
	if absf(climb) > STICK_DEAD_ZONE:
		v.y += climb * FLY_SPEED
	var moved := not viewer.standing
	if viewer.standing and v.y > 0.0:
		viewer.take_off()
		print("flying: off the floor at l %.2f" % viewer.l)
	if v != Vector3.ZERO:
		viewer.push(v, dt, height)
		moved = true
	else:
		viewer.coast(dt, height)
	if not tilting:
		viewer.right_up(dt, height)
	viewer.keep_head_up(height)
	if viewer.touch_down():
		hands.forget_motion()           # the hands jump with the view: no throw
		print("flying: landed at l %.2f" % viewer.l)
		moved = true
	return moved


func _head_forward_xz() -> Vector2:
	var f := -camera.transform.basis.z
	var v := Vector2(f.x, f.z)
	return v.normalized() if v.length() > 1e-4 else Vector2(0.0, -1.0)


## With the feet in the flat part of sheet A, chart coordinates and the play space differ by a
## rigid motion: computed where the body is placed and after a recentre of the play space, a stick
## step or turn, a fall or a landing, and left alone while one walks and turns in the room. The
## stereo check's overlay hangs on it (check_scene.gd). Elsewhere (the curved zone, sheet B) there is
## none, and a walk or a flight in the curved zone turns the axes against the chart: the map is made
## again as the feet come out.
func _update_chart_map() -> void:
	if overlay == null:
		return
	if viewer.l <= space.L:
		chart_map_stale = true
		return
	chart_map_stale = false
	var n := viewer.n
	var f: Array = viewer.frame
	var fc := space.chart_position(viewer.l, n)
	# columns: where play x, y, z point in the chart
	var B := Basis(WormholeSpace.vector_to_chart(1.0, n, f[0]), WormholeSpace.vector_to_chart(1.0, n, f[1]),
			WormholeSpace.vector_to_chart(1.0, n, f[2])).orthonormalized()
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
