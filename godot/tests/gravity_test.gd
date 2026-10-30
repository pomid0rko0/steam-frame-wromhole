extends SceneTree
## Gravity through the wormhole and its view (desktop, run with --fixed-fps 60), exit status 1 on
## any failure:
##   godot --path . --resolution 320x240 --fixed-fps 60 -s res://tests/gravity_test.gd [-- shots_prefix]
## 1. the field matches ref/gravity.py (python3 ref/test_gravity.py prints these numbers)
## 2. it solves Laplace's equation, (r^2 f')' = 2 f, also on the fillet's table
## 3. potential_grad is the gradient of potential (so the field conserves energy)
## 4. the renderer's table of gravity on the floor (gravity_table) is the field, and its end joins
##    the closed form beyond
## 5. G cycles the views (Renderer.GRAVITY_VIEWS): the floor's shader and the arrows; not during
##    the speed check
## 6. the pictures: the floor yellow (1 g) far out and dark purple (0.2 g) in the middle of the
##    throat, the sky untouched; arrows drawn over the view with view 2
## With a prefix, saves the pictures it checks.

const U := preload("res://tests/util.gd")

var main: Main
var frames := 0
var shots := ""
var step := 0
var pics := {}
# [name, l (null: the start's), degrees up, gravity view]
const PICS := [["far", 11.6, -70.0, 1], ["throat", 0.0, -70.0, 1], ["throat_off", 0.0, -70.0, 0],
		["start_off", null, 0.0, 0], ["start_floor", null, 0.0, 1], ["start_arrows", null, 0.0, 2]]


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	shots = a[0] if a.size() > 0 else ""
	main = load("res://main.tscn").instantiate() as Main
	main.toys.enabled = false            # its pictures and checks without the toys
	main.xr_name = "none"
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 2:
		main.menu.visible = false
		_math_checks(main.space)
		_control_checks()
	# the pictures: set a view and a pose, render, read back (3 frames each)
	if frames >= 4:
		var k := (frames - 4) % 3
		var i := (frames - 4) / 3
		if i >= PICS.size():
			_picture_checks()
			main.set_gravity_view(0)
			U.finish(self)
			return true
		var p: Array = PICS[i]
		if k == 0:
			main.set_gravity_view(p[3])
			var start_l: float = main.space.point_from_chart(1.0, main.START_POS)[0]
			main.place_on_axis(p[1] if p[1] != null else start_l, 0.0, p[2])
		elif k == 2:
			var img := root.get_texture().get_image()
			img.convert(Image.FORMAT_RGB8)
			pics[p[0]] = img
			if shots != "":
				img.save_png("%s_%s.png" % [shots, p[0]])
	return false


func _math_checks(sp: WormholeSpace) -> void:
	# 1: against the float64 reference
	var ref_l := [0.0, 2.0, 4.0, 5.0, sp.L]
	var ref_g := [0.20557, 0.30391, 0.69300, 0.91320, 0.94991]
	var worst := absf(sp.grav_beta - (-3.20586))
	var got := []
	for i in ref_l.size():
		got.append(snappedf(sp.floor_gravity(ref_l[i]), 0.00001))
		worst = maxf(worst, absf(sp.floor_gravity(ref_l[i]) - ref_g[i]))
		worst = maxf(worst, absf(sp.floor_gravity(-ref_l[i]) - ref_g[i]))     # the same in universe B
	U.check("gravity matches ref/gravity.py", worst < 2e-5,
			"floor g at l = 0, 2, 4, 5, L: %s (%s), beta %.5f m^3 (-3.20586)" % [str(got), str(ref_g), sp.grav_beta])

	# 2: (r^2 f')' = 2 f by central differences, in doubles
	var res := 0.0
	var e := 1e-3
	var f2 := Vector2(INF, -INF)      # the range of 2 f, against which the residual is small
	for i in 400:
		var l := -sp.L - 3.0 + (2.0 * sp.L + 6.0) * (i + 0.5) / 400.0
		var lap := (_flux(sp, l + e) - _flux(sp, l - e)) / (2.0 * e) - 2.0 * sp.gravity_f(l)[0]
		res = maxf(res, absf(lap))
		f2 = Vector2(minf(f2.x, 2.0 * sp.gravity_f(l)[0]), maxf(f2.y, 2.0 * sp.gravity_f(l)[0]))
	U.check("gravity solves Laplace's equation", res < 1e-4, "max |(r^2 f')' - 2 f| %s m over the shell and 3 m around it (2 f is %.1f..%.1f m)" % [_e(res), f2.x, f2.y])

	# 3: the gradient against differences of the potential, at points above the floor
	var gerr := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for i in 60:
		var l := rng.randf_range(-sp.L - 2.0, sp.L + 2.0)
		var n := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(0.05, 1)).normalized()
		var G := sp.potential_grad(l, n)
		var dl := (sp.potential(l + e, n) - sp.potential(l - e, n)) / (2.0 * e)
		# along n: the tangent t moves n by angle eps, a distance r eps
		var t := Vector3(0, 0, 1) - n.z * n
		t = t.normalized() if t.length() > 1e-6 else Vector3(1, 0, 0)
		var nu := (n + e * t).normalized()
		var nd := (n - e * t).normalized()
		var dt := (sp.potential(l, nu) - sp.potential(l, nd)) / (2.0 * e * sp.r(l))
		gerr = maxf(gerr, maxf(absf(dl - G.x), absf(dt - Vector3(G.y, G.z, G.w).dot(t))))
	U.check("potential_grad is the potential's gradient", gerr < 1e-4, "max difference %s (in g)" % _e(gerr))

	# 4: the renderer's table, float32, linear between its nodes as the GPU filters it
	var gt := sp.gravity_table()
	var img: Image = gt.image
	var ax: Vector2 = gt.axes
	var n := img.get_width()
	var terr := 0.0
	for i in 400:
		var l := (i + 0.5) / 400.0 * ax.x
		var x := l / ax.x * (n - 1)
		var k := mini(int(x), n - 2)
		var g := lerpf(img.get_pixel(k, 0).r, img.get_pixel(k + 1, 0).r, x - k)
		terr = maxf(terr, absf(g - sp.floor_gravity(l)))
	var rr := sp.r(ax.x)
	var join := absf(img.get_pixel(n - 1, 0).r - (1.0 + ax.y / (rr * rr * rr)))
	U.check("the renderer's gravity on the floor is the field", terr < 2e-3 and join < 1e-5,
			"within %s g between the nodes, at the end %s from the closed form" % [_e(terr), _e(join)])


## x as "1.5e-5"
static func _e(x: float) -> String:
	if x == 0.0:
		return "0"
	var ex := floori(log(absf(x)) / log(10.0))
	return "%.1fe%d" % [x / pow(10.0, ex), ex]


func _flux(sp: WormholeSpace, l: float) -> float:
	return sp.r(l) * sp.r(l) * sp.gravity_f(l)[1]


func _control_checks() -> void:
	var seen := []
	var r: Renderer = main.renderer
	for i in 3:
		U.key(KEY_G, true, true)
		main._process(0.0)
		U.key(KEY_G, false, true)
		main._process(0.0)
		seen.append([r.gravity_view, r.floor_mat.shader.resource_path.get_file(), r.arrows.visible])
	U.check("G cycles the gravity views", seen == [[1, "floor_gravity.gdshader", false], [2, "floor_gravity.gdshader", true],
			[0, "floor.gdshader", false]], str(seen))
	main.hold = true
	U.key(KEY_G, true, true)
	main._process(0.0)
	U.key(KEY_G, false, true)
	main._process(0.0)
	main.hold = false
	U.check("G does nothing during the speed check", r.gravity_view == 0, "view %d" % r.gravity_view)


## The colour in the middle of a picture, averaged over 5 x 5 pixels (between the floor's lines).
static func _mid(img: Image) -> Color:
	var s := Color(0, 0, 0)
	var x0 := img.get_width() / 2 + 7
	var y0 := img.get_height() / 2 + 5
	for dy in 5:
		for dx in 5:
			s += img.get_pixel(x0 + dx, y0 + dy)
	return s / 25.0


func _picture_checks() -> void:
	var far := _mid(pics.far)
	var thr := _mid(pics.throat)
	var off := _mid(pics.throat_off)
	U.check("floor far out: yellow, 1 g", far.r > 0.8 and far.g > 0.7 and far.r > far.b + 0.35 and far.g > far.b + 0.3,
			"middle of the view %s" % far)
	U.check("floor in the middle of the throat: dark purple, 0.2 g", thr.b > thr.g + 0.1 and thr.r > thr.g + 0.05 and thr.v < 0.7
			and (thr - off).get_luminance() != 0.0, "middle of the view %s (without the view %s)" % [thr, off])
	# from the start: the sky (top fifth) is the same with the floor view and without, the floor (bottom fifth) changes
	# with the floor view, and the arrows show only with view 2
	var sky := _diff(pics.start_off, pics.start_floor, 0.0, 0.2)
	var flo := _diff(pics.start_off, pics.start_floor, 0.8, 1.0)
	var arr := _diff(pics.start_floor, pics.start_arrows, 0.0, 1.0)
	U.check("from the start: sky untouched, floor coloured, arrows drawn", sky.x < 3.0 / 255.0 and flo.y > 0.9 and arr.y > 0.03 and arr.y < 0.6,
			"sky differs by %.1f/255 at most; %.0f%% of the floor's pixels changed; arrows on %.0f%% of the view" % [sky.x * 255.0, 100.0 * flo.y, 100.0 * arr.y])


## Between two pictures, over the rows from y0 to y1 (fractions of the height): (largest
## difference of a channel, share of pixels that differ by more than 4/255).
static func _diff(a: Image, b: Image, y0: float, y1: float) -> Vector2:
	var mx := 0.0
	var n := 0
	var changed := 0
	for y in range(int(y0 * a.get_height()), int(y1 * a.get_height())):
		for x in a.get_width():
			var p := a.get_pixel(x, y)
			var q := b.get_pixel(x, y)
			var d := maxf(maxf(absf(p.r - q.r), absf(p.g - q.g)), absf(p.b - q.b))
			mx = maxf(mx, d)
			n += 1
			if d > 4.0 / 255.0:
				changed += 1
	return Vector2(mx, float(changed) / maxf(n, 1))
