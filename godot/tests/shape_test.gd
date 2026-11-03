extends SceneTree
## The throat's shape changed at run time (main.set_shape, the menu's rows), exit status 1 on any
## failure:
##   godot --path . --resolution 320x240 -s res://tests/shape_test.gd [-- shots_prefix]
## 1. At every shape the menu offers (Menu.RADII x LENGTHS x FILLETS), what stands in chart
##    coordinates keeps out of the curved zone: scene.json's objects, the toys' places (at rest, where
##    the throw and the drop start, the ball and cube on B's floor), the stereo check scene's balls and
##    cube (their reach: a ball's radius, a cube's half diagonal, a pillar's whole length).
## 2. A shape put in while the app runs draws exactly what the app draws when it starts with that
##    shape (kept in the settings: Menu.kept_shape): the same pixels, from the start looking at the
##    mouth, with the scene's objects, the gravity view's field lines (built off the main thread with
##    the table), and again with the stereo check scene (CheckScene.fit) instead of them.
## 3. The viewer stays where it was in terms both shapes have (Viewer.shape_free): standing, at the
##    same place of the floor facing the same way; flying, the head at the same share of the curved
##    zone, or as far beyond it, its n and axes as they were.
## 4. No frame waits for the build: from the ask until the shape is in, main's _process takes at
##    most STALL ms a frame (the build alone takes a tenth of a second and more).
## With a prefix, saves the pictures of 2.

const U := preload("res://tests/util.gd")
# shapes of the menu's (Menu.shape_of: radius, length, fillet): all three numbers and the floor's lift
# change, and to one with no cylinder
var TO := Menu.shape_of(5.0, 10.0, 2.0)
var AGAIN := Menu.shape_of(2.0, 0.0, 3.0)
const STALL := 8.0                      # ms
const LOOK_UP := 0.3                    # rad: the desktop camera's pitch at the start, the mouth in view

var shots := ""


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	shots = a[0] if a.size() > 0 else ""
	_run.call_deferred()


func _run() -> void:
	_places()
	for check in [false, true]:
		var fresh := await _picture(TO, false, check)
		var live := await _picture(TO, true, check)
		var diff := _differing(fresh, live)
		U.check("a shape put in at run time draws what a start with it draws%s" % (", the stereo check scene" if check else ""),
				diff == 0, "%d of %d pixels differ" % [diff, fresh.get_width() * fresh.get_height()])
		if shots != "":
			var tag := "check" if check else "scene"
			fresh.save_png("%s_%s_start.png" % [shots, tag])
			live.save_png("%s_%s_live.png" % [shots, tag])
	await _carried()
	_settings(Vector3.ZERO)
	U.finish(self)


## 1: the chart places against the curved zone's ball at every shape the menu offers.
func _places() -> void:
	var scene: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://scene.json"))
	var worst := INF
	var where := ""
	var shapes := 0
	for r: float in Menu.RADII:
		for len: float in Menu.LENGTHS:
			for f: float in Menu.FILLETS:
				var v := Menu.shape_of(r, len, f)
				var sp := WormholeSpace.new(v.x, v.y, v.z)
				shapes += 1
				for p: Array in _chart_places(sp, scene):
					var side: float = p[0]
					var c: Vector3 = p[1]
					var top: Vector3 = p[2]
					# from the zone's centre to the nearest point of the segment c..top, less the reach
					var z := Vector3(0.0, 0.0, sp.lift)
					var t := clampf((z - c).dot(top - c) / maxf((top - c).length_squared(), 1e-12), 0.0, 1.0)
					var reach: float = p[3]
					var gap := (c + t * (top - c) - z).length() - reach - sp.Rout
					if gap < worst:
						worst = gap
						where = "%s in %s, throat %s" % [p[4], "A" if side > 0.0 else "B", sp.shape()]
	U.check("at every shape of the menu the chart places keep out of the curved zone", worst > 0.0,
			"%d shapes; nearest: %s, %.2f m off the zone" % [shapes, where, worst])


## [side, a point, the far end of its segment (the point again for a ball), its reach, name] of what
## stands in chart coordinates at shape sp.
func _chart_places(sp: WormholeSpace, scene: Dictionary) -> Array:
	var out := []
	for k in 2:
		var side := 1.0 if k == 0 else -1.0
		var key := "A" if k == 0 else "B"
		for s: Array in scene.get("spheres_" + key, []):
			var c := Vector3(s[0], s[1], s[2])
			out.append([side, c, c, s[3], "scene.json's sphere"])
		for p: Array in scene.get("pillars_" + key, []):
			out.append([side, Vector3(p[0], p[1], 0.0), Vector3(p[0], p[1], p[3]), p[2], "scene.json's pillar"])
		for b: Array in scene.get("boxes_" + key, []):
			var c := Vector3(b[0], b[1], b[2])
			out.append([side, c, c, b[3] * sqrt(3.0), "scene.json's box"])
	var toys := Toys.new(sp, scene)
	for b: Array in Toys.BALLS_A:
		var c := Vector3(b[0], b[1], b[2])
		out.append([1.0, c, c, b[2], "a toy ball at rest"])
	for c: Array in Toys.CUBES_A:
		var p := Vector3(c[0], c[1], c[2])
		out.append([1.0, p, p, c[2] * sqrt(3.0), "a toy cube at rest"])
	var ring := toys.ring_point()
	out.append([-1.0, Vector3(ring.x, ring.y, Toys.RING_RADIUS), Vector3(ring.x, ring.y, Toys.RING_RADIUS), Toys.RING_RADIUS, "the ball on B's floor"])
	var cube := Vector3(ring.x, Toys.RING_CUBE_Y, Toys.RING_CUBE_HALF)
	out.append([-1.0, cube, cube, Toys.RING_CUBE_HALF * sqrt(3.0), "the cube on B's floor"])
	for t: Array in toys.throw_starts():
		out.append([1.0, t[0], t[0], t[1], "where the throw starts"])
	var drop := toys.drop_place()
	out.append([1.0, drop, drop, Toys.DROP_RADIUS, "where the drop starts"])
	for c: Vector3 in CheckScene.BALLS:
		out.append([1.0, c, c, CheckScene.BALL_RADIUS, "the check scene's ball"])
	out.append([1.0, CheckScene.CUBE, CheckScene.CUBE, CheckScene.CUBE_HALF * sqrt(3.0), "the check scene's cube"])
	return out


## 2: the app's picture (the desktop's) from the start looking up at the mouth, at shape v: started
## with it (live false: kept in the settings) or started with main.SHAPE and v put in at run time;
## check: the stereo check scene, else the scene's objects and the field lines.
func _picture(v: Vector3, live: bool, check: bool) -> Image:
	_settings(Vector3.ZERO if live else v)
	var main := _start(check)
	await _frames(3)
	if live:
		U.check("started with the menu's own shape (none kept)", main.space.shape() == Main.SHAPE, str(main.space.shape()))
		await _put_in(main, v)
		# the viewer as a start puts it (3 checks where a change of shape puts it: the same place,
		# its numbers worked out another way, to the last digits)
		main.place(main.START_POS, main.START_FORWARD)
	U.check("the shape asked for is in", main.space.shape() == v, "%s, asked %s" % [main.space.shape(), v])
	await _frames(4)
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	main.queue_free()
	await _frames(2)
	return img


## main on the desktop at the start, the camera looking up at the mouth, the menu and the toys away;
## the gravity view's field lines on (check: the stereo check scene).
func _start(check: bool) -> Main:
	var main := load("res://main.tscn").instantiate() as Main
	main.xr_name = "none"
	main.show_check = check
	main.toys.enabled = false
	root.add_child(main)
	main.menu.visible = false
	main.camera.position = Vector3(0.0, 1.6, 0.0)
	main.camera.basis = Basis.from_euler(Vector3(LOOK_UP, 0.0, 0.0))
	main.place(main.START_POS, main.START_FORWARD)
	if not check:
		main.set_gravity_view(2)
	return main


## Ask for v and wait until it is in; 4: the frames meanwhile, main's _process (scripts_ms).
func _put_in(main: Main, v: Vector3) -> void:
	main.set_shape(v)
	var worst := 0.0
	var frames := 0
	var t0 := Time.get_ticks_msec()
	while main.shape_pending() and Time.get_ticks_msec() - t0 < 20000:
		await process_frame
		frames += 1
		worst = maxf(worst, main.scripts_ms)
	await process_frame
	worst = maxf(worst, main.scripts_ms)
	U.check("no frame waits for the shape's build", worst <= STALL and frames >= 2,
			"main's _process %.1f ms at most over the %d frames until %s was in, %d ms" % [worst, frames, v, Time.get_ticks_msec() - t0])


## 3: the viewer standing and flying, through a change of shape.
func _carried() -> void:
	_settings(Vector3.ZERO)
	var main := _start(false)
	await _frames(3)
	var height := main.camera.transform.origin.y
	# standing off the start, facing somewhere else
	main.place(Vector3(6.0, 4.0, 0.0), Vector3(-0.3, -1.0, 0.0))
	var c0 := main.space.chart_position(main.viewer.l, main.viewer.n)
	var x0 := WormholeSpace.vector_to_chart(1.0, main.viewer.n, main.viewer.frame[0])
	await _put_in(main, TO)
	var c1 := main.space.chart_position(main.viewer.l, main.viewer.n)
	var x1 := WormholeSpace.vector_to_chart(1.0, main.viewer.n, main.viewer.frame[0])
	U.check("standing, the viewer keeps its place on the floor and its bearing", main.viewer.standing
			and (c1 - c0).length() < 1e-4 and (x1 - x0).length() < 1e-4, "moved %s m, turned by %s" % [String.num_scientific((c1 - c0).length()), String.num_scientific((x1 - x0).length())])
	# flying in the throat, then out beyond the zone in B
	for place: Vector2 in [Vector2(0.45, 0.0), Vector2(-1.0, -2.5)]:
		main.hold = true                # the body stays (no coasting) while the shape changes
		main.place_on_axis(main.space.l_of(place), 30.0)
		main.viewer.V = Vector4(0.3, 0.0, 0.2, 0.0)
		var hp := main.viewer.head(height)
		var to := AGAIN if main.space.shape() != AGAIN else TO
		await _put_in(main, to)
		var hq := main.viewer.head(height)
		var axes := 0.0
		for k in 3:
			axes = maxf(axes, ((hq[2][k] as Vector4) - (hp[2][k] as Vector4)).length())
		U.check("flying at %s of the curved zone, the head stays there" % place, main.space.zone_place(hq[0]).distance_to(place) < 1e-4
				and (hq[1] as Vector3).distance_to(hp[1]) < 1e-4 and axes < 1e-4 and main.viewer.V == Vector4(0.3, 0.0, 0.2, 0.0),
				"at %s, n off by %s, axes by %s, velocity %s" % [main.space.zone_place(hq[0]),
				String.num_scientific((hq[1] as Vector3).distance_to(hp[1])), String.num_scientific(axes), main.viewer.V])
	main.queue_free()
	await _frames(2)


## The settings file with the throat's shape v kept (ZERO: none).
func _settings(v: Vector3) -> void:
	var cfg := ConfigFile.new()
	if v != Vector3.ZERO:
		cfg.set_value("throat", "shape", v)
	cfg.save(Menu.SETTINGS)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


static func _differing(a: Image, b: Image) -> int:
	if a.get_size() != b.get_size():
		return a.get_width() * a.get_height()
	var n := 0
	for y in a.get_height():
		for x in a.get_width():
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				n += 1
	return n
