extends SceneTree
## The controls through the desktop keys (the same code paths the sticks and buttons drive),
## run with --fixed-fps 60; exit status 1 on any failure:
##   godot --path . --fixed-fps 60 -s res://tests/controls_test.gd
## 1. W for one second walks 1.5 m toward the wormhole (chart A: x from 10 to 8.5)
## 2. E snap-turns the view 30 degrees to the right
## 3. X for one second lengthens the throat by GEOMETRY_RATE (half-length 5 -> 6.5 m)
## 4. R puts everything back: start position and direction, start geometry, five balls
## 5. F adds a ball

var main: Node3D
var frames := 0
var fails := 0
var t0 := 0


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


## Where the feet are in chart A, and which way the view points there (horizontal).
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
			_key(KEY_W, true)
		65:
			_key(KEY_W, false)
		67:
			var p := _feet()
			_check("W walks 1.5 m per second", absf(p.x - 8.5) < 0.03 and absf(p.y) < 0.01, "feet at (%.3f, %.3f), expected (8.5, 0)" % [p.x, p.y])
			_check("walking keeps the view direction", _forward().distance_to(Vector3(-1, 0, 0)) < 1e-3, "forward %s" % _forward())
			_key(KEY_E, true)
		69:
			_key(KEY_E, false)
		71:
			var f := _forward()
			# turning right from -x (whose right is +y) gives (-cos 30, +sin 30)
			var want := Vector3(-cos(deg_to_rad(30.0)), sin(deg_to_rad(30.0)), 0.0)
			_check("E snap-turns 30 degrees right", f.distance_to(want) < 1e-3, "forward (%.4f, %.4f), expected (%.4f, %.4f)" % [f.x, f.y, want.x, want.y])
			_key(KEY_X, true)
		131:
			_key(KEY_X, false)
		133:
			var h: float = main.space.h
			_check("X lengthens the throat", absf(h - 6.5) < 0.03, "half-length %.3f m, expected 6.5" % h)
			var p := _feet()
			_check("changing the throat leaves the feet in place", absf(p.x - 8.5) < 0.03 and absf(p.y) < 0.01, "feet at (%.3f, %.3f)" % [p.x, p.y])
			_key(KEY_R, true)
		135:
			_key(KEY_R, false)
		137:
			var p := _feet()
			var ok: bool = p.distance_to(Vector3(10, 0, 0)) < 1e-3 and _forward().distance_to(Vector3(-1, 0, 0)) < 1e-3 \
					and is_equal_approx(main.space.h, main.START_HALF_LENGTH) and main.world.balls.size() == 5
			_check("R resets position, direction, geometry and balls", ok,
					"feet (%.3f, %.3f), h %.3f, balls %d" % [p.x, p.y, main.space.h, main.world.balls.size()])
			_key(KEY_F, true)
		139:
			_key(KEY_F, false)
		141:
			_check("F adds a ball", main.world.balls.size() == 6, "balls %d" % main.world.balls.size())
			print("FAILURES: ", fails)
			quit(1 if fails > 0 else 0)
	return false
