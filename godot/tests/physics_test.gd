extends SceneTree
## Ball and cube physics checks (desktop, run with --fixed-fps 60), exit status 1 on any failure:
##   godot --path . --fixed-fps 60 -s res://tests/physics_test.gd [-- shot.png]
## 1. balls and cubes placed on the floor (one cube inside the throat) stay at rest
## 2. energy 1/2|U|^2 + g phi is conserved in free flight through the curved throat
## 3. a ball rolled toward the wormhole crosses into universe B and stays on the floor
## 4. two balls collide and conserve momentum along the line of centres (flat region)
## 5. cubes: the body axes are parallel-transported, a tumbling cube keeps its energy in free
##    flight through the throat, a sliding cube stops after v^2 / (2 mu g) without tipping or
##    rolling, a thrown cube comes to rest flat on a face, a cube slides on the curved floor of
##    the fillet and comes to rest on it, a ball pushes a cube, a cube pushes a cube, a pillar
##    stops a cube
## 6. gravity through the wormhole: the field matches ref/gravity.py and solves its equation; a
##    ball dropped in the middle of the throat falls as slowly as that field says, more than twice
##    as long as one dropped in front of the wormhole; above the throat's floor gravity pulls toward
##    the middle, where a ball rests; a ball set down at the shell's edge rolls in by itself and
##    rests in the middle (2-6 without air drag but that one: they check the motion itself)
## Then, with a screenshot path given, saves one with a ball and a cube inside the throat.

const U := preload("res://tests/util.gd")

var main: Node3D
var frames := 0
var flier: Dictionary
var roller: Dictionary
var e0 := 0.0
var emax := 0.0
var flying := true
var cubes_at_start: Array[Vector4] = []


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	main.toys.demo = false         # only the toys at rest
	root.add_child(main)


func _energy(b: Dictionary) -> float:
	var U: Vector4 = b["U"]
	return 0.5 * U.dot(U) + BallWorld.GRAVITY * main.space.potential(b["l"], b["n"])


func _process(_delta: float) -> bool:
	frames += 1
	var sp: WormholeSpace = main.space
	var w: BallWorld = main.toys.world
	if frames == 2:
		for c in w.cubes:
			cubes_at_start.append(sp.embed(c["l"], c["n"]))
	if frames == 150:
		# 1: the initial balls are still at rest on the floor after 2.5 s
		var worst_v := 0.0
		var worst_h := 0.0
		for b in w.balls:
			worst_v = maxf(worst_v, b["U"].length())
			worst_h = maxf(worst_h, absf(sp.height(b["l"], b["n"]) - b["radius"]))
		U.check("balls at rest stay at rest", worst_v < 0.05 and worst_h < 0.01, "max speed %.4f m/s, max |H - radius| %.4f m" % [worst_v, worst_h])
		var cube_moved := 0.0
		var cube_tilt := 0.0
		var cube_floor := 0.0
		for i in w.cubes.size():
			var c: Dictionary = w.cubes[i]
			cube_moved = maxf(cube_moved, (sp.embed(c["l"], c["n"]) - cubes_at_start[i]).length())
			cube_tilt = maxf(cube_tilt, _tilt(c))
			cube_floor = maxf(cube_floor, absf(_lowest(c)))
		U.check("cubes at rest stay at rest (one in the throat)", w.cubes.size() == 3 and cube_moved < 0.002 and cube_tilt < 0.01 and cube_floor < 0.003,
				"%d cubes, moved %.5f m, tilt %.5f rad, lowest corner %.5f m from the floor" % [w.cubes.size(), cube_moved, cube_tilt, cube_floor])
		w.balls.clear()
		w.cubes.clear()
		w.air = false          # 2-6 check the motion itself: no air drag
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
		U.check("energy conserved in free flight", emax < 1e-4 * absf(e0), "max |dE| %.7f of E %.3f, flier reached l = %.2f" % [emax, e0, flier["l"]])
		U.check("rolling ball went through to universe B", roller["l"] < -sp.L, "l = %.2f (shell |l| < %.2f)" % [roller["l"], sp.L])
		U.check("rolling ball stays on the floor", absf(sp.height(roller["l"], roller["n"]) - roller["radius"]) < 0.02, "H - radius = %.4f" % (sp.height(roller["l"], roller["n"]) - roller["radius"]))
		# 4: head-on collision in mid-air (flat A): horizontal momentum conserved, e = 0.85; far from
		# the wormhole, where gravity is uniform (nearer, it pulls a little toward the throat)
		w.balls.clear()
		var a := sp.point_from_chart(1.0, Vector3(28.0, 4.0, 2.0))
		var c := sp.point_from_chart(1.0, Vector3(29.0, 4.0, 2.0))
		var ba := w.add(a[0], a[1], 3.0 * WormholeSpace.vector_from_chart(1.0, a[1], Vector3(1, 0, 0)), 0.25, Color.WHITE)
		var bc := w.add(c[0], c[1], Vector4.ZERO, 0.25, Color.WHITE)
		for i in 18:
			w.step(1.0 / 60.0, [])
		var va: Vector3 = _chart_vel(ba)
		var vc: Vector3 = _chart_vel(bc)
		var e := BallWorld.RESTITUTION_BALL
		U.check("collision: momentum and restitution", absf(va.x + vc.x - 3.0) < 1e-3 and absf(vc.x - va.x - 3.0 * e) < 1e-2,
				"p %.4f (3.0), separation speed %.4f (%.4f)" % [va.x + vc.x, vc.x - va.x, 3.0 * e])
		_cube_checks(sp, w)
		_gravity_checks(sp, w)
		# a ball inside the throat for the screenshot
		w.balls.clear()
		main.toys.spawn()
		main.toys.launch_in = -1.0
		var t := sp.point_from_chart(1.0, Vector3(5.0, 0.4, 0.3))
		var tb := w.add(t[0], t[1], Vector4.ZERO, 0.3, Color(0.2, 0.9, 0.9))
		tb["l"] = 1.0
		tb["n"] = Vector3(1.0, 0.13, 0.1).normalized()
		tb["held"] = &"test"
	if frames == 336:
		if OS.get_cmdline_user_args().size() > 0:
			root.get_texture().get_image().save_png(OS.get_cmdline_user_args()[0])
		U.finish(self)
		return false
	return false


func _chart_vel(b: Dictionary) -> Vector3:
	var U: Vector4 = b["U"]
	var n: Vector3 = b["n"]
	return U.x * n + Vector3(U.y, U.z, U.w)   # flat A chart


# ---------------------------------------------------------------- cubes

## A cube on the floor of universe A at chart (x, y), turned by yaw, with chart velocity v and
## angular velocity w (body coordinates).
func _cube(x: Vector3, yaw: float, v: Vector3, w: Vector3, half: float, tilt := Vector3.ZERO) -> Dictionary:
	var sp: WormholeSpace = main.space
	var p := sp.point_from_chart(1.0, x)
	var b := Basis(Vector3(0, 0, 1), yaw) * Basis.from_euler(tilt)
	var F := []
	for ax in [b.x, b.y, b.z]:
		F.append(WormholeSpace.vector_from_chart(1.0, p[1], ax))
	return main.toys.world.add_cube(p[0], p[1], WormholeSpace.vector_from_chart(1.0, p[1], v), F, w, half, Color.WHITE)


## Angle between the cube's nearest body axis and the floor normal (0: resting flat on a face).
func _tilt(c: Dictionary) -> float:
	var up: Vector4 = main.space.height_grad(c["l"], c["n"]).normalized()
	var best := 0.0
	for A: Vector4 in c["F"]:
		best = maxf(best, absf(A.dot(up)))
	return acos(minf(best, 1.0))


## Height of the cube's lowest corner above the floor (first order at the centre, as the solver).
func _lowest(c: Dictionary) -> float:
	var sp: WormholeSpace = main.space
	var g := BallWorld.to_body(c["F"], sp.height_grad(c["l"], c["n"]))
	return sp.height(c["l"], c["n"]) - c["half"] * (absf(g.x) + absf(g.y) + absf(g.z))


func _cube_energy(c: Dictionary) -> float:
	var U: Vector4 = c["U"]
	var wb: Vector3 = c["w"]
	return BallWorld.cube_mass(c) * (0.5 * U.dot(U) + BallWorld.GRAVITY * main.space.potential(c["l"], c["n"])) \
			+ 0.5 * BallWorld.cube_inertia(c) * wb.dot(wb)


func _run(w: BallWorld, seconds: float) -> void:
	for i in int(seconds * 60.0):
		w.step(1.0 / 60.0, [])


func _cube_checks(sp: WormholeSpace, w: BallWorld) -> void:
	w.balls.clear()
	w.cubes.clear()

	# 5a: without gravity the free step transports the body axes like a geodesic does
	var p := sp.point_from_chart(1.0, Vector3(7.0, 1.2, 1.0))
	var V := WormholeSpace.vector_from_chart(1.0, p[1], Vector3(-1.0, -0.1, 0.05).normalized())
	var F0 := [WormholeSpace.vector_from_chart(1.0, p[1], Vector3(0.6, 0.8, 0.0)),
			WormholeSpace.vector_from_chart(1.0, p[1], Vector3(-0.8, 0.6, 0.0)),
			WormholeSpace.vector_from_chart(1.0, p[1], Vector3(0.0, 0.0, 1.0))]
	var st := [p[0], p[1], V, F0]
	for i in 1800:                     # 10 m through the throat at 1 m/s
		st = sp.dynamics_step(st[0], st[1], st[2], 1.0 / 180.0, 0.0, st[3])
	var g := sp.geodesic(p[0], p[1], V, 10.0, F0)
	var err: float = absf(st[0] - g[0])
	for i in 3:
		err = maxf(err, (st[3][i] - g[2][i]).length())
	U.check("cube axes parallel-transported", err < 1e-4, "free step vs geodesic after 10 m through the throat (l %.2f): %.7f" % [g[0], err])

	# 5b: a tumbling cube flies through the throat without touching anything
	var flier := _cube(Vector3(9.0, 0.3, 2.2), 0.3, 9.0 * Vector3(-1.0, 0.0, 0.45).normalized(), Vector3(3.0, -2.0, 5.0), 0.2)
	var e0 := _cube_energy(flier)
	var emax_c := 0.0
	var ortho := 0.0
	for i in 180:
		w.step(1.0 / 60.0, [])
		if _lowest(flier) < 0.02:
			break
		emax_c = maxf(emax_c, absf(_cube_energy(flier) - e0))
		for a in 3:
			for b in 3:
				ortho = maxf(ortho, absf(flier["F"][a].dot(flier["F"][b]) - (1.0 if a == b else 0.0)))
	U.check("tumbling cube: energy conserved in free flight", emax_c < 1e-4 * absf(e0) and ortho < 1e-5 and flier["l"] < 0.0,
			"max |dE| %.7f of E %.3f, axes orthonormal to %.7f, reached l = %.2f" % [emax_c, e0, ortho, flier["l"]])
	w.cubes.clear()

	# 5c: a cube sliding on the floor stops after v^2 / (2 mu g), flat, without rolling
	var slider := _cube(Vector3(12.0, 4.0, 0.25), 0.4, Vector3(0.0, 3.0, 0.0), Vector3.ZERO, 0.25)
	var x0 := sp.chart_position(slider["l"], slider["n"])
	var tilt := 0.0
	var spin := 0.0
	var t := 0.0
	var t0 := Time.get_ticks_usec()
	var steps := 0
	while t < 3.0:
		w.step(1.0 / 60.0, [])
		steps += 1
		t += 1.0 / 60.0
		tilt = maxf(tilt, _tilt(slider))
		spin = maxf(spin, slider["w"].length())
	var cost := (Time.get_ticks_usec() - t0) / 1000.0 / steps
	var dist := (sp.chart_position(slider["l"], slider["n"]) - x0).length()
	var expect := 9.0 / (2.0 * BallWorld.FRICTION_CUBE * BallWorld.GRAVITY)
	U.check("sliding cube stops after v^2 / (2 mu g), without tipping or rolling",
			absf(dist - expect) < 0.05 * expect and tilt < 0.01 and spin < 0.05 and slider["U"].length() < 1e-3,
			"%.3f m (%.3f), tilt %.4f rad, spin %.4f rad/s, %.2f ms per 60 Hz frame for one cube" % [dist, expect, tilt, spin, cost])
	w.cubes.clear()

	# 5d: a thrown, spinning cube comes to rest flat on a face and falls asleep
	var thrown := _cube(Vector3(12.0, -4.0, 1.5), 0.2, Vector3(-2.5, 0.8, 1.5), Vector3(4.0, -3.0, 2.0), 0.25, Vector3(0.5, 0.3, 0.0))
	_run(w, 5.0)
	U.check("thrown cube comes to rest flat on a face", _tilt(thrown) < 0.01 and absf(_lowest(thrown)) < 0.002 and thrown["still"] > BallWorld.SLEEP_TIME,
			"tilt %.4f rad, lowest corner %.4f m, still for %.2f s" % [_tilt(thrown), _lowest(thrown), thrown["still"]])
	w.cubes.clear()

	# 5e: a cube slides from the flat floor into the fillet, on the curved floor, and stops there
	var curved := _cube(Vector3(5.2, -0.5, 0.25), 0.0, Vector3(-5.0, 0.0, 0.0), Vector3.ZERO, 0.25)
	var low := 0.0
	var high := 0.0
	var tilt_c := 0.0
	var lmin := 1e9
	for i in 300:
		w.step(1.0 / 60.0, [])
		low = minf(low, _lowest(curved))
		if i > 10:
			high = maxf(high, _lowest(curved))
		tilt_c = maxf(tilt_c, _tilt(curved))
		lmin = minf(lmin, curved["l"])
	U.check("cube slides on the curved floor and stops on it", lmin < sp.L - 1.0 and low > -0.005 and high < 0.005 and tilt_c < 0.05 and curved["U"].length() < 1e-3,
			"reached l = %.2f (shell %.2f), lowest corner between %.4f and %.4f m, tilt %.4f rad, rests at l = %.2f" % [lmin, sp.L, low, high, tilt_c, curved["l"]])
	w.cubes.clear()

	# 5f: a ball rolls into a cube resting on the floor and pushes it
	var target := _cube(Vector3(10.0, -6.0, 0.25), 0.0, Vector3.ZERO, Vector3.ZERO, 0.25)
	var bp := sp.point_from_chart(1.0, Vector3(12.0, -6.0, 0.3))
	var ball := w.add(bp[0], bp[1], WormholeSpace.vector_from_chart(1.0, bp[1], Vector3(-4.0, 0.0, 0.0)), 0.3, Color.WHITE)
	var c0 := sp.chart_position(target["l"], target["n"])
	var gap_min := 1e9
	for i in 180:
		w.step(1.0 / 60.0, [])
		var d := (sp.embed(ball["l"], ball["n"]) - sp.embed(target["l"], target["n"])).length()
		gap_min = minf(gap_min, d)
	var pushed := sp.chart_position(target["l"], target["n"]) - c0
	var bv := WormholeSpace.vector_to_chart(1.0, ball["n"], ball["U"])
	U.check("ball pushes a cube", pushed.x < -0.1 and absf(pushed.y) < 0.05 and gap_min > 0.25 + 0.3 - 0.02 and _tilt(target) < 0.01,
			"cube moved %s m, ball now at %.2f m/s, closest centres %.3f m (touching %.2f)" % [str(pushed), bv.x, gap_min, 0.55])
	w.balls.clear()
	w.cubes.clear()

	# 5g: a cube slides into another one and pushes it, without passing into it
	var hitter := _cube(Vector3(13.0, 7.0, 0.25), 0.0, Vector3(-4.0, 0.0, 0.0), Vector3.ZERO, 0.25)
	var resting := _cube(Vector3(11.5, 7.05, 0.25), 0.3, Vector3.ZERO, Vector3.ZERO, 0.25)
	var r0 := sp.chart_position(resting["l"], resting["n"])
	var inside := 0.0
	for i in 180:
		w.step(1.0 / 60.0, [])
		inside = maxf(inside, _depth_in(hitter, resting))
		inside = maxf(inside, _depth_in(resting, hitter))
	var moved := (sp.chart_position(resting["l"], resting["n"]) - r0).length()
	U.check("cube pushes a cube, no passing through", moved > 0.1 and inside < 0.02 and resting["U"].length() < 1e-3 and hitter["U"].length() < 1e-3,
			"pushed %.3f m, deepest overlap %.4f m" % [moved, inside])
	w.cubes.clear()

	# 5h: a pillar of universe A stops a cube
	var pil: Array = main.scene["pillars_A"][0]
	var runner := _cube(Vector3(pil[0], pil[1] - 2.0, 0.25), 0.5, Vector3(0.0, 5.0, 0.0), Vector3.ZERO, 0.25)
	var closest := 1e9
	for i in 180:
		w.step(1.0 / 60.0, [])
		var x := sp.chart_position(runner["l"], runner["n"])
		closest = minf(closest, Vector2(x.x - pil[0], x.y - pil[1]).length())
	U.check("a pillar stops a cube", closest > pil[2] + 0.25 - 0.02,
			"closest approach of the centre to the axis %.3f m (pillar %.2f + half 0.25)" % [closest, pil[2]])
	w.cubes.clear()


## How deep the corners and edge midpoints of cube P are inside cube Q's box (0: not at all).
func _depth_in(P: Dictionary, Q: Dictionary) -> float:
	var w: BallWorld = main.toys.world
	var bp := w.box4(P)
	var bq := w.box4(Q)
	var deepest := 0.0
	for s: Vector3 in BallWorld.SAMPLES:
		var d: Vector4 = bp[0] + P["half"] * (s.x * bp[1] + s.y * bp[2] + s.z * bp[3]) - bq[0]
		var o := Vector3(Q["half"] - absf(d.dot(bq[1])), Q["half"] - absf(d.dot(bq[2])), Q["half"] - absf(d.dot(bq[3])))
		if o.x > 0.0 and o.y > 0.0 and o.z > 0.0:
			deepest = maxf(deepest, minf(o.x, minf(o.y, o.z)))
	return deepest


# ---------------------------------------------------------------- gravity

## First moment a ball touches the floor (s), or -1.
func _first_touch(w: BallWorld, b: Dictionary, seconds: float) -> float:
	var sp: WormholeSpace = main.space
	var t := 0.0
	while t < seconds:
		for k in 3:                           # one physics substep at a time
			w.step(BallWorld.DT, [])
			t += BallWorld.DT
			if sp.height(b["l"], b["n"]) < b["radius"] + 1e-3 or b["U"].dot(sp.height_grad(b["l"], b["n"])) > 0.0:
				return t
	return -1.0


func _gravity_checks(sp: WormholeSpace, w: BallWorld) -> void:
	w.balls.clear()
	w.cubes.clear()

	# 6a: the field against ref/gravity.py (python3 ref/test_gravity.py prints these numbers)
	var ref_l := [0.0, 2.0, 4.0, 5.0, sp.L]
	var ref_g := [0.20557, 0.30391, 0.69300, 0.91320, 0.94991]
	var worst := absf(sp.grav_beta - (-3.20586)) / 3.20586
	var got := []
	for i in ref_l.size():
		got.append(snappedf(sp.floor_gravity(ref_l[i]), 0.00001))
		worst = maxf(worst, absf(sp.floor_gravity(ref_l[i]) - ref_g[i]))
	U.check("gravity matches ref/gravity.py", worst < 2e-4, "floor g at l = 0, 2, 4, 5, L: %s (%s), beta %.5f (-3.20586)" % [str(got), str(ref_g), sp.grav_beta])

	# 6b: the potential solves Laplace's equation: (r^2 f')' = 2 f, also on the fillet's table
	var res := 0.0
	var e := 0.01
	for i in 120:
		var l := -sp.L - 3.0 + (2.0 * sp.L + 6.0) * (i + 0.5) / 120.0
		var flux := func(x: float) -> float: return sp.r(x) * sp.r(x) * sp.gravity_f(x)[1]
		var lap: float = (flux.call(l + e) - flux.call(l - e)) / (2.0 * e) - 2.0 * sp.gravity_f(l)[0]
		res = maxf(res, absf(lap))
	U.check("gravity solves Laplace's equation", res < 2e-3, "max |(r^2 f')' - 2 f| %.5f m^-1 over the shell and around it" % res)

	# 6c: the demo's two balls let go at the same height: in front of the wormhole and in the
	# middle of the throat
	var rad: float = Toys.DROP_RADIUS
	var hgt: float = Toys.DROP_HEIGHT
	var pa := sp.point_from_chart(1.0, Vector3(13.0, 3.0, hgt))
	var ba := w.add(pa[0], pa[1], Vector4.ZERO, rad, Color.WHITE)
	var ta := _first_touch(w, ba, 3.0)
	w.balls.clear()
	var bt := w.add(0.0, main.toys.throat_point(0.0, hgt), Vector4.ZERO, rad, Color.WHITE)
	var tt := _first_touch(w, bt, 6.0)
	var lmax := absf(bt["l"])
	w.balls.clear()
	# expected: in the middle of the throat the ball falls along a meridian of the sphere r = rho0
	# with s'' = -g f(0) / rho0 cos(s / rho0), until its height rho0 sin(s / rho0) is its radius
	var r0 := sp.r(0.0)
	var f0: float = sp.gravity_f(0.0)[0]
	var s := r0 * asin(hgt / r0)
	var v := 0.0
	var te := 0.0
	var dt := 1e-4
	while r0 * sin(s / r0) > rad:
		v -= BallWorld.GRAVITY * f0 / r0 * cos(s / r0) * dt
		s += v * dt
		te += dt
	var ta_e := sqrt(2.0 * (hgt - rad) / BallWorld.GRAVITY)
	U.check("dropped balls: slow fall in the throat", absf(ta - ta_e) < 0.02 and absf(tt - te) < 0.02 and tt > 2.0 * ta and lmax < 1e-6,
			"in front of the wormhole %.3f s (%.3f), in the middle of the throat %.3f s (%.3f), %.2f times longer; stays at l = 0 (|l| %.7f)" % [ta, ta_e, tt, te, tt / ta, lmax])

	# 6d: on the floor of the throat a ball is pulled toward the middle and rests there
	var z := 0.25 / sp.r(2.5)
	var side_ball := w.add(2.5, Vector3(0.0, sqrt(1.0 - z * z), z), Vector4.ZERO, 0.25, Color.WHITE)
	var z0 := 0.25 / sp.r(0.0)
	var mid_ball := w.add(0.0, Vector3(0.0, -sqrt(1.0 - z0 * z0), z0), Vector4.ZERO, 0.25, Color.WHITE)
	_run(w, 0.5)
	var l_half: float = side_ball["l"]
	var ul_half: float = side_ball["U"].x
	_run(w, 1.5)
	U.check("throat floor: pulled toward the middle, at rest in it", l_half < 2.48 and ul_half < -0.05 and mid_ball["U"].length() < 0.01 and absf(mid_ball["l"]) < 0.01,
			"ball from l = 2.5 at l = %.3f after 0.5 s (U_l %.3f m/s); ball in the middle at %.4f m/s, l = %.4f" % [l_half, ul_half, mid_ball["U"].length(), mid_ball["l"]])
	w.balls.clear()

	# 6e (with air, as in the headset): a ball set down at rest at the shell's edge rolls into the
	# throat by itself (gravity pulls along the floor toward it, 0.01 g there) and comes to rest in
	# its middle
	w.air = true
	var ze := 0.25 / sp.r(sp.L)
	var edge_ball := w.add(sp.L, Vector3(sqrt(1.0 - ze * ze), 0.0, ze), Vector4.ZERO, 0.25, Color.WHITE)
	_run(w, 10.0)
	var l10: float = edge_ball["l"]
	_run(w, 50.0)
	U.check("set down at the shell's edge, a ball rolls into the throat and rests in its middle",
			l10 < sp.L - 1.0 and absf(edge_ball["l"]) < 0.3 and edge_ball["U"].length() < 0.02,
			"l %.2f -> %.2f after 10 s -> %.3f after 60 s, %.3f m/s" % [sp.L, l10, edge_ball["l"], edge_ball["U"].length()])
	w.balls.clear()

	# 7: the scene as the headset shows it: the throw, then the drop; the thrown ball still rolls
	# through to universe B, nothing knocks the dropped balls off their spots, all come to rest
	main.toys.spawn()
	main.toys.launch_in = -1.0
	main.toys.drop_in = -1.0
	_run(w, Toys.LAUNCH_DELAY)
	main.toys.throw()
	_run(w, Toys.DROP_DELAY - Toys.LAUNCH_DELAY)
	main.toys.drop()
	var drops := []
	var orange: Dictionary
	for b in w.balls:
		if b["color"] == Toys.DROP_COLOR:
			drops.append([b, sp.embed(b["l"], b["n"])])
		elif b["color"] == Toys.BALL_COLORS[5]:
			orange = b
	_run(w, 6.0)
	var rest := []
	for d in drops:
		rest.append(sp.embed(d[0]["l"], d[0]["n"]))
	_run(w, 2.0)
	var creep := 0.0
	for i in drops.size():
		creep = maxf(creep, (sp.embed(drops[i][0]["l"], drops[i][0]["n"]) - rest[i]).length())
	var drift := 0.0
	var speed := 0.0
	for d in drops:
		var now: Vector4 = sp.embed(d[0]["l"], d[0]["n"])
		var moved: Vector4 = now - d[1]
		drift = maxf(drift, Vector3(moved.x, moved.y, 0.0).length() if d[0]["l"] > sp.L else absf(d[0]["l"]))
		speed = maxf(speed, d[0]["U"].length())
	U.check("the demo: thrown ball in universe B, dropped balls land where they fell and rest", drops.size() == 2 and not orange.is_empty() and orange["l"] < -sp.L and drift < 0.3 and speed < 0.05 and creep < 1e-5,
			"thrown ball at l = %.2f, dropped balls moved %.3f m sideways (pulled toward the throat), now at %.3f m/s, %.7f m in the last 2 s, %d balls" % [orange.get("l", 0.0), drift, speed, creep, w.balls.size()])
	w.balls.clear()
	w.cubes.clear()
