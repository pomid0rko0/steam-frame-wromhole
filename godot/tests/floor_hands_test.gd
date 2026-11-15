extends SceneTree
## The hands with the floor running through the throat (space.lift = 0, set before main._ready:
## WormholeSpace's top), through the code path the headset uses: the simulated headset
## (tests/fake_hmd.gd) and two controller trackers, as tests/pull_test.gd, which has the rest of the
## hands at the throat's usual height. Run with --fixed-fps 60 under a display; exit status 1 on any
## failure:
##   godot --path . --fixed-fps 60 -s res://tests/floor_hands_test.gd
## 1. the beam from the start, pointed at the floor where it bends (3.1 m from the axis, in the
##    curved zone): it ends on the floor there, pale
## 2. a ball lying on the bent floor there is aimed at (the beam orange, up to it), pulled by a
##    flick of the wrist and caught
## 3. a ball on universe B's floor, seen through the throat along the floor, 32 degrees off the
##    line through the throat's centre: aimed at, the beam through the throat to it; pulled through
##    the throat and caught, its throw missing the hand by less than 10 cm. (Nearer that line, and
##    past the throat's rim, the hands find no steady throw: hands.gd's top; with the floor through
##    the throat that is most of B's floor as seen from A's.)
## 4. standing in the throat's middle (walked there), a ball set down beside the feet rests on the
##    floor, and the hand takes it

const U := preload("res://tests/util.gd")
const SIZE := 96
const AIM := Hands.AIM_EVERY + 1     # frames after pointing: each hand has aimed
var main: Main
var hmd
var left: XRControllerTracker
var right: XRControllerTracker


func _initialize() -> void:
	hmd = U.headset(0, 0.0, Vector2i(SIZE, SIZE))
	left = U.controller(&"left_hand")
	right = U.controller(&"right_hand")
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "FakeHMD"
	main.toys.demo = false
	main.space.lift = 0.0
	root.add_child(main)
	_run()


func _step(n := 1) -> void:
	for _k in n:
		await process_frame


## The hand's grip and aim poses in the room, the same.
func _pose(t: XRControllerTracker, p: Vector3, b := Basis.IDENTITY) -> void:
	for pose in [&"grip", &"aim"]:
		t.set_pose(pose, Transform3D(b, p), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


## Pointing along dir in the room.
static func _toward(dir: Vector3) -> Basis:
	return Basis.looking_at(dir.normalized(), Vector3.UP if absf(dir.normalized().y) < 0.99 else Vector3.BACK)


func _clear() -> void:
	main.toys.world.balls.clear()
	main.toys.world.cubes.clear()
	main.hands.empty()


## Hand 1's beam as the renderer has it: [drawn, its points, colour].
func _drawn_beam() -> Array:
	var m: ShaderMaterial = main.renderer.beam_mats[1]
	var n: int = m.get_shader_parameter("beam_n")
	var pts: PackedVector4Array = m.get_shader_parameter("beam_p")
	return [main.renderer.beams[1].visible, pts.slice(0, n), m.get_shader_parameter("beam_col")]


## The pointing direction from hand h (room) whose geodesic passes nearest C (R^4): on a grid of
## 2 degrees, then of 0.1 degrees round the best: [direction, how near] (tests/pull_test.gd's).
func _toward_geodesic(h: Hands.Hand, C: Vector4, pitches := Vector2(-40, 30)) -> Array:
	var coarse := _grid(h, C, Vector2(-60, 60), pitches, 2.0)
	return _grid(h, C, Vector2(coarse[2].x - 2.0, coarse[2].x + 2.0), Vector2(coarse[2].y - 2.0, coarse[2].y + 2.0), 0.1)


func _grid(h: Hands.Hand, C: Vector4, yaws: Vector2, pitches: Vector2, step: float) -> Array:
	var sp: WormholeSpace = main.space
	var best := Vector3.ZERO
	var best_at := Vector2.ZERO
	var nearest := INF
	for iy in roundi((yaws.y - yaws.x) / step) + 1:
		var yaw := yaws.x + iy * step
		for ip in roundi((pitches.y - pitches.x) / step) + 1:
			var pitch := pitches.x + ip * step
			var d := Vector3(-sin(deg_to_rad(yaw)), sin(deg_to_rad(pitch)), -cos(deg_to_rad(yaw))).normalized()
			var r := sp.ray(h.ball.l, h.ball.n, WormholeSpace.combine(h.room, d), Hands.PULL_RANGE)
			var pts: Array = r[0]
			for j in pts.size() - 1:
				var A: Vector4 = pts[j]
				var AB: Vector4 = pts[j + 1] - A
				var t := clampf((C - A).dot(AB) / maxf(AB.length_squared(), 1e-12), 0.0, 1.0)
				var dist := (C - A - t * AB).length()
				if dist < nearest:
					nearest = dist
					best = d
					best_at = Vector2(yaw, pitch)
	return [best, nearest, best_at]


## Hand 1 at p pointing along b0 at ball, locked on it: the flick of the wrist, then held still.
## [the pull, frames until it flew, frames until it was caught (-1: not), the ball's lowest and
## highest l on the way].
func _pull(p: Vector3, b0: Basis, ball: BallWorld.Ball) -> Array:
	var h: Hands.Hand = main.hands.list[1]
	right.set_input(&"grip", 1.0)
	await _step(1)
	var flew := -1
	var caught := -1
	var pull: Hands.Pull = null
	var th := 0.0
	var lo := ball.l
	var hi := ball.l
	for k in 150:
		if k < 8:
			th += 10.0 / 60.0
		_pose(right, p, b0 * Basis(Vector3.RIGHT, th))
		await _step(1)
		if h.pull:
			pull = h.pull
		if flew < 0 and pull and pull.flying:
			flew = k
		lo = minf(lo, ball.l)
		hi = maxf(hi, ball.l)
		if h.held == ball:
			caught = k
			break
	return [pull, flew, caught, lo, hi]


func _run() -> void:
	await _step(AIM)
	var sp: WormholeSpace = main.space
	U.check("main runs in XR with the floor through the throat", main.in_xr and sp.lift == 0.0 and sp.floor_through(),
			"in_xr %s, lift %s" % [main.in_xr, sp.lift])
	main.menu.visible = false
	_clear()
	_pose(left, Vector3(-2.0, 1.0, 0.8))
	var p := Vector3(0.2, 1.3, -0.3)
	_pose(right, p, Basis.IDENTITY)
	await _step(2)
	var h: Hands.Hand = main.hands.list[1]
	main.menu.show_beam(true)

	# 1: the bent floor 3.1 m from the axis
	var f := sp.floor_point(1.0, Vector2(3.0, 0.8))
	var F := sp.embed(f[0], f[1])
	var way := _toward_geodesic(h, F)
	_pose(right, p, _toward(way[0]))
	await _step(AIM)
	var b := _drawn_beam()
	var pts: PackedVector4Array = b[1]
	var end: Vector4 = pts[pts.size() - 1] if pts.size() > 0 else Vector4.ZERO
	var e := sp.point_of(end)
	U.check("the beam pointed at the floor where it bends ends on it there, pale", b[0] and h.aimed == null and pts.size() >= 2
			and absf(e[0]) < sp.L and absf(sp.height(e[0], e[1])) < 2e-3 and (end - F).length() < 0.15 and b[2] == Hands.BEAM_COLOR,
			"drawn %s, %d points, its end at l %.2f, %.5f m over the floor, %.3f m from where it was pointed, colour %s"
			% [b[0], pts.size(), e[0], sp.height(e[0], e[1]), (end - F).length(), b[2]])

	# 2: a ball lying there
	var ball := main.toys.ball_on_floor(1.0, Vector2(3.0, 0.8), 0.25, Color(0.2, 0.6, 0.95))
	await _step(30)
	var C := sp.embed(ball.l, ball.n)
	var rest := absf(sp.floor_distance(ball.l, ball.n) - ball.radius)
	way = _toward_geodesic(h, C)
	_pose(right, p, _toward(way[0]))
	await _step(AIM)
	b = _drawn_beam()
	U.check("a ball lying on the bent floor is aimed at, the beam orange", absf(ball.l) < sp.L and rest < 2e-3 and h.aimed == ball
			and b[2] == Hands.COLOR_AIM, "the ball at l %.2f, %.4f m off its rest on the floor, aimed %s, %.2f m along"
			% [ball.l, rest, h.aimed == ball, h.aim_s])
	var res: Array = await _pull(p, _toward(way[0]), ball)
	var pull: Hands.Pull = res[0]
	U.check("... pulled by a flick of the wrist and caught", pull != null and res[2] > 0 and pull.miss < 0.1,
			"%d tries, missing by %.4f m, %.2f m/s, %.2f s to fly; caught %.2f s after it flew"
			% [pull.tries if pull else 0, pull.miss if pull else 0.0, pull.best.length() if pull else 0.0,
			pull.T if pull else 0.0, (res[2] - res[1]) / 60.0])
	right.set_input(&"grip", 0.0)
	await _step(2)

	# 3: through the throat along the floor
	_clear()
	_pose(right, p, Basis.IDENTITY)
	await _step(2)
	ball = main.toys.ball_on_floor(-1.0, Vector2(-7.2, 4.5), 0.3, Color(0.75, 0.35, 0.9))    # beside scene.json's box
	way = _toward_geodesic(h, sp.embed(ball.l, ball.n))
	_pose(right, p, _toward(way[0]))
	await _step(AIM)
	b = _drawn_beam()
	pts = b[1]
	end = pts[pts.size() - 1] if pts.size() > 0 else Vector4.ZERO
	var through := false
	for q: Vector4 in pts:
		through = through or absf(sp.point_of(q)[0]) < sp.Lc
	U.check("a ball on universe B's floor seen through the throat along the floor is aimed at, the beam through the throat to it",
			h.aimed == ball and through and b[2] == Hands.COLOR_AIM and (end - sp.embed(ball.l, ball.n)).length() < ball.radius,
			"aimed %s, %.2f m along; the ball at l %.2f, the beam's end %.3f m from its centre (its radius 0.3: where the geodesic passes nearest)"
			% [h.aimed == ball, h.aim_s, ball.l, (end - sp.embed(ball.l, ball.n)).length()])
	res = await _pull(p, _toward(way[0]), ball)
	pull = res[0]
	U.check("... pulled through the throat along the floor and caught", pull != null and res[2] > 0 and res[3] < -sp.L and res[4] > sp.L
			and pull.miss < 0.1, "%d tries, missing by %.4f m, %.2f m/s, %.2f s to fly, its miss moving %.2f m per m/s; caught %.2f s after it flew; l from %.2f to %.2f"
			% [pull.tries if pull else 0, pull.miss if pull else 0.0, pull.best.length() if pull else 0.0,
			pull.T if pull else 0.0, pull.sens if pull else 0.0, (res[2] - res[1]) / 60.0, res[3], res[4]])
	right.set_input(&"grip", 0.0)
	main.menu.show_beam(false)
	await _step(2)

	# 4: in the throat
	_clear()
	_pose(right, Vector3(0.6, 1.2, 0.0), Basis.IDENTITY)
	main.viewer.move((10.0 - sp.Rout + sp.L) * -(main.viewer.frame[2] as Vector4))    # to the throat's middle
	main.hands.forget_motion()
	await _step(2)
	var v := main.viewer
	# 0.5 m to the right of the feet, 0.25 m over the floor: there, in the throat's middle, gravity
	# is straight into the floor (off the middle it pulls a ball along the throat: docs/gravity.md)
	var at := sp.geodesic(v.l, v.n, v.frame[0], 0.5, v.frame)
	at = sp.geodesic(at[0], at[1], sp.floor_normal(at[0], at[1]), 0.25, [])
	ball = main.toys.world.add(at[0], at[1], Vector4.ZERO, 0.25, Color(0.3, 0.85, 0.4))
	await _step(60)
	var moved := (sp.embed(ball.l, ball.n) - sp.embed(at[0], at[1])).length()
	U.check("standing in the throat, a ball set down beside the feet rests on the floor", absf(v.l) < sp.Lc and absf(ball.l) < sp.Lc
			and moved < 0.01 and absf(sp.floor_distance(ball.l, ball.n) - ball.radius) < 2e-3,
			"the feet at l %.2f, the ball at l %.2f, %.4f m from where it was set, %.4f m from the floor"
			% [v.l, ball.l, moved, sp.floor_distance(ball.l, ball.n)])
	# the hand down at the ball's top, 5 cm over it: in the room, the way from the head there
	var top := sp.geodesic(ball.l, ball.n, sp.floor_normal(ball.l, ball.n), ball.radius + 0.05, [])
	var hp := v.head(U.HEAD_0.y)
	var D := sp.toward(hp[0], hp[1], top[0], top[1])
	_pose(right, U.HEAD_0 + BallWorld.to_body(hp[2], D), Basis.IDENTITY)
	await _step(2)
	right.set_input(&"grip", 1.0)
	await _step(3)
	U.check("... and the hand takes it", h.held == ball and ball.held == &"right_hand", "held %s" % [ball.held])
	right.set_input(&"grip", 0.0)
	await _step(2)
	U.finish(self, hmd, [left, right])
