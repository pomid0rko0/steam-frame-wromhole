extends SceneTree
## Walking and turning with controllers, through the code path the headset uses: the
## simulated headset (tests/fake_hmd.gd) and two controller trackers whose inputs the test sets
## by the action names of openxr_action_map.tres. Run with --fixed-fps 60; exit status 1 on any
## failure:
##   godot --path . --fixed-fps 60 -s res://tests/walking_xr_test.gd
## 0. the action map binds those names to the KHR generic controller (the profile the Steam
##    Frame's controllers come as, by its log), and to the Oculus Touch and Index ones
## 1. left stick forward for a second walks 1.5 m; with the left trigger, half a second runs 2 m
## 2. the right stick at half way (past the dead zone) turns 45 degrees per second, smoothly
## 3. a right stick click switches to snaps, even with the stick out (it snaps only once back
##    in the middle): then the right stick held right turns 30 degrees once
## 4. A goes back to the start
## 5. with the left controller pointed at the frame rate panel, the left trigger presses the
##    panel's buttons and does not run: the left stick walks at walking speed
## 6. while the speed check holds the viewer (main.hold), the sticks and A do nothing

# action name -> binding paths the action map must have for it, per profile
const BINDINGS := {
	"/interaction_profiles/khr/generic_controller": {
		"primary": ["/user/hand/left/input/thumbstick", "/user/hand/right/input/thumbstick"],
		"primary_click": ["/user/hand/right/input/thumbstick/click"],
		"trigger": ["/user/hand/left/input/trigger/value"],
		"ax_button": ["/user/hand/right/input/primary/click"],
	},
	"/interaction_profiles/oculus/touch_controller": {
		"primary": ["/user/hand/left/input/thumbstick", "/user/hand/right/input/thumbstick"],
		"primary_click": ["/user/hand/right/input/thumbstick/click"],
		"trigger": ["/user/hand/left/input/trigger/value"],
		"ax_button": ["/user/hand/right/input/a/click"],
	},
	"/interaction_profiles/valve/index_controller": {
		"primary": ["/user/hand/left/input/thumbstick", "/user/hand/right/input/thumbstick"],
		"primary_click": ["/user/hand/right/input/thumbstick/click"],
		"trigger": ["/user/hand/left/input/trigger/value"],
		"ax_button": ["/user/hand/right/input/a/click"],
	},
}

var main: Node3D
var hmd
var left: XRControllerTracker
var right: XRControllerTracker
var frames := 0
var fails := 0


func _initialize() -> void:
	hmd = preload("res://tests/fake_hmd.gd").new()
	hmd.size = Vector2i(64, 64)          # nothing here looks at the image
	hmd.setup(Transform3D(Basis.IDENTITY, Vector3(0.0, 1.6, 0.0)), 0.064, 0.0, Vector4(-1.0, 1.0, -1.1, 1.1))
	XRServer.add_interface(hmd)
	hmd.initialize()
	XRServer.primary_interface = hmd
	left = _controller(&"left_hand")
	right = _controller(&"right_hand")
	main = load("res://main.tscn").instantiate()
	main.xr_name = "FakeHMD"
	root.add_child(main)


func _controller(tracker_name: StringName) -> XRControllerTracker:
	var t := XRControllerTracker.new()
	t.name = tracker_name
	t.profile = "/interaction_profiles/khr/generic_controller"   # as the Frame's come
	t.set_input(&"primary", Vector2.ZERO)
	t.set_input(&"primary_click", false)
	t.set_input(&"trigger", 0.0)
	t.set_input(&"ax_button", false)
	XRServer.add_tracker(t)
	return t


func _check(name: String, ok: bool, detail: String) -> void:
	print(("PASS " if ok else "FAIL ") + name + "  " + detail)
	if not ok:
		fails += 1


func _check_action_map() -> void:
	var am: OpenXRActionMap = load("res://openxr_action_map.tres")
	for path: String in BINDINGS:
		var profile := am.find_interaction_profile(path)
		if profile == null:
			_check("action map has " + path, false, "no such profile")
			continue
		for action: String in BINDINGS[path]:
			var have := PackedStringArray()
			for i in profile.get_binding_count():
				var b := profile.get_binding(i)
				if b.action and b.action.resource_name == action:
					have.append(b.binding_path)
			var missing := PackedStringArray()
			for p: String in BINDINGS[path][action]:
				if not have.has(p):
					missing.append(p)
			_check("%s: %s" % [path.get_file(), action], missing.is_empty(), "bound to %s, missing %s" % [have, missing])


func _feet() -> Vector3:
	return main.space.chart_position(main.foot_l, main.foot_n)


## Which way the view points in chart A (horizontal).
func _forward() -> Vector3:
	var U: Vector4 = -main.frame[2]
	var d: Vector3 = U.x * main.foot_n + Vector3(U.y, U.z, U.w)
	return Vector3(d.x, d.y, 0.0).normalized()


func _check_turn(name: String, deg: float) -> void:
	var f := _forward()
	var want := Vector3(-cos(deg_to_rad(deg)), sin(deg_to_rad(deg)), 0.0)
	_check(name, f.distance_to(want) < 1e-3, "forward (%.4f, %.4f), expected (%.4f, %.4f)" % [f.x, f.y, want.x, want.y])


func _process(_delta: float) -> bool:
	frames += 1
	match frames:
		1:
			_check_action_map()
		5:
			_check("main runs in XR, so it reads the controllers", main.in_xr, "in_xr %s" % main.in_xr)
			left.set_input(&"primary", Vector2(0.0, 1.0))
		65:
			left.set_input(&"primary", Vector2.ZERO)
		67:
			var p := _feet()
			_check("left stick forward walks 1.5 m per second", absf(p.x - 8.5) < 0.03 and absf(p.y) < 0.01, "feet at (%.3f, %.3f), expected (8.5, 0)" % [p.x, p.y])
			left.set_input(&"primary", Vector2(0.0, 1.0))
			left.set_input(&"trigger", 1.0)
		97:
			left.set_input(&"primary", Vector2.ZERO)
			left.set_input(&"trigger", 0.0)
		99:
			var p := _feet()
			_check("with the left trigger, half a second runs 2 m", absf(p.x - 6.5) < 0.03 and absf(p.y) < 0.01, "feet at (%.3f, %.3f), expected (6.5, 0)" % [p.x, p.y])
			# half way past the dead zone: half speed
			right.set_input(&"primary", Vector2(0.5 * (1.0 + main.STICK_DEAD_ZONE), 0.0))
		159:
			right.set_input(&"primary", Vector2.ZERO)
		161:
			_check_turn("the right stick half way turns smoothly 45 degrees per second", 45.0)
			right.set_input(&"primary", Vector2(-0.1, 0.0))
		181:
			right.set_input(&"primary", Vector2.ZERO)
		183:
			_check_turn("the right stick inside the dead zone turns nothing", 45.0)
			right.set_input(&"primary", Vector2(1.0, 0.0))
		193:
			# a click with the stick still out, after 10 frames of a smooth turn at full speed
			right.set_input(&"primary_click", true)
		195:
			right.set_input(&"primary_click", false)
		205:
			_check("a right stick click switches to snaps", not main.smooth_turn, "smooth_turn %s" % main.smooth_turn)
			_check_turn("with the stick still out, no snap until it comes back", 60.0)
			right.set_input(&"primary", Vector2.ZERO)
		207:
			right.set_input(&"primary", Vector2(1.0, 0.0))
		237:
			right.set_input(&"primary", Vector2.ZERO)
		239:
			_check_turn("the right stick held right snaps 30 degrees, once", 90.0)
			right.set_input(&"ax_button", true)
		241:
			right.set_input(&"ax_button", false)
		243:
			var p := _feet()
			var ok: bool = p.distance_to(Vector3(10, 0, 0)) < 1e-3 and _forward().distance_to(Vector3(-1, 0, 0)) < 1e-3
			_check("A goes back to the start, facing the wormhole", ok, "feet (%.3f, %.3f), forward %s" % [p.x, p.y, _forward()])
			_point_left_at_panel()
		247:
			left.set_input(&"primary", Vector2(0.0, 1.0))
			left.set_input(&"trigger", 1.0)
		277:
			_check("the left ray is on the panel", main.perf.on_plate[0], "on_plate %s" % [main.perf.on_plate])
			left.set_input(&"primary", Vector2.ZERO)
			left.set_input(&"trigger", 0.0)
		279:
			var p := _feet()
			_check("the left trigger on the panel does not run: half a second walks 0.75 m", absf(p.x - 9.25) < 0.03 and absf(p.y) < 0.01, "feet at (%.3f, %.3f), expected (9.25, 0)" % [p.x, p.y])
			left.set_pose(&"aim", Transform3D.IDENTITY, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_NONE)
			main.hold = true
			left.set_input(&"primary", Vector2(0.0, 1.0))
			left.set_input(&"trigger", 1.0)
			right.set_input(&"primary", Vector2(1.0, 0.0))
			right.set_input(&"ax_button", true)
		309:
			left.set_input(&"primary", Vector2.ZERO)
			left.set_input(&"trigger", 0.0)
			right.set_input(&"primary", Vector2.ZERO)
			right.set_input(&"ax_button", false)
		311:
			var p := _feet()
			_check("while the speed check holds the viewer, the sticks do nothing", absf(p.x - 9.25) < 1e-4 and absf(p.y) < 1e-4, "feet at (%.4f, %.4f), expected (9.25, 0)" % [p.x, p.y])
			_check_turn("... nor does the right stick turn", 0.0)
			main.hold = false
			print("FAILURES: ", fails)
			_finish()
	return false


## The left controller's aim pose 0.5 m in front of the panel, pointing at the panel above its
## buttons: the ray is on the panel, not on a button.
func _point_left_at_panel() -> void:
	var p: Label3D = main.perf
	var r: Rect2 = p.plate_rect
	var at: Vector3 = p.transform * Vector3(r.get_center().x, r.end.y + 0.1, 0.0)
	var from: Vector3 = at + p.transform.basis.z * 0.5
	var aim := Transform3D(Basis.looking_at(at - from, Vector3.UP), from)
	left.set_pose(&"aim", aim, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


## Takes the simulated headset down before quitting: left up at exit, it aborts Godot, and the
## exit status would say nothing.
func _finish() -> void:
	XRServer.remove_tracker(left)
	XRServer.remove_tracker(right)
	XRServer.primary_interface = null
	hmd.uninitialize()
	XRServer.remove_interface(hmd)
	quit(1 if fails > 0 else 0)
