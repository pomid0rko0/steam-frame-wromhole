extends SceneTree
## The grab branch's buttons through the desktop keys, run with --fixed-fps 60; exit status 1
## on any failure:
##   godot --path . --fixed-fps 60 -s res://tests/grab_test.gd
## 1. both hands are on the manifold, in front of and below the head
## 2. F throws a new ball forward
## 3. T shows the avatar: two more balls for the shader
## 4. R puts the viewer back at the start and the five balls back in place
## Grabbing itself needs the grip of a tracked controller; it is not driven here.

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


func _process(_delta: float) -> bool:
	frames += 1
	match frames:
		5:
			var ok: bool = main.hand_balls.size() == 2
			var detail := "hands %d" % main.hand_balls.size()
			for h in main.hand_balls:
				# desktop hands: 0.38 m ahead (chart -x), 0.32 m below the head, 0.22 m to the side
				var p: Vector3 = main.space.chart_position(h["l"], h["n"])
				ok = ok and absf(p.x - 9.62) < 0.01 and absf(absf(p.y) - 0.22) < 0.01 and absf(p.z - 1.28) < 0.01
				detail += "  %s" % p
			_check("both hands in front of and below the head", ok, detail)
			_key(KEY_F, true)
		7:
			_key(KEY_F, false)
		9:
			var n: int = main.world.balls.size()
			var b: Dictionary = main.world.balls[n - 1] if n > 0 else {}
			var ok: bool = n == 6 and b["U"].length() > 5.0
			_check("F throws a new ball", ok, "balls %d" % n)
			_key(KEY_T, true)
		11:
			_key(KEY_T, false)
		13:
			var nb: int = main.material.get_shader_parameter("wh_nBall")
			var want: int = main.world.balls.size() + 2 + 2
			_check("T shows the avatar", main.show_avatar and nb == want, "shader balls %d, expected %d" % [nb, want])
			_key(KEY_W, true)
		43:
			_key(KEY_W, false)
			_key(KEY_R, true)
		45:
			_key(KEY_R, false)
		47:
			var p: Vector3 = main.space.chart_position(main.foot_l, main.foot_n)
			var n: int = main.world.balls.size()
			_check("R: back at the start, five balls", p.distance_to(Vector3(10, 0, 0)) < 1e-3 and n == 5,
					"feet (%.3f, %.3f), balls %d" % [p.x, p.y, n])
			print("FAILURES: ", fails)
			quit(1 if fails > 0 else 0)
	return false
