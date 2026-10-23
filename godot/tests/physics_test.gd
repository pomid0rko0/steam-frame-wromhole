extends SceneTree
## Ball physics checks (desktop, run with --fixed-fps 60), exit status 1 on any failure:
##   godot --path . --fixed-fps 60 -s res://tests/physics_test.gd [-- shot.png]
## 1. balls placed on the floor stay at rest
## 2. energy 1/2|U|^2 + g H is conserved in free flight through the curved throat
## 3. a ball rolled toward the wormhole crosses into universe B and stays on the floor
## 4. two balls collide and conserve momentum along the line of centres (flat region)
## Then, with a screenshot path given, saves one with a ball inside the throat.

var main: Node3D
var frames := 0
var fails := 0
var flier: Dictionary
var roller: Dictionary
var e0 := 0.0
var emax := 0.0
var flying := true


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)


func _check(name: String, ok: bool, detail: String) -> void:
	print(("PASS " if ok else "FAIL ") + name + "  " + detail)
	if not ok:
		fails += 1


func _energy(b: Dictionary) -> float:
	var U: Vector4 = b["U"]
	return 0.5 * U.dot(U) + BallWorld.GRAVITY * main.space.height(b["l"], b["n"])


func _process(_delta: float) -> bool:
	frames += 1
	var sp: WormholeSpace = main.space
	var w: BallWorld = main.world
	if frames == 150:
		# 1: the initial balls are still at rest on the floor after 2.5 s
		var worst_v := 0.0
		var worst_h := 0.0
		for b in w.balls:
			worst_v = maxf(worst_v, b["U"].length())
			worst_h = maxf(worst_h, absf(sp.height(b["l"], b["n"]) - b["radius"]))
		_check("balls at rest stay at rest", worst_v < 0.05 and worst_h < 0.01, "max speed %.4f m/s, max |H - radius| %.4f m" % [worst_v, worst_h])
		w.balls.clear()
		# 2: a ball flying through the throat without touching anything (no floor contact: high up)
		var p := sp.point_from_chart(1.0, Vector3(9.0, 0.3, 2.2))
		var d := WormholeSpace.vector_from_chart(1.0, p[1], Vector3(-1.0, 0.0, 0.45).normalized())
		flier = w.add(p[0], p[1], 9.0 * d, 0.2, Color.WHITE)
		e0 = _energy(flier)
		# 3: a ball rolling along the floor straight into the wormhole
		var q := sp.point_from_chart(1.0, Vector3(9.0, -0.6, 0.3))
		roller = w.add(q[0], q[1], 7.0 * WormholeSpace.vector_from_chart(1.0, q[1], Vector3(-1.0, 0.0, 0.0)), 0.3, Color.WHITE)
	if frames > 150 and frames < 330 and flying:
		# until its first contact with the floor the flier is in free flight
		if sp.height(flier["l"], flier["n"]) < flier["radius"] + 0.02:
			flying = false
		else:
			emax = maxf(emax, absf(_energy(flier) - e0))
	if frames == 330:
		_check("energy conserved in free flight", emax < 1e-4 * absf(e0), "max |dE| %.7f of E %.3f, flier reached l = %.2f" % [emax, e0, flier["l"]])
		_check("rolling ball went through to universe B", roller["l"] < -sp.L, "l = %.2f (shell |l| < %.2f)" % [roller["l"], sp.L])
		_check("rolling ball stays on the floor", absf(sp.height(roller["l"], roller["n"]) - roller["radius"]) < 0.02, "H - radius = %.4f" % (sp.height(roller["l"], roller["n"]) - roller["radius"]))
		# 4: head-on collision in mid-air (flat A): horizontal momentum conserved, e = 0.85
		w.balls.clear()
		var a := sp.point_from_chart(1.0, Vector3(12.0, 4.0, 2.0))
		var c := sp.point_from_chart(1.0, Vector3(13.0, 4.0, 2.0))
		var ba := w.add(a[0], a[1], 3.0 * WormholeSpace.vector_from_chart(1.0, a[1], Vector3(1, 0, 0)), 0.25, Color.WHITE)
		var bc := w.add(c[0], c[1], Vector4.ZERO, 0.25, Color.WHITE)
		for i in 18:
			w.step(1.0 / 60.0, [])
		var va: Vector3 = _chart_vel(ba)
		var vc: Vector3 = _chart_vel(bc)
		var e := BallWorld.RESTITUTION_BALL
		_check("collision: momentum and restitution", absf(va.x + vc.x - 3.0) < 1e-3 and absf(vc.x - va.x - 3.0 * e) < 1e-2,
				"p %.4f (3.0), separation speed %.4f (%.4f)" % [va.x + vc.x, vc.x - va.x, 3.0 * e])
		# a ball inside the throat for the screenshot
		w.balls.clear()
		main._spawn_initial_balls()
		var t := sp.point_from_chart(1.0, Vector3(5.0, 0.4, 0.3))
		var tb := w.add(t[0], t[1], Vector4.ZERO, 0.3, Color(0.2, 0.9, 0.9))
		tb["l"] = 1.0
		tb["n"] = Vector3(1.0, 0.13, 0.1).normalized()
		tb["held"] = &"test"
	if frames == 336:
		if OS.get_cmdline_user_args().size() > 0:
			root.get_texture().get_image().save_png(OS.get_cmdline_user_args()[0])
		print("FAILURES: ", fails)
		quit(1 if fails > 0 else 0)
		return false
	return false


func _chart_vel(b: Dictionary) -> Vector3:
	var U: Vector4 = b["U"]
	var n: Vector3 = b["n"]
	return U.x * n + Vector3(U.y, U.z, U.w)   # flat A chart
