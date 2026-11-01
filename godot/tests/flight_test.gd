extends SceneTree
## Flight (viewer.gd) through the desktop keys (the code paths the sticks drive), run with
## --fixed-fps 60; exit status 1 on any failure:
##   godot --path . --fixed-fps 60 -s res://tests/flight_test.gd
## 1. Space for a second flies 1.5 m straight up from the start; let go, with gravity the body falls
##    from the 1.5 m/s up it had and lands when and where an independent integration of
##    docs/gravity.md's field in chart A says (to a frame and a millimetre), standing upright
## 2. the menu's flight row turns gravity off; then let go in the air, the body hovers
## 3. W with the head looking 30 degrees up flies along the look, up too; C comes down and lands
## 4. in the middle of the throat, up from the floor goes round the throat (l stays 0, n along the
##    great circle, up along it); over the top, on with Shift, it comes down head first on the far
##    side: it lands on its feet below, rolled over (up along the floor's normal, the line of sight
##    kept)
## 5. there 2 m up and let go with gravity, it falls in the time docs/gravity.md gives (1.64 s from
##    exactly 2 m; here from where it got to, by the same equation as ref/test_gravity.py), along
##    the great circle (l stays 0)
## 6. off the floor at the start and on (W, Shift) for 24 m through the throat into universe B:
##    the feet and the room's axes where an independent RK4 of the geodesic equations
##    (docs/geometry.md, «Движение») puts them, up turned against the floor of B; and it prints how
##    much a path at several heights turns up (viewer.gd's top)

const U := preload("res://tests/util.gd")

var main: Main
var frames := 0
var phase := 0
var t0 := 0                     # the frame something started at
var landed_at := -1             # the first frame the body was seen standing again
var want := []                  # what a check expects
var saved: Array = []


func _initialize() -> void:
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "none"
	root.add_child(main)


func _feet() -> Vector3:
	return main.space.chart_position(main.viewer.l, main.viewer.n)


## The room's axis k at the feet in the chart of their side.
func _axis(k: int) -> Vector3:
	return WormholeSpace.vector_to_chart(signf(main.viewer.l), main.viewer.n, main.viewer.frame[k])


func _process(_delta: float) -> bool:
	frames += 1
	var v: Viewer = main.viewer
	if not v.standing:
		landed_at = -1
	elif landed_at < 0:
		landed_at = frames
	if frames > 461 and frames < 700 and v.standing and Input.is_key_pressed(KEY_SPACE):
		# landed over the top: let go before main's frame now, or it takes off again
		U.key(KEY_SPACE, false, true)
		U.key(KEY_SHIFT, false, true)
	match frames:
		3:
			_print_turns()
			U.check("it starts standing, falling with gravity", v.standing and v.gravity)
			U.key(KEY_SPACE, true)
		63:
			U.key(KEY_SPACE, false)
		64:
			var p := _feet()
			U.check("Space for a second flies 1.5 m straight up", not v.standing and p.distance_to(Vector3(10.0, 0.0, 1.5)) < 1e-3,
					"feet at %s" % p)
			want = _fall_in_chart(p, Vector3(0.0, 0.0, Main.WALK_SPEED))
			t0 = frames
			landed_at = -1
		120:
			var k := landed_at - t0
			var p := _feet()
			U.check("let go, it falls from 1.5 m/s up and lands when the field says", absf(k - want[0] * 60.0) <= 1.0,
					"after %d frames, expected %.2f" % [k, want[0] * 60.0])
			U.check("... where it says", p.distance_to(want[1]) < 1e-3, "feet at %s, expected %s" % [p, want[1]])
			U.check("... standing upright", v.standing and _axis(1).distance_to(Vector3(0.0, 0.0, 1.0)) < 1e-6, "up %s" % _axis(1))
			saved = [p]
			main.menu.set_open(true)
			main.menu.select("fly")
			main.menu.change(1)
			main.menu.press()
			U.check("the menu's flight row: without gravity", not v.gravity and main.menu.picked() == "fly")
			main.menu.set_open(false)
			U.key(KEY_SPACE, true)
		180:
			U.key(KEY_SPACE, false)
		240:
			var p := _feet()
			U.check("without gravity, let go in the air it hovers", not v.standing and absf(p.z - 1.5) < 1e-3
					and absf(p.x - saved[0].x) < 1e-6, "feet at %s" % p)
			saved = [p]
			main.camera.basis = Basis(Vector3.RIGHT, deg_to_rad(30.0))     # the head 30 degrees up
			U.key(KEY_W, true)
		300:
			U.key(KEY_W, false)
		301:
			var p := _feet()
			var w: Vector3 = saved[0] + Main.WALK_SPEED * Vector3(-cos(deg_to_rad(30.0)), 0.0, sin(deg_to_rad(30.0)))
			U.check("W flies along the look, 30 degrees up", p.distance_to(w) < 1e-3, "feet at %s, expected %s" % [p, w])
			main.camera.basis = Basis.IDENTITY
			U.key(KEY_C, true)
		400:
			U.key(KEY_C, false)
			U.check("C comes down and lands", v.standing and absf(_feet().z) < 1e-9, "standing %s, feet %s" % [v.standing, _feet()])
			# 4. the middle of the throat, facing across the throat (its right along it)
			main.place_on_axis(0.0, 90.0)
			saved = [main.viewer.frame.duplicate()]
			U.key(KEY_SPACE, true)
		461:
			# a second from the floor at l 0: 1.5 m round the circle of radius rho0
			var a := Main.WALK_SPEED / main.space.rho0
			var up: Vector4 = v.frame[1]
			U.check("up from the middle of the throat goes round it", absf(v.l) < 1e-6
					and v.n.distance_to(Vector3(cos(a), 0.0, sin(a))) < 1e-5 and up.distance_to(Vector4(0.0, -sin(a), 0.0, cos(a))) < 1e-5,
					"l %.9f, n %s, up %s" % [v.l, v.n, up])
			U.key(KEY_SHIFT, true)
			landed_at = -1
		700:
			var f: Array = saved[0]
			U.check("over the top it comes down head first and lands on the far side, on its feet",
					v.standing and absf(v.l) < 1e-6 and v.n.distance_to(Vector3(-1.0, 0.0, 0.0)) < 1e-6, "l %.9f, n %s" % [v.l, v.n])
			U.check("... rolled over: up along the floor's normal, the line of sight kept",
					(v.frame[1] as Vector4).distance_to(Vector4(0.0, 0.0, 0.0, 1.0)) < 1e-6
					and (v.frame[2] as Vector4).distance_to(f[2]) < 1e-6 and (v.frame[0] as Vector4).distance_to(-f[0]) < 1e-6,
					"frame %s, before the flight %s" % [v.frame, f])
			# 5. the middle of the throat again: 2.25 m round, hovering
			main.place_on_axis(0.0, 0.0)
			U.key(KEY_SPACE, true)
		790:
			U.key(KEY_SPACE, false)
		792:
			var s0 := main.space.rho0 * atan2(v.n.z, v.n.x)
			U.check("90 frames up: 2.25 m round the throat", absf(s0 - 2.25) < 1e-4 and absf(v.l) < 1e-9, "%.5f m, l %.9f" % [s0, v.l])
			want = [_fall_on_circle(s0)]
			main.set_fall(true)
			t0 = frames
			landed_at = -1
		900:
			var k := landed_at - t0
			U.check("let go 2 m up in the middle of the throat, it falls slowly, as the field says", absf(k - want[0] * 60.0) <= 1.0,
					"after %d frames, expected %.2f (from %.3f m)" % [k, want[0] * 60.0, main.space.rho0 * sin(2.25 / main.space.rho0)])
			U.check("... round the throat (l stays 0)", v.standing and absf(v.l) < 1e-6, "l %.9f" % v.l)
			# 6. the start, 0.5 m up, then through the throat
			main.place(main.START_POS, main.START_FORWARD)
			main.set_fall(false)
			U.key(KEY_SPACE, true)
		920:
			U.key(KEY_SPACE, false)
		921:
			saved = [v.l, v.n, v.frame.duplicate()]
			U.check("20 frames up: 0.5 m", absf(v.height() - 0.5) < 1e-6, "%.6f" % v.height())
			U.key(KEY_SHIFT, true)
			U.key(KEY_W, true)
		1281:
			U.key(KEY_W, false)
			U.key(KEY_SHIFT, false)
		1282:
			# 360 frames at 4 m/s: 24 m
			var ref := _rk4_geodesic(saved[0], saved[1], -(saved[2][2] as Vector4), 24.0, saved[2])
			var f: Array = ref[2]
			var worst := 0.0
			for k in 3:
				worst = maxf(worst, (v.frame[k] as Vector4).distance_to(f[k]))
			U.check("24 m through the throat: the feet where the geodesic goes", v.l < -main.space.L
					and absf(v.l - ref[0]) < 1e-3 and v.n.distance_to(ref[1]) < 1e-3, "l %.4f n %s, expected %.4f %s" % [v.l, v.n, ref[0], ref[1]])
			U.check("... the room's axes carried along it", worst < 1e-3, "off by %.9f" % worst)
			var tilt := rad_to_deg(acos(clampf(_axis(1).z, -1.0, 1.0)))
			U.check("... flying still, up turned against universe B's floor", not v.standing and tilt > 10.0, "%.1f degrees" % tilt)
			U.finish(self)
	return false


## A body let go at chart A position x with velocity u under docs/gravity.md's field there (phi =
## z + beta z / r^3, as ref/test_gravity.py's flat), RK4 in small steps: [the time it reaches z = 0,
## where].
func _fall_in_chart(x: Vector3, u: Vector3) -> Array:
	var beta := main.space.grav_beta
	var g := BallWorld.GRAVITY
	var acc := func(p: Vector3) -> Vector3:
		var r := p.length()
		return -g * (Vector3(0.0, 0.0, 1.0) * (1.0 + beta / (r * r * r)) - 3.0 * beta * p.z / pow(r, 5.0) * p)
	var h := 1e-4
	var t := 0.0
	while true:
		var a1: Vector3 = acc.call(x)
		var a2: Vector3 = acc.call(x + 0.5 * h * u)
		var a3: Vector3 = acc.call(x + 0.5 * h * u + 0.25 * h * h * a1)
		var a4: Vector3 = acc.call(x + h * u + 0.5 * h * h * a2)
		var nx := x + h * u + h * h / 6.0 * (a1 + a2 + a3)
		var nu := u + h / 6.0 * (a1 + 2.0 * a2 + 2.0 * a3 + a4)
		if nx.z <= 0.0:
			var f := x.z / (x.z - nx.z)
			return [t + f * h, x.lerp(nx, f)]
		x = nx
		u = nu
		t += h
	return []


## The time a point let go at arc s0 up the circle l = 0 takes to the floor: s'' = -g f(0) / rho0
## cos(s / rho0) (ref/test_gravity.py's), RK4 in small steps.
func _fall_on_circle(s0: float) -> float:
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
		if ns <= 0.0:
			return t + s / (s - ns) * h
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
