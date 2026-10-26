extends SceneTree
## main's scripts' CPU time a frame (main.cpu_us, what perf_panel.gd logs as "main's scripts"),
## through the code path the headset uses: the simulated headset (tests/fake_hmd.gd) and two
## tracked controllers, the demo's toys at rest, the feet at the shell's edge facing the throat,
## a ball held in the right hand in front of the chest. Prints the frame's time and its parts (each
## timed alone, many times over); no verdict (a machine's speed is its own). Run with
##   godot --path . --fixed-fps 72 -s res://tests/cpu_test.gd [-- l]
## under a display (xvfb-run); l: where the feet are (default 5.0, the shell's edge).

const SIZE := 64
const FRUSTUM := Vector4(-1.0, 1.0, -1.1, 1.1)
const HEAD := Vector3(0.0, 1.6, 0.0)
const FRAMES := 300
const REPEAT := 200

var main: Node3D
var hmd
var left: XRControllerTracker
var right: XRControllerTracker
var at_l := 5.0


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0:
		at_l = float(a[0])
	hmd = preload("res://tests/fake_hmd.gd").new()
	hmd.size = Vector2i(SIZE, SIZE)
	hmd.setup(Transform3D(Basis.IDENTITY, HEAD), 0.064, 0.0, FRUSTUM)
	XRServer.add_interface(hmd)
	hmd.initialize()
	XRServer.primary_interface = hmd
	left = _controller(&"left_hand")
	right = _controller(&"right_hand")
	main = load("res://main.tscn").instantiate()
	main.xr_name = "FakeHMD"
	main.throw_toys = false
	root.add_child(main)
	_run()


func _controller(tracker_name: StringName) -> XRControllerTracker:
	var t := XRControllerTracker.new()
	t.name = tracker_name
	t.profile = "/interaction_profiles/khr/generic_controller"
	for b in [&"primary_click", &"ax_button", &"by_button", &"menu_button", &"dpad_down"]:
		t.set_input(b, false)
	t.set_input(&"primary", Vector2.ZERO)
	t.set_input(&"trigger", 0.0)
	t.set_input(&"grip", 0.0)
	XRServer.add_tracker(t)
	return t


func _step(n := 1) -> void:
	for _k in n:
		await process_frame


func _run() -> void:
	await _step(3)
	main.perf.visible = false
	# the demo after the throw and the drop, at rest
	main._throw()
	main._drop()
	for k in 12 * 60:
		main.world.step(1.0 / 60.0, [])
	main.place_on_axis(at_l, 0.0, 0.0)
	left.set_pose(&"grip", Transform3D(Basis.IDENTITY, HEAD + Vector3(-0.22, -0.35, -0.3)),
			Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	right.set_pose(&"grip", Transform3D(Basis.IDENTITY, HEAD + Vector3(0.22, -0.35, -0.3)),
			Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	right.set_input(&"grip", 1.0)
	await _step(2)
	# a ball in the right hand (right B with the grip closed)
	right.set_input(&"by_button", true)
	await _step(2)
	right.set_input(&"by_button", false)
	await _step(30)
	var held: bool = main.hand_state[1].has("held")
	var times := PackedInt64Array()
	main.prof = {}
	for k in FRAMES:
		await _step()
		times.append(main.get("cpu_us") if main.get("cpu_us") != null else 0)
	times.sort()
	var mean := 0.0
	for t in times:
		mean += t
	mean /= times.size()
	var asleep := 0
	for b in main.world.balls:
		asleep += 1 if BallWorld._asleep(b) else 0
	for c in main.world.cubes:
		asleep += 1 if c["still"] > BallWorld.SLEEP_TIME else 0
	print("cpu: %d of the toys asleep" % asleep)
	print("cpu: feet at l %.2f, %d balls, %d cubes, a ball held: %s" % [main.foot_l, main.world.balls.size(),
			main.world.cubes.size(), held])
	print("cpu: main's scripts a frame: mean %.0f us, median %d, 95%% %d, most %d" % [mean,
			times[times.size() / 2], times[int(times.size() * 0.95)], times[-1]])
	var keys: Array = main.prof.keys()
	keys.sort()
	for k in keys:
		print("cpu:   in frames: %s %.0f us" % [k, float(main.prof[k]) / FRAMES])
	_parts()
	XRServer.remove_tracker(left)
	XRServer.remove_tracker(right)
	XRServer.primary_interface = null
	hmd.uninitialize()
	XRServer.remove_interface(hmd)
	quit(0)


## Each part of main._step alone, REPEAT times (the state as the last frame left it).
func _parts() -> void:
	var sp: WormholeSpace = main.space
	var head: Transform3D = main.camera.transform
	var hp: Array = sp.geodesic(main.foot_l, main.foot_n, main.frame[1], maxf(head.origin.y, 0.05),
			main.frame, WormholeSpace.STEP_FRAME)
	var t0 := Time.get_ticks_usec()
	for k in REPEAT:
		main._process(1.0 / 72.0)
	_part("main._process, called again", t0)
	t0 = Time.get_ticks_usec()
	for k in REPEAT:
		sp.geodesic(main.foot_l, main.foot_n, main.frame[1], maxf(head.origin.y, 0.05), main.frame,
				WormholeSpace.STEP_FRAME)
	_part("the head's geodesic", t0)
	t0 = Time.get_ticks_usec()
	for k in REPEAT:
		main.clock += 1.0 / 72.0          # as a frame: the hands' recent places stay a few
		main._update_hands(hp, head)
	_part("_update_hands", t0)
	var hb: Array = main._hand_balls()
	t0 = Time.get_ticks_usec()
	for k in REPEAT:
		main.world.step(1.0 / 72.0, hb)
	_part("world.step (physics)", t0)
	t0 = Time.get_ticks_usec()
	for k in REPEAT:
		main._upload_toys()
	_part("_upload_toys", t0)
	t0 = Time.get_ticks_usec()
	for k in REPEAT:
		main._update_proxies(hp[0], hp[1], hp[2], head.origin)
	_part("_update_proxies", t0)
	t0 = Time.get_ticks_usec()
	for k in REPEAT:
		main._update_near(hp[0], hp[1], hp[2], head.origin)
	_part("  of it _update_near", t0)


func _part(name: String, t0: int) -> void:
	print("cpu:   %s %.0f us" % [name, float(Time.get_ticks_usec() - t0) / REPEAT])
