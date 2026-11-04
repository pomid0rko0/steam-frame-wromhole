extends SceneTree
## The throat's shape changed at run time (main.reshape, the menu's shape rows), exit status 1 on any
## failure:
##   godot --path . --resolution 480x270 -s res://tests/shape_test.gd
## 1. The menu's shape rows offer only shapes the method takes (WormholeSpace.fits), the video's
##    among them, each of its sizes a value of its row.
## 2. While a new shape is built (on a worker thread) no frame's scripts take BUSY ms; the frame it
##    takes effect in is printed.
## 3. Standing, the body stays on the same place of the floor; flying in the curved zone, at the same
##    place against it (WormholeSpace.carried_l), the room's axes as they were.
## 4. A shape set at run time draws what the app started with that shape draws, pixel for pixel: the
##    floor, the sky, the scene's objects and the gravity view's floor and field lines (rebuilt for
##    the shape), from the start. The app is started again with the shape kept in the settings
##    (Menu.saved_shape) for the second picture.

const U := preload("res://tests/util.gd")
const SHAPE := Vector3(2.0, 1.5, 1.0)     # another throat the method takes: narrower, shorter
const VIDEO := Vector3(Main.THROAT_RADIUS, Main.HALF_LENGTH, Main.FILLET)
const BUSY := 40.0                        # ms: a frame of the build's (it takes hundreds on the main thread)

var main: Main
var frames := 0
var stage := 0
var wait := 0
var busy := 0.0                 # the longest frame's scripts while building
var built_frames := 0
var before := []                # the body before a new shape
var picture: Image              # the run-time reshape's
var video_picture: Image        # the video's throat's, from the same place


func _initialize() -> void:
	_start()


func _start() -> void:
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "none"
	main.toys.enabled = false
	root.add_child(main)


func _settle(m: Main) -> void:
	m.menu.visible = false
	m.camera.position = Vector3(0.0, 1.6, 0.0)
	m.camera.basis = Basis.IDENTITY
	m.place(Main.START_POS, Main.START_FORWARD)
	m.hold = true
	m.set_gravity_view(2)


func _process(_delta: float) -> bool:
	frames += 1
	if wait > 0:
		wait -= 1
		return false
	if main.reshaping():
		busy = maxf(busy, main.scripts_ms)
		built_frames += 1
		if built_frames > 3000:
			U.check("a new shape takes effect", false, "still building after %d frames" % built_frames)
			U.finish(self)
			return true
		return false
	match stage:
		0:
			_settle(main)
			wait = 12
			stage = 7
		7:
			video_picture = root.get_texture().get_image()
			_rows()
			before = [main.space.chart_position(main.viewer.l, main.viewer.n)]
			_reshape(SHAPE, 1)
		1:
			print("the shape took effect after %d frames, %.1f ms in that one" % [built_frames, main.scripts_ms])
			U.check("while a shape is built, no frame's scripts take %.0f ms" % BUSY, busy < BUSY, "%.1f ms at most" % busy)
			U.check("it is the shape asked for", main.shape_now().is_equal_approx(SHAPE), str(main.shape_now()))
			var x0: Vector3 = before[0]
			var x1 := main.space.chart_position(main.viewer.l, main.viewer.n)
			U.check("standing, the body stays on the same place of the floor", x0.distance_to(x1) < 1e-9 and main.viewer.standing,
					"%s -> %s" % [x0, x1])
			# flying in the curved zone, to the video's throat
			main.place_on_axis(0.5 * main.space.L)
			before = main.viewer.get_state()
			before.append([main.space.L, main.space.Rout])     # float64: a Vector2 is single precision
			_reshape(VIDEO, 2)
		2:
			# carried to the same share of the way to where both shapes are flat
			var was: Array = before[5]
			var e := maxf(was[1], main.space.Rout)
			var want: float = before[0] * (main.space.L + e - main.space.Rout) / (was[0] + e - was[1])
			var st := main.viewer.get_state()
			var same := true
			for k in 3:
				same = same and (st[2][k] as Vector4).is_equal_approx(before[2][k])
			U.check("flying in the curved zone, the body stays at the same place against it, the room's axes as they were",
					absf(st[0] - want) < 1e-9 and absf(st[0]) < main.space.L and same and not st[3],
					"l %.4f -> %.4f (want %.4f)" % [before[0], st[0], want])
			_reshape(SHAPE, 3)
		3:
			_settle(main)
			wait = 12
			stage = 4
		4:
			picture = root.get_texture().get_image()
			# the app again, started with the shape kept
			var cfg := ConfigFile.new()
			cfg.load(Menu.SETTINGS)
			cfg.set_value("shape", "radius", SHAPE.x)
			cfg.set_value("shape", "distance", 2.0 * SHAPE.y)
			cfg.set_value("shape", "fillet", SHAPE.z)
			cfg.save(Menu.SETTINGS)
			root.remove_child(main)
			main.free()
			_start()
			wait = 2
			stage = 5
		5:
			U.check("started with the kept shape", main.shape_now().is_equal_approx(SHAPE), str(main.shape_now()))
			_settle(main)
			wait = 12
			stage = 6
		6:
			var img := root.get_texture().get_image()
			var diff := _differ(img, picture)
			U.check("the shape set at run time draws what the app started with it draws", diff == 0,
					"%d of %d pixels differ" % [diff, img.get_width() * img.get_height()])
			var other := _differ(img, video_picture)
			U.check("and the video's throat draws another picture there (the check sees the shape)", other > img.get_width() * img.get_height() / 50,
					"%d pixels differ" % other)
			U.finish(self)
			return true
	return false


func _reshape(s: Vector3, then: int) -> void:
	busy = 0.0
	built_frames = 0
	main.reshape(s)
	stage = then


static func _differ(a: Image, b: Image) -> int:
	var n := 0
	for y in a.get_height():
		for x in a.get_width():
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				n += 1
	return n


## 1: the rows' values.
func _rows() -> void:
	var bad := []
	for r in main.menu._make_rows():
		if not r is Menu.ShapeRow:
			continue
		var row := r as Menu.ShapeRow
		var mine: float = 2.0 * VIDEO.y if row.part == 1 else VIDEO[row.part]
		if not row.values().has(mine):
			bad.append("%s: the video's %.2f m not offered" % [row.key, mine])
		for v: float in row.values():
			var s := row._with(v)
			if not WormholeSpace.fits(s.x, s.y, s.z, Main.LIFT):
				bad.append("%s: %.2f m" % [row.key, v])
	U.check("the shape rows offer the video's shape and only shapes the method takes", bad.is_empty(), ", ".join(bad))
