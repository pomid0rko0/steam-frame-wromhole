extends SceneTree
## Stick walking and snap turn through the desktop keys (the same code paths the sticks and
## buttons drive), run with --fixed-fps 60; exit status 1 on any failure:
##   godot --path . --fixed-fps 60 -s res://tests/walking_test.gd
## 1. W for one second walks 1.5 m toward the wormhole (chart A: x from 10 to 8.5)
## 2. E snap-turns the view 30 degrees to the right, Q back to the left
## 3. R puts the viewer back at the start, facing the wormhole
## 4. Shift + W for six seconds runs 24 m: through the middle of the throat into universe B,
##    on the floor, still walking straight (chart B: x = -10.86)

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


## The side the feet are on (+1 universe A, -1 universe B) and their chart position there.
func _side() -> float:
	return signf(main.foot_l)


func _feet() -> Vector3:
	return main.space.chart_position(main.foot_l, main.foot_n)


## Which way the view points in the chart of the feet's side (horizontal).
func _forward() -> Vector3:
	var U: Vector4 = -main.frame[2]        # play-space forward is -z
	var d: Vector3 = _side() * U.x * main.foot_n + Vector3(U.y, U.z, U.w)
	if _side() < 0.0:
		d.x = -d.x
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
			var p := _feet()
			_check("turning leaves the feet in place", absf(p.x - 8.5) < 0.03 and absf(p.y) < 0.01, "feet at (%.3f, %.3f)" % [p.x, p.y])
			_key(KEY_E, true)          # held: one turn per push, not one per frame
		81:
			_key(KEY_E, false)
		83:
			var f := _forward()
			var want := Vector3(-cos(deg_to_rad(60.0)), sin(deg_to_rad(60.0)), 0.0)
			_check("holding E turns once", f.distance_to(want) < 1e-3, "forward (%.4f, %.4f), expected (%.4f, %.4f)" % [f.x, f.y, want.x, want.y])
			_key(KEY_Q, true)
		85:
			_key(KEY_Q, false)
		87:
			var f := _forward()
			var want := Vector3(-cos(deg_to_rad(30.0)), sin(deg_to_rad(30.0)), 0.0)
			_check("Q snap-turns 30 degrees left", f.distance_to(want) < 1e-3, "forward (%.4f, %.4f), expected (%.4f, %.4f)" % [f.x, f.y, want.x, want.y])
			_key(KEY_R, true)
		89:
			_key(KEY_R, false)
		91:
			var p := _feet()
			var ok: bool = p.distance_to(Vector3(10, 0, 0)) < 1e-3 and _forward().distance_to(Vector3(-1, 0, 0)) < 1e-3
			_check("R goes back to the start, facing the wormhole", ok, "feet (%.3f, %.3f), forward %s" % [p.x, p.y, _forward()])
			_key(KEY_SHIFT, true)
			_key(KEY_W, true)
		451:
			_key(KEY_W, false)
			_key(KEY_SHIFT, false)
		453:
			# 24 m from chart A x = 10: 6 m of flat floor, 2L = 11.14 m of throat, 6.86 m in B
			var want_r: float = 24.0 - (10.0 - main.space.Rout) - 2.0 * main.space.L + main.space.Rout
			var p := _feet()
			_check("Shift + W runs through the throat into universe B", _side() < 0.0 and absf(p.x + want_r) < 0.05 and absf(p.y) < 0.01,
					"side %+.0f, feet at (%.3f, %.3f), expected (%.3f, 0)" % [_side(), p.x, p.y, -want_r])
			_check("on the floor in B", absf(main.foot_n.z) < 1e-6, "n.z %s" % main.foot_n.z)
			_check("still walking straight in B", _forward().distance_to(Vector3(-1, 0, 0)) < 1e-3, "forward %s" % _forward())
			print("FAILURES: ", fails)
			quit(1 if fails > 0 else 0)
	return false
