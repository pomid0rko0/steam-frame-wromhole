extends SceneTree
## Walking and turning with controllers, through the code path the headset uses: the
## simulated headset (tests/fake_hmd.gd) and two controller trackers whose inputs the test sets
## by the action names of openxr_action_map.tres. Run with --fixed-fps 60; exit status 1 on any
## failure:
##   godot --path . --fixed-fps 60 -s res://tests/walking_xr_test.gd
## 0. the action map is exactly util.gd's, every binding of every profile (U.check_bindings)
## 1. left stick forward for a second walks 1.5 m; with the left trigger, half a second runs 2 m
## 2. the right stick at half way (past the dead zone) turns 45 degrees per second, smoothly
## 3. a right stick click switches the flight's gravity off (the line below says so) and on again;
##    a switch to snaps (the menu's) with the stick out snaps only once it is back in the middle:
##    then the right stick held right turns 30 degrees once
## 4. A goes back to the start
## 5. the menu by actions the generic profile binds too (util.gd's BINDINGS): a left stick click
##    opens it; then the left stick walks no more but picks rows (held, it repeats), A presses the
##    picked row (turns: snap -> smooth) and does not go back to the start, two rows up (past the
##    flight's) right steps the gravity row's value, which takes effect half a second later, B
##    closes it; then the stick
##    walks again
## 6. the menu by actions only the Frame's profile binds: View opens it, the D-pad picks and
##    changes, A puts the value into effect at once, Menu closes it; closed, the D-pad up, left and
##    right show gravity (the floor, the arrows, off)
## 7. while the speed check holds the viewer (main.hold), the sticks and A do nothing; then
##    left Y (generic: secondary/click) shows gravity: the floor, the arrows, off
## 8. standing, the right stick up does nothing; the right trigger flies up; flying (without
##    gravity: the right stick's click), the right stick up pitches and the right bumper rolls,
##    each about the head; with gravity again, let go, the body turns upright, falls and lands; held
##    by the speed check, the trigger does not fly

const U := preload("res://tests/util.gd")

var main: Main
var hmd
var left: XRControllerTracker
var right: XRControllerTracker
var frames := 0
var gravity_seen := []
var saved := []
var grav_frame := []


func _initialize() -> void:
	hmd = U.headset(0, 0.0, Vector2i(64, 64))      # nothing here looks at the image
	left = U.controller(&"left_hand")
	right = U.controller(&"right_hand")
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "FakeHMD"
	root.add_child(main)


func _feet() -> Vector3:
	return main.space.chart_position(main.viewer.l, main.viewer.n)


## Which way the view points in chart A (horizontal).
func _forward() -> Vector3:
	var d := WormholeSpace.vector_to_chart(1.0, main.viewer.n, -main.viewer.frame[2])
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
			# a switch with the stick still out, after 10 frames of a smooth turn at full speed (the
			# menu's turn row; no button has it)
			main.set_smooth_turn(false)
			right.set_input(&"primary_click", true)
		195:
			right.set_input(&"primary_click", false)
			U.check("a right stick click: flying, nothing pushed hovers, the line below says so", not main.viewer.gravity
					and main.menu.strip.visible and main.menu.strip_label.text.begins_with("полёт: без гравитации"),
					"gravity %s, line %s" % [main.viewer.gravity, main.menu.strip_label.text])
		197:
			right.set_input(&"primary_click", true)
		199:
			right.set_input(&"primary_click", false)
			U.check("... clicked again, it falls", main.viewer.gravity)
		205:
			U.check("the stick turns in snaps now", not main.smooth_turn, "smooth_turn %s" % main.smooth_turn)
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
			U.check("its rows here (no OpenXR: no rate, scale or foveation)", _keys() == ["radius", "distance", "fillet", "video", "gaze", "beam", "grav", "fly", "turn", "strip", "bench"], str(_keys()))
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
			U.check("... one row up: the flight row", main.menu.picked() == "fly", main.menu.picked())
		323:
			left.set_input(&"primary", Vector2(0.0, 1.0))
		325:
			left.set_input(&"primary", Vector2.ZERO)
		327:
			left.set_input(&"primary", Vector2(1.0, 0.0))
		329:
			left.set_input(&"primary", Vector2.ZERO)
		331:
			U.check("the stick right on the gravity row: the floor chosen, not yet in effect", main.menu.picked() == "grav"
					and main.renderer.gravity_view == 0 and main.menu.pending == 1, "row %s, view %d, pending %d" % [main.menu.picked(), main.renderer.gravity_view, main.menu.pending])
		364:
			U.check("... in effect half a second later", main.renderer.gravity_view == 1 and main.menu.pending == -1, "view %d, pending %d" % [main.renderer.gravity_view, main.menu.pending])
			right.set_input(&"by_button", true)
		366:
			right.set_input(&"by_button", false)
		368:
			U.check("B closes the menu", not main.menu.open and main.menu.strip.visible, "open %s" % main.menu.open)
			left.set_input(&"primary", Vector2(0.0, 1.0))
		398:
			left.set_input(&"primary", Vector2.ZERO)
		400:
			_check_feet("menu closed: the stick walks again", 8.5)
			left.profile = U.FRAME
			right.profile = U.FRAME
			left.set_input(&"menu_button", true)
		402:
			left.set_input(&"menu_button", false)
		404:
			U.check("Frame: View opens the menu where it was", main.menu.open and main.menu.picked() == "grav", "open %s, row %s" % [main.menu.open, main.menu.picked()])
			left.set_input(&"dpad_down", true)
		406:
			left.set_input(&"dpad_down", false)
		408:
			U.check("the D-pad down: the next row", main.menu.picked() == "fly", main.menu.picked())
			left.set_input(&"dpad_up", true)
		410:
			left.set_input(&"dpad_up", false)
		412:
			U.check("the D-pad up: back", main.menu.picked() == "grav", main.menu.picked())
			left.set_input(&"dpad_left", true)
		414:
			left.set_input(&"dpad_left", false)
			right.set_input(&"ax_button", true)
		416:
			right.set_input(&"ax_button", false)
		418:
			U.check("the D-pad left, then A: gravity off at once, the menu stays", main.renderer.gravity_view == 0 and main.menu.open
					and main.menu.pending == -1, "view %d, open %s" % [main.renderer.gravity_view, main.menu.open])
			right.set_input(&"menu_button", true)
		420:
			right.set_input(&"menu_button", false)
		422:
			U.check("Menu closes it", not main.menu.open, "open %s" % main.menu.open)
		424, 426, 428:
			left.set_input([&"dpad_up", &"dpad_left", &"dpad_right"][(frames - 424) / 2], true)
		425, 427, 429:
			left.set_input([&"dpad_up", &"dpad_left", &"dpad_right"][(frames - 425) / 2], false)
			grav_frame.append(main.renderer.gravity_view)
		430:
			U.check("menu closed, the D-pad up, left, right show gravity: the floor, the arrows, off", grav_frame == [1, 2, 0], "views %s" % [grav_frame])
			left.profile = U.GENERIC
			right.profile = U.GENERIC
			main.hold = true
			left.set_input(&"primary", Vector2(0.0, 1.0))
			left.set_input(&"trigger", 1.0)
			right.set_input(&"primary", Vector2(1.0, 0.0))
			right.set_input(&"ax_button", true)
		460:
			left.set_input(&"primary", Vector2.ZERO)
			left.set_input(&"trigger", 0.0)
			right.set_input(&"primary", Vector2.ZERO)
			right.set_input(&"ax_button", false)
		462:
			_check_feet("while the speed check holds the viewer, the sticks do nothing", 8.5)
			_check_turn("... nor does the right stick turn", 0.0)
			main.hold = false
		464, 466, 468:
			left.set_input(&"by_button", true)
		465, 467, 469:
			left.set_input(&"by_button", false)
			gravity_seen.append(main.renderer.gravity_view)
		470:
			U.check("left Y shows gravity: the floor, the arrows, off", gravity_seen == [1, 2, 0], "views %s" % [gravity_seen])
			right.set_input(&"primary", Vector2(0.0, 1.0))
		480:
			right.set_input(&"primary", Vector2.ZERO)
			U.check("standing, the right stick up does nothing", main.viewer.standing and absf(main.viewer.height()) < 1e-5,
					"the feet %s m over the floor" % main.viewer.height())
			_check_turn("... nor turns", 0.0)
			right.set_input(&"primary_click", true)
		482:
			right.set_input(&"primary_click", false)
			U.check("flight without gravity", not main.viewer.gravity)
			right.set_input(&"trigger", 1.0)
		497:
			right.set_input(&"trigger", 0.0)
		499:
			var hgt: float = main.viewer.height()
			U.check("the right trigger for a quarter second flies 1 m up", not main.viewer.standing and absf(hgt - 1.0) < 0.02,
					"standing %s, the feet %.3f m over the floor" % [main.viewer.standing, hgt])
			saved = [_head()]
			right.set_input(&"primary", Vector2(0.0, 1.0))
		529:
			right.set_input(&"primary", Vector2.ZERO)
		531:
			var f := WormholeSpace.vector_to_chart(1.0, main.viewer.n, -main.viewer.frame[2])
			U.check("flying, the right stick up for half a second pitches 30 degrees up about the head",
					_head().distance_to(saved[0]) < 1e-4 and absf(rad_to_deg(asin(f.z)) - 30.0) < 0.01,
					"the head moved %.6f m, forward %.3f deg up" % [_head().distance_to(saved[0]), rad_to_deg(asin(f.z))])
			saved = [_head(), _chart(1)]
			right.set_input(&"bumper", true)
		561:
			right.set_input(&"bumper", false)
		563:
			var turned := rad_to_deg(acos(clampf(_chart(1).dot(saved[1]), -1.0, 1.0)))
			U.check("the right bumper for half a second rolls 30 degrees about the head", _head().distance_to(saved[0]) < 1e-4
					and absf(turned - 30.0) < 0.01, "the head moved %.6f m, up turned %.3f deg" % [_head().distance_to(saved[0]), turned])
			right.set_input(&"primary_click", true)
		565:
			right.set_input(&"primary_click", false)
			U.check("flight with gravity again", main.viewer.gravity)
		640:
			U.check("let go, it turns upright, falls and lands", main.viewer.standing
					and _chart(1).distance_to(Vector3(0.0, 0.0, 1.0)) < 1e-6, "standing %s, up %s" % [main.viewer.standing, _chart(1)])
			main.hold = true
			right.set_input(&"trigger", 1.0)
		655:
			right.set_input(&"trigger", 0.0)
		657:
			U.check("while the speed check holds the viewer, the right trigger does not fly", main.viewer.standing
					and absf(main.viewer.height()) < 1e-5, "standing %s, the feet %s m over the floor" % [main.viewer.standing, main.viewer.height()])
			main.hold = false
			U.finish(self, hmd, [left, right])
	return false


## The head's chart A position.
func _head() -> Vector3:
	var hp: Array = main.viewer.head(main.camera.transform.origin.y)
	return main.space.chart_position(hp[0], hp[1])


## The room's axis k in chart A.
func _chart(k: int) -> Vector3:
	return WormholeSpace.vector_to_chart(1.0, main.viewer.n, main.viewer.frame[k])


func _check_feet(name: String, x: float) -> void:
	var p := _feet()
	U.check(name, absf(p.x - x) < 0.03 and absf(p.y) < 0.01, "feet at (%.3f, %.3f), expected (%.2f, 0)" % [p.x, p.y, x])


func _keys() -> Array:
	return main.menu.rows.map(func(r: Menu.Row) -> String: return r.key)
