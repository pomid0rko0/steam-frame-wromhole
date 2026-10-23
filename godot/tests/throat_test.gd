extends SceneTree
## The throat knobs through the desktop keys (the same code paths the right stick drives), run
## with --fixed-fps 60; exit status 1 on any failure:
##   godot --path . --fixed-fps 60 -s res://tests/throat_test.gd
## 1. X for one second lengthens the throat by GEOMETRY_RATE (half-length 5 -> 6.5 m); the feet
##    stay where they are; Z shortens it back
## 2. V for one second widens the fillet by half that (1 -> 1.75 m); the feet keep their
##    distance to the mouth, so they move out with it, and the overlay follows them
## 3. Z held long stops at the shortest throat
## 4. inside the throat, a longer throat keeps the feet's distance to the mouth
## 5. R puts back the start geometry, position and direction

var main: Node3D
var frames := 0
var fails := 0


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	main.xr_name = "none"
	root.add_child(main)


func _check(name: String, ok: bool, detail: String) -> void:
	print(("PASS " if ok else "FAIL ") + name + "  " + detail)
	if not ok:
		fails += 1


func _key(code: Key, down: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = down
	Input.parse_input_event(ev)


func _feet() -> Vector3:
	return main.space.chart_position(main.foot_l, main.foot_n)


func _forward() -> Vector3:
	var U: Vector4 = -main.frame[2]        # play-space forward is -z
	var d: Vector3 = U.x * main.foot_n + Vector3(U.y, U.z, U.w)
	return Vector3(d.x, d.y, 0.0).normalized()


func _process(_delta: float) -> bool:
	frames += 1
	match frames:
		5:
			_key(KEY_X, true)
		65:
			_key(KEY_X, false)
		67:
			var h: float = main.space.h
			_check("X lengthens the throat", absf(h - 6.5) < 0.03, "half-length %.3f m, expected 6.5" % h)
			var p := _feet()
			_check("a longer throat leaves the feet in place", p.distance_to(Vector3(10, 0, 0)) < 1e-4, "feet at (%.4f, %.4f)" % [p.x, p.y])
			_key(KEY_Z, true)
		127:
			_key(KEY_Z, false)
		129:
			var h: float = main.space.h
			_check("Z shortens it back", absf(h - 5.0) < 0.03, "half-length %.3f m, expected 5" % h)
			_key(KEY_V, true)
		189:
			_key(KEY_V, false)
		191:
			var fr: float = main.space.fillet
			_check("V widens the fillet", absf(fr - 1.75) < 0.02, "fillet %.3f m, expected 1.75" % fr)
			# 6 m from the mouth before, 6 m now: the mouth is at Rout = rho0 + fillet
			var p := _feet()
			var want: float = 6.0 + main.space.Rout
			_check("the feet keep their distance to the mouth", absf(p.x - want) < 0.03 and absf(p.y) < 1e-4,
					"feet at (%.3f, %.3f), expected (%.3f, 0)" % [p.x, p.y, want])
			var head := Vector3(main.prev_head.x, 0.0, main.prev_head.y)
			var mapped: Vector3 = main.overlay.transform * p
			_check("the overlay follows: the feet's chart point maps to the head", mapped.distance_to(head) < 1e-4,
					"chart feet -> play %s, head %s" % [mapped, head])
			_key(KEY_C, true)
		251:
			_key(KEY_C, false)
			_key(KEY_Z, true)
		551:
			_key(KEY_Z, false)
		553:
			var h: float = main.space.h
			_check("Z stops at the shortest throat", is_equal_approx(h, main.HALF_LENGTH_RANGE.x), "half-length %.3f m" % h)
			_key(KEY_R, true)
		555:
			_key(KEY_R, false)
		557:
			var p := _feet()
			var ok: bool = p.distance_to(Vector3(10, 0, 0)) < 1e-3 and _forward().distance_to(Vector3(-1, 0, 0)) < 1e-3 \
					and is_equal_approx(main.space.h, main.START_HALF_LENGTH) and is_equal_approx(main.space.fillet, main.START_FILLET)
			_check("R resets geometry, position and direction", ok,
					"feet (%.3f, %.3f), h %.3f, fillet %.3f" % [p.x, p.y, main.space.h, main.space.fillet])
			# into the throat: 1 m inside the mouth, on the cylinder side
			main.foot_l = main.space.L - 1.0
			_key(KEY_X, true)
		617:
			_key(KEY_X, false)
		619:
			var d: float = main.space.L - main.foot_l
			_check("inside, a longer throat keeps the distance to the mouth", absf(d - 1.0) < 1e-4 and main.space.h > 6.4,
					"%.4f m inside the mouth, half-length %.3f" % [d, main.space.h])
			print("FAILURES: ", fails)
			quit(1 if fails > 0 else 0)
	return false
