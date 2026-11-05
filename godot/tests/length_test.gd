extends SceneTree
## The throat's length changed at run time (main.set_length, the menu's row «длина горла»), exit
## status 1 on any failure:
##   godot --path . --resolution 480x270 -s res://tests/length_test.gd
## 1. Holding right on the row stretches the throat frame by frame, no frame's scripts taking BUSY ms;
##    LONG is reached, and holding on, LENGTH_MAX and no more; A gives the video's length back.
## 2. Gravity by the fillet's two solutions summed (WormholeSpace._grav_sum) is the one solved for
##    that throat from scratch (a WormholeSpace made with it), f and f' all along l.
## 3. Standing, the body stays on the same place of the floor; flying in the cylinder, at the same
##    share of its length; in the fillet, as far from the mouth; the room's axes as they were. A toy
##    in the cylinder goes with it.
## 4. A length set at run time draws what the app started with that length draws, pixel for pixel:
##    the floor, the sky, the scene's objects, the gravity view's floor and field lines (built again
##    off the main thread for the length), and a ball and a cube in the throat's cylinder (_bodies:
##    there from before the throat stretches; their meshes and their images' tail), from the start.
##    The app is started again with the length kept in the settings (Menu.saved_length) for the
##    second picture.

const U := preload("res://tests/util.gd")
const LONG := 40.0                        # m: a long throat's cylinder
const BUSY := 8.0                         # ms: main's scripts in a frame while it stretches, at most (Main.scripts_ms,
                                          # from the menu's input on: on this machine's CPU, not the headset's)

var main: Main
var frames := 0
var stage := 0
var wait := 0
var busy := 0.0
var slid_frames := 0
var before := []
var picture: Image
var video_picture: Image


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
	match stage:
		0:
			_settle(main)
			main.hold = false
			wait = 12
			stage = 1
		1:
			video_picture = root.get_texture().get_image()
			before = [main.space.chart_position(main.viewer.l, main.viewer.n)]
			# the bodies in the throat while it stretches
			_bodies()
			main.menu.set_open(true)
			U.check("the menu has the throat's length", main.menu.select("length"), "")
			busy = 0.0
			slid_frames = 0
			stage = 2
		2:
			# held right: the arrow key, as handle_input reads it
			var ev := InputEventKey.new()
			ev.keycode = KEY_RIGHT
			ev.physical_keycode = KEY_RIGHT
			ev.pressed = true
			Input.parse_input_event(ev)
			if slid_frames > 0:
				busy = maxf(busy, main.scripts_ms)
			slid_frames += 1
			# where they are on this frame's throat, as main sends its toys each frame
			_bodies()
			if 2.0 * main.space.Lc >= WormholeSpace.LENGTH_MAX or slid_frames > 2000:
				var up := InputEventKey.new()
				up.keycode = KEY_RIGHT
				up.physical_keycode = KEY_RIGHT
				up.pressed = false
				Input.parse_input_event(up)
				stage = 3
				wait = 3
		3:
			U.check("held right, the throat stretches to its longest and no further",
					is_equal_approx(2.0 * main.space.Lc, WormholeSpace.LENGTH_MAX),
					"%.3f m after %d frames" % [2.0 * main.space.Lc, slid_frames])
			U.check("while it stretches, no frame's scripts take %.0f ms" % BUSY, busy < BUSY, "%.1f ms at most" % busy)
			U.check("the length is kept", is_equal_approx(Menu.saved_length(0.0), WormholeSpace.LENGTH_MAX),
					"%.3f m" % Menu.saved_length(0.0))
			var x1 := main.space.chart_position(main.viewer.l, main.viewer.n)
			var x0: Vector3 = before[0]
			U.check("standing, the body stays on the same place of the floor", x0.distance_to(x1) < 1e-9 and main.viewer.standing,
					"%s -> %s" % [x0, x1])
			main.menu.press()
			U.check("A: the video's length", is_equal_approx(2.0 * main.space.Lc, Main.LENGTH), "%.3f m" % (2.0 * main.space.Lc))
			main.menu.set_open(false)
			_gravity()
			_carried()
			main.set_length(LONG)
			main.menu._save()
			_settle(main)
			_bodies()
			stage = 4
			wait = 2
		4:
			# the field lines built off the main thread, then the picture
			if main.renderer._lines_task >= 0:
				return false
			wait = 12
			stage = 5
		5:
			picture = root.get_texture().get_image()
			root.remove_child(main)
			main.free()
			_start()
			wait = 2
			stage = 6
		6:
			U.check("started with the kept length", is_equal_approx(2.0 * main.space.Lc, LONG), "%.3f m" % (2.0 * main.space.Lc))
			_settle(main)
			_bodies()
			wait = 12
			stage = 7
		7:
			var img := root.get_texture().get_image()
			var diff := _differ(img, picture)
			U.check("the length set at run time draws what the app started with it draws", diff == 0,
					"%d of %d pixels differ" % [diff, img.get_width() * img.get_height()])
			var seen := _seen(img)
			U.check("the ball and the cube in the throat are in the picture", seen.x > 20 and seen.y > 20,
					"%d red pixels, %d green" % [seen.x, seen.y])
			var other := _differ(img, video_picture)
			U.check("and the video's throat draws another picture there (the check sees the length)",
					other > img.get_width() * img.get_height() / 100, "%d pixels differ" % other)
			picture = img
			main.renderer.tail_shown = false
			wait = 3
			stage = 8
		8:
			var tail := _differ(picture, root.get_texture().get_image())
			U.check("and the tail of their images draws some of it", tail > 0, "%d pixels without it differ" % tail)
			# back to the video's for the next runs of the app on this machine
			main.renderer.tail_shown = true
			main.set_length(Main.LENGTH)
			main.menu._save()
			U.finish(self)
			return true
	return false


## 2: summed against solved, at lengths along the row's span.
func _gravity() -> void:
	var worst := 0.0
	for cyl in [0.0, 0.5, 8.0, 23.0, LONG, WormholeSpace.LENGTH_MAX]:
		main.space.set_length(cyl)
		var fresh := WormholeSpace.new(main.space.rho0, 0.5 * cyl + main.space.fillet, main.space.fillet, main.space.lift)
		worst = maxf(worst, absf(main.space.grav_beta - fresh.grav_beta) / absf(fresh.grav_beta))
		for i in 200:
			var l := (i / 199.0 - 0.5) * 2.0 * (fresh.L + 2.0)
			var a := main.space.gravity_f(l)
			var b := fresh.gravity_f(l)
			for k in 2:
				worst = maxf(worst, absf(a[k] - b[k]) / maxf(absf(b[k]), 1e-12))
	main.set_length(Main.LENGTH)
	U.check("gravity by the fillet's two solutions summed is the one solved for the throat", worst < 1e-9, String.num_scientific(worst) + " at most, relative")


## 3: flying in the cylinder and in the fillet, and a toy.
func _carried() -> void:
	var sp := main.space
	var bad := []
	for at in [[0.3, "in the cylinder"], [-0.5 * (sp.Lc + sp.L), "in B's fillet"]]:
		main.set_length(Main.LENGTH)
		var l0: float = at[0] * (sp.Lc if at[0] > 0.0 and at[0] < 1.0 else 1.0)
		main.place_on_axis(l0)
		var st0 := main.viewer.get_state()
		var Lc0 := sp.Lc
		var ball := main.toys.world.add(l0 * 0.5, Vector3(0.0, 0.0, 1.0), Vector4.ZERO, 0.2, Color.RED)
		var bl0 := ball.l
		main.set_length(LONG)
		var st := main.viewer.get_state()
		# the feet's l (the head is l0; on B's fillet the room's up bends off the axis)
		var f0: float = st0[0]
		var want := f0 * sp.Lc / Lc0 if absf(f0) < Lc0 else signf(f0) * (absf(f0) - Lc0 + sp.Lc)
		var wantb := bl0 * sp.Lc / Lc0 if absf(bl0) < Lc0 else signf(bl0) * (absf(bl0) - Lc0 + sp.Lc)
		var same := true
		for k in 3:
			same = same and (st[2][k] as Vector4).is_equal_approx(st0[2][k])
		if absf(st[0] - want) > 1e-9 or not same or st[3]:
			bad.append("%s: l %.4f -> %.4f (want %.4f)" % [at[1], f0, st[0], want])
		if absf(ball.l - wantb) > 1e-9:
			bad.append("%s: the toy at l %.4f -> %.4f (want %.4f)" % [at[1], bl0, ball.l, wantb])
		main.toys.world.balls.erase(ball)
	main.set_length(Main.LENGTH)
	U.check("flying, the body (and a toy) stay where they were against their part of the throat, the room's axes as they were",
			bad.is_empty(), ", ".join(bad))


## A ball and a cube in the throat's cylinder, at the same shares of its length whatever it is, as
## the renderer takes them (toys are off: main sends none of its own).
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
