extends SceneTree
## Walking and turning with controllers, through the code path the headset uses: the
## simulated headset (tests/fake_hmd.gd) and two controller trackers whose inputs the test sets
## by the action names of openxr_action_map.tres. Run with --fixed-fps 60; exit status 1 on any
## failure:
##   godot --path . --fixed-fps 60 -s res://tests/walking_xr_test.gd
## 0. the action map is exactly util.gd's, every binding of every profile (U.check_bindings)
## 1. left stick forward for a second walks 1.5 m; with the left trigger, half a second runs 2 m
## 2. the right stick at half way (past the dead zone) turns 45 degrees per second, smoothly
## 3. a right stick click switches to snaps, even with the stick out (it snaps only once back
##    in the middle): then the right stick held right turns 30 degrees once
## 4. A goes back to the start
## 5. the menu by actions the generic profile binds too (util.gd's BINDINGS): a left stick click
##    opens it; then the left stick walks no more but picks rows (held, it repeats), A presses the
##    picked row (turns: snap -> smooth) and does not go back to the start, right steps the
##    gravity row's value, which takes effect half a second later, B closes it; then the stick
##    walks again
## 6. the menu by actions only the Frame's profile binds: View opens it, the D-pad picks and
##    changes, A puts the value into effect at once, Menu closes it; closed, the D-pad up, left and
##    right show gravity (the floor, the arrows, off)
## 7. while the speed check holds the viewer (main.hold), the sticks and A do nothing; then
##    left Y (generic: secondary/click) shows gravity: the floor, the arrows, off

const U := preload("res://tests/util.gd")

var main: Node3D
var hmd
var left: XRControllerTracker
var right: XRControllerTracker
var frames := 0
var gravity_seen := []
var grav_frame := []


func _initialize() -> void:
	hmd = U.headset(0, 0.0, Vector2i(64, 64))      # nothing here looks at the image
	left = U.controller(&"left_hand")
	right = U.controller(&"right_hand")
	main = load("res://main.tscn").instantiate()
	main.xr_name = "FakeHMD"
	root.add_child(main)


func _feet() -> Vector3:
	return main.space.chart_position(main.foot_l, main.foot_n)


## Which way the view points in chart A (horizontal).
func _forward() -> Vector3:
	var d := WormholeSpace.vector_to_chart(1.0, main.foot_n, -main.frame[2])
	return Vector3(d.x, d.y, 0.0).normalized()


func _check_turn(name: String, deg: float) -> void:
	var f := _forward()
	var want := Vector3(-cos(deg_to_rad(deg)), sin(deg_to_rad(deg)), 0.0)
	U.check(name, f.distance_to(want) < 1e-3, "forward (%.4f, %.4f), expected (%.4f, %.4f)" % [f.x, f.y, want.x, want.y])


func _process(_delta: float) -> bool:
	frames += 1
	match frames:
		1:
			U.check_bindings()
		5:
			U.check("main runs in XR, so it reads the controllers", main.in_xr, "in_xr %s" % main.in_xr)
			left.set_input(&"primary", Vector2(0.0, 1.0))
		65:
			left.set_input(&"primary", Vector2.ZERO)
		67:
			var p := _feet()
			U.check("left stick forward walks 1.5 m per second", absf(p.x - 8.5) < 0.03 and absf(p.y) < 0.01, "feet at (%.3f, %.3f), expected (8.5, 0)" % [p.x, p.y])
			left.set_input(&"primary", Vector2(0.0, 1.0))
			left.set_input(&"trigger", 1.0)
		97:
			left.set_input(&"primary", Vector2.ZERO)
			left.set_input(&"trigger", 0.0)
		99:
			var p := _feet()
			U.check("with the left trigger, half a second runs 2 m", absf(p.x - 6.5) < 0.03 and absf(p.y) < 0.01, "feet at (%.3f, %.3f), expected (6.5, 0)" % [p.x, p.y])
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
			U.check("a right stick click switches to snaps", not main.smooth_turn, "smooth_turn %s" % main.smooth_turn)
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
			U.check("A goes back to the start, facing the wormhole", ok, "feet (%.3f, %.3f), forward %s" % [p.x, p.y, _forward()])
			left.set_input(&"primary", Vector2(0.0, 1.0))
		273:
			left.set_input(&"primary", Vector2.ZERO)
		275:
			_check_feet("half a second walks 0.75 m", 9.25)
			U.check("the menu is closed at first, its line shown", not main.menu.open and main.menu.strip.visible, "open %s" % main.menu.open)
			left.set_input(&"primary_click", true)
		277:
			left.set_input(&"primary_click", false)
		279:
			U.check("a left stick click opens the menu, the line hides", main.menu.open and main.menu.menu.visible
					and not main.menu.strip.visible, "open %s" % main.menu.open)
			U.check("its rows here (no OpenXR: no rate, scale, foveation or its order)", _keys() == ["gaze", "grav", "turn", "strip", "bench"], str(_keys()))
			left.set_input(&"primary", Vector2(0.0, 1.0))
			left.set_input(&"trigger", 1.0)
		309:
			left.set_input(&"primary", Vector2.ZERO)
			left.set_input(&"trigger", 0.0)
		311:
			_check_feet("menu open: the left stick and trigger do not walk", 9.25)
			U.check("the stick up picks the row above, held it repeats: round to the last row and one up", main.menu.picked() == "strip", main.menu.picked())
			left.set_input(&"primary", Vector2(0.0, 1.0))
		313:
			left.set_input(&"primary", Vector2.ZERO)
		315:
			U.check("a flick up: one row up", main.menu.picked() == "turn", main.menu.picked())
			right.set_input(&"ax_button", true)
		317:
			right.set_input(&"ax_button", false)
		319:
			U.check("A on the turn row: snaps -> smooth at once", main.smooth_turn, "smooth_turn %s" % main.smooth_turn)
			_check_feet("A in the menu does not go back to the start", 9.25)
			left.set_input(&"primary", Vector2(0.0, 1.0))
		321:
			left.set_input(&"primary", Vector2.ZERO)
		323:
			left.set_input(&"primary", Vector2(1.0, 0.0))
		325:
			left.set_input(&"primary", Vector2.ZERO)
		327:
			U.check("the stick right on the gravity row: the floor chosen, not yet in effect", main.menu.picked() == "grav"
					and main.tracer.gravity_view == 0 and main.menu.pending == 1, "row %s, view %d, pending %d" % [main.menu.picked(), main.tracer.gravity_view, main.menu.pending])
		360:
			U.check("... in effect half a second later", main.tracer.gravity_view == 1 and main.menu.pending == -1, "view %d, pending %d" % [main.tracer.gravity_view, main.menu.pending])
			right.set_input(&"by_button", true)
		362:
			right.set_input(&"by_button", false)
		364:
			U.check("B closes the menu", not main.menu.open and main.menu.strip.visible, "open %s" % main.menu.open)
			left.set_input(&"primary", Vector2(0.0, 1.0))
		394:
			left.set_input(&"primary", Vector2.ZERO)
		396:
			_check_feet("menu closed: the stick walks again", 8.5)
			left.profile = U.FRAME
			right.profile = U.FRAME
			left.set_input(&"menu_button", true)
		398:
			left.set_input(&"menu_button", false)
		400:
			U.check("Frame: View opens the menu where it was", main.menu.open and main.menu.picked() == "grav", "open %s, row %s" % [main.menu.open, main.menu.picked()])
			left.set_input(&"dpad_down", true)
		402:
			left.set_input(&"dpad_down", false)
		404:
			U.check("the D-pad down: the next row", main.menu.picked() == "turn", main.menu.picked())
			left.set_input(&"dpad_up", true)
		406:
			left.set_input(&"dpad_up", false)
		408:
			U.check("the D-pad up: back", main.menu.picked() == "grav", main.menu.picked())
			left.set_input(&"dpad_left", true)
		410:
			left.set_input(&"dpad_left", false)
			right.set_input(&"ax_button", true)
		412:
			right.set_input(&"ax_button", false)
		414:
			U.check("the D-pad left, then A: gravity off at once, the menu stays", main.tracer.gravity_view == 0 and main.menu.open
					and main.menu.pending == -1, "view %d, open %s" % [main.tracer.gravity_view, main.menu.open])
			right.set_input(&"menu_button", true)
		416:
			right.set_input(&"menu_button", false)
		418:
			U.check("Menu closes it", not main.menu.open, "open %s" % main.menu.open)
		420, 422, 424:
			left.set_input([&"dpad_up", &"dpad_left", &"dpad_right"][(frames - 420) / 2], true)
		421, 423, 425:
			left.set_input([&"dpad_up", &"dpad_left", &"dpad_right"][(frames - 421) / 2], false)
			grav_frame.append(main.tracer.gravity_view)
		426:
			U.check("menu closed, the D-pad up, left, right show gravity: the floor, the arrows, off", grav_frame == [1, 2, 0], "views %s" % [grav_frame])
			left.profile = U.GENERIC
			right.profile = U.GENERIC
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
			gravity_seen.append(main.tracer.gravity_view)
		466:
			U.check("left Y shows gravity: the floor, the arrows, off", gravity_seen == [1, 2, 0], "views %s" % [gravity_seen])
			U.finish(self, hmd, [left, right])
	return false


func _check_feet(name: String, x: float) -> void:
	var p := _feet()
	U.check(name, absf(p.x - x) < 0.03 and absf(p.y) < 0.01, "feet at (%.3f, %.3f), expected (%.2f, 0)" % [p.x, p.y, x])


func _keys() -> Array:
	return main.menu.rows.map(func(r: Dictionary) -> String: return r.key)
