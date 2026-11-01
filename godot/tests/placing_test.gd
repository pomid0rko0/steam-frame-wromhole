extends SceneTree
## Moving the wormhole's mouth (placing.gd, main.move_mouth) and the worlds it stands in
## (WormholeSpace, «the worlds»), through the simulated headset and controllers. Run with
## --fixed-fps 60; exit status 1 on any failure:
##   godot --path . --fixed-fps 60 -s res://tests/placing_test.gd
## 1. world and chart coordinates: there and back, points, directions, and rechart, which keeps a
##    world place and direction where they are when a mouth moves, or pushes a place out of the new
##    curved zone along the floor
## 2. main.move_mouth: the viewer, its way and the toys in that flat universe stay where they are in
##    the world, the cube in the throat goes along with it, the other universe stays; the shaders
##    get the mouth; a toy where the new curved zone comes is pushed out past its edge; flying, the
##    head and its velocity stay as they are in the world
## 3. the physics with both mouths moved and turned: a ball dropped on a pillar of A and a cube on
##    a box of B come to rest on them, a ball rolled at A's wall comes back from 40 m off A's world
##    origin; the viewer walked at it stops there
## 4. allowed: a pillar, a sphere, a box, the wall and the viewer each keep the mouth off
## 5. the buttons: X takes hold of the mouth where it stands; the right stick up leads it farther,
##    right turns it, and the throat glides after (neither turns nor moves the viewer); A lets go of
##    it where it was led and does not go back to the start; B puts it back; X again lets go of it;
##    led onto a pillar it stays, a red ring there, and A lets go of it where it stands; not from the
##    curved zone, not while the speed check holds; the menu lets go of it; P and Backspace on the
##    keyboard; A, placing over, puts the mouths back where scene.json has them with the toys

const U := preload("res://tests/util.gd")
const HAND := Vector3(0.25, 1.2, -0.3)      # the right controller in the room

var main: Main
var hmd
var left: XRControllerTracker
var right: XRControllerTracker
var frames := 0
var wait := 0
var queue: Array[Callable] = []
var watch: BallWorld.Ball               # the ball rolled at the wall, and how far it went
var watch_far := 0.0
var low := INF                          # the ball dropped on the pillar: its lowest once it got there
var saved := {}
var releases := []                      # [tracker, button, frame]: _press's


func _initialize() -> void:
	hmd = U.headset(0, 0.0, Vector2i(64, 64))      # nothing here looks at the image
	left = U.controller(&"left_hand")
	right = U.controller(&"right_hand")
	_hand(Basis.IDENTITY)
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "FakeHMD"
	main.toys.demo = false
	root.add_child(main)
	queue = [_coordinates, _move, _move_checked, _push, _push_checked, _fly, _physics, _physics_checked,
			_wall_walk, _allowed, _x, _x_checked, _farther, _farther_checked, _turned, _turned_checked,
			_put, _put_checked, _cancel_start, _cancel, _cancel_checked, _x_again, _x_again_checked, _red,
			_red_checked, _red_put, _red_out, _zone, _zone_checked, _hold, _hold_checked, _menu, _menu_open, _menu_checked,
			_keys, _keys_on, _keys_off, _reset, _reset_checked]


func _process(_delta: float) -> bool:
	frames += 1
	for r: Array in releases.duplicate():
		if r[2] <= frames:
			r[0].set_input(r[1], false)
			releases.erase(r)
	if watch:
		watch_far = maxf(watch_far, main.space.world_position(watch.l, watch.n).length())
		var b := _world(saved["on_pillar"])
		if b.z < 4.4 or low < INF:
			low = minf(low, b.z)
	if frames < 5:
		return false
	if wait > 0:
		wait -= 1
		return false
	if queue.is_empty():
		U.finish(self, hmd, [left, right])
		return true
	wait = queue.pop_front().call()
	return false


func _hand(b: Basis) -> void:
	for p in [&"aim", &"grip"]:
		right.set_pose(p, Transform3D(b, HAND), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


## Button b down for two frames.
func _press(t: XRControllerTracker, b: StringName) -> void:
	t.set_input(b, true)
	releases.append([t, b, frames + 2])


func _world(b: BallWorld.Body) -> Vector3:
	return main.space.world_position(b.l, b.n)


func _feet() -> Vector3:
	return main.space.world_position(main.viewer.l, main.viewer.n)


func _forward() -> Vector3:
	return main.space.vector_to_world(signf(main.viewer.l), main.viewer.n, -main.viewer.frame[2])


# ---------------------------------------------------------------- 1. coordinates

func _coordinates() -> int:
	var sp := WormholeSpace.new(3.0, 5.0, 1.0)
	sp.set_mouth(1.0, Vector3(2.0, -3.0, 0.7))
	sp.set_mouth(-1.0, Vector3(-4.0, 1.0, -1.2))
	var worst := 0.0
	for side in [1.0, -1.0]:
		for x: Vector3 in [Vector3(12.0, -5.0, 0.0), Vector3(-9.0, 7.5, 1.3), Vector3(20.0, 20.0, 3.0)]:
			worst = maxf(worst, (sp.world_from_chart(side, sp.chart_from_world(side, x)) - x).length())
			var p := sp.point_from_world(side, x)
			worst = maxf(worst, (sp.world_position(p[0], p[1]) - x).length())
			var d := Vector3(0.3, -0.8, 0.52).normalized()
			worst = maxf(worst, (sp.vector_to_world(side, p[1], sp.vector_from_world(side, p[1], d)) - d).length())
			U.check("side %+d, %s: a world point is on its side of the flat universe" % [side, x], p[0] * side > sp.L, "l %.3f" % p[0])
	U.check("world -> chart -> world, points and directions, both sides", worst < 1e-4, "worst %.7f m" % worst)
	# rechart: a mouth moved, the place and its direction stay in the world
	var x := Vector3(15.0, -6.0, 0.4)
	var d := Vector3(-0.6, 0.8, 0.0)
	var p := sp.point_from_world(1.0, x)
	var U4 := sp.vector_from_world(1.0, p[1], d)
	var was: Vector3 = sp.mouths[0]
	sp.set_mouth(1.0, Vector3(-5.0, 6.0, 2.0))
	var r := sp.rechart(was, p[0], p[1], [U4])
	var moved := (sp.world_position(r[0], r[1]) - x).length()
	var turned := (sp.vector_to_world(1.0, r[1], r[2][0]) - d).length()
	U.check("rechart: the place and its direction stay in the world", moved < 1e-4 and turned < 1e-4 and not r[3],
			"place off %.7f m, direction %.7f, pushed %s" % [moved, turned, r[3]])
	# a place 1 m from the new centre, 0.5 m up: out to Rout + 0.2 along the floor
	was = sp.mouths[0]
	var near := sp.world_from_chart(1.0, Vector3(3.6, -4.8, 0.5))
	p = sp.point_from_world(1.0, near)
	sp.set_mouth(1.0, Vector3(near.x - 0.6, near.y + 0.8, 0.3))
	r = sp.rechart(was, p[0], p[1], [], 0.2)
	var c := sp.chart_from_world(1.0, sp.world_position(r[0], r[1]))
	var dir := Vector2(c.x, c.y).normalized()
	var want := Vector2(sp.chart_dir(1.0, Vector3(0.6, -0.8, 0.0)).x, sp.chart_dir(1.0, Vector3(0.6, -0.8, 0.0)).y)
	U.check("rechart: a place in the new curved zone is pushed out to Rout + clear along the floor",
			r[3] and absf(c.length() - (sp.Rout + 0.2)) < 1e-4 and absf(c.z - 0.5) < 1e-4 and dir.distance_to(want) < 1e-4,
			"pushed %s, at %.4f m from the centre, %.4f up, way %s (expected %s)" % [r[3], c.length(), c.z, dir, want])
	return 0


# ---------------------------------------------------------------- 2. moving a mouth

func _move() -> int:
	var w := main.toys.world
	saved = {"toys": [], "rider": null, "feet": _feet(), "fwd": _forward(), "B": main.space.mouths[1]}
	for b: BallWorld.Body in w.balls + w.cubes:
		if b.l > main.space.L:
			saved["toys"].append([b, _world(b), main.space.vector_to_world(1.0, b.n, b.U)])
		elif absf(b.l) < main.space.L:
			saved["rider"] = [b, b.l, b.n]
	U.check("the toys: some in universe A, one in the throat", saved["toys"].size() >= 7 and saved["rider"] != null,
			"%d in A" % saved["toys"].size())
	main.hold = true                    # the toys still: only the move moves them
	main.move_mouth(1.0, Vector3(-3.0, -14.0, deg_to_rad(40.0)))
	return 1


func _move_checked() -> int:
	main.hold = false
	var worst := 0.0
	for t: Array in saved["toys"]:
		worst = maxf(worst, (_world(t[0]) - t[1]).length())
	U.check("move_mouth: the toys of A stay where they were in its world", worst < 1e-3, "worst %.7f m" % worst)
	var rider: Array = saved["rider"]
	U.check("... the cube in the throat goes along with it", absf(rider[0].l - rider[1]) < 1e-9 and rider[0].n == rider[2])
	var f: float = (_feet() - saved["feet"]).length()
	var fw: float = (_forward() - saved["fwd"]).length()
	U.check("... the viewer stays, facing the same way in the world", f < 1e-3 and fw < 1e-4, "feet off %.7f m, way %.7f" % [f, fw])
	U.check("... universe B's mouth stays", main.space.mouths[1] == saved["B"])
	var g: PackedVector4Array = main.renderer.ball_mat.get_shader_parameter("g_mouth")
	var want := Vector4(-3.0, -14.0, cos(deg_to_rad(40.0)), sin(deg_to_rad(40.0)))
	U.check("... the shaders have it", g.size() == 2 and g[0].distance_to(want) < 1e-5, str(g))
	var suns: PackedVector3Array = main.renderer.ball_mat.get_shader_parameter("g_sun")
	var a: Array = main.scene["suns"]["A"]
	var sun := main.space.chart_dir(1.0, Vector3(a[0], a[1], a[2]))
	U.check("... and A's sun turned into its chart, so it stays put in the world", suns.size() == 2
			and suns[0].distance_to(sun) < 1e-6 and absf(suns[0].z - a[2]) < 1e-6
			and Vector2(suns[0].x, suns[0].y).angle_to(Vector2(a[0], a[1])) > 0.69, str(suns))
	return 0


func _push() -> int:
	# the viewer out of the way, then the mouth onto the toys at rest in front of the start
	main.place(Vector3(15.0, 12.0, 0.0), Vector3(-1.0, 0.0, 0.0))
	saved["near"] = []
	var c := Vector3(6.5, 0.0, 0.0)
	for b: BallWorld.Body in main.toys.world.balls + main.toys.world.cubes:
		if b.l > main.space.L and (_world(b) - c).length() < main.space.Rout + 0.5:
			saved["near"].append([b, _world(b)])
	main.hold = true
	main.move_mouth(1.0, Vector3(c.x, c.y, 0.0))
	return 1


func _push_checked() -> int:
	main.hold = false
	var c := Vector3(6.5, 0.0, 0.0)
	var bad := 0
	for t: Array in saved["near"]:
		var b: BallWorld.Body = t[0]
		var size: float = (b as BallWorld.Cube).half * sqrt(3.0) if b is BallWorld.Cube else (b as BallWorld.Ball).radius
		var x := _world(b)
		var was: Vector3 = t[1]
		var way := Vector2(x.x - c.x, x.y - c.y).normalized().dot(Vector2(was.x - c.x, was.y - c.y).normalized())
		if b.l <= main.space.L or (x - c).length() < main.space.Rout + size + 0.05 - 1e-3 or way < 0.9999 or absf(x.z - was.z) > 1e-3:
			bad += 1
	U.check("move_mouth onto toys: each pushed out past the new curved zone along the floor, straight away from its centre",
			saved["near"].size() >= 5 and bad == 0, "%d toys there, %d not" % [saved["near"].size(), bad])
	return 0


func _fly() -> int:
	var v := main.viewer
	var h: float = main.camera.transform.origin.y
	main.move_mouths(main.scene_mouths())
	main.place(main.START_POS, main.START_FORWARD)
	v.take_off()
	v.move(WormholeSpace.combine(v.frame, Vector3(0.0, 1.5, 0.0)))
	var hp := v.head(h)
	var d := Vector3(1.0, -2.0, 0.5)
	v.V = main.space.vector_from_world(1.0, hp[1], d)
	var head := main.space.world_position(hp[0], hp[1])
	main.hold = true
	main.move_mouth(1.0, Vector3(-4.0, 9.0, deg_to_rad(-120.0)))
	main.hold = false
	hp = v.head(h)
	var off := (main.space.world_position(hp[0], hp[1]) - head).length()
	var dv := (main.space.vector_to_world(1.0, hp[1], v.V) - d).length()
	U.check("move_mouth, flying: the head and its velocity stay as they are in the world", off < 1e-3 and dv < 1e-4,
			"head off %.7f m, velocity off %.7f m/s" % [off, dv])
	main.place(main.START_POS, main.START_FORWARD)
	return 0


# ---------------------------------------------------------------- 3. the physics in moved worlds

func _physics() -> int:
	main.move_mouth(1.0, Vector3(-3.0, -14.0, deg_to_rad(40.0)))
	main.move_mouth(-1.0, Vector3(-2.0, -12.0, deg_to_rad(-70.0)))
	var sp := main.space
	var w := main.toys.world
	var p := sp.point_from_world(1.0, Vector3(7.5, 7.5, 5.5))
	saved["on_pillar"] = w.add(p[0], p[1], Vector4.ZERO, 0.3, Color.WHITE)
	var q := sp.point_from_world(-1.0, Vector3(8.5, 5.0, 3.0))
	var F := []
	for ax in [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)]:
		F.append(sp.vector_from_world(-1.0, q[1], ax))
	saved["on_box"] = w.add_cube(q[0], q[1], Vector4.ZERO, F, Vector3.ZERO, 0.2, Color.WHITE)
	var r := sp.point_from_world(1.0, Vector3(34.0, 0.0, 0.3))
	watch = w.add(r[0], r[1], sp.vector_from_world(1.0, r[1], Vector3(6.0, 0.0, 0.0)), 0.3, Color.WHITE)
	return 180


func _physics_checked() -> int:
	var b := _world(saved["on_pillar"])
	U.check("a ball dropped on a pillar of A (its mouth moved and turned) bounces on its top",
			Vector2(b.x - 7.5, b.y - 7.5).length() < 0.05 and absf(low - 4.3) < 0.02 and b.z > 4.29,
			"at %s, lowest %.3f m" % [b, low])
	var c := _world(saved["on_box"])
	U.check("a cube dropped on a box of B (its mouth moved and turned) rests on it",
			Vector2(c.x - 8.5, c.y - 5.0).length() < 0.1 and absf(c.z - 1.7) < 0.03, "at %s" % c)
	var x := _world(watch)
	U.check("a ball rolled at A's wall turns back 40 m off A's world origin",
			watch_far > 39.0 and watch_far < 40.0 and x.x < 39.5, "farthest %.3f m, now x %.2f" % [watch_far, x.x])
	return 0


func _wall_walk() -> int:
	main.place(Vector3(38.5, 0.0, 0.0), Vector3(1.0, 0.0, 0.0))
	main.viewer.take_off()
	main.viewer.move(WormholeSpace.combine(main.viewer.frame, Vector3(0.0, 0.0, -3.0)))
	var f := _feet()
	U.check("the viewer flown at the wall stops 40 m off the world's origin, facing the same way",
			absf(f.length() - 40.0) < 1e-3 and absf(f.z) < 1e-4 and _forward().distance_to(Vector3(1, 0, 0)) < 1e-4,
			"feet %s, forward %s" % [f, _forward()])
	main.place(main.START_POS, main.START_FORWARD)
	return 0


# ---------------------------------------------------------------- 4. allowed

func _allowed() -> int:
	main.place(main.START_POS, main.START_FORWARD)
	var pl := main.placing
	for c: Array in [[1.0, Vector2(7.5, 7.5), "мешает столб"], [1.0, Vector2(14.0, -5.0), "мешает шар"],
			[1.0, Vector2(37.0, 0.0), "там стена мира"], [1.0, Vector2(12.0, 2.0), "слишком близко к тебе"],
			[-1.0, Vector2(8.5, 5.0), "мешает ящик"], [1.0, Vector2(-3.0, -14.0), ""]]:
		var a := pl.allowed(c[0], Vector3(c[1].x, c[1].y, 0.0))
		U.check("allowed at %s of %s: %s" % [c[1], "A" if c[0] > 0.0 else "B", c[2] if c[2] != "" else "yes"],
				a[0] == (c[2] == "") and a[1] == c[2], str(a))
	return 0


# ---------------------------------------------------------------- 5. the buttons

func _x() -> int:
	_hand(Basis.IDENTITY)
	main.move_mouths(main.scene_mouths())
	main.place(main.START_POS, main.START_FORWARD)
	_press(right, &"place_button")
	return 3


func _x_checked() -> int:
	var pl := main.placing
	# the hand: 0.3 m ahead of the feet at (10, 0), 0.25 m to the right (world +y), pointing at the
	# throat (-x): as far from its centre as the hand is
	var want := Vector2(9.7, 0.25).length()
	U.check("X takes hold of universe A's mouth where it stands: it stays, no ring",
			pl.active and pl.side == 1.0 and absf(pl.dist - want) < 1e-3 and pl.ok and pl.pts.is_empty()
			and pl.centre.length() < 1e-3 and Vector2(main.space.mouths[0].x, main.space.mouths[0].y).length() < 1e-3,
			"active %s, side %s, dist %.4f (%.4f), ok %s %s, %d points, mouth %s" % [pl.active, pl.side, pl.dist, want, pl.ok, pl.why, pl.pts.size(), main.space.mouths[0]])
	saved["fwd"] = _forward()
	saved["feet"] = _feet()
	right.set_input(&"primary", Vector2(0.0, 1.0))
	return 30


func _farther() -> int:
	right.set_input(&"primary", Vector2.ZERO)
	return 60


func _farther_checked() -> int:
	var pl := main.placing
	var want := Vector2(9.7, 0.25).length() + 31.0 / 60.0 * Placing.DIST_SPEED
	var m: Vector3 = main.space.mouths[0]
	var c := Vector2(9.7, 0.25) + want * (-Vector2(9.7, 0.25).normalized())
	U.check("the right stick up for 31 frames: led 3.1 m farther, and the throat has glided there",
			absf(pl.dist - want) < 1e-3 and Vector2(m.x, m.y).distance_to(pl.centre) < 0.01 and pl.centre.distance_to(c) < 1e-3,
			"dist %.3f, expected %.3f; mouth %s, led to %s" % [pl.dist, want, m, pl.centre])
	saved["dist"] = pl.dist
	right.set_input(&"primary", Vector2(1.0, 0.0))
	return 30


func _turned() -> int:
	right.set_input(&"primary", Vector2.ZERO)
	return 60


func _turned_checked() -> int:
	var pl := main.placing
	var m: Vector3 = main.space.mouths[0]
	U.check("the right stick right for 31 frames: turned 46.5 degrees clockwise, the throat with it",
			absf(rad_to_deg(pl.turn) + 46.5) < 1e-3 and absf(angle_difference(m.z, pl.turn)) < 0.01,
			"led to %.2f deg, the mouth at %.2f" % [rad_to_deg(pl.turn), rad_to_deg(m.z)])
	U.check("... and the viewer did not turn", _forward().distance_to(saved["fwd"]) < 1e-5, str(_forward()))
	U.check("... nor move", (_feet() - saved["feet"]).length() < 1e-3, str(_feet()))
	saved["turn"] = pl.turn
	saved["centre"] = pl.centre
	saved["balls"] = main.toys.world.balls.size()
	_press(right, &"ax_button")
	return 3


func _put() -> int:
	return 0


func _put_checked() -> int:
	var m: Vector3 = main.space.mouths[0]
	var c: Vector2 = saved["centre"]
	U.check("A lets go of it where it was led", not main.placing.active and Vector2(m.x, m.y).distance_to(c) < 1e-5
			and absf(m.z - saved["turn"]) < 1e-6, "mouth %s, led to %s" % [m, c])
	U.check("... and does not go back to the start", (_feet() - saved["feet"]).length() < 1e-3, str(_feet()))
	U.check("... the line below says so", main.menu.notice_text == "червоточина переставлена", main.menu.notice_text)
	return 0


func _cancel_start() -> int:
	saved["mouth"] = main.space.mouths[0]
	_press(right, &"place_button")
	right.set_input(&"primary", Vector2(0.0, -1.0))
	return 20


func _cancel() -> int:
	right.set_input(&"primary", Vector2.ZERO)
	saved["moved"] = Vector2(main.space.mouths[0].x - saved["mouth"].x, main.space.mouths[0].y - saved["mouth"].y).length()
	_press(right, &"by_button")
	return 3


func _cancel_checked() -> int:
	U.check("B puts it back where it stood, and puts no new ball in the hand", not main.placing.active
			and saved["moved"] > 0.5 and main.space.mouths[0] == saved["mouth"] and main.toys.world.balls.size() == saved["balls"]
			and main.menu.notice_text == "червоточина вернулась на место",
			"active %s, had moved %.2f m, mouth %s, balls %d, line %s" % [main.placing.active, saved["moved"],
			main.space.mouths[0], main.toys.world.balls.size(), main.menu.notice_text])
	_press(right, &"place_button")
	right.set_input(&"primary", Vector2(0.0, 1.0))
	return 10


func _x_again() -> int:
	right.set_input(&"primary", Vector2.ZERO)
	saved["led"] = Vector3(main.placing.centre.x, main.placing.centre.y, main.placing.turn)
	_press(right, &"place_button")
	return 3


func _x_again_checked() -> int:
	var m: Vector3 = main.space.mouths[0]
	var led: Vector3 = saved["led"]
	U.check("X again lets go of it where it was led", not main.placing.active and m.distance_to(led) < 1e-5
			and Vector2(m.x - saved["mouth"].x, m.y - saved["mouth"].y).length() > 0.5, "mouth %s, led to %s" % [m, led])
	saved["mouth"] = m
	_press(right, &"place_button")
	return 3


func _red() -> int:
	# then, at once, the hand toward the pillar at (7.5, 7.5) of A from where it is, (9.7, 0.25): room
	# x is world y, room -z world -x (led a few degrees off that: the way it took hold of the throat)
	var w := Vector2(7.5 - 9.7, 7.5 - 0.25)
	_hand(Basis.looking_at(Vector3(w.y, 0.0, w.x).normalized(), Vector3.UP))
	main.placing.dist = w.length()
	return 3


func _red_checked() -> int:
	var pl := main.placing
	U.check("led onto a pillar: the throat stays, a red ring there, the line below says why",
			pl.active and not pl.ok and pl.why == "мешает столб" and pl.pts.size() == Placing.RING_POINTS + 2
			and main.renderer.beams[Renderer.PLACING].visible and pl.centre.distance_to(Vector2(7.5, 7.5)) < 0.5
			and main.space.mouths[0] == saved["mouth"] and main.menu.notice_text == "сюда нельзя: мешает столб",
			"ok %s %s, %d points, centre %s, mouth %s, line %s" % [pl.ok, pl.why, pl.pts.size(), pl.centre, main.space.mouths[0], main.menu.notice_text])
	_press(right, &"ax_button")
	return 3


func _red_put() -> int:
	U.check("A there lets go of it where it stands", not main.placing.active and main.space.mouths[0] == saved["mouth"],
			str(main.space.mouths[0]))
	_hand(Basis.IDENTITY)
	return 1


func _red_out() -> int:
	return 0


func _zone() -> int:
	main.place_on_axis(1.0)
	_press(right, &"place_button")
	return 3


func _zone_checked() -> int:
	U.check("not from the curved zone: the line below says why", not main.placing.active
			and main.menu.notice_text == "сначала выйди из кривой зоны", main.menu.notice_text)
	main.place(main.START_POS, main.START_FORWARD)
	main.hold = true
	_press(right, &"place_button")
	return 3


func _hold() -> int:
	return 0


func _hold_checked() -> int:
	U.check("not while the speed check holds the viewer", not main.placing.active)
	main.hold = false
	return 0


func _menu() -> int:
	_press(right, &"place_button")
	return 3


func _menu_open() -> int:
	U.check("placing again", main.placing.active)
	_press(left, &"primary_click")
	return 3


func _menu_checked() -> int:
	U.check("the menu opened lets go of it", main.menu.open and not main.placing.active, "open %s" % main.menu.open)
	_press(left, &"primary_click")
	return 3


func _keys() -> int:
	U.check("the menu closed", not main.menu.open)
	U.key(KEY_P, true)
	return 2


func _keys_on() -> int:
	U.key(KEY_P, false)
	U.check("P starts it", main.placing.active)
	U.key(KEY_BACKSPACE, true)
	return 2


func _keys_off() -> int:
	U.key(KEY_BACKSPACE, false)
	U.check("Backspace puts it back", not main.placing.active)
	return 1


func _reset() -> int:
	main.move_mouth(1.0, Vector3(-3.0, -14.0, 0.5))
	_press(right, &"ax_button")
	return 3


func _reset_checked() -> int:
	var want: Array = main.scene_mouths()
	U.check("A (placing over) puts the mouths back where scene.json has them, the toys and the viewer too",
			main.space.mouths[0] == want[0] and main.space.mouths[1] == want[1] and main.toys.world.balls.size() == 5
			and _feet().distance_to(main.START_POS) < 1e-3, "mouths %s, %d balls, feet %s" % [main.space.mouths, main.toys.world.balls.size(), _feet()])
	return 0
