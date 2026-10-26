extends SceneTree
## Walking and turning with controllers, through the code path the headset uses: the
## simulated headset (tests/fake_hmd.gd) and two controller trackers whose inputs the test sets
## by the action names of openxr_action_map.tres. Run with --fixed-fps 60; exit status 1 on any
## failure:
##   godot --path . --fixed-fps 60 -s res://tests/walking_xr_test.gd
## 0. the action map binds those names to the Steam Frame's own controller profile (its D-pad,
##    View and Menu), to the KHR generic controller (the profile the Frame's controllers came as
##    before the map had theirs, by its log), and to the Oculus Touch and Index ones
## 1. left stick forward for a second walks 1.5 m; with the left trigger, half a second runs 2 m
## 2. the right stick at half way (past the dead zone) turns 45 degrees per second, smoothly
## 3. a right stick click switches to snaps, even with the stick out (it snaps only once back
##    in the middle): then the right stick held right turns 30 degrees once
## 4. A goes back to the start
## 5. the menu with the generic profile: a left stick click opens it; then the left stick walks
##    no more but picks rows (held, it repeats), A presses the picked row (turns: snap ->
##    smooth) and does not go back to the start, right steps the gravity row's value, which takes
##    effect half a second later, B closes it; then the stick walks again
## 6. the menu with the Frame's profile: View opens it, the D-pad picks and changes, A puts the
##    value into effect at once, Menu closes it; closed, the D-pad up, left and right show gravity
##    (the floor, the arrows, off)
## 7. while the speed check holds the viewer (main.hold), the sticks and A do nothing; then
##    left Y (generic: the D-pad's upper buttons) shows gravity: the floor, the arrows, off

# action name -> binding paths the action map must have for it, per profile
const FRAME := "/interaction_profiles/valve/frame_controller_valve"
const GENERIC := "/interaction_profiles/khr/generic_controller"
const BINDINGS := {
	FRAME: {
		"primary": ["/user/hand/left/input/thumbstick", "/user/hand/right/input/thumbstick"],
		"primary_click": ["/user/hand/left/input/thumbstick/click", "/user/hand/right/input/thumbstick/click"],
		"trigger": ["/user/hand/left/input/trigger/value", "/user/hand/right/input/trigger/value"],
		"ax_button": ["/user/hand/right/input/a/click"],
		"by_button": ["/user/hand/right/input/b/click"],
		"menu_button": ["/user/hand/left/input/view/click", "/user/hand/right/input/menu/click"],
		"dpad_up": ["/user/hand/left/input/dpad_up/click"],
		"dpad_down": ["/user/hand/left/input/dpad_down/click"],
		"dpad_left": ["/user/hand/left/input/dpad_left/click"],
		"dpad_right": ["/user/hand/left/input/dpad_right/click"],
		"grip": ["/user/hand/left/input/squeeze/value", "/user/hand/right/input/squeeze/value"],
		"aim_pose": ["/user/hand/left/input/aim/pose", "/user/hand/right/input/aim/pose"],
		"grip_pose": ["/user/hand/left/input/grip/pose", "/user/hand/right/input/grip/pose"],
		"haptic": ["/user/hand/left/output/haptic", "/user/hand/right/output/haptic"],
	},
	GENERIC: {
		"primary": ["/user/hand/left/input/thumbstick", "/user/hand/right/input/thumbstick"],
		"primary_click": ["/user/hand/left/input/thumbstick/click", "/user/hand/right/input/thumbstick/click"],
		"trigger": ["/user/hand/left/input/trigger/value"],
		"ax_button": ["/user/hand/right/input/primary/click"],
		"by_button": ["/user/hand/left/input/secondary/click"],
	},
	"/interaction_profiles/oculus/touch_controller": {
		"primary": ["/user/hand/left/input/thumbstick", "/user/hand/right/input/thumbstick"],
		"primary_click": ["/user/hand/right/input/thumbstick/click"],
		"trigger": ["/user/hand/left/input/trigger/value"],
		"ax_button": ["/user/hand/right/input/a/click"],
		"by_button": ["/user/hand/left/input/y/click"],
	},
	"/interaction_profiles/valve/index_controller": {
		"primary": ["/user/hand/left/input/thumbstick", "/user/hand/right/input/thumbstick"],
		"primary_click": ["/user/hand/right/input/thumbstick/click"],
		"trigger": ["/user/hand/left/input/trigger/value"],
		"ax_button": ["/user/hand/right/input/a/click"],
		"by_button": ["/user/hand/left/input/b/click"],
	},
}

var main: Node3D
var hmd
var left: XRControllerTracker
var right: XRControllerTracker
var frames := 0
var fails := 0
var gravity_seen := []
var grav_frame := []


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
	t.profile = GENERIC   # as the Frame's came before the map had theirs
	t.set_input(&"primary", Vector2.ZERO)
	t.set_input(&"trigger", 0.0)
	for b in [&"primary_click", &"ax_button", &"by_button", &"menu_button", &"dpad_up", &"dpad_down",
			&"dpad_left", &"dpad_right"]:
		t.set_input(b, false)
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
			left.set_input(&"primary", Vector2(0.0, 1.0))
		273:
			left.set_input(&"primary", Vector2.ZERO)
		275:
			_check_feet("half a second walks 0.75 m", 9.25)
			_check("the menu is closed at first, its line shown", not main.perf.open and main.perf.strip.visible, "open %s" % main.perf.open)
			left.set_input(&"primary_click", true)
		277:
			left.set_input(&"primary_click", false)
		279:
			_check("a left stick click opens the menu, the line hides", main.perf.open and main.perf.menu.visible
					and not main.perf.strip.visible, "open %s" % main.perf.open)
			_check("its rows here (no OpenXR: no rate, scale, foveation)", _keys() == ["gaze", "grav", "turn", "strip", "bench"], str(_keys()))
			left.set_input(&"primary", Vector2(0.0, 1.0))
			left.set_input(&"trigger", 1.0)
		309:
			left.set_input(&"primary", Vector2.ZERO)
			left.set_input(&"trigger", 0.0)
		311:
			_check_feet("menu open: the left stick and trigger do not walk", 9.25)
			_check("the stick up picks the row above, held it repeats: round to the last row and one up", main.perf.picked() == "strip", main.perf.picked())
			left.set_input(&"primary", Vector2(0.0, 1.0))
		313:
			left.set_input(&"primary", Vector2.ZERO)
		315:
			_check("a flick up: one row up", main.perf.picked() == "turn", main.perf.picked())
			right.set_input(&"ax_button", true)
		317:
			right.set_input(&"ax_button", false)
		319:
			_check("A on the turn row: snaps -> smooth at once", main.smooth_turn, "smooth_turn %s" % main.smooth_turn)
			_check_feet("A in the menu does not go back to the start", 9.25)
			left.set_input(&"primary", Vector2(0.0, 1.0))
		321:
			left.set_input(&"primary", Vector2.ZERO)
		323:
			left.set_input(&"primary", Vector2(1.0, 0.0))
		325:
			left.set_input(&"primary", Vector2.ZERO)
		327:
			_check("the stick right on the gravity row: the floor chosen, not yet in effect", main.perf.picked() == "grav"
					and main.gravity_view == 0 and main.perf.pending == 1, "row %s, view %d, pending %d" % [main.perf.picked(), main.gravity_view, main.perf.pending])
		360:
			_check("... in effect half a second later", main.gravity_view == 1 and main.perf.pending == -1, "view %d, pending %d" % [main.gravity_view, main.perf.pending])
			right.set_input(&"by_button", true)
		362:
			right.set_input(&"by_button", false)
		364:
			_check("B closes the menu", not main.perf.open and main.perf.strip.visible, "open %s" % main.perf.open)
			left.set_input(&"primary", Vector2(0.0, 1.0))
		394:
			left.set_input(&"primary", Vector2.ZERO)
		396:
			_check_feet("menu closed: the stick walks again", 8.5)
			left.profile = FRAME
			right.profile = FRAME
			left.set_input(&"menu_button", true)
		398:
			left.set_input(&"menu_button", false)
		400:
			_check("Frame: View opens the menu where it was", main.perf.open and main.perf.picked() == "grav", "open %s, row %s" % [main.perf.open, main.perf.picked()])
			left.set_input(&"dpad_down", true)
		402:
			left.set_input(&"dpad_down", false)
		404:
			_check("the D-pad down: the next row", main.perf.picked() == "turn", main.perf.picked())
			left.set_input(&"dpad_up", true)
		406:
			left.set_input(&"dpad_up", false)
		408:
			_check("the D-pad up: back", main.perf.picked() == "grav", main.perf.picked())
			left.set_input(&"dpad_left", true)
		410:
			left.set_input(&"dpad_left", false)
			right.set_input(&"ax_button", true)
		412:
			right.set_input(&"ax_button", false)
		414:
			_check("the D-pad left, then A: gravity off at once, the menu stays", main.gravity_view == 0 and main.perf.open
					and main.perf.pending == -1, "view %d, open %s" % [main.gravity_view, main.perf.open])
			right.set_input(&"menu_button", true)
		416:
			right.set_input(&"menu_button", false)
		418:
			_check("Menu closes it", not main.perf.open, "open %s" % main.perf.open)
		420, 422, 424:
			left.set_input([&"dpad_up", &"dpad_left", &"dpad_right"][(frames - 420) / 2], true)
		421, 423, 425:
			left.set_input([&"dpad_up", &"dpad_left", &"dpad_right"][(frames - 421) / 2], false)
			grav_frame.append(main.gravity_view)
		426:
			_check("menu closed, the D-pad up, left, right show gravity: the floor, the arrows, off", grav_frame == [1, 2, 0], "views %s" % [grav_frame])
			left.profile = GENERIC
			right.profile = GENERIC
			main.hold = true
			left.set_input(&"primary", Vector2(0.0, 1.0))
			left.set_input(&"trigger", 1.0)
			right.set_input(&"primary", Vector2(1.0, 0.0))
			right.set_input(&"ax_button", true)
		456:
			left.set_input(&"primary", Vector2.ZERO)
			left.set_input(&"trigger", 0.0)
			right.set_input(&"primary", Vector2.ZERO)
			right.set_input(&"ax_button", false)
		458:
			_check_feet("while the speed check holds the viewer, the sticks do nothing", 8.5)
			_check_turn("... nor does the right stick turn", 0.0)
			main.hold = false
		460, 462, 464:
			left.set_input(&"by_button", true)
		461, 463, 465:
			left.set_input(&"by_button", false)
			gravity_seen.append(main.gravity_view)
		466:
			_check("left Y shows gravity: the floor, the arrows, off", gravity_seen == [1, 2, 0], "views %s" % [gravity_seen])
			print("FAILURES: ", fails)
			_finish()
	return false


func _check_feet(name: String, x: float) -> void:
	var p := _feet()
	_check(name, absf(p.x - x) < 0.03 and absf(p.y) < 0.01, "feet at (%.3f, %.3f), expected (%.2f, 0)" % [p.x, p.y, x])


func _keys() -> Array:
	return main.perf.rows.map(func(r: Dictionary) -> String: return r.key)


## Takes the simulated headset down before quitting: left up at exit, it aborts Godot, and the
## exit status would say nothing.
func _finish() -> void:
	XRServer.remove_tracker(left)
	XRServer.remove_tracker(right)
	XRServer.primary_interface = null
	hmd.uninitialize()
	XRServer.remove_interface(hmd)
	quit(1 if fails > 0 else 0)
