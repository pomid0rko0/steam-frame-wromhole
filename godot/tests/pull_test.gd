extends SceneTree
## Pulling toys to the hand (hands.gd's top), through the code path the headset uses: the simulated
## headset (tests/fake_hmd.gd) and two controller trackers whose grip and aim poses and inputs the
## test sets. Run with --fixed-fps 60 under a display; exit status 1 on any failure:
##   godot --path . --fixed-fps 60 -s res://tests/pull_test.gd
## 1. BallWorld.flight, the throw's tries, flies as step does: a ball in universe A, a ball and a
##    cube into the throat, within 5 mm after the flight's time; WormholeSpace.ray ends where
##    geodesic does and stops at the floor; a ball with neither gravity nor air flies along the
##    geodesic of its start and direction (the beam's way), round the throat's rim and into B
## 2. a hand pointing at a ball far off aims at it: the ball glows and the hand turns orange;
##    pointing 20 degrees past it, neither; pointing through two balls, at the nearer one (the
##    balls behind the start, where the floor holds them: under the mouth its push rolls them)
## 3. the grip locks on it; a slow move pulls nothing, and the grip let go, nothing flies
## 4. a flick of the wrist throws the ball to the hand: let fly within PULL_TRIES frames, missing
##    by less than PULL_MISS, caught by the closed hand before the planned arrival, drawn in until
##    it touches
## 5. a yank of the left hand back and up pulls a cube to it
## 6. let go of the grip after the flick, the ball arrives and is not caught
## 7. a toy within reach is grabbed, not the one pointed at
## 8. from the start, a ball on universe B's floor seen through the throat: aimed at, pulled
##    through the throat (out of A's mouth in the air) and caught, its throw missing the hand by
##    less than 10 cm
## 9. hovering in the middle of the throat, a ball on universe A's floor (seen along no straight
##    line): aimed at, pulled up into the throat and caught
## 11. flying on the axis over the start, a ball on A's floor beyond the mouth, behind the
##    throat's sphere from the hand, seen round the throat's rim: aimed at, thrown steadily, caught;
##    from the start, a ball seen along a straight line 35 m off is not aimed at (PULL_RANGE), one
##    25 m off is
## 12. pulls from the start (MANY: near, far, under the mouth and past it, from universe B through
##    the throat, from inside the throat), the throw found as _fly finds it, then flown by the
##    world's own physics: each within 10 cm of the hand, in PULL_FLIGHTS flights at most; the ball
##    on B's floor at Toys.ring_point is aimed at (no throw along the throat's axis is steady:
##    hands.gd's top)
## 10. the beam (the menu's «луч прицела»): off, none; on, from the hand along its pointing geodesic
##    to the ball it aims at, orange, and else to the floor, pale; through the throat into universe
##    B; none while the hand holds a toy

const U := preload("res://tests/util.gd")
const SIZE := 96
const AIM := Hands.AIM_EVERY + 1     # frames after pointing: each hand has aimed
const AT := Vector3(13.0, 0.4, 0.25)     # chart A: a ball 3.4 m from the hand, behind the start
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
	root.add_child(main)
	_run()


func _step(n := 1) -> void:
	for _k in n:
		await process_frame


## The hand's grip and aim poses in the room, the same.
func _pose(t: XRControllerTracker, p: Vector3, b := Basis.IDENTITY) -> void:
	for pose in [&"grip", &"aim"]:
		t.set_pose(pose, Transform3D(b, p), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


## Pointing from p in the room along dir.
static func _toward(dir: Vector3) -> Basis:
	return Basis.looking_at(dir.normalized(), Vector3.UP if absf(dir.normalized().y) < 0.99 else Vector3.BACK)


## The room against chart A at the start (feet at Main.START_POS, facing -x): right is +y, up +z,
## back +x.
static func _play(c: Vector3) -> Vector3:
	return Vector3(c.y, c.z, c.x - Main.START_POS.x)


func _hand(i: int) -> Hands.Hand:
	return main.hands.list[i]


func _ball_at(c: Vector3, radius: float, color := Color(0.2, 0.6, 0.95)) -> BallWorld.Ball:
	var p: Array = main.space.point_from_chart(1.0, c)
	return main.toys.world.add(p[0], p[1], Vector4.ZERO, radius, color)


func _clear() -> void:
	main.toys.world.balls.clear()
	main.toys.world.cubes.clear()
	main.hands.empty()


## The colour the renderer got for the ball of this radius.
func _drawn(radius: float) -> Color:
	for c: Vector4 in main.renderer.ball_col:
		if absf(c.w - radius) < 1e-6:
			return Color(c.x, c.y, c.z)
	return Color.BLACK


## The colour hand i is drawn in.
func _hand_color(i: int) -> Color:
	var at := main.space.embed(_hand(i).ball.l, _hand(i).ball.n)
	for e: Array in main.hands.drawn():
		if (e[0] - at).length() < 1e-6:
			return Color(e[1].x, e[1].y, e[1].z)
	return Color.BLACK


func _away(t: XRControllerTracker) -> void:
	_pose(t, Vector3(-2.0 if t == left else 2.0, 1.0, 0.8))


func _run() -> void:
	await _step(AIM)
	U.check("main runs in XR, so it reads the controllers", main.in_xr, "in_xr %s" % main.in_xr)
	main.menu.visible = false
	_clear()
	_flight()
	_no_gravity()
	_ray()
	await _aim()
	await _lock()
	await _flick()
	await _yank()
	await _let_go()
	await _near_first()
	await _through()
	await _from_throat()
	await _beam()
	await _far_side()
	_many()
	U.finish(self, hmd, [left, right])


# 1
## BallWorld.flight against step's own flight (no contacts on the way), with the air.
func _flight() -> void:
	var sp: WormholeSpace = main.space
	var cases := [["ball in universe A", Vector3(6.0, 1.0, 0.3), Vector3(3.0, -1.0, 4.0), 0.2, false, 0.8],
			["ball into the throat", Vector3(6.0, 0.0, 3.0), Vector3(-6.5, 0.3, 4.0), 0.25, false, 0.8],
			["cube into the throat", Vector3(6.0, -0.5, 3.0), Vector3(-7.0, 0.6, 4.2), 0.2, true, 0.8]]
	for cs in cases:
		var w := BallWorld.new(sp, main.scene)
		var p: Array = sp.point_from_chart(1.0, cs[1])
		var U4 := WormholeSpace.vector_from_chart(1.0, p[1], cs[2])
		var b: BallWorld.Body
		if cs[4]:
			b = w.add_cube(p[0], p[1], U4, [Vector4(0, 0, 1, 0), Vector4(0, 0, 0, 1), Vector4(1, 0, 0, 0)],
					Vector3.ZERO, cs[3], Color.WHITE)
		else:
			b = w.add(p[0], p[1], U4, cs[3], Color.WHITE)
		var T: float = cs[5]
		var t0 := Time.get_ticks_usec()
		var res := w.flight(b, p[0], p[1], U4, T, [Vector4(1, 0, 0, 0)])
		var us := Time.get_ticks_usec() - t0
		var low := INF
		for k in roundi(T * 60.0):
			w.step(1.0 / 60.0, [])
			low = minf(low, sp.height(b.l, b.n))
		var gap: float = (sp.embed(b.l, b.n) - sp.embed(res[0], res[1])).length()
		U.check("flight flies as the physics does: " + cs[0], gap < 0.005 and low > cs[3],
				"%.4f m apart after %.1f s, at l %.2f (the curved zone below %.2f); lowest %.2f m up; flight took %d us"
				% [gap, T, b.l, sp.L, low, us])


# 1
## dynamics_step without gravity against geodesic, 2 s at 10 m/s from 4 m up in front of the
## throat: into B, and round the rim.
func _no_gravity() -> void:
	var sp: WormholeSpace = main.space
	var p: Array = sp.point_from_chart(1.0, Vector3(9.7, 0.2, 4.0))
	for dir: Vector3 in [Vector3(-1.0, 0.0, 0.0), Vector3(-1.0, 0.36, 0.0)]:
		var D := WormholeSpace.vector_from_chart(1.0, p[1], dir.normalized())
		var l: float = p[0]
		var n: Vector3 = p[1]
		var V := D * 10.0
		var worst := 0.0
		var lo := l
		for k in 360:
			var st := sp.dynamics_step(l, n, V, BallWorld.DT, 0.0)
			l = st[0]
			n = st[1]
			V = st[2]
			lo = minf(lo, l)
			if k % 18 == 17:
				var g := sp.geodesic(p[0], p[1], D, 10.0 * (k + 1) * BallWorld.DT, [])
				worst = maxf(worst, (sp.embed(l, n) - sp.embed(g[0], g[1])).length())
		U.check("with neither gravity nor air a ball flies along the geodesic (the beam's way), %s" % ("into B" if lo < -sp.L else "round the rim"),
				worst < 1e-3 and lo < sp.L, "%.5f m apart at most over 20 m, down to l %.2f" % [worst, lo])


# 1
func _ray() -> void:
	var sp: WormholeSpace = main.space
	# level from 4 m up toward the throat: through it into universe B, as geodesic goes
	var p: Array = sp.point_from_chart(1.0, Vector3(9.0, 0.3, 4.0))
	var D := WormholeSpace.vector_from_chart(1.0, p[1], Vector3(-1.0, 0.0, 0.0))
	var r := sp.ray(p[0], p[1], D, 20.0)
	var pts: Array = r[0]
	var lens: Array = r[1]
	var g := sp.geodesic(p[0], p[1], D, lens[lens.size() - 1], [])
	var end: Vector4 = pts[pts.size() - 1]
	U.check("ray ends where geodesic does, through the throat", (end - sp.embed(g[0], g[1])).length() < 1e-4
			and g[0] < -sp.L, "%.6f m apart, %d points, at l %.2f" % [(end - sp.embed(g[0], g[1])).length(), pts.size(), g[0]])
	# 30 degrees down from 1.2 m in universe A: the floor (R^4's z = -lift) 2.4 m on
	p = sp.point_from_chart(1.0, Vector3(9.0, 0.3, 1.2))
	var Dd := WormholeSpace.vector_from_chart(1.0, p[1], Vector3(-cos(PI / 6.0), 0.0, -sin(PI / 6.0)))
	r = sp.ray(p[0], p[1], Dd, 20.0)
	lens = r[1]
	pts = r[0]
	U.check("ray stops at the floor", absf(lens[lens.size() - 1] - 2.4) < 1e-4 and absf(pts[pts.size() - 1].z + sp.lift) < 1e-5,
			"%.4f m (2.4), height %.6f" % [lens[lens.size() - 1], pts[pts.size() - 1].z + sp.lift])


# 2
func _aim() -> void:
	_clear()
	_away(left)
	var ball := _ball_at(AT, 0.25)
	var own := ball.color
	var p := Vector3(0.2, 1.2, -0.3)
	var dir := _play(AT) - p
	_pose(right, p, _toward(dir))
	await _step(AIM)
	var h := _hand(1)
	var got := _drawn(0.25)
	U.check("pointed at a ball 3.4 m off, the hand aims at it", h.aimed == ball, "aimed %s" % [h.aimed])
	U.check("... the ball glows", Vector3(got.r - own.r, got.g - own.g, got.b - own.b).length() > 0.2,
			"drawn %s, its own %s" % [got, own])
	U.check("... and the hand turns orange", _hand_color(1) == Hands.COLOR_AIM, "hand %s" % _hand_color(1))
	_pose(right, p, _toward(Basis(Vector3.UP, deg_to_rad(20.0)) * dir))
	await _step(AIM)
	U.check("pointed 20 degrees past it, neither", h.aimed == null and _drawn(0.25) == own
			and _hand_color(1) == Hands.COLOR, "aimed %s, ball %s, hand %s" % [h.aimed, _drawn(0.25), _hand_color(1)])
	# from 0.5 m up at the centre of a ball 4.8 m off, through one 2.8 m off on the way (the far one
	# first in the list)
	_clear()
	var far := _ball_at(Vector3(14.5, 0.2, 0.25), 0.25)
	var near := _ball_at(Vector3(12.5, 0.2, 0.25), 0.25)
	var q := Vector3(0.2, 0.5, -0.3)
	_pose(right, q, _toward(_play(Vector3(14.5, 0.2, 0.25)) - q))
	await _step(AIM)
	U.check("pointed through two balls, the hand aims at the nearer", h.aimed == near,
			"aimed the near one %s, the far one %s" % [h.aimed == near, h.aimed == far])


# 3
func _lock() -> void:
	_clear()
	var ball := _ball_at(AT, 0.25)
	var p := Vector3(0.2, 1.2, -0.3)
	_pose(right, p, _toward(_play(AT) - p))
	await _step(AIM)
	right.set_input(&"grip", 1.0)
	await _step(1)
	var h := _hand(1)
	var locked := h.locked and h.aimed == ball
	var b0 := _toward(_play(AT) - p)
	for k in 30:
		p += Vector3(0.0, 0.0, 0.3 / 60.0)        # back at 0.3 m/s, turning up at 1 rad/s
		_pose(right, p, b0 * Basis(Vector3.RIGHT, k / 60.0))
		await _step(1)
	U.check("the grip locks on the ball aimed at; a slow move pulls nothing", locked and h.locked and h.pull == null
			and ball.U == Vector4.ZERO, "locked %s, then %s, pull %s" % [locked, h.locked, h.pull])
	right.set_input(&"grip", 0.0)
	await _step(20)
	U.check("... and the grip let go, nothing flies", not h.locked and h.pull == null and ball.U == Vector4.ZERO,
			"locked %s, the ball at %.3f m/s" % [h.locked, ball.U.length()])


## Hand i (tracker t) at p locked on toy, then the flick: frames of the wrist turning up at
## turn rad/s, or of the hand moving at move m/s; then held still. Returns the frames until the toy
## flew, the pull and the frames until it was caught (or -1).
func _pull(i: int, t: XRControllerTracker, p: Vector3, b0: Basis, turn: float, move: Vector3,
		let_go_after := -1) -> Array:
	var h := _hand(i)
	t.set_input(&"grip", 1.0)
	await _step(1)
	if not h.locked:
		return [-1, null, -1]
	var flew := -1
	var caught := -1
	var pull: Hands.Pull = null
	var th := 0.0
	for k in 120:
		if k < 8:
			th += turn / 60.0
			p += move / 60.0
		_pose(t, p, b0 * Basis(Vector3.RIGHT, th))
		if k == let_go_after:
			t.set_input(&"grip", 0.0)
		await _step(1)
		if h.pull:
			pull = h.pull
		if flew < 0 and pull and pull.flying:
			flew = k
		if pull and h.held == pull.toy:
			caught = k
			break
		if pull and h.pull == null:
			break
	return [flew, pull, caught]


# 4
func _flick() -> void:
	_clear()
	var ball := _ball_at(AT, 0.25)
	var p := Vector3(0.2, 1.2, -0.3)
	var b0 := _toward(_play(AT) - p)
	_pose(right, p, b0)
	await _step(AIM)
	var res: Array = await _pull(1, right, p, b0, 10.0, Vector3.ZERO)
	var pull: Hands.Pull = res[1]
	if pull == null:
		U.check("a flick of the wrist pulls the ball", false, "no pull (locked %s)" % _hand(1).locked)
		return
	U.check("a flick of the wrist throws the ball: let fly within PULL_TRIES frames, aimed within PULL_MISS",
			res[0] >= 0 and pull.tries <= Hands.PULL_TRIES and pull.miss < Hands.PULL_MISS,
			"flew %d frames after the flick began, %d tries (the slowest %d us), missing by %.4f m, %.2f m/s, %.2f s to fly"
			% [res[0], pull.tries, pull.slowest, pull.miss, pull.best.length(), pull.T])
	var flight: float = (res[2] - res[0]) / 60.0
	U.check("... caught by the closed hand before the planned arrival", ball.held == &"right_hand" and res[2] > 0
			and flight > 0.5 * pull.T and flight <= pull.T + 1.0 / 60.0, "held by '%s' %.2f s after it flew (%.2f)"
			% [ball.held, flight, pull.T])
	await _step(20)
	var h := _hand(1)
	var gap: float = (main.space.embed(ball.l, ball.n) - main.space.embed(h.ball.l, h.ball.n)).length()
	U.check("... and drawn in until it touches the hand", absf(gap - 0.25 - Hands.RADIUS) < 2e-3 and not h.glide,
			"centres %.4f m apart (%.4f)" % [gap, 0.25 + Hands.RADIUS])
	right.set_input(&"grip", 0.0)
	await _step(2)


# 5
func _yank() -> void:
	_clear()
	_away(right)
	var cube: BallWorld.Cube = main.toys.cube_on_floor(1.0, Vector2(7.0, -0.9), 0.2, 0.3, Color(0.35, 0.8, 0.75))
	var p := Vector3(-0.25, 1.1, -0.3)
	var b0 := _toward(_play(Vector3(7.0, -0.9, 0.2)) - p)
	_pose(left, p, b0)
	await _step(AIM)
	U.check("the left hand aims at a cube", _hand(0).aimed == cube, "aimed %s" % [_hand(0).aimed])
	var res: Array = await _pull(0, left, p, b0, 0.0, Vector3(0.0, 1.0, 1.6))
	var pull: Hands.Pull = res[1]
	U.check("a yank of the hand back and up pulls the cube to it", pull != null and cube.held == &"left_hand",
			"pull %s, held by '%s'" % [pull, cube.held])
	left.set_input(&"grip", 0.0)
	await _step(2)
	_away(left)


# 6
func _let_go() -> void:
	_clear()
	var ball := _ball_at(AT, 0.25)
	var p := Vector3(0.2, 1.2, -0.3)
	var b0 := _toward(_play(AT) - p)
	_pose(right, p, b0)
	await _step(AIM)
	var res: Array = await _pull(1, right, p, b0, 10.0, Vector3.ZERO, 3)
	var pull: Hands.Pull = res[1]
	U.check("the grip let go after the flick: the ball flies, is not caught", pull != null and res[0] >= 0
			and res[2] < 0 and ball.held == &"" and _hand(1).pull == null,
			"flew %d, caught %d, held by '%s'" % [res[0], res[2], ball.held])


# 7
func _near_first() -> void:
	_clear()
	var far := _ball_at(AT, 0.25)
	var p := Vector3(0.2, 1.2, -0.3)
	var near := _ball_at(Vector3(Main.START_POS.x + p.z, p.x, p.y - 0.29), 0.2)
	near.held = &"test"                      # kinematic: it stays where it is put
	_pose(right, p, _toward(_play(AT) - p))
	await _step(AIM)
	near.held = &""
	await _step(1)
	var aimed := _hand(1).aimed
	right.set_input(&"grip", 1.0)
	await _step(1)
	U.check("a toy within reach is grabbed, not the one pointed at", aimed == far and near.held == &"right_hand"
			and not _hand(1).locked, "aimed at the far one %s, the near one held by '%s'" % [aimed == far, near.held])
	right.set_input(&"grip", 0.0)
	await _step(2)


# 8
func _through() -> void:
	_clear()
	_away(left)
	var sp: WormholeSpace = main.space
	var p := Vector3(0.2, 1.3, -0.3)
	_pose(right, p, Basis.IDENTITY)
	await _step(2)
	var h := _hand(1)
	# 13 m out on B's floor (where the floor holds a ball), off the line from the hand through the
	# throat's centre (along it no throw is steady: hands.gd's top), pointed at along the geodesic
	# that passes nearest its centre
	var q: Array = sp.point_from_chart(-1.0, Vector3(-13.0, 2.0, 0.3))
	var ball := main.toys.world.add(q[0], q[1], Vector4.ZERO, 0.3, Color(0.75, 0.35, 0.9))
	var dir: Vector3 = _toward_geodesic(h, sp.embed(ball.l, ball.n))[0]
	_pose(right, p, _toward(dir))
	await _step(AIM)
	U.check("from the start, a ball on universe B's floor seen through the throat is aimed at",
			h.aimed == ball, "aimed %s, %.2f m along; the ball at l %.2f" % [h.aimed, h.aim_s, ball.l])
	var lo := ball.l
	var hi := ball.l
	var b0 := _toward(dir)
	right.set_input(&"grip", 1.0)
	await _step(1)
	var flew := -1
	var caught := -1
	var pull: Hands.Pull = null
	var th := 0.0
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
	U.check("... pulled through the throat and caught", pull != null and caught > 0 and lo < -sp.L and hi > sp.L
			and pull.miss < 0.1 and (caught - flew) / 60.0 <= pull.T + 1.0 / 60.0,
			"%d tries (the slowest %d us), missing by %.4f m, %.2f m/s, %.2f s to fly; caught %.2f s after it flew; l from %.2f to %.2f"
			% [pull.tries if pull else 0, pull.slowest if pull else 0, pull.miss if pull else 0.0,
			pull.best.length() if pull else 0.0, pull.T if pull else 0.0, (caught - flew) / 60.0, lo, hi])
	right.set_input(&"grip", 0.0)
	await _step(2)


# 9
func _from_throat() -> void:
	_clear()
	_away(left)
	var sp: WormholeSpace = main.space
	main.place_on_axis(0.0, 180.0)                  # facing universe A
	main.set_fall(false)
	var ball := _ball_at(Vector3(9.0, 1.0, 0.25), 0.25)
	var p := Vector3(0.2, 1.3, -0.3)
	_pose(right, p, Basis.IDENTITY)
	await _step(2)
	var h := _hand(1)
	var way := _toward_geodesic(h, sp.embed(ball.l, ball.n), Vector2(-50, 10))
	_pose(right, p, _toward(way[0]))
	await _step(AIM)
	U.check("hovering in the throat, a ball on universe A's floor is aimed at", h.aimed == ball and not h.aim_chord,
			"aimed %s, %.2f m along, the geodesic %.2f m from its centre; the hand at l %.2f" % [h.aimed, h.aim_s, way[1], h.ball.l])
	var res: Array = await _pull(1, right, p, _toward(way[0]), 10.0, Vector3.ZERO)
	var pull: Hands.Pull = res[1]
	U.check("... pulled up into the throat and caught", pull != null and ball.held == &"right_hand" and h.held == ball,
			"%d tries, missing by %.4f m, %.2f m/s, %.2f s to fly; caught %.2f s after it flew"
			% [pull.tries if pull else 0, pull.miss if pull else 0.0, pull.best.length() if pull else 0.0,
			pull.T if pull else 0.0, (res[2] - res[0]) / 60.0])
	right.set_input(&"grip", 0.0)
	await _step(2)
	main.place(main.START_POS, main.START_FORWARD)
	main.set_fall(true)
	await _step(1)


## Hand 1's beam as the renderer has it: [drawn, its points, colour].
func _drawn_beam() -> Array:
	var m: ShaderMaterial = main.renderer.beam_mats[1]
	var n: int = m.get_shader_parameter("beam_n")
	var pts: PackedVector4Array = m.get_shader_parameter("beam_p")
	return [main.renderer.beams[1].visible, pts.slice(0, n), m.get_shader_parameter("beam_col")]


# 10
func _beam() -> void:
	_clear()
	_away(left)
	var sp: WormholeSpace = main.space
	var ball := _ball_at(AT, 0.25)
	var p := Vector3(0.2, 1.2, -0.3)
	var dir := _play(AT) - p
	_pose(right, p, _toward(dir))
	await _step(AIM)
	var h := _hand(1)
	U.check("the beam off: none drawn", not main.hands.beam and not _drawn_beam()[0], "drawn %s" % _drawn_beam()[0])
	main.menu.show_beam(true)
	await _step(2)
	var b := _drawn_beam()
	var pts: PackedVector4Array = b[1]
	var at := sp.embed(h.ball.l, h.ball.n)
	var C := sp.embed(ball.l, ball.n)
	var gap := 0.0
	for k in pts.size() - 1:
		gap = maxf(gap, (pts[k + 1] - pts[k]).length())
	U.check("the beam on: from the hand to the ball it aims at, in steps of BEAM_STEP at most, orange",
			b[0] and h.aimed == ball and pts.size() >= 2 and (pts[0] - at).length() < 1e-4
			and (pts[pts.size() - 1] - C).length() < 1e-3 and gap <= Hands.BEAM_STEP + 1e-4 and b[2] == Hands.COLOR_AIM,
			"drawn %s, %d points %.2f m apart at most, from %.5f m off the hand to %.5f m off the ball's centre, colour %s"
			% [b[0], pts.size(), gap, (pts[0] - at).length(), (pts[pts.size() - 1] - C).length(), b[2]])
	# a little past it: the beam ends where it passes nearest the ball
	var past := Basis(Vector3.UP, deg_to_rad(4.0)) * dir
	_pose(right, p, _toward(past))
	await _step(AIM)
	b = _drawn_beam()
	pts = b[1]
	var E: Vector4 = pts[pts.size() - 1]
	var along := (E - at).normalized()
	U.check("... pointing 4 degrees past it: still at it, the beam ending where it passes nearest the ball",
			h.aimed == ball and absf((C - E).dot(along)) < 1e-3,
			"aimed %s, the ball's centre %.4f m along the beam from its end" % [h.aimed == ball, (C - E).dot(along)])
	_pose(right, p, _toward(Basis(Vector3.UP, deg_to_rad(20.0)) * dir))
	await _step(AIM)
	b = _drawn_beam()
	pts = b[1]
	U.check("... pointing past it: to the floor, pale", b[0] and h.aimed == null and absf(pts[pts.size() - 1].z + sp.lift) < 1e-4
			and b[2] == Hands.BEAM_COLOR, "aimed %s, ends %.5f m up, colour %s" % [h.aimed, pts[pts.size() - 1].z + sp.lift, b[2]])
	# at the throat's centre: through it into universe B
	_pose(right, p, _toward(_play(Vector3(0.0, 0.0, sp.lift)) - p))
	await _step(2)
	b = _drawn_beam()
	pts = b[1]
	var into := false
	for q: Vector4 in pts:
		into = into or (sp.point_of(q)[0] < -sp.L)
	U.check("... toward the throat: through it into universe B", b[0] and into, "%d points, into B %s" % [pts.size(), into])
	right.set_input(&"grip", 1.0)
	right.set_input(&"by_button", true)
	await _step(2)
	right.set_input(&"by_button", false)
	await _step(1)
	U.check("... none while the hand holds a toy", h.held != null and not _drawn_beam()[0], "holds %s, drawn %s" % [h.held, _drawn_beam()[0]])
	right.set_input(&"grip", 0.0)
	main.menu.show_beam(false)
	await _step(2)
	U.check("off again: none", not _drawn_beam()[0])


## The pointing direction from hand h (room) whose geodesic passes nearest C (R^4): on a grid of
## 2 degrees, pitches from pitches.x to pitches.y, then of 0.1 degrees round the best (the throat
## magnifies what is seen through it many times): [direction, how near].
func _toward_geodesic(h: Hands.Hand, C: Vector4, pitches := Vector2(-20, 50)) -> Array:
	var coarse := _grid(h, C, Vector2(-60, 60), pitches, 2.0)
	return _grid(h, C, Vector2(coarse[2].x - 2.0, coarse[2].x + 2.0), Vector2(coarse[2].y - 2.0, coarse[2].y + 2.0), 0.1)


## The grid's best: [direction, how near, (yaw, pitch)].
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


# 11
func _far_side() -> void:
	_clear()
	_away(left)
	var sp: WormholeSpace = main.space
	# the head on the axis 10.4 m out (chart A (10.4, 0, lift)), facing the throat
	main.place_on_axis(12.0, 0.0)
	main.set_fall(false)
	var p := Vector3(0.2, 1.3, -0.3)
	_pose(right, p, Basis.IDENTITY)
	await _step(2)
	var h := _hand(1)
	# behind the sphere, near its shadow's edge: deeper in, a path round the rim needs an impact
	# parameter near r_min, where the ways part so fast that no throw is steady (hands.gd's top)
	var ball := _ball_at(Vector3(-8.5, 5.0, 0.25), 0.25)
	var C := sp.embed(ball.l, ball.n)
	var behind := h.ball.l > sp.L and main.hands._behind_shell(sp.embed(h.ball.l, h.ball.n), C)
	var way := _toward_geodesic(h, C)
	_pose(right, p, _toward(way[0]))
	await _step(AIM)
	U.check("flying over the start, a ball on A's floor behind the throat's sphere, seen round its rim, is aimed at",
			behind and h.aimed == ball and not h.aim_chord, "behind the sphere %s, aimed %s, along a chord %s, the geodesic %.2f m from its centre"
			% [behind, h.aimed == ball, h.aim_chord, way[1]])
	right.set_input(&"grip", 1.0)
	await _step(1)
	var b0 := _toward(way[0])
	var th := 0.0
	var pull: Hands.Pull = null
	var caught := false
	var lo := INF
	for k in 200:
		if k < 8:
			th += 10.0 / 60.0
		_pose(right, p, b0 * Basis(Vector3.RIGHT, th))
		await _step(1)
		if h.pull:
			pull = h.pull
		if pull and pull.flying:
			lo = minf(lo, absf(ball.l))
		if h.held == ball:
			caught = true
			break
	U.check("... thrown steadily and caught", pull != null and caught and pull.sens <= Hands.STEADY,
			"thrown %s, %d flights tried, its miss moving %.1f m per m/s, missing by %.3f m, %.2f s; |l| down to %.2f (the curved zone below %.2f)"
			% [pull.way if pull else "", pull.tries if pull else 0, pull.sens if pull else 0.0, pull.miss if pull else 0.0,
			pull.T if pull else 0.0, lo, sp.L])
	right.set_input(&"grip", 0.0)
	await _step(2)
	main.place(main.START_POS, main.START_FORWARD)
	main.set_fall(true)
	await _step(1)
	# straight lines to the right, 35 and 25 m off
	for d: float in [35.0, 25.0]:
		_clear()
		var c := Vector3(9.7 - 0.3 * d, 0.2 + 0.95 * d, 0.25)
		var far := _ball_at(c, 0.25)
		_pose(right, p, _toward(_play(c) - p))
		await _step(AIM)
		var want: bool = d < Hands.PULL_RANGE
		U.check("a ball %.0f m off along a straight line: %s" % [d, "aimed at" if want else "not aimed at (PULL_RANGE)"],
				(h.aimed == far) == want, "aimed %s" % [h.aimed == far])


# 12
# [universe: A, B (chart), R (Toys.ring_point, B) or T (the throat: l, azimuth, elevation of n in
# radians), place, radius]
const MANY := [["A", Vector3(6.5, 0.4, 0.25), 0.25], ["A", Vector3(4.6, -2.0, 0.25), 0.25],
		["A", Vector3(0.5, 4.6, 0.25), 0.25], ["A", Vector3(-6.0, 0.5, 0.25), 0.25], ["A", Vector3(-5.0, 2.5, 0.25), 0.25],
		["A", Vector3(-4.5, -1.0, 0.25), 0.25], ["A", Vector3(-8.0, 3.0, 0.25), 0.25], ["B", Vector3(-10.0, 2.0, 0.3), 0.3],
		["B", Vector3(-12.0, -2.5, 0.3), 0.3], ["T", Vector3(0.8, -0.45, 0.0), 0.3], ["R", Vector3.ZERO, 0.4]]


## Off the scene: a world and a hand of their own, the hand 1.3 m up at the start (chart A
## (9.7, 0.2)), the room's axes as there.
func _many() -> void:
	var sp: WormholeSpace = main.space
	for cs: Array in MANY:
		var w := BallWorld.new(sp, main.scene)
		var hands := Hands.new(sp, w)
		var g := XRController3D.new()
		hands.add(g, null)
		var h: Hands.Hand = hands.list[0]
		var p: Array = sp.point_from_chart(1.0, Vector3(9.7, 0.2, 1.3))
		h.ball.l = p[0]
		h.ball.n = p[1]
		h.ball.held = &"many"
		h.room = [WormholeSpace.vector_from_chart(1.0, p[1], Vector3(0, 1, 0)),
				WormholeSpace.vector_from_chart(1.0, p[1], Vector3(0, 0, 1)), WormholeSpace.vector_from_chart(1.0, p[1], Vector3(1, 0, 0))]
		var at: Vector3 = cs[1]
		var ball: BallWorld.Ball
		if cs[0] == "T":
			ball = w.add(at.x, Vector3(cos(at.y) * cos(at.z), sin(at.y) * cos(at.z), sin(at.z)), Vector4.ZERO, cs[2], Color.WHITE)
		elif cs[0] == "R":
			at = main.toys.ring_point()
			var q: Array = sp.point_from_chart(-1.0, at)
			ball = w.add(q[0], q[1], Vector4.ZERO, cs[2], Color.WHITE)
		else:
			var q: Array = sp.point_from_chart(1.0 if cs[0] == "A" else -1.0, at)
			ball = w.add(q[0], q[1], Vector4.ZERO, cs[2], Color.WHITE)
		var way := _toward_geodesic(h, sp.embed(ball.l, ball.n))
		g.transform = Transform3D(Basis.looking_at(way[0]), Vector3.ZERO)
		hands.clock += 1.0
		hands._aim(h)
		var name := "%s %s" % [cs[0], at]
		if h.aimed != ball or cs[0] == "R":
			U.check("pull from %s: aimed at" % name, h.aimed == ball, "%.1f m along, the geodesic %.2f m from its centre" % [h.aim_s, way[1]])
			continue
		h.locked = true
		hands._launch(0)
		var pl: Hands.Pull = h.pull
		var us := 0
		var done := false
		while not done:
			var t0 := Time.get_ticks_usec()
			done = hands._solve(pl)
			us += Time.get_ticks_usec() - t0
		ball.held = &""
		ball.U = pl.best
		var nearest := INF
		var lo := INF
		for k in roundi((pl.best_T + 0.3) * 60.0):
			w.step(1.0 / 60.0, [])
			nearest = minf(nearest, (sp.embed(ball.l, ball.n) - pl.target).length())
			lo = minf(lo, absf(ball.l))
		U.check("pull from %s, %.1f m: flown within 10 cm of the hand" % [name, h.aim_s], nearest < 0.1 and pl.tries <= Hands.PULL_FLIGHTS,
				"thrown %s in %.2f s at %.1f m/s, its miss moving %.1f m per m/s; %d flights tried, %.1f ms; flown %.3f m from the hand at the nearest, |l| down to %.2f"
				% [pl.way, pl.best_T, pl.best.length(), pl.sens, pl.tries, us / 1000.0, nearest, lo])
