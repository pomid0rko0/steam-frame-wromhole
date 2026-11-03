extends SceneTree
## Ball and cube physics checks (desktop, run with --fixed-fps 60 in a small window: the checks look
## at no picture, and a frame costs by its pixels; shot.png, the window at the end, as big as
## --resolution gives), exit status 1 on any failure:
##   godot --path . --resolution 160x90 --fixed-fps 60 -s res://tests/physics_test.gd [-- shot.png]
## 1. the demo's balls and cubes at rest on the floors of universes A and B stay at rest
## 2. energy 1/2|U|^2 + g phi is conserved in free flight into the mouth, through the throat
## 3. a ball rolled along universe A's floor passes under the mouth and stays on the floor in A
## 4. two balls collide and conserve momentum along the line of centres (flat region); two held
##    ones that touch do not
## 5. cubes: the body axes are parallel-transported, a tumbling cube keeps its energy in free
##    flight through the throat, a sliding cube stops after v^2 / (2 mu g) without tipping or
##    rolling, a thrown cube comes to rest flat on a face, a cube thrown into the mouth comes out of
##    universe B's and comes to rest flat on B's floor, a ball pushes a cube, a cube pushes a cube,
##    a pillar stops a cube
## 6. gravity through the wormhole (the field itself: tests/gravity_test.gd): a ball let go right
##    over the throat's centre falls into it as that field says (it prints how long a uniform field
##    takes over the same length), through it into universe B and up to the height it fell from, n
##    staying +z; under the mouth the floor pushes a ball away from the point under the throat's
##    centre as that field says, and one right on that point rests; a ball set down 1 m off it rolls
##    away by itself and comes to rest where the push no longer beats rolling friction (2-6 without
##    air drag but that one: they check the motion itself)
## 7. the demo as the headset shows it: the thrown ball goes through to universe B and comes to
##    rest on its floor, the thrown cube in front of the mouth; the ball dropped into the throat's top
##    goes through to B once, falls past B's mouth onto B's floor and comes to rest; the toys at rest
##    stay
## Then, with a screenshot path given, saves one with a ball inside the throat.

const U := preload("res://tests/util.gd")

var main: Main
var frames := 0
var flier: BallWorld.Ball
var roller: BallWorld.Ball
var e0 := 0.0
var emax := 0.0
var flier_lmin := INF
var roller_low := 0.0
var roller_lmin := INF
var cubes_at_start: Array[Vector4] = []
# a throw into the mouth that goes through the throat without touching the floor (2, 5b): chart A
const FLIGHT_FROM := Vector3(9.0, 0.3, 2.2)
const FLIGHT_V := Vector3(-9.0, -0.3, 7.7)


func _initialize() -> void:
	main = load("res://main.tscn").instantiate() as Main
	main.toys.demo = false         # only the toys at rest
	root.add_child(main)


func _energy(b: BallWorld.Ball) -> float:
	var U: Vector4 = b.U
	return 0.5 * U.dot(U) + BallWorld.GRAVITY * main.space.potential(b.l, b.n)


func _process(_delta: float) -> bool:
	frames += 1
	var sp: WormholeSpace = main.space
	var w: BallWorld = main.toys.world
	if frames == 2:
		for c in w.cubes:
			cubes_at_start.append(sp.embed(c.l, c.n))
	if frames == 150:
		# 1: the initial balls are still at rest on the floor after 2.5 s
		var worst_v := 0.0
		var worst_h := 0.0
		for b in w.balls:
			worst_v = maxf(worst_v, b.U.length())
			worst_h = maxf(worst_h, absf(sp.height(b.l, b.n) - b.radius))
		U.check("balls at rest stay at rest", worst_v < 0.05 and worst_h < 0.01, "max speed %.4f m/s, max |H - radius| %.4f m" % [worst_v, worst_h])
		var cube_moved := 0.0
		var cube_tilt := 0.0
		var cube_floor := 0.0
		for i in w.cubes.size():
			var c := w.cubes[i]
			cube_moved = maxf(cube_moved, (sp.embed(c.l, c.n) - cubes_at_start[i]).length())
			cube_tilt = maxf(cube_tilt, _tilt(c))
			cube_floor = maxf(cube_floor, absf(_lowest(c)))
		U.check("cubes at rest stay at rest (under the mouth too)", w.cubes.size() == cubes_at_start.size() and cube_moved < 0.002 and cube_tilt < 0.01 and cube_floor < 0.003,
				"%d cubes, moved %.5f m, tilt %.5f rad, lowest corner %.5f m from the floor" % [w.cubes.size(), cube_moved, cube_tilt, cube_floor])
		w.balls.clear()
		w.cubes.clear()
		w.air = false          # 2-6b check the motion itself: no air drag (6c turns it on)
		# 2: a ball thrown into the mouth, through the throat, without touching anything: in free
		# flight until it comes within 10 cm of the floor (more than a substep's way: a contact leaves
		# it just at its radius over the floor), seen one physics substep at a time
		var p := sp.point_from_chart(1.0, FLIGHT_FROM)
		flier = w.add(p[0], p[1], WormholeSpace.vector_from_chart(1.0, p[1], FLIGHT_V), 0.2, Color.WHITE)
		e0 = _energy(flier)
		var t := 0.0
		while t < 3.0:
			w.step(BallWorld.DT, [])
			t += BallWorld.DT
			if sp.height(flier.l, flier.n) < flier.radius + 0.1:
				break
			emax = maxf(emax, absf(_energy(flier) - e0))
			flier_lmin = minf(flier_lmin, flier.l)
		U.check("energy conserved in free flight through the throat", emax < 1e-4 * absf(e0) and flier_lmin < -sp.L,
				"max |dE| %.7f of E %.3f, the flier down to l = %.2f in free flight for %.2f s (universe B below %.2f)" % [emax, e0, flier_lmin, t, -sp.L])
		w.balls.clear()
		# 3: a ball rolling along the floor under the mouth
		var q := sp.point_from_chart(1.0, Vector3(9.0, -0.6, 0.3))
		roller = w.add(q[0], q[1], 7.0 * WormholeSpace.vector_from_chart(1.0, q[1], Vector3(-1.0, 0.0, 0.0)), 0.3, Color.WHITE)
		for i in 180:
			w.step(1.0 / 60.0, [])
			roller_low = maxf(roller_low, absf(sp.height(roller.l, roller.n) - roller.radius))
			roller_lmin = minf(roller_lmin, roller.l)
		var rx := sp.chart_position(roller.l, roller.n)
		U.check("a ball rolled under the mouth stays on the floor in universe A", roller_lmin > sp.L and rx.x < -2.0 and roller_low < 0.02,
				"now at chart A %s, l at least %.2f (A above %.2f), |H - radius| at most %.4f" % [rx, roller_lmin, sp.L, roller_low])
		# 4: head-on collision in mid-air (flat A): horizontal momentum conserved, RESTITUTION_BALL (and two
		# held balls do not collide); far from
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
		# two held balls that touch, moving at each other: the hands place both, neither pushes the other
		w.balls.clear()
		var c2 := sp.point_from_chart(1.0, Vector3(28.45, 4.0, 2.0))
		var h1 := w.add(a[0], a[1], WormholeSpace.vector_from_chart(1.0, a[1], Vector3(1, 0, 0)), 0.25, Color.WHITE)
		var h2 := w.add(c2[0], c2[1], WormholeSpace.vector_from_chart(1.0, c2[1], Vector3(-1, 0, 0)), 0.25, Color.WHITE)
		h1.held = &"left_hand"
		h2.held = &"right_hand"
		var u1: Vector4 = h1.U
		var u2: Vector4 = h2.U
		w.step(1.0 / 60.0, [])
		U.check("two held balls that touch don't push each other", h1.U == u1 and h2.U == u2,
				"velocities %s, %s" % [_chart_vel(h1), _chart_vel(h2)])
		_cube_checks(sp, w)
		_gravity_checks(sp, w)
		# a ball inside the throat for the screenshot
		w.balls.clear()
		main.toys.spawn()
		main.toys.launch_in = -1.0
		main.toys.drop_in = -1.0
		var tb := w.add(1.0, Vector3(1.0, 0.13, -0.5).normalized(), Vector4.ZERO, 0.3, Color(0.2, 0.9, 0.9))
		tb.held = &"test"
	if frames == 156:
		if OS.get_cmdline_user_args().size() > 0:
			root.get_texture().get_image().save_png(OS.get_cmdline_user_args()[0])
		U.finish(self)
		return false
	return false


func _chart_vel(b: BallWorld.Body) -> Vector3:
	var U: Vector4 = b.U
	var n: Vector3 = b.n
	return U.x * n + Vector3(U.y, U.z, U.w)   # flat A chart


# ---------------------------------------------------------------- cubes

## A cube at chart point x of universe A, turned by yaw, with chart velocity v and
## angular velocity w (body coordinates).
func _cube(x: Vector3, yaw: float, v: Vector3, w: Vector3, half: float, tilt := Vector3.ZERO) -> BallWorld.Cube:
	var sp: WormholeSpace = main.space
	var p := sp.point_from_chart(1.0, x)
	var b := Basis(Vector3(0, 0, 1), yaw) * Basis.from_euler(tilt)
	var F := []
	for ax in [b.x, b.y, b.z]:
		F.append(WormholeSpace.vector_from_chart(1.0, p[1], ax))
	return main.toys.world.add_cube(p[0], p[1], WormholeSpace.vector_from_chart(1.0, p[1], v), F, w, half, Color.WHITE)


## Angle between the cube's nearest body axis and the floor normal (0: resting flat on a face).
func _tilt(c: BallWorld.Cube) -> float:
	var up: Vector4 = main.space.height_grad(c.l, c.n).normalized()
	var best := 0.0
	for A: Vector4 in c.F:
		best = maxf(best, absf(A.dot(up)))
	return acos(minf(best, 1.0))


## Height of the cube's lowest corner above the floor (first order at the centre, as the solver).
func _lowest(c: BallWorld.Cube) -> float:
	var sp: WormholeSpace = main.space
	var g := BallWorld.to_body(c.F, sp.height_grad(c.l, c.n))
	return sp.height(c.l, c.n) - c.half * (absf(g.x) + absf(g.y) + absf(g.z))


func _cube_energy(c: BallWorld.Cube) -> float:
	var U: Vector4 = c.U
	var wb: Vector3 = c.w
	return BallWorld.cube_mass(c) * (0.5 * U.dot(U) + BallWorld.GRAVITY * main.space.potential(c.l, c.n)) \
			+ 0.5 * BallWorld.cube_inertia(c) * wb.dot(wb)


func _run(w: BallWorld, seconds: float) -> void:
	for i in int(seconds * 60.0):
		w.step(1.0 / 60.0, [])


func _cube_checks(sp: WormholeSpace, w: BallWorld) -> void:
	w.balls.clear()
	w.cubes.clear()

	# 5a: without gravity the free step transports the body axes like a geodesic does
	var p := sp.point_from_chart(1.0, Vector3(7.0, 1.2, 4.0))
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
	U.check("cube axes parallel-transported", err < 1e-4, "free step vs geodesic after 10 m into the throat (l %.2f): %.7f" % [g[0], err])

	# 5b: a tumbling cube flies through the throat without touching anything
	var flier := _cube(FLIGHT_FROM, 0.3, FLIGHT_V, Vector3(3.0, -2.0, 5.0), 0.2)
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
				ortho = maxf(ortho, absf(flier.F[a].dot(flier.F[b]) - (1.0 if a == b else 0.0)))
	U.check("tumbling cube: energy conserved in free flight", emax_c < 1e-4 * absf(e0) and ortho < 1e-5 and flier.l < -sp.L,
			"max |dE| %.7f of E %.3f, axes orthonormal to %.7f, reached l = %.2f" % [emax_c, e0, ortho, flier.l])
	w.cubes.clear()

	# 5c: a cube sliding on the floor stops after v^2 / (2 mu g), flat, without rolling
	var slider := _cube(Vector3(12.0, 4.0, 0.25), 0.4, Vector3(0.0, 3.0, 0.0), Vector3.ZERO, 0.25)
	var x0 := sp.chart_position(slider.l, slider.n)
	var tilt := 0.0
	var spin := 0.0
	var t := 0.0
	var usec := 0
	var steps := 0
	while t < 3.0:
		var t0 := Time.get_ticks_usec()
		w.step(1.0 / 60.0, [])
		usec += Time.get_ticks_usec() - t0
		steps += 1
		t += 1.0 / 60.0
		tilt = maxf(tilt, _tilt(slider))
		spin = maxf(spin, slider.w.length())
	var cost := usec / 1000.0 / steps
	var dist := (sp.chart_position(slider.l, slider.n) - x0).length()
	var expect := 9.0 / (2.0 * BallWorld.FRICTION_CUBE * BallWorld.GRAVITY)
	U.check("sliding cube stops after v^2 / (2 mu g), without tipping or rolling",
			absf(dist - expect) < 0.05 * expect and tilt < 0.01 and spin < 0.05 and slider.U.length() < 1e-3,
			"%.3f m (%.3f), tilt %.4f rad, spin %.4f rad/s, %.2f ms per 60 Hz frame for one cube" % [dist, expect, tilt, spin, cost])
	w.cubes.clear()

	# 5d: a thrown, spinning cube comes to rest flat on a face and falls asleep
	var thrown := _cube(Vector3(12.0, -4.0, 1.5), 0.2, Vector3(-2.5, 0.8, 1.5), Vector3(4.0, -3.0, 2.0), 0.25, Vector3(0.5, 0.3, 0.0))
	_run(w, 5.0)
	U.check("thrown cube comes to rest flat on a face", _tilt(thrown) < 0.01 and absf(_lowest(thrown)) < 0.002 and thrown.still > BallWorld.SLEEP_TIME,
			"tilt %.4f rad, lowest corner %.4f m, still for %.2f s" % [_tilt(thrown), _lowest(thrown), thrown.still])
	w.cubes.clear()

	# 5e: a cube thrown into the mouth comes out of universe B's, lands on B's floor and comes to rest
	# flat there
	var through := _cube(FLIGHT_FROM, 0.2, Vector3(-8.0, -0.3, 7.0), Vector3(4.0, -3.0, 2.0), 0.2)
	var lmin := INF
	for i in 600:
		w.step(1.0 / 60.0, [])
		lmin = minf(lmin, through.l)
	var bx := sp.chart_position(through.l, through.n)
	U.check("a cube thrown into the mouth comes to rest flat on universe B's floor", lmin < -sp.L and through.l < -sp.L
			and _tilt(through) < 0.01 and absf(_lowest(through)) < 0.002 and through.still > BallWorld.SLEEP_TIME,
			"down to l %.2f, rests at chart B %s, tilt %.4f rad, lowest corner %.4f m, still for %.2f s" % [lmin, bx, _tilt(through), _lowest(through), through.still])
	w.cubes.clear()

	# 5f: a ball rolls into a cube resting on the floor and pushes it
	var target := _cube(Vector3(10.0, -6.0, 0.25), 0.0, Vector3.ZERO, Vector3.ZERO, 0.25)
	var bp := sp.point_from_chart(1.0, Vector3(12.0, -6.0, 0.3))
	var ball := w.add(bp[0], bp[1], WormholeSpace.vector_from_chart(1.0, bp[1], Vector3(-4.0, 0.0, 0.0)), 0.3, Color.WHITE)
	var c0 := sp.chart_position(target.l, target.n)
	var gap_min := 1e9
	for i in 180:
		w.step(1.0 / 60.0, [])
		var d := (sp.embed(ball.l, ball.n) - sp.embed(target.l, target.n)).length()
		gap_min = minf(gap_min, d)
	var pushed := sp.chart_position(target.l, target.n) - c0
	var bv := WormholeSpace.vector_to_chart(1.0, ball.n, ball.U)
	U.check("ball pushes a cube", pushed.x < -0.1 and absf(pushed.y) < 0.05 and gap_min > 0.25 + 0.3 - 0.02 and _tilt(target) < 0.01,
			"cube moved %s m, ball now at %.2f m/s, closest centres %.3f m (touching %.2f)" % [str(pushed), bv.x, gap_min, 0.55])
	w.balls.clear()
	w.cubes.clear()

	# 5g: a cube slides into another one and pushes it, without passing into it
	var hitter := _cube(Vector3(13.0, 7.0, 0.25), 0.0, Vector3(-4.0, 0.0, 0.0), Vector3.ZERO, 0.25)
	var resting := _cube(Vector3(11.5, 7.05, 0.25), 0.3, Vector3.ZERO, Vector3.ZERO, 0.25)
	var r0 := sp.chart_position(resting.l, resting.n)
	var inside := 0.0
	for i in 180:
		w.step(1.0 / 60.0, [])
		inside = maxf(inside, _depth_in(hitter, resting))
		inside = maxf(inside, _depth_in(resting, hitter))
	var moved := (sp.chart_position(resting.l, resting.n) - r0).length()
	U.check("cube pushes a cube, no passing through", moved > 0.1 and inside < 0.02 and resting.U.length() < 1e-3 and hitter.U.length() < 1e-3,
			"pushed %.3f m, deepest overlap %.4f m" % [moved, inside])
	w.cubes.clear()

	# 5h: a pillar of universe A stops a cube
	var pil: Array = main.scene["pillars_A"][0]
	var runner := _cube(Vector3(pil[0], pil[1] - 2.0, 0.25), 0.5, Vector3(0.0, 5.0, 0.0), Vector3.ZERO, 0.25)
	var closest := 1e9
	for i in 180:
		w.step(1.0 / 60.0, [])
		var x := sp.chart_position(runner.l, runner.n)
		closest = minf(closest, Vector2(x.x - pil[0], x.y - pil[1]).length())
	U.check("a pillar stops a cube", closest > pil[2] + 0.25 - 0.02,
			"closest approach of the centre to the axis %.3f m (pillar %.2f + half 0.25)" % [closest, pil[2]])
	w.cubes.clear()


## How deep the corners and edge midpoints of cube P are inside cube Q's box (0: not at all).
func _depth_in(P: BallWorld.Cube, Q: BallWorld.Cube) -> float:
	var w: BallWorld = main.toys.world
	var bp := w.box4(P)
	var bq := w.box4(Q)
	var deepest := 0.0
	for s: Vector3 in BallWorld.SAMPLES:
		var d: Vector4 = bp[0] + P.half * (s.x * bp[1] + s.y * bp[2] + s.z * bp[3]) - bq[0]
		var o := Vector3(Q.half - absf(d.dot(bq[1])), Q.half - absf(d.dot(bq[2])), Q.half - absf(d.dot(bq[3])))
		if o.x > 0.0 and o.y > 0.0 and o.z > 0.0:
			deepest = maxf(deepest, minf(o.x, minf(o.y, o.z)))
	return deepest


# ---------------------------------------------------------------- gravity

## First moment a ball touches the floor (s), or -1.
func _first_touch(w: BallWorld, b: BallWorld.Ball, seconds: float) -> float:
	var sp: WormholeSpace = main.space
	var t := 0.0
	while t < seconds:
		for k in 3:                           # one physics substep at a time
			w.step(BallWorld.DT, [])
			t += BallWorld.DT
			if sp.height(b.l, b.n) < b.radius + 1e-3 or b.U.dot(sp.height_grad(b.l, b.n)) > 0.0:
				return t
	return -1.0


func _gravity_checks(sp: WormholeSpace, w: BallWorld) -> void:
	w.balls.clear()
	w.cubes.clear()

	# 6a: a ball of the demo's size let go right over the throat's centre, 1.5 m over the curved zone:
	# along n = +z the potential is f(l) + lift, so l'' = -g f'(l); it falls into the throat, through
	# it into universe B and up to the l it fell from, and back
	var rad: float = Toys.DROP_RADIUS
	var top := sp.point_from_chart(1.0, Vector3(0.0, 0.0, sp.lift + sp.Rout + 1.5))
	var l0: float = top[0]
	var bt := w.add(l0, top[1], Vector4.ZERO, rad, Color.WHITE)
	var t := 0.0
	var t_mid := -1.0
	var l_low := INF
	var off := 0.0
	var prev: float = bt.l
	while t < 8.0:
		w.step(BallWorld.DT, [])
		t += BallWorld.DT
		off = maxf(off, bt.n.distance_to(Vector3(0.0, 0.0, 1.0)))
		if t_mid < 0.0 and bt.l <= 0.0:
			t_mid = t - BallWorld.DT * bt.l / (bt.l - prev)     # where l crossed 0, linearly
		if t_mid > 0.0 and bt.l > prev:
			break                               # past its lowest l: on its way back
		l_low = minf(l_low, bt.l)
		prev = bt.l
	w.balls.clear()
	# the same in small RK4 steps of l'' = -g f'(l); and a uniform field over the same length, to compare
	var tm := _fall_along_axis(sp, l0)
	var tu := sqrt(2.0 * l0 / BallWorld.GRAVITY)
	U.check("let go over the throat's centre: into the throat as the field says, through it to B and up as high",
			absf(t_mid - tm) < 0.01 and absf(l_low + l0) < 1e-3 and off < 1e-9,
			"to the middle %.3f s (%.3f; uniform %.3f s), up to l %.4f in B (%.4f), n off +z by %s" % [t_mid, tm, tu, l_low, -l0, String.num_scientific(off)])

	# 6b: on the floor under the mouth: 2.5 m off the point under the throat's centre the floor pushes
	# a ball away from that point, at what the field there leaves over rolling friction; right on the
	# point it rests
	var pa := sp.point_from_chart(1.0, Vector3(2.5, 0.0, 0.25))
	var pushed := w.add(pa[0], pa[1], Vector4.ZERO, 0.25, Color.WHITE)
	var pc := sp.point_from_chart(1.0, Vector3(0.0, 0.0, 0.25))
	var middle := w.add(pc[0], pc[1], Vector4.ZERO, 0.25, Color.WHITE)
	var G := sp.potential_grad(pushed.l, pushed.n)
	var N := sp.height_grad(pushed.l, pushed.n).normalized()
	var up := G.dot(N)
	var along := (G - up * N).length()
	var a := BallWorld.GRAVITY * (along - BallWorld.ROLLING_RESISTANCE * up)
	_run(w, 0.5)
	var v_want := a / BallWorld.ROLLING_DRAG * (1.0 - exp(-BallWorld.ROLLING_DRAG * 0.5))
	var vp := WormholeSpace.vector_to_chart(1.0, pushed.n, pushed.U)
	U.check("under the mouth the floor pushes a ball away from the point under the throat's centre, as the field says",
			absf(vp.x - v_want) < 0.03 * v_want and absf(vp.y) < 1e-6 and middle.U.length() < 1e-9,
			"2.5 m off it: %.4f m/s outward after 0.5 s (%.4f: %.4f g along the floor against %.4f g of rolling friction); right on it %.6f m/s"
			% [vp.x, v_want, along, BallWorld.ROLLING_RESISTANCE * up, middle.U.length()])
	w.balls.clear()

	# 6c (with air, as in the headset): a ball set down at rest 1 m off the point under the throat's
	# centre rolls away by itself and comes to rest beyond where the push gives way to rolling
	# friction (found here on the floor along chart A's x)
	w.air = true
	var pe := sp.point_from_chart(1.0, Vector3(1.0, 0.0, 0.25))
	var away := w.add(pe[0], pe[1], Vector4.ZERO, 0.25, Color.WHITE)
	_run(w, 10.0)
	var x10 := sp.chart_position(away.l, away.n)
	_run(w, 50.0)
	var x60 := sp.chart_position(away.l, away.n)
	var holds := _held_from(sp, 0.25)
	U.check("set down 1 m off the point under the throat's centre, a ball rolls away by itself and rests where friction holds it",
			away.l > sp.L and x60.x > holds and absf(x60.y) < 1e-3 and away.U.length() < 0.02,
			"chart A x 1 -> %.2f after 10 s -> %.2f after 60 s, %.4f m/s; friction holds it beyond x %.2f" % [x10.x, x60.x, away.U.length(), holds])
	w.balls.clear()

	# 7: the scene as the headset shows it: the throw, then the drop
	main.toys.spawn()
	main.toys.launch_in = -1.0
	main.toys.drop_in = -1.0
	var resting := []
	for b in w.balls + w.cubes:
		resting.append([b, sp.embed(b.l, b.n)])
	_run(w, Toys.LAUNCH_DELAY)
	var thrown: Array[BallWorld.Body] = main.toys.throw()
	var orange := thrown[1] as BallWorld.Ball
	var orange_low := INF
	for i in roundi((Toys.DROP_DELAY - Toys.LAUNCH_DELAY) * 60.0):
		w.step(1.0 / 60.0, [])
		orange_low = minf(orange_low, orange.l)
	var dropped: BallWorld.Ball = main.toys.drop()
	var crossings := 0
	var was := signf(dropped.l)
	for i in 40 * 60:
		w.step(1.0 / 60.0, [])
		orange_low = minf(orange_low, orange.l)
		if signf(dropped.l) != was:
			crossings += 1
			was = signf(dropped.l)
	var at_rest := []
	for b in w.balls + w.cubes:
		at_rest.append(sp.embed(b.l, b.n))
	_run(w, 2.0)
	var creep := 0.0
	var speed := 0.0
	var all := w.balls + w.cubes
	for i in all.size():
		creep = maxf(creep, (sp.embed(all[i].l, all[i].n) - at_rest[i]).length())
		speed = maxf(speed, all[i].U.length())
	var moved := 0.0
	for r in resting:
		moved = maxf(moved, (sp.embed(r[0].l, r[0].n) - r[1]).length())
	var cube_at := sp.chart_position(thrown[0].l, thrown[0].n)
	var drop_at := sp.chart_position(dropped.l, dropped.n)
	U.check("the demo: the thrown ball through to universe B, at rest on its floor; the thrown cube in front of the mouth",
			orange.l < -sp.L and absf(sp.height(orange.l, orange.n) - orange.radius) < 1e-3 and thrown[0].l > sp.L and cube_at.x > 4.0,
			"the ball down to l %.2f, now at chart B %s; the cube at chart A %s" % [orange_low, sp.chart_position(orange.l, orange.n), cube_at])
	U.check("... the ball dropped into the throat's top goes through to B once and comes to rest on B's floor",
			crossings == 1 and dropped.l < -sp.L and absf(sp.height(dropped.l, dropped.n) - dropped.radius) < 1e-3,
			"%d crossings of the throat's middle, at chart %s %s" % [crossings, "B" if dropped.l < 0.0 else "A", drop_at])
	U.check("... the toys at rest stay, all at rest at the end", moved < 2e-3 and speed < 0.05 and creep < 1e-5 and all.size() == resting.size() + 3,
			"the resting ones moved %.4f m at most; all now at %.3f m/s at most, %.7f m in the last 2 s; %d toys" % [moved, speed, creep, all.size()])
	w.balls.clear()
	w.cubes.clear()


## The time a body let go at l0 > L on n = +z takes to reach the throat's middle: l'' = -g f'(l),
## RK4 in small steps.
func _fall_along_axis(sp: WormholeSpace, l0: float) -> float:
	var g := BallWorld.GRAVITY
	var l := l0
	var v := 0.0
	var h := 1e-4
	var t := 0.0
	while true:
		var a1: float = -g * sp.gravity_f(l)[1]
		var a2: float = -g * sp.gravity_f(l + 0.5 * h * v)[1]
		var a3: float = -g * sp.gravity_f(l + 0.5 * h * v + 0.25 * h * h * a1)[1]
		var a4: float = -g * sp.gravity_f(l + h * v + 0.5 * h * h * a2)[1]
		var nl := l + h * v + h * h / 6.0 * (a1 + a2 + a3)
		v += h / 6.0 * (a1 + 2.0 * a2 + 2.0 * a3 + a4)
		if nl <= 0.0:
			return t + l / (l - nl) * h
		l = nl
		t += h
	return 0.0


## How far along chart A's x from the point under the throat's centre rolling friction starts to hold
## a ball of radius rad against the floor's push (the farther of the two such places), by bisection
## of the push against its share of the weight at the ball's centre.
func _held_from(sp: WormholeSpace, rad: float) -> float:
	var lo := 3.0              # pushed here
	var hi := 30.0             # held here
	for _it in 40:
		var x := 0.5 * (lo + hi)
		var p := sp.point_from_chart(1.0, Vector3(x, 0.0, rad))
		var G := sp.potential_grad(p[0], p[1])
		var N := sp.height_grad(p[0], p[1]).normalized()
		var up := G.dot(N)
		if (G - up * N).length() > BallWorld.ROLLING_RESISTANCE * up:
			lo = x
		else:
			hi = x
	return hi
