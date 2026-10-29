extends SceneTree
## Stick walking and turning through the desktop keys (the same code paths the sticks and
## buttons drive), run with --fixed-fps 60; exit status 1 on any failure:
##   godot --path . --fixed-fps 60 -s res://tests/walking_test.gd
## 1. W for one second walks 1.5 m toward the wormhole (chart A: x from 10 to 8.5)
## 2. E for one second turns smoothly 90 degrees to the right, Q for half a second 45 back
## 3. Tab switches to snaps: E snap-turns 30 degrees to the right (once per push), Q back
## 4. R puts the viewer back at the start, facing the wormhole
## 5. Shift + W for six seconds runs 24 m: through the middle of the throat into universe B,
##    on the floor, still walking straight, to where 24 m along the floor end in chart B
## 6. the speed check's view tilt turns about the head's own axes, whichever way it faces
## Controllers: tests/walking_xr_test.gd.

const U := preload("res://tests/util.gd")

var main: Node3D
var frames := 0


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	main.xr_name = "none"
	root.add_child(main)


## The side the feet are on (+1 universe A, -1 universe B) and their chart position there.
func _side() -> float:
	return signf(main.foot_l)


func _feet() -> Vector3:
	return main.space.chart_position(main.foot_l, main.foot_n)


## Which way the view points in the chart of the feet's side (horizontal).
func _forward() -> Vector3:
	var d := WormholeSpace.vector_to_chart(_side(), main.foot_n, -main.frame[2])    # play-space forward is -z
	return Vector3(d.x, d.y, 0.0).normalized()


## Facing `deg` degrees to the right of the start direction -x (whose right is +y).
func _check_turn(name: String, deg: float) -> void:
	var f := _forward()
	var want := Vector3(-cos(deg_to_rad(deg)), sin(deg_to_rad(deg)), 0.0)
	U.check(name, f.distance_to(want) < 1e-3, "forward (%.4f, %.4f), expected (%.4f, %.4f)" % [f.x, f.y, want.x, want.y])


func _check_feet_kept(name: String) -> void:
	var p := _feet()
	U.check(name, absf(p.x - 8.5) < 0.03 and absf(p.y) < 0.01, "feet at (%.3f, %.3f), expected (8.5, 0)" % [p.x, p.y])


## The speed check's view tilt (main._tilt) turns about the head's own axes, whichever way the head
## faces in the room: the look goes pitch up, the head's right turns roll about the look.
func _check_tilt() -> void:
	var f := [Vector4(1, 0, 0, 0), Vector4(0, 1, 0, 0), Vector4(0, 0, 1, 0)]     # play x, up, z
	var pitch := deg_to_rad(-35.0)
	var roll := deg_to_rad(20.0)
	var worst := 0.0
	for yaw in [0.0, 90.0, 200.0]:
		var a := deg_to_rad(yaw)
		var fwd := Vector2(-sin(a), -cos(a))         # the head turned yaw to the left of -z
		var t: Array = main._tilt(f, pitch, roll, fwd)
		var look: Vector4 = fwd.x * t[0] + fwd.y * t[2]
		var right: Vector4 = -fwd.y * t[0] + fwd.x * t[2]
		var flat: Vector4 = fwd.x * f[0] + fwd.y * f[2]
		var want_look: Vector4 = cos(pitch) * flat + sin(pitch) * f[1]
		var flat_r: Vector4 = -fwd.y * f[0] + fwd.x * f[2]
		var up_p: Vector4 = cos(pitch) * f[1] - sin(pitch) * flat
		var want_right: Vector4 = cos(roll) * flat_r + sin(roll) * up_p
		worst = maxf(worst, maxf((look - want_look).length(), (right - want_right).length()))
	U.check("the speed check's tilt turns about the head's own axes", worst < 1e-6, "off by %.2e" % worst)


func _process(_delta: float) -> bool:
	frames += 1
	match frames:
		3:
			_check_tilt()
		5:
			U.key(KEY_W, true)
		65:
			U.key(KEY_W, false)
		67:
			_check_feet_kept("W walks 1.5 m per second")
			_check_turn("walking keeps the view direction", 0.0)
			U.check("the right stick starts out turning smoothly", main.smooth_turn, "smooth_turn %s" % main.smooth_turn)
			U.key(KEY_E, true)
		127:
			U.key(KEY_E, false)
		129:
			_check_turn("E held for a second turns smoothly 90 degrees right", 90.0)
			_check_feet_kept("turning leaves the feet in place")
			U.key(KEY_Q, true)
		159:
			U.key(KEY_Q, false)
		161:
			_check_turn("Q held for half a second turns 45 degrees back left", 45.0)
			U.key(KEY_TAB, true)
		163:
			U.key(KEY_TAB, false)
		165:
			U.check("Tab switches to snap turns", not main.smooth_turn, "smooth_turn %s" % main.smooth_turn)
			_check_turn("switching turns nothing", 45.0)
			U.key(KEY_R, true)
		167:
			U.key(KEY_R, false)
		169:
			var p := _feet()
			var ok: bool = p.distance_to(Vector3(10, 0, 0)) < 1e-3 and _forward().distance_to(Vector3(-1, 0, 0)) < 1e-3
			U.check("R goes back to the start, facing the wormhole", ok, "feet (%.3f, %.3f), forward %s" % [p.x, p.y, _forward()])
			U.key(KEY_E, true)
		171:
			U.key(KEY_E, false)
		173:
			_check_turn("E snap-turns 30 degrees right", 30.0)
			U.key(KEY_E, true)          # held: one turn per push, not one per frame
		185:
			U.key(KEY_E, false)
		187:
			_check_turn("holding E turns once", 60.0)
			U.key(KEY_Q, true)
		189:
			U.key(KEY_Q, false)
		191:
			_check_turn("Q snap-turns 30 degrees left", 30.0)
			U.key(KEY_TAB, true)
		193:
			U.key(KEY_TAB, false)
			U.key(KEY_R, true)
		195:
			U.key(KEY_R, false)
		197:
			U.check("Tab again switches back to smooth turns", main.smooth_turn, "smooth_turn %s" % main.smooth_turn)
			_check_turn("R faces the wormhole again", 0.0)
			U.key(KEY_SHIFT, true)
			U.key(KEY_W, true)
		557:
			U.key(KEY_W, false)
			U.key(KEY_SHIFT, false)
		559:
			# 24 m from the start: START_POS.x - Rout of flat floor, 2L of curved zone, the rest in B
			var want_r: float = 24.0 - (main.START_POS.x - main.space.Rout) - 2.0 * main.space.L + main.space.Rout
			var p := _feet()
			U.check("Shift + W runs through the throat into universe B", _side() < 0.0 and absf(p.x + want_r) < 0.05 and absf(p.y) < 0.01,
					"side %+.0f, feet at (%.3f, %.3f), expected (%.3f, 0)" % [_side(), p.x, p.y, -want_r])
			U.check("on the floor in B", absf(main.foot_n.z) < 1e-6, "n.z %s" % main.foot_n.z)
			U.check("still walking straight in B", _forward().distance_to(Vector3(-1, 0, 0)) < 1e-3, "forward %s" % _forward())
			U.finish(self)
	return false
