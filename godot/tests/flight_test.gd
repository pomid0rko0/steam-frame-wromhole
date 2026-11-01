extends SceneTree
## Flight (viewer.gd) through the desktop keys (the code paths the sticks, triggers and bumpers
## drive), run with --fixed-fps 60; exit status 1 on any failure:
##   godot --path . --fixed-fps 60 -s res://tests/flight_test.gd
## 1. Space for half a second flies 2 m straight up from the start; let go, with gravity the head
##    falls from the 4 m/s up it had and the feet land when and where an independent integration of
##    docs/gravity.md's field in chart A says, the room turning upright as viewer.gd's top says (to
##    a frame and a millimetre), standing upright
## 2. the menu's flight row turns gravity off; then let go in the air, the body hovers
## 3. I (pitch up) for half a second turns the room 30 degrees about the head, which stays put; W
##    then flies along the room's floor, 30 degrees up; L (roll right) turns it 30 degrees more
##    about the head; in snaps (Tab), K pitches 30 degrees at once
## 4. F: gravity on (the line below says so): let go, the room turns upright as it falls (faster
##    than exp(-t / RIGHT_TIME) would leave it), nearly upright at the floor, and lands upright
## 5. in the middle of the throat, up from the floor goes round the throat (l stays 0, n along the
##    great circle, up along it); over the top the head comes down to the far side's floor and
##    stays out of it (HEAD_CLEAR); gravity on there turns it over, and it lands on its feet
## 6. there with the head 2 m up and let go with gravity, the head falls round the great circle
##    (l stays 0) by the equation ref/test_gravity.py gives docs/gravity.md's falls with, and the
##    feet reach the floor when it says
## 7. crouching, off the floor at the start and on (W) for 24 m through the throat into universe
##    B: the head and the room's axes where an independent RK4 of the geodesic equations
##    (docs/geometry.md, «Движение») puts them, up turned against the floor of B; and it prints how
##    much a path at several heights turns up (viewer.gd's top)

const U := preload("res://tests/util.gd")
const SPEED := Main.FLY_SPEED

var main: Main
var frames := 0
var steps: Array = []           # [frames after the step before, Callable]
var k := 0
var next_at := 3
var t0 := 0                     # the frame a fall started
var landed_at := -1             # the first frame the body was seen standing again
var tilt_last := 0.0            # degrees: up against chart A's, the last frame it was seen flying
var want := []                  # what a check expects
var saved: Array = []


func _initialize() -> void:
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "none"
	root.add_child(main)
	steps = [
		[0, func() -> void:
			_print_turns()
			U.check("it starts standing, falling with gravity", _v().standing and _v().gravity)
			U.key(KEY_SPACE, true)],
		[30, func() -> void: U.key(KEY_SPACE, false)],
		[1, func() -> void:
			var p := _feet()
			U.check("Space for half a second flies 2 m straight up", not _v().standing and p.distance_to(Vector3(10.0, 0.0, 2.0)) < 1e-3,
					"feet at %s" % p)
			var up := _axis(1)
			want = _fall_in_chart(_head(), up, SPEED * up, main.camera.transform.origin.y)
			_fall_starts()],
		[90, func() -> void:
			var n := landed_at - t0
			var p := _feet()
			U.check("let go, it falls from 4 m/s up and lands when the field says", absf(n - want[0] * 60.0) <= 1.0,
					"after %d frames, expected %.2f" % [n, want[0] * 60.0])
			U.check("... where it says", p.distance_to(want[1]) < 1e-3, "feet at %s, expected %s" % [p, want[1]])
			U.check("... standing upright", _v().standing and _axis(1).distance_to(Vector3(0.0, 0.0, 1.0)) < 1e-6, "up %s" % _axis(1))
			saved = [p]
			main.menu.set_open(true)
			main.menu.select("fly")
			main.menu.change(1)
			main.menu.press()
			U.check("the menu's flight row: without gravity", not _v().gravity and main.menu.picked() == "fly")
			main.menu.set_open(false)
			U.key(KEY_SPACE, true)],
		[30, func() -> void: U.key(KEY_SPACE, false)],
		[60, func() -> void:
			var p := _feet()
			U.check("without gravity, let go in the air it hovers", not _v().standing and absf(p.z - 2.0) < 1e-3
					and absf(p.x - saved[0].x) < 1e-6, "feet at %s" % p)
			saved = [_head()]
			U.key(KEY_I, true)],
		[30, func() -> void: U.key(KEY_I, false)],
		[1, func() -> void:
			var f := -_axis(2)
			U.check("I for half a second pitches 30 degrees up about the head", _head().distance_to(saved[0]) < 1e-4
					and absf(rad_to_deg(asin(f.z)) - 30.0) < 0.01 and absf(rad_to_deg(acos(_axis(1).z)) - 30.0) < 0.01,
					"the head moved %.6f m, forward %.3f deg up" % [_head().distance_to(saved[0]), rad_to_deg(asin(f.z))])
			saved = [_feet(), f]
			U.key(KEY_W, true)],
		[30, func() -> void: U.key(KEY_W, false)],
		[1, func() -> void:
			var w: Vector3 = saved[0] + 2.0 * saved[1]
			U.check("W flies along the room's floor, 30 degrees up now", _feet().distance_to(w) < 1e-3, "feet at %s, expected %s" % [_feet(), w])
			saved = [_head(), _axis(1), -_axis(2)]
			U.key(KEY_L, true)],
		[30, func() -> void: U.key(KEY_L, false)],
		[1, func() -> void:
			U.check("L for half a second rolls 30 degrees about the head and the line of sight", _head().distance_to(saved[0]) < 1e-4
					and absf(_deg(_axis(1), saved[1]) - 30.0) < 0.01 and _deg(-_axis(2), saved[2]) < 0.01 and _axis(0).z < 0.0,
					"the head moved %.6f m, up turned %.3f deg, the line of sight %.3f deg, right z %.3f" % [_head().distance_to(saved[0]),
					_deg(_axis(1), saved[1]), _deg(-_axis(2), saved[2]), _axis(0).z])
			saved = [_head(), _axis(1)]
			U.key(KEY_TAB, true)],
		[2, func() -> void:
			U.key(KEY_TAB, false)
			U.key(KEY_K, true)],
		[20, func() -> void: U.key(KEY_K, false)],
		[2, func() -> void:
			U.check("in snaps, K held pitches 30 degrees down at once, once", not main.smooth_turn and _head().distance_to(saved[0]) < 1e-4
					and absf(_deg(_axis(1), saved[1]) - 30.0) < 0.01, "the head moved %.6f m, up turned %.3f deg"
					% [_head().distance_to(saved[0]), _deg(_axis(1), saved[1])])
			U.key(KEY_TAB, true)],
		[2, func() -> void:
			U.key(KEY_TAB, false)
			saved = [rad_to_deg(acos(_axis(1).z))]
			U.key(KEY_F, true)],
		[2, func() -> void:
			U.key(KEY_F, false)
			U.check("F: gravity on, the line below says so", _v().gravity and main.menu.strip_label.text.begins_with("полёт: с гравитацией"),
					main.menu.strip_label.text)],
		[18, func() -> void:
			var tilt := rad_to_deg(acos(_axis(1).z))
			# 19 frames (F is seen from the frame after its press) of exp(-t / RIGHT_TIME) leave 40 %
			U.check("let go with gravity, the room turns upright", not _v().standing and tilt < 0.42 * saved[0] and saved[0] > 20.0,
					"%.1f deg from %.1f" % [tilt, saved[0]])
			landed_at = -1],
		[120, func() -> void:
			U.check("... lands nearly upright, and stands upright", _v().standing and tilt_last < 5.0
					and _axis(1).distance_to(Vector3(0.0, 0.0, 1.0)) < 1e-6, "%.2f deg off just before" % tilt_last)
			# 5. the middle of the throat, facing across the throat (its right along it)
			main.place_on_axis(0.0, 90.0)
			main.set_fall(false)
			saved = [_v().frame.duplicate()]
			U.key(KEY_SPACE, true)],
		[16, func() -> void:
			# 15 frames from the floor at l 0: 1 m round the circle of radius rho0
			var a := SPEED * 0.25 / main.space.rho0
			var up: Vector4 = _v().frame[1]
			U.check("up from the middle of the throat goes round it", absf(_v().l) < 1e-6
					and _v().n.distance_to(Vector3(cos(a), 0.0, sin(a))) < 1e-5 and up.distance_to(Vector4(0.0, -sin(a), 0.0, cos(a))) < 1e-5,
					"l %.9f, n %s, up %s" % [_v().l, _v().n, up])],
		[134, func() -> void:
			U.key(KEY_SPACE, false)
			var hp := _v().head(main.camera.transform.origin.y)
			var H := main.space.height(hp[0], hp[1])
			U.check("over the top the head comes down to the far side's floor and stays out of it", not _v().standing
					and absf(H - Viewer.HEAD_CLEAR) < 2e-3 and absf(_v().l) < 1e-6 and absf(_v().n.y) < 1e-6 and _v().n.x < 0.0,
					"head %.4f m over the floor, feet l %.9f n %s" % [H, _v().l, _v().n])
			landed_at = -1
			main.set_fall(true)],
		[120, func() -> void:
			# exactly upside down there: rolled about the line of sight (across the throat), the feet
			# swing along the throat
			U.check("gravity on there turns it over, and it lands on its feet on the far side", _v().standing
					and _v().n.distance_to(Vector3(-1.0, 0.0, 0.0)) < 1e-3 and (_v().frame[1] as Vector4).distance_to(Vector4(0.0, 0.0, 0.0, 1.0)) < 1e-6,
					"standing %s, l %.9f, n %s" % [_v().standing, _v().l, _v().n])
			# 6. the middle of the throat again: 0.53 m round, hovering, the head 2 m over the floor
			main.place_on_axis(0.0, 0.0)
			main.set_fall(false)
			U.key(KEY_SPACE, true)],
		[8, func() -> void: U.key(KEY_SPACE, false)],
		[2, func() -> void:
			var s0 := main.space.rho0 * atan2(_v().n.z, _v().n.x)
			var want_s := SPEED * 8.0 / 60.0
			U.check("8 frames up: %.3f m round the throat" % want_s, absf(s0 - want_s) < 1e-4 and absf(_v().l) < 1e-9, "%.5f m, l %.9f" % [s0, _v().l])
			var h := main.camera.transform.origin.y
			want = [_fall_on_circle(s0 + h, h), main.space.rho0 * sin((s0 + h) / main.space.rho0)]
			main.set_fall(true)
			_fall_starts()],
		[150, func() -> void:
			var n := landed_at - t0
			U.check("let go in the middle of the throat, it falls slowly, as the field says", absf(n - want[0] * 60.0) <= 1.0,
					"after %d frames, expected %.2f (the head from %.3f m)" % [n, want[0] * 60.0, want[1]])
			U.check("... round the throat (l stays 0)", _v().standing and absf(_v().l) < 1e-6, "l %.9f" % _v().l)
			# 7. the start, crouching (the head 0.5 m over the feet: at 2 m over the floor the head's
			# geodesic would come down onto B's floor), 0.53 m up, then through the throat
			main.camera.position.y = 0.5
			main.place(main.START_POS, main.START_FORWARD)
			main.set_fall(false)
			U.key(KEY_SPACE, true)],
		[8, func() -> void: U.key(KEY_SPACE, false)],
		[1, func() -> void:
			var hp := _v().head(main.camera.transform.origin.y)
			saved = [hp[0], hp[1], hp[2].duplicate()]
			U.check("8 frames up: 0.53 m", absf(_v().height() - SPEED * 8.0 / 60.0) < 1e-6, "%.6f" % _v().height())
			U.key(KEY_W, true)],
		[360, func() -> void: U.key(KEY_W, false)],
		[1, func() -> void:
			# 360 frames at 4 m/s: 24 m
			var ref := _rk4_geodesic(saved[0], saved[1], -(saved[2][2] as Vector4), 24.0, saved[2])
			var f: Array = ref[2]
			var hp := _v().head(main.camera.transform.origin.y)
			var worst := 0.0
			for i in 3:
				worst = maxf(worst, (hp[2][i] as Vector4).distance_to(f[i]))
			U.check("24 m through the throat: the head where the geodesic goes", hp[0] < -main.space.L
					and absf(hp[0] - ref[0]) < 1e-3 and (hp[1] as Vector3).distance_to(ref[1]) < 1e-3,
					"l %.4f n %s, expected %.4f %s" % [hp[0], hp[1], ref[0], ref[1]])
			U.check("... the room's axes carried along it", worst < 1e-3, "off by %.6f" % worst)
			var tilt := rad_to_deg(acos(clampf(_axis(1).z, -1.0, 1.0)))
			U.check("... flying still, up turned against universe B's floor", not _v().standing and tilt > 10.0, "%.1f degrees" % tilt)
			U.finish(self)],
	]


func _process(_delta: float) -> bool:
	frames += 1
	if not _v().standing:
		landed_at = -1
		tilt_last = rad_to_deg(acos(clampf(_axis(1).z, -1.0, 1.0))) if absf(_v().l) > main.space.L else tilt_last
	elif landed_at < 0:
		landed_at = frames
	if k < steps.size() and frames == next_at:
		steps[k][1].call()
		k += 1
		if k < steps.size():
			next_at = frames + steps[k][0]
	return false


func _v() -> Viewer:
	return main.viewer


func _fall_starts() -> void:
	t0 = frames
	landed_at = -1


func _feet() -> Vector3:
	return main.space.chart_position(main.viewer.l, main.viewer.n)


func _head() -> Vector3:
	var hp: Array = main.viewer.head(main.camera.transform.origin.y)
	return main.space.chart_position(hp[0], hp[1])


## The room's axis k at the feet in the chart of their side.
func _axis(i: int) -> Vector3:
	return WormholeSpace.vector_to_chart(signf(main.viewer.l), main.viewer.n, main.viewer.frame[i])


## Degrees between two chart directions.
static func _deg(a: Vector3, b: Vector3) -> float:
	return rad_to_deg(acos(clampf(a.normalized().dot(b.normalized()), -1.0, 1.0)))


## The head let go at chart A position x with velocity u under docs/gravity.md's field there (phi
## = z + beta z / r^3, as ref/test_gravity.py's flat), the room's up from up turning toward the
## field's (the least way, exp(-t / Viewer.RIGHT_TIME), at most Viewer.RIGHT_MAX a second), RK4 and
## Euler in small steps: [the time the feet, h below the head along up, reach z = 0, where].
func _fall_in_chart(x: Vector3, up: Vector3, u: Vector3, h: float) -> Array:
	var beta := main.space.grav_beta
	var g := BallWorld.GRAVITY
	var grad := func(p: Vector3) -> Vector3:
		var r := p.length()
		return Vector3(0.0, 0.0, 1.0) * (1.0 + beta / (r * r * r)) - 3.0 * beta * p.z / pow(r, 5.0) * p
	var dt := 1e-4
	var t := 0.0
	var feet := x - h * up
	while true:
		var a1: Vector3 = -g * grad.call(x)
		var a2: Vector3 = -g * grad.call(x + 0.5 * dt * u)
		var a3: Vector3 = -g * grad.call(x + 0.5 * dt * u + 0.25 * dt * dt * a1)
		var a4: Vector3 = -g * grad.call(x + dt * u + 0.5 * dt * dt * a2)
		x += dt * u + dt * dt / 6.0 * (a1 + a2 + a3)
		u += dt / 6.0 * (a1 + 2.0 * a2 + 2.0 * a3 + a4)
		var G: Vector3 = grad.call(x)
		var w := minf(G.length() / Viewer.RIGHT_G, 1.0)
		var T := G.normalized()
		var a := acos(clampf(up.dot(T), -1.0, 1.0))
		if a > 1e-9:
			var b := minf(a * (1.0 - exp(-dt * w / Viewer.RIGHT_TIME)), Viewer.RIGHT_MAX * w * dt)
			var p := (T - up.dot(T) * up).normalized()
			up = cos(b) * up + sin(b) * p
		var nf := x - h * up
		if nf.z <= 0.0:
			var f := feet.z / (feet.z - nf.z)
			return [t + f * dt, feet.lerp(nf, f)]
		feet = nf
		t += dt
	return []


## The time a point let go at arc s0 up the circle l = 0 takes to arc s1: s'' = -g f(0) / rho0
## cos(s / rho0) (ref/test_gravity.py's), RK4 in small steps.
func _fall_on_circle(s0: float, s1: float) -> float:
	var rho := main.space.rho0
	var k := BallWorld.GRAVITY * main.space.gravity_f(0.0)[0] / rho
	var s := s0
	var u := 0.0
	var h := 1e-4
	var t := 0.0
	while true:
		var a1 := -k * cos(s / rho)
		var a2 := -k * cos((s + 0.5 * h * u) / rho)
		var a3 := -k * cos((s + 0.5 * h * u + 0.25 * h * h * a1) / rho)
		var a4 := -k * cos((s + h * u + 0.5 * h * h * a2) / rho)
		var ns := s + h * u + h * h / 6.0 * (a1 + a2 + a3)
		u += h / 6.0 * (a1 + 2.0 * a2 + 2.0 * a3 + a4)
		if ns <= s1:
			return t + (s - s1) / (s - ns) * h
		s = ns
		t += h
	return 0.0


## The geodesic from (l, n) along the unit tangent vector D for length dist, the vectors of vecs
## carried along: RK4 of docs/geometry.md's equations in steps of 5 mm, not WormholeSpace.geodesic's
## method. [l, n, vecs].
func _rk4_geodesic(l: float, n: Vector3, D: Vector4, dist: float, vecs: Array) -> Array:
	var sp: WormholeSpace = main.space
	var st := [l, n, D] + vecs
	var steps := ceili(dist / 0.005)
	var h := dist / steps
	for _i in steps:
		var k1 := _rate(sp, st)
		var k2 := _rate(sp, _plus(st, k1, 0.5 * h))
		var k3 := _rate(sp, _plus(st, k2, 0.5 * h))
		var k4 := _rate(sp, _plus(st, k3, h))
		var out := []
		for i in st.size():
			out.append(st[i] + h / 6.0 * (k1[i] + 2.0 * k2[i] + 2.0 * k3[i] + k4[i]))
		out[1] = (out[1] as Vector3).normalized()
		for i in range(2, out.size()):
			out[i] = WormholeSpace.tangent(out[1], out[i])
		st = out
	return [st[0], st[1], st.slice(3)]


static func _plus(st: Array, d: Array, c: float) -> Array:
	var out := []
	for i in st.size():
		out.append(st[i] + c * d[i])
	return out


## The rates of [l, n, V, vecs...]: dl = V_l, dn = v / r, and for V and each carried U:
## dU_l = (r'/r) v.u, du = -(r'/r) U_l v - (u.v / r) n.
static func _rate(sp: WormholeSpace, st: Array) -> Array:
	var l: float = st[0]
	var n: Vector3 = st[1]
	var V: Vector4 = st[2]
	var r := sp.r(l)
	var k := sp.dr(l) / r
	var v := Vector3(V.y, V.z, V.w)
	var out := [V.x, v / r]
	for i in range(2, st.size()):
		var A: Vector4 = st[i]
		var u := Vector3(A.y, A.z, A.w)
		var du := -k * A.x * v - (u.dot(v) / r) * n
		out.append(Vector4(k * v.dot(u), du.x, du.y, du.z))
	return out


## How much a straight flight from the start toward the throat turns up, for viewer.gd's top: from
## chart A (10, 0, z) along -x, the room's up carried along (WormholeSpace.geodesic), until it meets
## the floor or is 40 m on.
func _print_turns() -> void:
	var sp: WormholeSpace = main.space
	for z in [0.25, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0]:
		var p := sp.point_from_chart(1.0, Vector3(10.0, 0.0, z))
		var l: float = p[0]
		var n: Vector3 = p[1]
		var f := [WormholeSpace.vector_from_chart(1.0, n, Vector3(-1.0, 0.0, 0.0)),
				WormholeSpace.vector_from_chart(1.0, n, Vector3(0.0, 0.0, 1.0))]
		var s := 0.0
		var hit := false
		while s < 40.0:
			var g := sp.geodesic(l, n, f[0], 0.05, f)
			if sp.height(g[0], g[1]) <= 0.0:
				hit = true
				break
			l = g[0]
			n = g[1]
			f = g[2]
			s += 0.05
		var c := WormholeSpace.vector_to_chart(signf(l), n, f[1])
		var d := WormholeSpace.vector_to_chart(signf(l), n, f[0])
		print("flight from 10 m out at %.2f m along -x: %s %.1f m on, in %s, %.0f deg on, up turned %.0f deg from the chart's"
				% [z, "meets the floor" if hit else "flies on", s, "A" if l > 0.0 else "B", rad_to_deg(acos(clampf(d.dot(Vector3(-1.0, 0.0, 0.0)), -1.0, 1.0))),
				rad_to_deg(acos(clampf(c.z, -1.0, 1.0)))])
