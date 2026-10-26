extends SceneTree
## Grabbing and throwing balls and cubes with the controllers' grips, through the code path the
## headset uses: the simulated headset (tests/fake_hmd.gd) and two controller trackers whose grip
## poses and inputs the test sets by the action names of openxr_action_map.tres. Run with
## --fixed-fps 60 under a display (xvfb-run: it looks at the left eye's picture); exit status 1
## on any failure:
##   godot --path . --fixed-fps 60 -s res://tests/grab_test.gd
## 0. the action map binds grip, haptic, right B and left X (the Frame's own profile: the D-pad
##    down) on the profiles the Frame may use
## 1. each hand is a ball on the curved space, where the controller's grip is; the shader gets
##    them, the stencil's proxies cover them, and the left eye sees the hand's ball where it is
## 2. near a ball the hand turns green; the grip takes the ball, which follows the hand (a light
##    ball: within a few mm, the hand's strength is ample)
## 3. let go while the hand moves, the ball flies off with the motion it has, the hand's: along a
##    line, and along an arc (no lag: the direction right)
## 4. left X with the grip closed: a new cube in the left hand; it turns with the hand, and let go
##    it spins as the hand turned and its centre moves round the hand as it did
## 5. right B with the grip closed: a new ball in the right hand; the left hand takes it too, both
##    hold it, then each lets go
## 6. the hand pushes a ball and a cube it meets, softly (a ball at most 1.3 times the hand's speed;
##    one pressed into the floor is not flung); a held ball pushes a ball
## 7. a half-open grip keeps holding, more open lets go; a hand that loses its tracking leaves its
##    ball in the air, and let go then it falls from rest
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
## 12. the hand's finite strength: a flick of the wrist (38 rad/s) spins a light cube far slower
##     than the hand turned, a heavy one hardly; a held ball is not pushed through the floor; a big
##     heavy ball held at its side sags and stays there; the crate is too heavy for one hand, two at
##     its sides lift it level

const SIZE := 160                    # each eye's picture
const FRUSTUM := Vector4(-1.0, 1.0, -1.1, 1.1)
const IPD := 0.064
const HEAD := Vector3(0.0, 1.6, 0.0)
# action name -> binding paths the action map must have for it, per profile
const BINDINGS := {
	"/interaction_profiles/valve/frame_controller_valve": {
		"grip": ["/user/hand/left/input/squeeze/value", "/user/hand/right/input/squeeze/value"],
		"grip_pose": ["/user/hand/left/input/grip/pose", "/user/hand/right/input/grip/pose"],
		"haptic": ["/user/hand/left/output/haptic", "/user/hand/right/output/haptic"],
		"by_button": ["/user/hand/right/input/b/click"],
		"dpad_down": ["/user/hand/left/input/dpad_down/click"],
	},
	"/interaction_profiles/khr/generic_controller": {
		"grip": ["/user/hand/left/input/squeeze/value", "/user/hand/right/input/squeeze/value"],
		"grip_pose": ["/user/hand/left/input/grip/pose", "/user/hand/right/input/grip/pose"],
		"haptic": ["/user/hand/left/output/haptic", "/user/hand/right/output/haptic"],
		"by_button": ["/user/hand/right/input/secondary/click"],
		"ax_button": ["/user/hand/left/input/primary/click"],
	},
	"/interaction_profiles/oculus/touch_controller": {
		"grip": ["/user/hand/left/input/squeeze/value", "/user/hand/right/input/squeeze/value"],
		"grip_pose": ["/user/hand/left/input/grip/pose", "/user/hand/right/input/grip/pose"],
		"by_button": ["/user/hand/right/input/b/click"],
		"ax_button": ["/user/hand/left/input/x/click"],
	},
	"/interaction_profiles/valve/index_controller": {
		"grip": ["/user/hand/left/input/squeeze/value", "/user/hand/right/input/squeeze/value"],
		"grip_pose": ["/user/hand/left/input/grip/pose", "/user/hand/right/input/grip/pose"],
		"by_button": ["/user/hand/right/input/b/click"],
		"ax_button": ["/user/hand/left/input/a/click"],
	},
}

var main: Node3D
var hmd
var left: XRControllerTracker
var right: XRControllerTracker
var fails := 0


func _initialize() -> void:
	hmd = preload("res://tests/fake_hmd.gd").new()
	hmd.size = Vector2i(SIZE, SIZE)
	hmd.setup(Transform3D(Basis.IDENTITY, HEAD), IPD, 0.0, FRUSTUM)
	XRServer.add_interface(hmd)
	hmd.initialize()
	XRServer.primary_interface = hmd
	left = _controller(&"left_hand")
	right = _controller(&"right_hand")
	main = load("res://main.tscn").instantiate()
	main.xr_name = "FakeHMD"
	main.throw_toys = false
	root.add_child(main)
	_run()


func _controller(tracker_name: StringName) -> XRControllerTracker:
	var t := XRControllerTracker.new()
	t.name = tracker_name
	t.profile = "/interaction_profiles/khr/generic_controller"   # as the Frame's come
	for b in [&"primary_click", &"ax_button", &"by_button", &"menu_button", &"dpad_down"]:
		t.set_input(b, false)
	t.set_input(&"primary", Vector2.ZERO)
	t.set_input(&"trigger", 0.0)
	t.set_input(&"grip", 0.0)
	XRServer.add_tracker(t)
	return t


func _check(name: String, ok: bool, detail: String) -> void:
	print(("PASS " if ok else "FAIL ") + name + "  " + detail)
	if not ok:
		fails += 1


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


## The room against chart A at the start (feet at (10, 0), facing -x, the head above the room's
## origin): right is +y, up +z, back +x.
static func _chart(p: Vector3) -> Vector3:
	return Vector3(10.0 + p.z, p.x, p.y)


static func _play(c: Vector3) -> Vector3:
	return Vector3(c.y, c.z, c.x - 10.0)


static func _chart_dir(v: Vector3) -> Vector3:
	return Vector3(v.z, v.x, v.y)


func _at(b: Dictionary) -> Vector3:
	return main.space.chart_position(b["l"], b["n"])


func _vel(b: Dictionary) -> Vector3:
	return WormholeSpace.vector_to_chart(signf(b["l"]), b["n"], b["U"])


func _hand(i: int) -> Dictionary:
	return main.hand_state[i]


func _ball_at(c: Vector3, radius: float) -> Dictionary:
	var p: Array = main.space.point_from_chart(1.0, c)
	return main.world.add(p[0], p[1], Vector4.ZERO, radius, Color(0.9, 0.2, 0.2))


func _clear() -> void:
	for st in main.hand_state:
		st.erase("held")
	main.world.balls.clear()
	main.world.cubes.clear()


## The hands' colours the shader got (the balls of the hands' radius).
func _hand_colors() -> Array:
	var out := []
	var col: PackedVector4Array = main.material.get_shader_parameter("wh_ballCol")
	var n: int = main.material.get_shader_parameter("wh_nBall")
	for k in n:
		if absf(col[k].w - main.HAND_RADIUS) < 1e-6:
			out.append(Color(col[k].x, col[k].y, col[k].z))
	return out


func _left_eye() -> Image:
	var img: Image = RenderingServer.texture_2d_layer_get(main.xr_view.get_texture().get_rid(), 0)
	img.convert(Image.FORMAT_RGB8)
	return img


func _run() -> void:
	await _step(3)
	_check_action_map()
	_check("main runs in XR, so it reads the controllers", main.in_xr, "in_xr %s" % main.in_xr)
	main.perf.visible = false        # it follows the head: in every view
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
	await _strength()
	print("FAILURES: ", fails)
	_finish()


func _check_action_map() -> void:
	var am: OpenXRActionMap = load("res://openxr_action_map.tres")
	for path: String in BINDINGS:
		var profile := am.find_interaction_profile(path)
		if profile == null:
			_check("action map has " + path, false, "no such profile")
			continue
		for action: String in BINDINGS[path]:
			var have := PackedStringArray()
			for i in profile.get_binding_count():
				var b := profile.get_binding(i)
				if b.action and b.action.resource_name == action:
					have.append(b.binding_path)
			var missing := PackedStringArray()
			for p: String in BINDINGS[path][action]:
				if not have.has(p):
					missing.append(p)
			_check("%s: %s" % [path.get_file(), action], missing.is_empty(), "bound to %s, missing %s" % [have, missing])


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
	_check("each hand where its grip is, on the curved space", ok, detail)
	var nb: int = main.material.get_shader_parameter("wh_nBall")
	var proxies: int = main.proxy_spheres(main.foot_l).size()
	_check("the shader draws both hands, the stencil's proxies cover them", nb == 2 and proxies == 3,
			"shader balls %d (2), proxies %d (the shell and 2 hands)" % [nb, proxies])
	# the left eye's picture with the right hand and without it
	var with_hand := _left_eye()
	_pose(right, pr, Basis.IDENTITY, false)
	await _step(3)
	_check("a hand that loses its tracking is not drawn", main.material.get_shader_parameter("wh_nBall") == 1,
			"shader balls %d" % main.material.get_shader_parameter("wh_nBall"))
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
	var rx: float = main.HAND_RADIUS / d.length() * 0.5 * SIZE
	var area := PI * rx * rx / FRUSTUM.w
	_check("the left eye sees the hand's ball where the hand is", count > 0 and got.distance_to(want) < 2.0
			and count > 0.6 * area and count < 2.0 * area,
			"centre of the changed pixels %s, expected %s; %d pixels (a disc of about %.0f)" % [got, want, count, area])
	hue /= maxf(count, 1)
	_check("an empty hand is grey-blue", hue.z > hue.x, "mean colour %s" % hue)
	_pose(right, pr)
	await _step(2)


# 2, 3
func _grab_and_throw() -> void:
	_clear()
	var ball := _ball_at(Vector3(9.5, 0.3, 0.2), 0.2)
	var p0 := _play(Vector3(9.5, 0.3, 0.45))       # 5 cm above its surface
	_pose(right, p0)
	await _step(6)              # the jump there is over (it would be the hand's motion as it starts)
	var cols := _hand_colors()
	_check("near a ball the hand turns green", _hand(1)["ready"] and cols.has(main.HAND_COLOR_READY),
			"ready %s, hand colours %s" % [_hand(1)["ready"], cols])
	right.set_input(&"grip", 1.0)
	await _step(1)
	_check("the grip takes the ball", ball["holds"].has(&"right_hand") and _hand(1).has("held"), "held by %s" % [ball["holds"].keys()])
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
	_check("the held ball follows the hand", worst < 5e-3, "farthest from its place under the hand %.5f m" % worst)
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
	_check("let go, the ball flies off with the hand's velocity", ball["holds"].is_empty() and got.distance_to(want) < 0.05,
			"chart velocity %s, expected %s" % [got, want])
	var before := _at(ball)
	await _step(12)
	var moved := _at(ball) - before
	_check("... and keeps flying", absf(moved.x - want.x * 0.2) < 0.03, "0.2 s later %s along chart x (%.2f)" % [moved.x, want.x * 0.2])
	# along an arc: a circle of 0.5 m in the room's y-z plane at 8 rad/s, let go when the hand moves
	# straight up; an average over the last 60 ms would point 14 degrees back along the arc
	_clear()
	right.set_input(&"grip", 1.0)
	var c := Vector3(0.2, 1.0, -0.1)
	var w := 8.0
	var th := -1.2
	_pose(right, c + 0.5 * Vector3(0.0, sin(th), -cos(th)))
	await _step(6)
	right.set_input(&"by_button", true)
	await _step(1)
	right.set_input(&"by_button", false)
	var held: Dictionary = _hand(1).get("held", {})
	_check("right B with the grip closed: a new ball in the right hand", not held.is_empty() and not held.has("F")
			and held["radius"] == main.NEW_BALL_RADIUS, "held %s" % [held.keys()])
	for k in 9:
		th = -1.2 + (k + 1) * w / 60.0          # 0 at the last
		_pose(right, c + 0.5 * Vector3(0.0, sin(th), -cos(th)))
		if k == 8:
			right.set_input(&"grip", 0.0)
		await _step(1)
	got = _vel(held)
	want = _chart_dir(0.5 * w * Vector3(0.0, 1.0, 0.0))
	var angle := rad_to_deg(got.angle_to(want))
	_check("thrown along an arc, the ball leaves along it", angle < 2.0 and absf(got.length() / want.length() - 1.0) < 0.04,
			"%.2f degrees off, speed %.3f m/s (%.3f)" % [angle, got.length(), want.length()])


# 4
func _cube_and_spin() -> void:
	_clear()
	var pl := Vector3(-0.3, 1.2, -0.4)
	_pose(left, pl)
	left.set_input(&"grip", 1.0)
	await _step(6)
	left.set_input(&"ax_button", true)
	await _step(1)
	left.set_input(&"ax_button", false)
	var cube: Dictionary = _hand(0).get("held", {})
	var reach: float = main.NEW_CUBE_HALF + main.HAND_RADIUS + 0.01
	var ok: bool = not cube.is_empty() and cube.has("F") and cube["holds"].has(&"left_hand")
	_check("left X with the grip closed: a new cube in the left hand", ok and _at(cube).distance_to(_chart(pl + Vector3(0.0, 0.0, -reach))) < 1e-3,
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
	# the hand starts turning at once: the cube lags while the hand's spin is learned (60 ms)
	_check("the held cube turns with the hand", worst < 5e-3 and worst_ax < 0.01,
			"centre off by %.5f m, axes by %.5f" % [worst, worst_ax])
	var spin: Vector3 = cube["w"]
	var got_v := _vel(cube)
	# its centre went round the hand at the hand's spin: it leaves at the spin times the lever
	var want_v := Vector3(0.0, 0.0, w).cross(_at(cube) - _chart(pl))
	_check("let go, it spins as the hand turned, its centre moves round the hand as it did",
			spin.distance_to(Vector3(0.0, w, 0.0)) < 0.05 * w and got_v.distance_to(want_v) < 0.05 * want_v.length(),
			"spin %s rad/s (body; (0, %.1f, 0)), velocity %s (%s)" % [spin, w, got_v, want_v])


# 5
func _hand_over() -> void:
	_clear()
	var pr := Vector3(0.3, 1.2, -0.3)
	_pose(right, pr)
	right.set_input(&"grip", 1.0)
	await _step(6)
	right.set_input(&"by_button", true)
	await _step(1)
	right.set_input(&"by_button", false)
	var ball: Dictionary = _hand(1).get("held", {})
	# the left hand at the ball's left side, 5 cm from its surface
	var c := _play(_at(ball))
	_pose(left, c + Vector3(-(main.NEW_BALL_RADIUS + 0.05), 0.0, 0.0))
	await _step(2)
	left.set_input(&"grip", 1.0)
	await _step(1)
	_check("the left hand takes the ball too: both hold it", ball["holds"].size() == 2
			and is_same(_hand(0).get("held"), ball) and is_same(_hand(1).get("held"), ball), "held by %s" % [ball["holds"].keys()])
	right.set_input(&"grip", 0.0)
	await _step(2)
	_check("... the right lets go, the left keeps it", ball["holds"].keys() == [&"left_hand"] and not _hand(1).has("held"),
			"held by %s" % [ball["holds"].keys()])
	left.set_input(&"grip", 0.0)
	await _step(2)
	_check("the left lets it go", ball["holds"].is_empty(), "held by %s" % [ball["holds"].keys()])


# 6
func _pushes() -> void:
	_clear()
	var ball := _ball_at(Vector3(9.0, 0.0, 0.2), 0.2)
	var cube: Dictionary = main._cube_on_floor(Vector2(9.0, -1.2), 0.15, 0.0, Color.WHITE)
	_pose(left, Vector3(-2.0, 1.0, 0.5))          # out of the way
	# the right hand sweeps along +y (room +x) at 2 m/s through the ball's centre height
	var p := Vector3(-0.5, 0.2, -1.0)
	for k in 30:
		_pose(right, p)
		p += Vector3(2.0 / 60.0, 0.0, 0.0)
		await _step(1)
	var v := _vel(ball)
	_check("the hand pushes a ball it meets, softly", v.y > 1.5 and v.y < 1.35 * 2.0 and absf(v.x) < 0.3,
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
	_check("the hand pushes a cube it meets", moved.y > 0.1, "the cube moved %s" % moved)
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
	_check("a ball pressed into the floor by the hand is not flung", fastest < 0.5, "fastest %.2f m/s (hand 0.3 m/s)" % fastest)
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
	_check("a held ball pushes a ball it meets", v.y > 1.0, "the ball's chart velocity %s" % v)
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
	var kept: bool = ball["holds"].has(&"right_hand")
	right.set_input(&"grip", 0.4)
	await _step(1)
	_check("a half-open grip keeps the ball, more open lets go", kept and ball["holds"].is_empty(), "kept %s, then held by %s" % [kept, ball["holds"].keys()])
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
	var nb: int = main.material.get_shader_parameter("wh_nBall")
	# it moved up at 1.8 m/s: the hand stops it where it last was
	_check("a hand that loses its tracking keeps its ball where it was", ball["holds"].has(&"right_hand")
			and _at(ball).distance_to(at) < 0.03 and nb == 2, "moved %.4f m, shader balls %d (the ball and the left hand)" % [_at(ball).distance_to(at), nb])
	right.set_input(&"grip", 0.0)
	await _step(1)
	_check("... and let go then, it falls from rest", ball["holds"].is_empty() and _vel(ball).length() < 0.2, "chart velocity %s" % _vel(ball))
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
	var nb: int = main.material.get_shader_parameter("wh_nBall")
	_check("during the speed check: no hands drawn, no grab, B and X make nothing",
			nb == 1 and ball["holds"].is_empty() and main.world.balls.size() == 1 and main.world.cubes.is_empty(),
			"shader balls %d, held by %s, %d balls, %d cubes" % [nb, ball["holds"].keys(), main.world.balls.size(), main.world.cubes.size()])
	main.hold = false
	# the menu open: B, X and the D-pad down are its, and A; B closes it and makes no ball
	_pose(left, _play(Vector3(9.5, -0.6, 0.45)))
	left.set_input(&"menu_button", true)
	await _step(2)
	left.set_input(&"menu_button", false)
	var opened: bool = main.perf.open
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
	_check("menu open: X, the D-pad down and A make nothing, the B that closes it no ball",
			opened and not main.perf.open and main.world.balls.size() == 1 and main.world.cubes.is_empty(),
			"opened %s, open %s, %d balls, %d cubes" % [opened, main.perf.open, main.world.balls.size(), main.world.cubes.size()])
	left.set_input(&"dpad_down", true)
	await _step(1)
	left.set_input(&"dpad_down", false)
	await _step(1)
	_check("menu closed: the D-pad down puts a new cube in the left hand", main.world.cubes.size() == 1
			and _hand(0).has("held") and _hand(0)["held"].has("F"), "%d cubes" % main.world.cubes.size())
	right.set_input(&"grip", 0.0)
	left.set_input(&"grip", 0.0)
	await _step(2)
	right.set_input(&"grip", 1.0)
	await _step(2)
	var took: bool = ball["holds"].has(&"right_hand")
	right.set_input(&"ax_button", true)
	await _step(1)
	right.set_input(&"ax_button", false)
	await _step(1)
	var free := true
	for b in main.world.balls + main.world.cubes:
		free = free and b["holds"].is_empty()
	_check("A puts everything back and empties the hands", took and free and not _hand(1).has("held")
			and main.world.balls.size() == 5 and main.world.cubes.size() == 4,
			"took %s, %d balls, %d cubes, all free %s" % [took, main.world.balls.size(), main.world.cubes.size(), free])
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
	await _step(6)
	right.set_input(&"by_button", true)
	await _step(1)
	right.set_input(&"by_button", false)
	var ball: Dictionary = _hand(1).get("held", {})
	if ball.is_empty():
		_check("a new ball in the hand in the throat", false, "none")
		return
	# hand and head: the geodesic between them is as long as the hand is from the head in the room
	var h := _hand(1)
	var head_l: float = main.material.get_shader_parameter("head_l")
	var head_n: Vector3 = main.material.get_shader_parameter("head_n")
	var gap := sp.toward(head_l, head_n, h["l"], h["n"]).length()
	_check("in the throat the hand is the room's distance from the head along the space", absf(gap - (p - HEAD).length()) < 1e-3,
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
	# the hand starts moving at once: the ball lags while the hand's motion is learned (60 ms)
	_check("in the throat the held ball keeps its offset in the hand's axes", worst < 0.01,
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
	_check("in the throat the ball leaves the hand smoothly", ball["holds"].is_empty() and (after - before).length() < 0.1,
			"%.3f m/s in the hand, %.3f m/s just after, apart by %.3f" % [before.length(), after.length(), (after - before).length()])
	main.place(1.0, main.START_POS, main.START_FORWARD)
	await _step(1)


# 10
func _into_b() -> void:
	_clear()
	var p := Vector3(0.25, 1.3, -0.3)
	_pose(right, p)
	right.set_input(&"grip", 1.0)
	await _step(6)
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
	_check("a ball thrown from the start toward the wormhole ends up in universe B",
			not ball.is_empty() and ball["l"] < -main.space.L, "l = %.2f (universe B: below %.2f)" % [ball.get("l", 0.0), -main.space.L])


# 11
func _set_down() -> void:
	_clear()
	var sp: WormholeSpace = main.space
	# feet 1.2 m outside the shell's edge (chart radius Rout), facing the throat
	main.place(1.0, Vector3(sp.Rout + 1.2, 0.0, 0.0), Vector3(-1.0, 0.0, 0.0))
	_pose(left, Vector3(-2.0, 1.0, 0.5))
	var p := Vector3(0.0, 0.8, -1.1)
	_pose(right, p)
	await _step(3)
	# a ball whose centre is 10 cm in front of the hand: the hand is inside it
	var rad := 0.2
	var c: Array = sp.point_from_chart(1.0, Vector3(sp.Rout, 0.0, 0.8))
	var ball: Dictionary = main.world.add(c[0], c[1], Vector4.ZERO, rad, Color(0.95, 0.95, 0.97))
	right.set_input(&"grip", 1.0)
	await _step(1)
	if not ball["holds"].has(&"right_hand"):
		_check("a ball at the shell's edge taken", false, "held by %s" % [ball["holds"].keys()])
		return
	# down at 0.3 m/s until the ball touches the floor, still for half a second, let go
	while p.y > rad + 0.0025:          # (p is single precision)
		p.y = maxf(p.y - 0.3 / 60.0, rad + 0.002)
		_pose(right, p)
		await _step(1)
	await _step(30)
	right.set_input(&"grip", 0.0)
	await _step(1)
	var E0: Vector4 = sp.embed(ball["l"], ball["n"])
	var v0 := _vel(ball).length()
	_check("let go with the hand still, the ball is set down at rest", ball["holds"].is_empty() and v0 < 1e-3,
			"%.4f m/s, at l = %.3f (the edge %.3f)" % [v0, ball["l"], sp.L])
	await _step(20)
	var moved: float = (sp.embed(ball["l"], ball["n"]) - E0).length()
	_check("the hand that let it go, still inside it, does not push it", moved < 0.01,
			"moved %.4f m in 1/3 s, %.3f m/s" % [moved, _vel(ball).length()])
	var l0: float = ball["l"]
	_pose(right, Vector3(0.6, 1.2, -0.3))
	await _step(8 * 60)
	_check("set down at the shell's edge, the ball rolls toward the throat by itself", l0 - ball["l"] > 0.2,
			"l %.3f -> %.3f in 8 s, %.3f m/s" % [l0, ball["l"], _vel(ball).length()])


# 12
func _strength() -> void:
	_clear()
	main.place(1.0, main.START_POS, main.START_FORWARD)
	_pose(right, Vector3(1.0, 1.5, 0.3))
	_pose(left, Vector3(-2.0, 1.0, 0.5))
	await _step(2)
	# a flick of the wrist: 90 degrees up about the room's x at 38 rad/s (the headset's log), let go
	# at its end; a light cube (0.7 kg) and a heavy one (3 kg), held at a face
	var spins := []
	for half in [0.15, 0.25]:
		_clear()
		var pl := Vector3(-0.3, 1.2, -0.4)
		_pose(left, pl)
		await _step(2)
		var p: Array = main.space.point_from_chart(1.0, _chart(pl) + Vector3(-(half + 0.06), 0.0, 0.0))
		var F := []
		for ax in [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)]:
			F.append(WormholeSpace.vector_from_chart(1.0, p[1], ax))
		var cube: Dictionary = main.world.add_cube(p[0], p[1], Vector4.ZERO, F, Vector3.ZERO, half, Color.WHITE)
		left.set_input(&"grip", 1.0)
		await _step(30)
		var th := 0.0
		for k in 3:
			th = minf(th + 38.0 / 60.0, PI / 2.0)
			_pose(left, pl, Basis(Vector3.RIGHT, th))
			if k == 2:
				left.set_input(&"grip", 0.0)
			await _step(1)
		spins.append(cube["w"].length())
		_pose(left, Vector3(-2.0, 1.0, 0.5))
	_check("a flick of the wrist at 38 rad/s spins a light cube far slower, a heavy one hardly",
			spins[0] > 3.0 and spins[0] < 11.0 and spins[1] < 3.0,
			"0.7 kg: %.1f rad/s, 3 kg: %.1f rad/s" % spins)
	# a ball held off the hand (B: 0.25 m in front), thrown by a flick of the wrist alone: it leaves
	# a little faster than the hand (which stands), not at the flick times the lever (9.5 m/s)
	_clear()
	var pr := Vector3(0.2, 1.2, -0.4)
	_pose(right, pr)
	right.set_input(&"grip", 1.0)
	await _step(2)
	right.set_input(&"by_button", true)
	await _step(1)
	right.set_input(&"by_button", false)
	var ball: Dictionary = _hand(1).get("held", {})
	await _step(20)
	var th := 0.0
	for k in 3:
		th = minf(th + 38.0 / 60.0, PI / 2.0)
		_pose(right, pr, Basis(Vector3.RIGHT, -th))
		if k == 2:
			right.set_input(&"grip", 0.0)
		await _step(1)
	_check("a ball held off the hand, flicked by the wrist alone, leaves slowly", not ball.is_empty()
			and _vel(ball).length() < 4.0, "%.2f m/s (the flick times the lever: 9.5)" % _vel(ball).length())
	# a held ball pressed 0.3 m into the floor: the floor holds it
	_clear()
	var p := Vector3(0.2, 0.6, -0.5)
	_pose(right, p)
	right.set_input(&"grip", 1.0)
	await _step(2)
	right.set_input(&"by_button", true)
	await _step(1)
	right.set_input(&"by_button", false)
	ball = _hand(1).get("held", {})
	var lowest := 9.0
	for k in 60:
		_pose(right, Vector3(0.2, 0.6 - 0.9 * minf(k / 30.0, 1.0), -0.5))
		await _step(1)
		lowest = minf(lowest, _at(ball).z)
	_check("a held ball pressed into the floor stays on it", not ball.is_empty() and lowest > ball["radius"] - 0.01,
			"its centre down to %.3f m (radius %.2f)" % [lowest, ball.get("radius", 0.0)])
	right.set_input(&"grip", 0.0)
	await _step(2)
	# a big ball (4.5 kg) taken at its side: its weight's lever is more than the wrist holds, so it
	# sinks below the hand (slowly: the stretched wrist brakes it) until the wrist holds it, and
	# stays there (does not swing)
	_clear()
	pr = Vector3(0.3, 1.2, -0.4)
	_pose(right, pr)
	await _step(2)
	var bc: Array = main.space.point_from_chart(1.0, _chart(pr) + Vector3(0.0, 0.35 + 0.06, 0.0))
	var big: Dictionary = main.world.add(bc[0], bc[1], Vector4.ZERO, 0.35, Color.WHITE)
	right.set_input(&"grip", 1.0)
	var sags := []
	for k in 240:
		await _step(1)
		var d := _at(big) - _chart(pr)
		sags.append(rad_to_deg(atan2(-d.z, Vector2(d.x, d.y).length())))
	var late: Array = sags.slice(210)
	_check("a big heavy ball held at its side sags below the hand and stays there", big["holds"].has(&"right_hand")
			and sags.back() > 3.0 and sags.back() < 45.0 and late.max() - late.min() < 3.0,
			"%.0f degrees below after 4 s (%.1f-%.1f in the last 0.5 s; 1 s: %.0f, 2 s: %.0f)" % [sags.back(), late.min(), late.max(), sags[59], sags[119]])
	right.set_input(&"grip", 0.0)
	await _step(2)
	# the crate (18 kg): one hand at its top's middle pulls up 0.5 m and cannot lift it off the
	# floor (it may tip it: pulled up nearly as hard as it weighs, it is easy to tip); two at its
	# sides lift it level
	_clear()
	main._cube_on_floor(Vector2(9.0, 0.0), main.CRATE_HALF, 0.0, main.CRATE_COLOR)
	var crate: Dictionary = main.world.cubes.back()
	_pose(right, Vector3(1.0, 1.5, 0.3))
	await _step(30)
	var top: float = 2.0 * main.CRATE_HALF + 0.05
	_pose(right, _play(Vector3(9.0, 0.0, top)))
	await _step(6)
	right.set_input(&"grip", 1.0)
	await _step(2)
	var off_floor := 0.0
	for k in 60:
		_pose(right, _play(Vector3(9.0, 0.0, top + 0.5 * minf(k / 30.0, 1.0))))
		await _step(1)
		off_floor = maxf(off_floor, _lowest_corner(crate))
	_check("the crate is too heavy for one hand: it stays on the floor", crate["holds"].has(&"right_hand") and off_floor < 0.03,
			"%.0f kg, its lowest corner up to %.3f m above the floor" % [BallWorld.mass_kg(crate), off_floor])
	right.set_input(&"grip", 0.0)
	_pose(right, Vector3(1.0, 1.5, 0.3))
	await _step(2)
	_clear()
	main._cube_on_floor(Vector2(9.0, 0.0), main.CRATE_HALF, 0.0, main.CRATE_COLOR)
	crate = main.world.cubes.back()
	await _step(30)
	var side: float = main.CRATE_HALF + 0.05
	_pose(right, _play(Vector3(9.0, side, main.CRATE_HALF)))
	_pose(left, _play(Vector3(9.0, -side, main.CRATE_HALF)))
	await _step(6)
	right.set_input(&"grip", 1.0)
	left.set_input(&"grip", 1.0)
	await _step(2)
	var z0 := _at(crate).z
	for k in 60:
		var up := 0.5 * minf(k / 30.0, 1.0)
		_pose(right, _play(Vector3(9.0, side, main.CRATE_HALF + up)))
		_pose(left, _play(Vector3(9.0, -side, main.CRATE_HALF + up)))
		await _step(1)
	var tilt := rad_to_deg(acos(clampf(WormholeSpace.vector_to_chart(1.0, crate["n"], crate["F"][2]).z, -1.0, 1.0)))
	_check("two hands at its sides lift it level", crate["holds"].size() == 2 and _at(crate).z - z0 > 0.45 and tilt < 3.0,
			"rose %.3f m of 0.5, tilted %.1f degrees" % [_at(crate).z - z0, tilt])
	right.set_input(&"grip", 0.0)
	left.set_input(&"grip", 0.0)
	await _step(2)


## The height of a cube's lowest corner above the floor (chart A).
func _lowest_corner(c: Dictionary) -> float:
	var x := _at(c)
	var lowest := INF
	for s: Vector3 in BallWorld.CORNERS:
		var p := x
		for k in 3:
			p += c["half"] * s[k] * WormholeSpace.vector_to_chart(1.0, c["n"], c["F"][k])
		lowest = minf(lowest, p.z)
	return lowest


## Takes the simulated headset down before quitting: left up at exit, it aborts Godot, and the
## exit status would say nothing.
func _finish() -> void:
	XRServer.remove_tracker(left)
	XRServer.remove_tracker(right)
	XRServer.primary_interface = null
	hmd.uninitialize()
	XRServer.remove_interface(hmd)
	quit(1 if fails > 0 else 0)
