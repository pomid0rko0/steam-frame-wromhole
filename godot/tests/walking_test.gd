extends SceneTree
## Stick walking and turning through the desktop keys (the same code paths the sticks and
## buttons drive), run with --fixed-fps 60; exit status 1 on any failure:
##   godot --path . --fixed-fps 60 -s res://tests/walking_test.gd
## 1. W for one second walks 1.5 m toward the wormhole (chart A: x from 10 to 8.5)
## 2. E for one second turns smoothly 90 degrees to the right, Q for half a second 45 back
## 3. Tab switches to snaps: E snap-turns 30 degrees to the right (once per push), Q back
## 4. R puts the viewer back at the start, facing the wormhole
## 5. Shift + W for six seconds runs 24 m: through the middle of the throat into universe B,
##    on the floor, still walking straight (chart B: x = -10.86)
## tests/walking_xr_test.gd does the same with controllers.

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


## Facing `deg` degrees to the right of the start direction -x (whose right is +y).
func _check_turn(name: String, deg: float) -> void:
	var f := _forward()
	var want := Vector3(-cos(deg_to_rad(deg)), sin(deg_to_rad(deg)), 0.0)
	_check(name, f.distance_to(want) < 1e-3, "forward (%.4f, %.4f), expected (%.4f, %.4f)" % [f.x, f.y, want.x, want.y])


func _check_feet_kept(name: String) -> void:
	var p := _feet()
	_check(name, absf(p.x - 8.5) < 0.03 and absf(p.y) < 0.01, "feet at (%.3f, %.3f), expected (8.5, 0)" % [p.x, p.y])


func _process(_delta: float) -> bool:
	frames += 1
	match frames:
		5:
			_key(KEY_W, true)
		65:
			_key(KEY_W, false)
		67:
			_check_feet_kept("W walks 1.5 m per second")
			_check_turn("walking keeps the view direction", 0.0)
			_check("the right stick starts out turning smoothly", main.smooth_turn, "smooth_turn %s" % main.smooth_turn)
			_key(KEY_E, true)
		127:
			_key(KEY_E, false)
		129:
			_check_turn("E held for a second turns smoothly 90 degrees right", 90.0)
			_check_feet_kept("turning leaves the feet in place")
			_key(KEY_Q, true)
		159:
			_key(KEY_Q, false)
		161:
			_check_turn("Q held for half a second turns 45 degrees back left", 45.0)
			_key(KEY_TAB, true)
		163:
			_key(KEY_TAB, false)
		165:
			_check("Tab switches to snap turns", not main.smooth_turn, "smooth_turn %s" % main.smooth_turn)
			_check_turn("switching turns nothing", 45.0)
			_key(KEY_R, true)
		167:
			_key(KEY_R, false)
		169:
			var p := _feet()
			var ok: bool = p.distance_to(Vector3(10, 0, 0)) < 1e-3 and _forward().distance_to(Vector3(-1, 0, 0)) < 1e-3
			_check("R goes back to the start, facing the wormhole", ok, "feet (%.3f, %.3f), forward %s" % [p.x, p.y, _forward()])
			_key(KEY_E, true)
		171:
			_key(KEY_E, false)
		173:
			_check_turn("E snap-turns 30 degrees right", 30.0)
			_key(KEY_E, true)          # held: one turn per push, not one per frame
		185:
			_key(KEY_E, false)
		187:
			_check_turn("holding E turns once", 60.0)
			_key(KEY_Q, true)
		189:
			_key(KEY_Q, false)
		191:
			_check_turn("Q snap-turns 30 degrees left", 30.0)
			_key(KEY_TAB, true)
		193:
			_key(KEY_TAB, false)
			_key(KEY_R, true)
		195:
			_key(KEY_R, false)
		197:
			_check("Tab again switches back to smooth turns", main.smooth_turn, "smooth_turn %s" % main.smooth_turn)
			_check_turn("R faces the wormhole again", 0.0)
			_key(KEY_SHIFT, true)
			_key(KEY_W, true)
		557:
			_key(KEY_W, false)
			_key(KEY_SHIFT, false)
		559:
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
