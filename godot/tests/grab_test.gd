extends SceneTree
## Grabbing and throwing balls and cubes with the controllers' grips, through the code path the
## headset uses: the simulated headset (tests/fake_hmd.gd) and two controller trackers whose grip
## poses and inputs the test sets by the action names of openxr_action_map.tres. Run with
## --fixed-fps 60 under a display (xvfb-run: it looks at the left eye's picture); exit status 1
## on any failure:
##   godot --path . --fixed-fps 60 -s res://tests/grab_test.gd
## 0. the action map is exactly util.gd's, every binding of every profile (U.check_bindings)
## 1. each hand is a ball on the curved space, where the controller's grip is; the shader gets
##    them, the stencil's proxies cover them, and the left eye sees the hand's ball where it is
## 2. near a ball the hand turns green; the grip takes the ball, which follows the hand
## 3. let go while the hand moves, the ball flies off with the hand's velocity: along a line,
##    and along an arc (no lag: the direction right)
## 4. left X with the grip closed: a new cube in the left hand; it turns with the hand, and let go
##    it spins as the hand turned and moves as the hand did (not with the wrist's turn times its
##    lever to the cube's centre)
## 5. right B with the grip closed: a new ball in the right hand; the left hand takes it over
## 6. the hand pushes a ball and a cube it meets, softly (a ball under 1.35 times the hand's speed;
##    one pressed into the floor is not flung); a held ball pushes a ball
## 7. a half-open grip keeps holding, more open lets go; a hand that loses its tracking leaves its
##    ball in the air, at rest (a ball set on it is not flung), and let go then it falls from rest
## 8. while the speed check holds the viewer, the hands are not drawn and grab nothing, B and X
##    make nothing; while the menu is open, B, X and the D-pad down make nothing either (the B
##    that closes it neither), A does not reset; the D-pad down makes a cube as X does; A puts
##    everything back and empties the hands
## 9. in the middle of the throat: the hand is a head-to-hand geodesic away, the held ball keeps
##    its offset in the hand's axes through the curved space, and leaves the hand smoothly
## 10. from the start, a ball thrown toward the wormhole ends up in universe B
## 11. a ball held with the hand inside it, lowered onto the floor at the shell's edge and let go
##     with the hand still: it is set down at rest, the hand that let it go does not push it, and
##     gravity rolls it toward the throat by itself

const U := preload("res://tests/util.gd")
const SIZE := 160                    # each eye's picture
const FRUSTUM := U.FRUSTUM_0         # util.gd's headset, case 0
const IPD := U.IPD
const HEAD := U.HEAD_0
var main: Node3D
var spawned: Array                   # [balls, cubes] the demo's spawn makes
var hmd
var left: XRControllerTracker
var right: XRControllerTracker


func _initialize() -> void:
	hmd = U.headset(0, 0.0, Vector2i(SIZE, SIZE))
	left = U.controller(&"left_hand")
	right = U.controller(&"right_hand")
	main = load("res://main.tscn").instantiate()
	main.xr_name = "FakeHMD"
	main.toys.demo = false
	root.add_child(main)
	_run()


func _step(n := 1) -> void:
	for _k in n:
		await process_frame


## A hand's grip pose in the room; untracked, the controller has lost it (as Godot's OpenXR
## reports a pose without tracking: the tracker's pose invalidated).
func _pose(t: XRControllerTracker, p: Vector3, b := Basis.IDENTITY, tracked := true) -> void:
	if tracked:
		t.set_pose(&"grip", Transform3D(b, p), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	else:
		t.invalidate_pose(&"grip")


## The room against chart A at the start (feet at Main.START_POS, facing -x: START_FORWARD; the head
## above the room's origin): right is +y, up +z, back +x.
static func _chart(p: Vector3) -> Vector3:
	return Vector3(Main.START_POS.x + p.z, p.x, p.y)


static func _play(c: Vector3) -> Vector3:
	return Vector3(c.y, c.z, c.x - Main.START_POS.x)


static func _chart_dir(v: Vector3) -> Vector3:
	return Vector3(v.z, v.x, v.y)


func _at(b: Dictionary) -> Vector3:
	return main.space.chart_position(b["l"], b["n"])


func _vel(b: Dictionary) -> Vector3:
	return WormholeSpace.vector_to_chart(signf(b["l"]), b["n"], b["U"])


func _hand(i: int) -> Dictionary:
	return main.hands.state[i]


func _ball_at(c: Vector3, radius: float) -> Dictionary:
	var p: Array = main.space.point_from_chart(1.0, c)
	return main.toys.world.add(p[0], p[1], Vector4.ZERO, radius, Color(0.9, 0.2, 0.2))


func _clear() -> void:
	main.toys.world.balls.clear()
	main.toys.world.cubes.clear()


## The hands' colours the shader got (the balls of the hands' radius).
func _hand_colors() -> Array:
	var out := []
	var col: PackedVector4Array = main.tracer.material.get_shader_parameter("wh_ballCol")
	var n: int = main.tracer.material.get_shader_parameter("wh_nBall")
	for k in n:
		if absf(col[k].w - Hands.RADIUS) < 1e-6:
			out.append(Color(col[k].x, col[k].y, col[k].z))
	return out


func _left_eye() -> Image:
	var img: Image = RenderingServer.texture_2d_layer_get(main.xr_view.get_texture().get_rid(), 0)
	img.convert(Image.FORMAT_RGB8)
	return img


func _run() -> void:
	await _step(3)
	U.check_bindings()
	U.check("main runs in XR, so it reads the controllers", main.in_xr, "in_xr %s" % main.in_xr)
	main.menu.visible = false        # it follows the head: in every view
	spawned = [main.toys.world.balls.size(), main.toys.world.cubes.size()]
	_clear()
	await _hands()
	await _grab_and_throw()
	await _cube_and_spin()
	await _hand_over()
	await _pushes()
	await _grip_and_tracking()
	await _hold_and_reset()
	await _throat()
	await _into_b()
	await _set_down()
	U.finish(self, hmd, [left, right])


# 1
func _hands() -> void:
	var pr := Vector3(0.15, 1.45, -0.4)
	var pl := Vector3(-0.2, 1.1, -0.35)
	_pose(right, pr)
	_pose(left, pl)
	await _step(3)
	var hr := _hand(1)
	var hl := _hand(0)
	var ok: bool = hr.get("on", false) and hl.get("on", false)
	var detail := ""
	if ok:
		var cr: Vector3 = main.space.chart_position(hr["l"], hr["n"])
		var cl: Vector3 = main.space.chart_position(hl["l"], hl["n"])
		ok = cr.distance_to(_chart(pr)) < 1e-4 and cl.distance_to(_chart(pl)) < 1e-4
		detail = "right at %s (%s), left at %s (%s)" % [cr, _chart(pr), cl, _chart(pl)]
	U.check("each hand where its grip is, on the curved space", ok, detail)
	var nb: int = main.tracer.material.get_shader_parameter("wh_nBall")
	var proxies: int = main.tracer.proxy_spheres(main.foot_l).size()
	U.check("the shader draws both hands, the stencil's proxies cover them", nb == 2 and proxies == 3,
			"shader balls %d (2), proxies %d (the shell and 2 hands)" % [nb, proxies])
	# the left eye's picture with the right hand and without it
	var with_hand := _left_eye()
	_pose(right, pr, Basis.IDENTITY, false)
	await _step(3)
	U.check("a hand that loses its tracking is not drawn", main.tracer.material.get_shader_parameter("wh_nBall") == 1,
			"shader balls %d" % main.tracer.material.get_shader_parameter("wh_nBall"))
	var without := _left_eye()
	var sum := Vector2.ZERO
	var count := 0
	var hue := Vector3.ZERO
	for y in SIZE:
		for x in SIZE:
			var a := with_hand.get_pixel(x, y)
			var b := without.get_pixel(x, y)
			if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > 0.1:
				sum += Vector2(x + 0.5, y + 0.5)
				count += 1
				hue += Vector3(a.r, a.g, a.b)
	# where the left eye sees the hand's centre (the eye IPD / 2 to the left of the head)
	var d := pr - (HEAD - Vector3(0.5 * IPD, 0.0, 0.0))
	var want := Vector2((d.x / -d.z + 1.0) * 0.5 * SIZE, (1.0 - d.y / -d.z / FRUSTUM.w) * 0.5 * SIZE)
	var got := sum / maxf(count, 1)
	# the disc: the ball's angular radius in pixels across and (a taller frustum) down
	var rx: float = Hands.RADIUS / d.length() * 0.5 * SIZE
	var area := PI * rx * rx / FRUSTUM.w
	U.check("the left eye sees the hand's ball where the hand is", count > 0 and got.distance_to(want) < 2.0
			and count > 0.6 * area and count < 2.0 * area,
			"centre of the changed pixels %s, expected %s; %d pixels (a disc of about %.0f)" % [got, want, count, area])
	hue /= maxf(count, 1)
	U.check("an empty hand is grey-blue", hue.z > hue.x, "mean colour %s" % hue)
	_pose(right, pr)
	await _step(2)


# 2, 3
func _grab_and_throw() -> void:
	_clear()
	var ball := _ball_at(Vector3(9.5, 0.3, 0.2), 0.2)
	var p0 := _play(Vector3(9.5, 0.3, 0.45))       # 5 cm above its surface
	_pose(right, p0)
	await _step(3)
	var cols := _hand_colors()
	U.check("near a ball the hand turns green", _hand(1)["ready"] and cols.has(Hands.COLOR_READY),
			"ready %s, hand colours %s" % [_hand(1)["ready"], cols])
	right.set_input(&"grip", 1.0)
	await _step(1)
	U.check("the grip takes the ball", ball["held"] == &"right_hand" and _hand(1).has("held"), "held by '%s'" % ball["held"])
	# up and away, 1 cm a frame: the ball keeps 25 cm below the hand
	var worst := 0.0
	var p := p0
	for k in 20:
		p += Vector3(0.0, 0.01, -0.01)
		_pose(right, p)
		await _step(1)
		var h := _hand(1)
		var hc: Vector3 = main.space.chart_position(h["l"], h["n"])
		worst = maxf(worst, _at(ball).distance_to(hc + Vector3(0.0, 0.0, -0.25)))
	U.check("the held ball follows the hand", worst < 1e-3, "farthest from its place under the hand %.5f m" % worst)
	# a straight throw: 4 m/s forward, 2 m/s up, let go on the 8th frame
	var v := Vector3(0.0, 2.0, -4.0)
	for k in 8:
		p += v / 60.0
		_pose(right, p)
		if k == 7:
			right.set_input(&"grip", 0.0)
		await _step(1)
	var got := _vel(ball)
	var want := _chart_dir(v)
	U.check("let go, the ball flies off with the hand's velocity", ball["held"] == &"" and got.distance_to(want) < 0.02,
			"chart velocity %s, expected %s" % [got, want])
	var before := _at(ball)
	await _step(12)
	var moved := _at(ball) - before
	U.check("... and keeps flying", absf(moved.x - want.x * 0.2) < 0.03, "0.2 s later %s along chart x (%.2f)" % [moved.x, want.x * 0.2])
	# along an arc: a circle in the room's y-z plane, let go when the hand moves straight up; an
	# average over the last VELOCITY_WINDOW would point back along the arc by half the turn in it
	_clear()
	right.set_input(&"grip", 1.0)
	var c := Vector3(0.2, 1.0, -0.1)
	var w := 8.0
	var th := -1.2
	_pose(right, c + 0.5 * Vector3(0.0, sin(th), -cos(th)))
	await _step(2)
	right.set_input(&"by_button", true)
	await _step(1)
	right.set_input(&"by_button", false)
	var held: Dictionary = _hand(1).get("held", {})
	U.check("right B with the grip closed: a new ball in the right hand", not held.is_empty() and not held.has("F")
			and held["radius"] == Hands.NEW_BALL_RADIUS, "held %s" % [held.keys()])
	for k in 9:
		th = -1.2 + (k + 1) * w / 60.0          # 0 at the last
		_pose(right, c + 0.5 * Vector3(0.0, sin(th), -cos(th)))
		if k == 8:
			right.set_input(&"grip", 0.0)
		await _step(1)
	got = _vel(held)
	want = _chart_dir(0.5 * w * Vector3(0.0, 1.0, 0.0))
	var angle := rad_to_deg(got.angle_to(want))
	U.check("thrown along an arc, the ball leaves along it", angle < 2.0 and absf(got.length() / want.length() - 1.0) < 0.04,
			"%.2f degrees off, speed %.3f m/s (%.3f)" % [angle, got.length(), want.length()])


# 4
func _cube_and_spin() -> void:
	_clear()
	var pl := Vector3(-0.3, 1.2, -0.4)
	_pose(left, pl)
	left.set_input(&"grip", 1.0)
	await _step(2)
	left.set_input(&"ax_button", true)
	await _step(1)
	left.set_input(&"ax_button", false)
	var cube: Dictionary = _hand(0).get("held", {})
	var reach: float = Hands.NEW_CUBE_HALF + Hands.RADIUS + 0.01
	var ok: bool = not cube.is_empty() and cube.has("F") and cube["held"] == &"left_hand"
	U.check("left X with the grip closed: a new cube in the left hand", ok and _at(cube).distance_to(_chart(pl + Vector3(0.0, 0.0, -reach))) < 1e-3,
			"cube at %s, expected %s" % [_at(cube) if ok else Vector3.ZERO, _chart(pl + Vector3(0.0, 0.0, -reach))])
	if not ok:
		return
	# the hand turns about the vertical at 3 rad/s, in place
	var w := 3.0
	var worst := 0.0
	var worst_ax := 0.0
	var th := 0.0
	for k in 16:
		th += w / 60.0
		var b := Basis(Vector3.UP, th)
		_pose(left, pl, b)
		if k == 15:
			left.set_input(&"grip", 0.0)
		await _step(1)
		if k < 15:
			worst = maxf(worst, _at(cube).distance_to(_chart(pl + b * Vector3(0.0, 0.0, -reach))))
			for a in 3:
				var A: Vector3 = WormholeSpace.vector_to_chart(1.0, cube["n"], cube["F"][a])
				worst_ax = maxf(worst_ax, A.distance_to(_chart_dir(b[a])))
	U.check("the held cube turns with the hand", worst < 1e-3 and worst_ax < 1e-3,
			"centre off by %.5f m, axes by %.5f" % [worst, worst_ax])
	var spin: Vector3 = cube["w"]
	var got_v := _vel(cube)
	# with the hand's velocity, not its own: the hand turned in place, so the cube only spins (its
	# centre moved round the hand at the wrist's turn times the lever, which no throw gets)
	U.check("let go, it spins as the hand turned and moves as the hand did (it stood)",
			spin.distance_to(Vector3(0.0, w, 0.0)) < 0.03 * w and got_v.length() < 0.01,
			"spin %s rad/s (body; (0, %.1f, 0)), velocity %s" % [spin, w, got_v])


# 5
func _hand_over() -> void:
	_clear()
	var pr := Vector3(0.3, 1.2, -0.3)
	_pose(right, pr)
	right.set_input(&"grip", 1.0)
	await _step(2)
	right.set_input(&"by_button", true)
	await _step(1)
	right.set_input(&"by_button", false)
	var ball: Dictionary = _hand(1).get("held", {})
	# the left hand at the ball's left side, 5 cm from its surface
	var c := _play(_at(ball))
	_pose(left, c + Vector3(-(Hands.NEW_BALL_RADIUS + 0.05), 0.0, 0.0))
	await _step(2)
	left.set_input(&"grip", 1.0)
	await _step(1)
	U.check("the left hand takes the ball over from the right", ball["held"] == &"left_hand"
			and is_same(_hand(0).get("held"), ball) and not _hand(1).has("held"), "held by '%s'" % ball["held"])
	right.set_input(&"grip", 0.0)
	await _step(2)
	U.check("... and the right grip, let go, throws nothing", ball["held"] == &"left_hand", "held by '%s'" % ball["held"])
	left.set_input(&"grip", 0.0)
	await _step(2)
	U.check("the left lets it go", ball["held"] == &"", "held by '%s'" % ball["held"])


# 6
func _pushes() -> void:
	_clear()
	var ball := _ball_at(Vector3(9.0, 0.0, 0.2), 0.2)
	var cube: Dictionary = main.toys.cube_on_floor(Vector2(9.0, -1.2), 0.15, 0.0, Color.WHITE)
	_pose(left, Vector3(-2.0, 1.0, 0.5))          # out of the way
	# the right hand sweeps along +y (room +x) at 2 m/s through the ball's centre height
	var p := Vector3(-0.5, 0.2, -1.0)
	for k in 30:
		_pose(right, p)
		p += Vector3(2.0 / 60.0, 0.0, 0.0)
		await _step(1)
	var v := _vel(ball)
	U.check("the hand pushes a ball it meets, softly", v.y > 1.5 and v.y < 1.35 * 2.0 and absf(v.x) < 0.3,
			"ball's chart velocity %s (hand 2 m/s)" % v)
	# the left hand through the cube at 1.5 m/s, 10 cm above the floor
	var c0 := _at(cube)
	p = Vector3(-1.6, 0.1, -1.0)
	for k in 30:
		_pose(left, p)
		p += Vector3(1.5 / 60.0, 0.0, 0.0)
		await _step(1)
	_pose(left, Vector3(-2.0, 1.0, 0.5))
	await _step(30)
	var moved := _at(cube) - c0
	U.check("the hand pushes a cube it meets", moved.y > 0.1, "the cube moved %s" % moved)
	# the right hand, held still above a ball, then pressing it into the floor at 0.3 m/s
	_clear()
	_pose(right, Vector3(0.6, 0.5, -1.0))
	await _step(5)
	ball = _ball_at(Vector3(9.0, 0.6, 0.2), 0.2)
	var fastest := 0.0
	for k in 40:
		_pose(right, Vector3(0.6, 0.5 - 0.3 * k / 60.0, -1.0))
		await _step(1)
		fastest = maxf(fastest, _vel(ball).length())
	U.check("a ball pressed into the floor by the hand is not flung", fastest < 0.5, "fastest %.2f m/s (hand 0.3 m/s)" % fastest)
	_pose(right, Vector3(0.6, 1.0, -0.3))
	await _step(5)
	# a held ball against a ball at rest
	_clear()
	var target := _ball_at(Vector3(9.0, 0.0, 0.2), 0.2)
	p = Vector3(-0.8, 0.45, -1.0)
	_pose(right, p)
	right.set_input(&"grip", 1.0)
	await _step(2)
	right.set_input(&"by_button", true)
	await _step(1)
	right.set_input(&"by_button", false)
	for k in 30:
		p += Vector3(2.0 / 60.0, -0.25 / 30.0, 0.0)
		_pose(right, p)
		await _step(1)
	v = _vel(target)
	U.check("a held ball pushes a ball it meets", v.y > 1.0, "the ball's chart velocity %s" % v)
	right.set_input(&"grip", 0.0)
	await _step(2)


# 7
func _grip_and_tracking() -> void:
	_clear()
	var ball := _ball_at(Vector3(9.5, 0.3, 0.2), 0.2)
	var p := _play(Vector3(9.5, 0.3, 0.45))
	_pose(right, p)
	await _step(2)
	right.set_input(&"grip", 1.0)
	await _step(1)
	right.set_input(&"grip", 0.6)
	await _step(3)
	var kept: bool = ball["held"] == &"right_hand"
	right.set_input(&"grip", 0.4)
	await _step(1)
	U.check("a half-open grip keeps the ball, more open lets go", kept and ball["held"] == &"", "kept %s, then held by '%s'" % [kept, ball["held"]])
	right.set_input(&"grip", 1.0)
	await _step(1)
	for k in 10:
		p += Vector3(0.0, 0.03, 0.0)
		_pose(right, p)
		await _step(1)
	_pose(right, p, Basis.IDENTITY, false)
	await _step(1)
	var at := _at(ball)
	await _step(10)
	var nb: int = main.tracer.material.get_shader_parameter("wh_nBall")
	U.check("a hand that loses its tracking leaves its ball where it was", ball["held"] == &"right_hand"
			and _at(ball).distance_to(at) < 1e-6 and nb == 2, "moved %.6f m, shader balls %d (the ball and the left hand)" % [_at(ball).distance_to(at), nb])
	# at rest there: a ball set on it is not flung with the velocity the hand last had
	var other := _ball_at(at + Vector3(0.0, 0.0, 0.39), 0.2)
	await _step(3)
	U.check("... at rest: it pushes nothing with the hand's last velocity", ball["U"] == Vector4.ZERO
			and _vel(other).length() < 0.5, "its velocity %s, the ball on it %s" % [ball["U"], _vel(other)])
	main.toys.world.balls.erase(other)
	right.set_input(&"grip", 0.0)
	await _step(1)
	U.check("... and let go then, it falls from rest", ball["held"] == &"" and _vel(ball).length() < 0.2, "chart velocity %s" % _vel(ball))
	_pose(right, p)


# 8
func _hold_and_reset() -> void:
	_clear()
	var ball := _ball_at(Vector3(9.5, 0.3, 0.2), 0.2)
	_pose(right, _play(Vector3(9.5, 0.3, 0.45)))
	await _step(2)
	main.hold = true
	right.set_input(&"grip", 1.0)
	await _step(2)
	right.set_input(&"by_button", true)
	left.set_input(&"grip", 1.0)
	left.set_input(&"ax_button", true)
	await _step(2)
	right.set_input(&"by_button", false)
	left.set_input(&"ax_button", false)
	var nb: int = main.tracer.material.get_shader_parameter("wh_nBall")
	U.check("during the speed check: no hands drawn, no grab, B and X make nothing",
			nb == 1 and ball["held"] == &"" and main.toys.world.balls.size() == 1 and main.toys.world.cubes.is_empty(),
			"shader balls %d, held by '%s', %d balls, %d cubes" % [nb, ball["held"], main.toys.world.balls.size(), main.toys.world.cubes.size()])
	main.hold = false
	# the menu open: B, X and the D-pad down are its, and A; B closes it and makes no ball
	_pose(left, _play(Vector3(9.5, -0.6, 0.45)))
	left.set_input(&"menu_button", true)
	await _step(2)
	left.set_input(&"menu_button", false)
	var opened: bool = main.menu.open
	left.set_input(&"ax_button", true)
	left.set_input(&"dpad_down", true)
	right.set_input(&"ax_button", true)
	await _step(2)
	left.set_input(&"ax_button", false)
	left.set_input(&"dpad_down", false)
	right.set_input(&"ax_button", false)
	await _step(2)
	right.set_input(&"by_button", true)
	await _step(2)
	right.set_input(&"by_button", false)
	await _step(2)
	U.check("menu open: X, the D-pad down and A make nothing, the B that closes it no ball",
			opened and not main.menu.open and main.toys.world.balls.size() == 1 and main.toys.world.cubes.is_empty(),
			"opened %s, open %s, %d balls, %d cubes" % [opened, main.menu.open, main.toys.world.balls.size(), main.toys.world.cubes.size()])
	left.set_input(&"dpad_down", true)
	await _step(1)
	left.set_input(&"dpad_down", false)
	await _step(1)
	U.check("menu closed: the D-pad down puts a new cube in the left hand", main.toys.world.cubes.size() == 1
			and _hand(0).has("held") and _hand(0)["held"].has("F"), "%d cubes" % main.toys.world.cubes.size())
	right.set_input(&"grip", 0.0)
	left.set_input(&"grip", 0.0)
	await _step(2)
	right.set_input(&"grip", 1.0)
	await _step(2)
	var took: bool = ball["held"] == &"right_hand"
	right.set_input(&"ax_button", true)
	await _step(1)
	right.set_input(&"ax_button", false)
	await _step(1)
	var free := true
	for b in main.toys.world.balls + main.toys.world.cubes:
		free = free and b["held"] == &""
	U.check("A puts everything back and empties the hands", took and free and not _hand(1).has("held")
			and [main.toys.world.balls.size(), main.toys.world.cubes.size()] == spawned,
			"took %s, %d balls, %d cubes, all free %s" % [took, main.toys.world.balls.size(), main.toys.world.cubes.size(), free])
	right.set_input(&"grip", 0.0)
	await _step(1)


# 9
func _throat() -> void:
	_clear()
	main.place_on_axis(0.0, 90.0)
	var sp: WormholeSpace = main.space
	var p := Vector3(0.25, 1.3, -0.45)
	_pose(right, p)
	_pose(left, Vector3(-2.0, 1.0, 0.5))
	right.set_input(&"grip", 1.0)
	await _step(2)
	right.set_input(&"by_button", true)
	await _step(1)
	right.set_input(&"by_button", false)
	var ball: Dictionary = _hand(1).get("held", {})
	if ball.is_empty():
		U.check("a new ball in the hand in the throat", false, "none")
		return
	# hand and head: the geodesic between them is as long as the hand is from the head in the room
	var h := _hand(1)
	var head_l: float = main.tracer.material.get_shader_parameter("head_l")
	var head_n: Vector3 = main.tracer.material.get_shader_parameter("head_n")
	var gap := sp.toward(head_l, head_n, h["l"], h["n"]).length()
	U.check("in the throat the hand is the room's distance from the head along the space", absf(gap - (p - HEAD).length()) < 1e-3,
			"%.4f m (%.4f)" % [gap, (p - HEAD).length()])
	# round and turning, 30 frames: the ball keeps its offset in the hand's axes
	var off: Vector3 = h["off"]
	var worst := 0.0
	var p0 := p
	for k in 30:
		var t := (k + 1) / 60.0
		var b := Basis.from_euler(Vector3(0.8 * sin(5.0 * t), 2.5 * t, 0.3 * t))
		p = p0 + Vector3(0.3 * sin(4.0 * t), 0.2 * (1.0 - cos(4.0 * t)), -0.2 * t)
		_pose(right, p, b)
		await _step(1)
		h = _hand(1)
		var D := sp.toward(h["l"], h["n"], ball["l"], ball["n"])
		worst = maxf(worst, BallWorld.to_body(h["F"], D).distance_to(off))
	U.check("in the throat the held ball keeps its offset in the hand's axes", worst < 1e-3,
			"off by %.5f m at most (offset %.3f m)" % [worst, off.length()])
	# a straight move at constant speed, let go: the ball leaves the hand smoothly
	var v := Vector3(0.0, 0.5, -3.0)
	var E := []
	for k in 10:
		p += v / 60.0
		_pose(right, p, Basis.from_euler(Vector3(0.8 * sin(2.5), 1.25, 0.15)))
		if k == 7:
			right.set_input(&"grip", 0.0)
		await _step(1)
		E.append(sp.embed(ball["l"], ball["n"]))
	var before: Vector4 = (E[7] - E[6]) * 60.0
	var after: Vector4 = (E[8] - E[7]) * 60.0
	U.check("in the throat the ball leaves the hand smoothly", ball["held"] == &"" and (after - before).length() < 0.1,
			"%.3f m/s in the hand, %.3f m/s just after, apart by %.3f" % [before.length(), after.length(), (after - before).length()])
	main.place(main.START_POS, main.START_FORWARD)
	await _step(1)


# 10
func _into_b() -> void:
	_clear()
	var p := Vector3(0.25, 1.3, -0.3)
	_pose(right, p)
	right.set_input(&"grip", 1.0)
	await _step(2)
	right.set_input(&"by_button", true)
	await _step(1)
	right.set_input(&"by_button", false)
	var ball: Dictionary = _hand(1).get("held", {})
	var v := Vector3(-0.15, 1.0, -8.0)
	for k in 8:
		p += v / 60.0
		_pose(right, p)
		if k == 7:
			right.set_input(&"grip", 0.0)
		await _step(1)
	_pose(right, Vector3(0.25, 1.0, -0.3))
	await _step(240)
	U.check("a ball thrown from the start toward the wormhole ends up in universe B",
			not ball.is_empty() and ball["l"] < -main.space.L, "l = %.2f (universe B: below %.2f)" % [ball.get("l", 0.0), -main.space.L])


# 11
func _set_down() -> void:
	_clear()
	var sp: WormholeSpace = main.space
	# feet 1.2 m outside the shell's edge (chart radius Rout), facing the throat
	main.place(Vector3(sp.Rout + 1.2, 0.0, 0.0), Vector3(-1.0, 0.0, 0.0))
	_pose(left, Vector3(-2.0, 1.0, 0.5))
	var p := Vector3(0.0, 0.8, -1.1)
	_pose(right, p)
	await _step(3)
	# a ball whose centre is 10 cm in front of the hand: the hand is inside it
	var rad := 0.2
	var c: Array = sp.point_from_chart(1.0, Vector3(sp.Rout, 0.0, 0.8))
	var ball: Dictionary = main.toys.world.add(c[0], c[1], Vector4.ZERO, rad, Color(0.95, 0.95, 0.97))
	right.set_input(&"grip", 1.0)
	await _step(1)
	if ball["held"] != &"right_hand":
		U.check("a ball at the shell's edge taken", false, "held by '%s'" % ball["held"])
		return
	# down at 0.3 m/s until the ball is 1 cm above the floor, still for half a second, let go
	while p.y > rad + 0.01:
		p.y = maxf(p.y - 0.3 / 60.0, rad + 0.01)
		_pose(right, p)
		await _step(1)
	await _step(30)
	right.set_input(&"grip", 0.0)
	await _step(1)
	var E0: Vector4 = sp.embed(ball["l"], ball["n"])
	var v0 := _vel(ball).length()
	U.check("let go with the hand still, the ball is set down at rest", ball["held"] == &"" and v0 < 1e-3,
			"%.4f m/s, at l = %.3f (the edge %.3f)" % [v0, ball["l"], sp.L])
	await _step(20)
	var moved: float = (sp.embed(ball["l"], ball["n"]) - E0).length()
	U.check("the hand that let it go, still inside it, does not push it", moved < 0.01,
			"moved %.4f m in 1/3 s, %.3f m/s" % [moved, _vel(ball).length()])
	var l0: float = ball["l"]
	_pose(right, Vector3(0.6, 1.2, -0.3))
	await _step(8 * 60)
	U.check("set down at the shell's edge, the ball rolls toward the throat by itself", l0 - ball["l"] > 0.2,
			"l %.3f -> %.3f in 8 s, %.3f m/s" % [l0, ball["l"], _vel(ball).length()])
