extends SceneTree
## The throat's shape changed at run time (main.set_shape; the menu's rows «радиус горла»,
## «скругление», «высота горла»; its length: length_test.gd), exit status 1 on any failure:
##   godot --path . --resolution 480x270 -s res://tests/shape_test.gd
## 1. Holding right or left on a row changes its part frame by frame up to its limit
##    (WormholeSpace.fit) and no further; a radius' and a fillet's sweep table is built off the main
##    thread: the frames go on while one is built (how long the slowest frame's scripts took
##    against a table's build here is printed, held to no limit: their time is the wall's, and on a
##    machine busy with other tests a frame waits its turn); the shape in effect follows in steps
##    while the row is held; the other rows follow where they must: a fillet made soft widens the throat, a throat
##    made narrow sharpens the fillet, a throat grown wider than its height allows rises, and held
##    left the height stops where the floor would come into the curved zone (WormholeSpace.lift_min);
##    A gives the video's back; the shape is kept for the next start, and a kept one the app does
##    not take is fitted.
## 2. Gravity after set_shape is the one solved for that throat from scratch.
## 3. What stands in the space goes with its part of it (WormholeSpace.carried): standing, the body
##    stays on its place of the floor; flying out in a flat universe, at its place of the chart (its
##    height over the floor kept as the throat rises), or straight out of the throat's centre at the
##    edge of a curved zone that grew over it; in the cylinder and on a fillet, with the throat; the
##    room's axes as they were there. The toys too, their velocities with them, and awake.
## 4. On every corner of the menu's shapes: the scene's objects, the toys at rest, the throw's and
##    the drop's starts and the stereo check's bodies are out of the curved zone; the field lines
##    fit the renderer (Renderer.LINE_CHUNKS: thinned where they are too many) and the texture of
##    their vertices the device; the demo runs (the throw, the drop: every toy stays a
##    number, over the floor and within the world), a walk along the floor under the mouth keeps the
##    feet on it, and a flight along the axis comes out in universe B.
## 5. A shape set at run time draws what the app started with that shape draws, pixel for pixel
##    (as length_test.gd's 4: the gravity view's floor and field lines, a ball and a cube in the
##    throat), and the video's throat another picture.

const U := preload("res://tests/util.gd")
const HEAD := 1.6                         # m: the head in the room
const LOOK_UP := 35.0                     # degrees: the pictures' view up from the start, into a mouth hung high too

var main: Main
var frames := 0
var stage := 0
var wait := 0
var busy := 0.0
var building := 0                         # frames that went on while a sweep table was being built
var held := 0                             # frames a key has been held
var seen := {}                            # the values the space had of the part being held
var held_from := 0.0                      # and the one it had before
var before := Vector3.ZERO
var picture: Image
var video_picture: Image
var video := WormholeSpace.fit(Main.THROAT_RADIUS, Main.LENGTH, Main.FILLET, Main.LIFT)
# the rows held in turn: [row, key, the part of the shape (WormholeSpace.shape's), its limit, the
# whole shape then (the other rows following), or null]
var holds := []
var hold_at := 0


func _initialize() -> void:
	_start()


func _start() -> void:
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "none"
	main.toys.enabled = false
	root.add_child(main)


func _settle(m: Main) -> void:
	m.menu.visible = false
	m.camera.position = Vector3(0.0, HEAD, 0.0)
	m.camera.basis = Basis(Vector3.RIGHT, deg_to_rad(LOOK_UP))
	m.place(Main.START_POS, Main.START_FORWARD)
	m.hold = true
	m.set_gravity_view(2)


## The widest and softest throat the menu gives, on a cylinder of 20 m, 1.5 m over its lowest: every
## part another than the video's.
static func _far() -> PackedFloat64Array:
	var s := WormholeSpace.fit(WormholeSpace.RADIUS_MAX, 20.0, WormholeSpace.FILLET_MAX, 0.0)
	return WormholeSpace.fit(s[0], s[1], s[2], s[3] + 1.5)


func _process(_delta: float) -> bool:
	frames += 1
	if wait > 0:
		wait -= 1
		return false
	match stage:
		0:
			_settle(main)
			main.hold = false
			wait = 12
			stage = 1
		1:
			video_picture = root.get_texture().get_image()
			before = main.space.chart_position(main.viewer.l, main.viewer.n)
			main.menu.set_open(true)
			# from the video's: the fillet to its softest (the throat widens with it), the throat to
			# its narrowest (the fillet sharpens with it) and its widest, then the height down and up
			var soft := WormholeSpace.fit(Main.THROAT_RADIUS, Main.LENGTH, WormholeSpace.FILLET_MAX, Main.LIFT, true)
			var narrow := WormholeSpace.fit(WormholeSpace.RADIUS_MIN, Main.LENGTH, soft[2], soft[3])
			var wide := WormholeSpace.fit(WormholeSpace.RADIUS_MAX, Main.LENGTH, narrow[2], narrow[3])
			holds = [["fillet", KEY_RIGHT, 2, soft[2], soft], ["radius", KEY_LEFT, 0, narrow[0], narrow],
					["radius", KEY_RIGHT, 0, wide[0], wide],
					["lift", KEY_LEFT, 3, WormholeSpace.lift_min(wide[0], wide[2]), null],
					["lift", KEY_RIGHT, 3, WormholeSpace.LIFT_MAX, null]]
			hold_at = 0
			stage = 2
		2:
			if _hold():
				stage = 3
				wait = 2
		3:
			var t0 := Time.get_ticks_usec()
			for i in 3:
				WormholeSpace.of(_far()).sweep_table()
			var build := (Time.get_ticks_usec() - t0) / 3000.0
			U.check("while the rows are held, the frames go on as a sweep table is built", building > 10,
					"%d frames with one being built; a frame's scripts %.1f ms at most, a table's build %.0f ms" % [building, busy, build])
			var x := main.space.chart_position(main.viewer.l, main.viewer.n)
			U.check("standing, the body stays on the same place of the floor", before.distance_to(x) < 1e-5 and main.viewer.standing
					and absf(main.viewer.height()) < 1e-6, "%s -> %s" % [before, x])
			var kept := Menu.saved_shape(video)
			U.check("the shape is kept", kept == main.shape_want and kept != video, "%s" % kept)
			for key: String in ["radius", "fillet", "lift"]:
				main.menu.select(key)
				main.menu.press()
			stage = 4
		4:
			if main.shaping():
				return false
			U.check("A on each row: the video's throat", main.space.shape() == video and main.shape_want == video
					and Menu.saved_shape(_far()) == video, "%s" % main.space.shape())
			main.menu.set_open(false)
			_kept()
			_gravity()
			_carried()
			_corners()
			var far := _far()
			main.set_shape(far[0], far[1], far[2], far[3])
			stage = 5
		5:
			# the sweep table and the field lines built off the main thread, then the picture
			if main.shaping() or main.renderer._lines_task >= 0:
				return false
			U.check("a shape asked for is in effect once its table is built", main.space.shape() == _far(), "%s" % main.space.shape())
			main.menu._save()
			_settle(main)
			_bodies()
			wait = 12
			stage = 6
		6:
			picture = root.get_texture().get_image()
			root.remove_child(main)
			main.free()
			_start()
			wait = 2
			stage = 7
		7:
			U.check("started with the kept shape", main.space.shape() == _far(), "%s" % main.space.shape())
			_settle(main)
			_bodies()
			wait = 12
			stage = 8
		8:
			var img := root.get_texture().get_image()
			var diff := _differ(img, picture)
			U.check("the shape set at run time draws what the app started with it draws", diff == 0,
					"%d of %d pixels differ" % [diff, img.get_width() * img.get_height()])
			var shown := _seen(img)
			U.check("the ball and the cube in the throat are in the picture", shown.x > 20 and shown.y > 20,
					"%d red pixels, %d green" % [shown.x, shown.y])
			var other := _differ(img, video_picture)
			U.check("and the video's throat draws another picture there (the check sees the shape)",
					other > img.get_width() * img.get_height() / 100 or _far() == video, "%d pixels differ" % other)
			# back to the video's for the next runs of the app on this machine
			main.set_shape(video[0], video[1], video[2], video[3], true)
			main.menu._save()
			U.finish(self)
			return true
	return false


## 1: holds[hold_at]'s key on its row until the shape in effect has its part at the limit; true
## when all are done.
func _hold() -> bool:
	var h: Array = holds[hold_at]
	var k: int = h[2]
	if held == 0:
		U.check("the menu has the row " + h[0], main.menu.select(h[0]), "")
		seen = {}
		held_from = main.space.shape()[k]
	else:
		busy = maxf(busy, main.scripts_ms)
		building += int(main.shaping())
	seen[main.space.shape()[k]] = true
	var there := absf(main.shape_want[k] - h[3]) < 1e-9 and not main.shaping() and absf(main.space.shape()[k] - h[3]) < 1e-9
	if not there and held < 3000:
		U.key(h[1], true)
		held += 1
		return false
	U.key(h[1], false)
	U.check("held %s on the row %s, it goes to its limit and no further" % ["right" if h[1] == KEY_RIGHT else "left", h[0]], there,
			"%.3f m (limit %.3f) after %d frames, in effect in %d steps" % [main.space.shape()[k], h[3], held, seen.size()])
	if there and absf(held_from - h[3]) > 0.3:
		U.check("... the shape in effect following in steps while it is held", seen.size() >= 3, "%d values" % seen.size())
	if h[4] != null:
		U.check("... the other rows following", main.space.shape() == h[4] and main.shape_want == h[4], "%s, want %s" % [main.space.shape(), h[4]])
	var w := main.shape_want
	U.check("... the height no lower than the floor allows this throat", w[3] >= WormholeSpace.lift_min(w[0], w[2]) - 1e-9
			and main.space.lift >= main.space.Rout + WormholeSpace.FLOOR_CLEAR - 1e-9, "%.3f m over the floor, the curved zone's radius %.3f m" % [main.space.lift, main.space.Rout])
	held = 0
	hold_at += 1
	return hold_at >= holds.size()


## 1: a shape kept that the app does not take (another build's, a file written by hand).
func _kept() -> void:
	var cfg := ConfigFile.new()
	cfg.load(Menu.SETTINGS)
	var keep := {}
	for k: String in Menu.SHAPE_KEYS:
		keep[k] = cfg.get_value("throat", k)
	cfg.set_value("throat", "radius", 0.01)
	cfg.set_value("throat", "fillet", 500.0)
	cfg.set_value("throat", "lift", -3.0)
	cfg.set_value("throat", "length", 1e6)
	cfg.save(Menu.SETTINGS)
	var s := Menu.saved_shape(video)
	var want := WormholeSpace.fit(0.01, 1e6, 500.0, -3.0)
	U.check("a kept shape the app does not take is fitted", s == want and s[0] == WormholeSpace.RADIUS_MIN
			and s[1] == WormholeSpace.LENGTH_MAX and s[3] == WormholeSpace.lift_min(s[0], s[2]), "%s" % s)
	for k: String in keep:
		cfg.set_value("throat", k, keep[k])
	cfg.save(Menu.SETTINGS)


## The shapes at the corners of what the menu gives: the radius' and the fillet's limits (as fit
## takes them together), no cylinder and the longest, the lowest and the highest.
static func _corner_shapes() -> Array:
	var out := []
	for rad in [WormholeSpace.RADIUS_MIN, WormholeSpace.RADIUS_MAX]:
		for fil in [WormholeSpace.FILLET_MIN, WormholeSpace.FILLET_MAX]:
			for cyl in [0.0, WormholeSpace.LENGTH_MAX]:
				for lift in [0.0, WormholeSpace.LIFT_MAX]:
					var s := WormholeSpace.fit(rad, cyl, fil, lift)
					if not out.has(s):
						out.append(s)
	return out


## 2: set against solved, at shapes all over the menu's.
func _gravity() -> void:
	var worst := 0.0
	var sp := main.space
	for s: PackedFloat64Array in _corner_shapes() + [_far(), video]:
		sp.set_shape(s[0], s[1], s[2], s[3])
		var fresh := WormholeSpace.new(s[0], 0.5 * s[1] + s[2], s[2], s[3])
		worst = maxf(worst, absf(sp.grav_beta - fresh.grav_beta) / absf(fresh.grav_beta))
		for i in 200:
			var l := (i / 199.0 - 0.5) * 2.0 * (fresh.L + 2.0)
			var a := sp.gravity_f(l)
			var b := fresh.gravity_f(l)
			for k in 2:
				worst = maxf(worst, absf(a[k] - b[k]) / maxf(absf(b[k]), 1e-12))
		worst = maxf(worst, absf(sp.L - fresh.L) + absf(sp.h - fresh.h) + absf(sp.Rout - fresh.Rout))
	sp.set_shape(video[0], video[1], video[2], video[3])      # as main and the renderer have it
	U.check("gravity and the profile after set_shape are those of a throat made with that shape", worst < 1e-9, String.num_scientific(worst) + " at most, relative")


## 3: the body flying and toys, carried to the far shape from the video's and back.
func _carried() -> void:
	var sp := main.space
	var far := _far()
	var bad := []
	for back in [false, true]:
		var a := far if back else video
		var b := video if back else far
		var a_L := 0.5 * a[1] + a[2] * PI / 2.0
		var b_L := 0.5 * b[1] + b[2] * PI / 2.0
		var b_Rout := b[0] + b[2]
		# [the head's l on the axis (n = +x), where that is]
		for at: Array in [[0.3 * 0.5 * a[1], "in the cylinder"], [-(0.5 * a[1] + 0.5 * a[2] * PI / 2.0), "on B's fillet"],
				[a_L + 0.4, "just out of the curved zone"], [-(a_L + 9.0), "out in B"]]:
			main.set_shape(a[0], a[1], a[2], a[3], true)
			var l0: float = at[0]
			main.place_on_axis(l0)
			var hp0: Array = main.viewer.head(HEAD).duplicate(true)
			var x0 := sp.chart_position(l0, hp0[1])
			var c0 := []
			for A: Vector4 in hp0[2]:
				c0.append(WormholeSpace.vector_to_chart(signf(l0), hp0[1], A))
			var ball := main.toys.world.add(l0, Vector3(0.0, 0.6, 0.8), Vector4(0.3, 0.4, 0.0, 0.0), 0.2, Color.RED)
			ball.U = WormholeSpace.tangent(ball.n, ball.U)
			ball.still = 5.0
			var bx0 := sp.chart_position(ball.l, ball.n)
			var bv0 := WormholeSpace.vector_to_chart(signf(l0), ball.n, ball.U)
			var bu0 := ball.U
			main.set_shape(b[0], b[1], b[2], b[3], true)
			var hp: Array = main.viewer.head(HEAD)
			var al := absf(l0)
			var what: String = "%s -> %s, %s" % [a, b, at[1]]
			if al < a_L:
				# with the throat: the cylinder's share, the fillet's angle; n and the axes as they were
				var want := l0 * b[1] / a[1] if al < 0.5 * a[1] else signf(l0) * (0.5 * b[1] + (al - 0.5 * a[1]) * b[2] / a[2])
				var same := (hp[1] as Vector3).is_equal_approx(hp0[1])
				for k in 3:
					same = same and (hp[2][k] as Vector4).is_equal_approx(hp0[2][k])
				if absf(hp[0] - want) > 1e-6 or not same:
					bad.append("%s: the head at l %.5f -> %.5f (want %.5f), n and the axes the same: %s" % [what, l0, hp[0], want, same])
				if absf(ball.l - want) > 1e-9 or not ball.n.is_equal_approx(Vector3(0.0, 0.6, 0.8)) or not ball.U.is_equal_approx(bu0):
					bad.append("%s: the toy at l %.5f -> %.5f (want %.5f), U %s -> %s" % [what, l0, ball.l, want, bu0, ball.U])
			else:
				# at its place of the chart, or straight out of the centre at the zone's edge
				var x := sp.chart_position(hp[0], hp[1])
				var centre := Vector3(0.0, 0.0, b[3])
				var off := x0 - centre
				var want := x0 if off.length() >= b_Rout else centre + off.normalized() * b_Rout
				var same := true
				for k in 3:
					same = same and WormholeSpace.vector_to_chart(signf(l0), hp[1], hp[2][k]).is_equal_approx(c0[k])
				if x.distance_to(want) > 2e-5 or not same or signf(hp[0]) != signf(l0) or absf(hp[0]) < b_L - 1e-9:
					bad.append("%s: the head at chart %s -> %s (want %s), the axes as the chart has them: %s" % [what, x0, x, want, same])
				var bx := sp.chart_position(ball.l, ball.n)
				var boff := bx0 - centre
				var bwant := bx0 if boff.length() >= b_Rout else centre + boff.normalized() * b_Rout
				if bx.distance_to(bwant) > 2e-5 or not WormholeSpace.vector_to_chart(signf(l0), ball.n, ball.U).is_equal_approx(bv0):
					bad.append("%s: the toy at chart %s -> %s (want %s)" % [what, bx0, bx, bwant])
			if main.viewer.standing or ball.still != 0.0:
				bad.append("%s: flying %s, the toy awake %s" % [what, not main.viewer.standing, ball.still == 0.0])
			main.toys.world.balls.erase(ball)
	# a toy at rest on the floor stays on it as the throat rises, and one under the zone's bottom
	main.set_shape(video[0], video[1], video[2], video[3], true)
	var rest := main.toys.ball_on_floor(1.0, Vector2(0.4, 0.3), 0.35, Color.RED)
	main.set_shape(far[0], far[1], far[2], far[3], true)
	var rx := sp.chart_position(rest.l, rest.n)
	if rx.distance_to(Vector3(0.4, 0.3, 0.35)) > 2e-5:
		bad.append("a ball on the floor under the mouth: at chart %s" % rx)
	main.toys.world.balls.erase(rest)
	main.set_shape(video[0], video[1], video[2], video[3], true)
	main.place(Main.START_POS, Main.START_FORWARD)
	U.check("flying, the body and a toy go with their part of the space, the room's axes and the velocity as they were there",
			bad.is_empty(), "; ".join(bad))


## 4: every corner of the menu's shapes.
func _corners() -> void:
	var sp := main.space
	var toys := main.toys
	var bad := []
	var most := 0
	for s: PackedFloat64Array in _corner_shapes():
		main.set_shape(s[0], s[1], s[2], s[3], true)
		var what := "%s" % s
		var centre := Vector3(0.0, 0.0, sp.lift)
		# the scene's objects: spheres, pillars (their axes' points nearest the centre), boxes (their corners' reach)
		for key in ["A", "B"]:
			for p: Array in main.scene["spheres_" + key]:
				if Vector3(p[0], p[1], p[2]).distance_to(centre) < sp.Rout + p[3]:
					bad.append("%s: a sphere of %s in the curved zone" % [what, key])
			for p: Array in main.scene.get("pillars_" + key, []):
				var z := clampf(sp.lift, 0.0, p[3])
				if Vector3(p[0], p[1], z).distance_to(centre) < sp.Rout + p[2]:
					bad.append("%s: a pillar of %s in the curved zone" % [what, key])
			for p: Array in main.scene.get("boxes_" + key, []):
				if Vector3(p[0], p[1], p[2]).distance_to(centre) < sp.Rout + sqrt(3.0) * p[3]:
					bad.append("%s: a box of %s in the curved zone" % [what, key])
		# the stereo check's bodies and the start
		for c: Vector3 in CheckScene.BALLS:
			if c.distance_to(centre) < sp.Rout + CheckScene.BALL_RADIUS:
				bad.append("%s: the stereo check's ball in the curved zone" % what)
		if CheckScene.CUBE.distance_to(centre) < sp.Rout + sqrt(3.0) * CheckScene.CUBE_HALF:
			bad.append("%s: the stereo check's cube in the curved zone" % what)
		if (Main.START_POS + Vector3(0.0, 0.0, 2.2)).distance_to(centre) < sp.Rout + 1.0:
			bad.append("%s: the start in the curved zone" % what)
		# the toys at rest, the throw's and the drop's starts
		toys.enabled = true
		toys.demo = true
		toys.spawn()
		for b: BallWorld.Body in _toys():
			var reach: float = (b as BallWorld.Cube).half * sqrt(3.0) if b is BallWorld.Cube else (b as BallWorld.Ball).radius
			if absf(b.l) < sp.L or sp.r(b.l) < sp.Rout + reach:
				bad.append("%s: a toy at rest reaches into the curved zone, at l %.2f" % [what, b.l])
		var started: Array = []
		started.append_array(toys.throw())
		started.append(toys.drop())
		for b: BallWorld.Body in started:
			if absf(b.l) < sp.L or sp.r(b.l) < sp.Rout + 0.5:
				bad.append("%s: a toy thrown or dropped starts in the curved zone, at l %.2f" % [what, b.l])
		# the demo: 12 s of it
		var empty: Array[BallWorld.Ball] = []
		for i in 12 * 60:
			toys.world.step(1.0 / 60.0, empty)
		for b: BallWorld.Body in _toys():
			var size: float = (b as BallWorld.Cube).half if b is BallWorld.Cube else (b as BallWorld.Ball).radius
			var H := sp.height(b.l, b.n)
			if not is_finite(b.l) or not b.n.is_finite() or not b.U.is_finite() or H < 0.5 * size or sp.r(b.l) > BallWorld.WORLD_RADIUS + 1.0:
				bad.append("%s: after the demo a toy at l %.2f, %.3f m over the floor, speed %.2f" % [what, b.l, H, b.U.length()])
		toys.world.balls.clear()
		toys.world.cubes.clear()
		toys.enabled = false
		# a walk along the floor under the mouth, through the point under the centre
		var v := main.viewer
		main.place(Vector3(sp.Rout + 2.0, 0.3, 0.0), Vector3(-1.0, 0.0, 0.0))
		for i in 200:
			v.push(Vector3(0.0, 0.0, -1.0), (2.0 * sp.Rout + 4.0) / 200.0, HEAD)
			var hp := v.head(HEAD)
			if not v.standing or absf(v.height()) > 1e-5 or not is_finite(hp[0]) or not (hp[1] as Vector3).is_finite():
				bad.append("%s: walking under the mouth, the feet %.4f m over the floor, the head at l %.3f" % [what, v.height(), hp[0]])
				break
		var wx := sp.chart_position(v.l, v.n)
		if wx.distance_to(Vector3(-sp.Rout - 2.0, 0.3, 0.0)) > 1e-3:
			bad.append("%s: the walk under the mouth ends at %s" % [what, wx])
		# a flight along the axis, through the throat
		main.place_on_axis(sp.L + 1.0)
		var way := 2.0 * sp.L + 2.0
		for i in 200:
			v.push(Vector3(0.0, 0.0, -1.0), way / 200.0, HEAD)
		var fp := v.head(HEAD)
		if absf(fp[0] + sp.L + 1.0) > 1e-3 or not (fp[1] as Vector3).is_equal_approx(Vector3(1.0, 0.0, 0.0)):
			bad.append("%s: the flight through the throat ends with the head at l %.4f (want %.4f)" % [what, fp[0], -sp.L - 1.0])
		most = maxi(most, Renderer.line_chunks(sp).n)
	U.check("on every corner of the menu's shapes the scene, the toys and the start keep out of the curved zone, the demo, a walk under the mouth and a flight through the throat go",
			bad.is_empty(), "%d shapes; %s" % [_corner_shapes().size(), "; ".join(bad)])
	var widest := RenderingServer.get_rendering_device().limit_get(RenderingDevice.LIMIT_MAX_TEXTURE_SIZE_2D)
	U.check("and the field lines fit the renderer, thinned where they are too many, and their vertices' texture the device",
			most <= Renderer.LINE_CHUNKS and most > Renderer.LINE_CHUNKS / 4 and Renderer.LINE_CHUNKS * Renderer.LINE_CV <= widest,
			"%d chunks at most (Renderer.LINE_CHUNKS %d, %d texels of the device's %d)" % [most, Renderer.LINE_CHUNKS, Renderer.LINE_CHUNKS * Renderer.LINE_CV, widest])
	main.set_shape(video[0], video[1], video[2], video[3], true)
	main.place(Main.START_POS, Main.START_FORWARD)


## The toys, balls and cubes.
func _toys() -> Array:
	var out: Array = []
	out.append_array(main.toys.world.balls)
	out.append_array(main.toys.world.cubes)
	return out


## A ball and a cube in the throat's cylinder, as length_test.gd's.
func _bodies() -> void:
	var sp := main.space
	var bn := Vector3(0.75, 0.0, 0.66).normalized()
	var pos := PackedVector4Array([sp.embed(0.35 * sp.Lc, bn)])
	var col := PackedVector4Array([Vector4(4.0, 0.0, 0.0, 0.35)])
	var cl := -0.45 * sp.Lc
	var cn := Vector3(0.6, 0.5, 0.62).normalized()
	var e1 := cn.cross(Vector3(0.0, 0.0, 1.0)).normalized()
	var e2 := cn.cross(e1)
	var axes := PackedVector4Array([sp.embed_vector(cl, cn, Vector4(0.0, e1.x, e1.y, e1.z)).normalized(),
			sp.embed_vector(cl, cn, Vector4(0.0, e2.x, e2.y, e2.z)).normalized()])
	main.renderer.set_objects(pos, col, PackedVector4Array([sp.embed(cl, cn)]), axes,
			PackedVector4Array([Vector4(0.0, 4.0, 0.0, 0.3)]))


## The picture's red and green pixels (the ball's and the cube's).
static func _seen(img: Image) -> Vector2i:
	var n := Vector2i.ZERO
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.r - maxf(c.g, c.b) > 0.25:
				n.x += 1
			elif c.g - maxf(c.r, c.b) > 0.25:
				n.y += 1
	return n


static func _differ(a: Image, b: Image) -> int:
	var n := 0
	for y in a.get_height():
		for x in a.get_width():
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				n += 1
	return n
