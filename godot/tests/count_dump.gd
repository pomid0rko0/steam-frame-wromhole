extends SceneTree
## What the curved region's toy search does per pixel at a scene of play_scenes.gd: the ray tracer
## with every toy over the whole view (main.TOYS_WHOLE), compiled with WH_COUNT, colours each pixel
## by its search's counts (wormhole_core.gdshaderinc: samples of the path, window solves,
## candidates searched). Prints their means over the view and over its waves (an 8x8 tile runs as
## long as its dearest pixel), and where the dearest are.
##   godot --path . --rendering-method mobile --resolution 256x256 -s res://tests/count_dump.gd -- scene [fov] [split] [xr]
## (under xvfb-run; scene: an index into PlayScenes.SCENES; split: the frame split by the stencil as
## in play, every ray tracer counting, the counts kept only where stencil 2 or 3 is; xr: both eyes
## of the scripted headset, fake_hmd.gd, 256x256 each, side by side)

var main: Node3D
var frames := 0
var scene := 0
var fov := 100.0
var shot := -1
var split := false          # split: the frame as the app splits it; counts only where the shell's toys are looked for
var counts: Image
var hmd = null               # xr: the scripted headset


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	scene = int(a[0]) if a.size() > 0 else 7
	if a.size() > 1 and a[1] != "split":
		fov = float(a[1])
	split = a.has("split")
	main = load("res://main.tscn").instantiate()
	main.xr_name = "none"
	if a.has("xr"):
		hmd = preload("res://tests/fake_hmd.gd").new()
		hmd.size = Vector2i(256, 256)
		hmd.setup(Transform3D(Basis.IDENTITY, Vector3(0.0, 1.6, 0.0)), 0.064, 0.0, Vector4(-1.25, 0.95, -1.15, 1.05))
		XRServer.add_interface(hmd)
		hmd.initialize()
		XRServer.primary_interface = hmd
		main.xr_name = "FakeHMD"
	main.physics = true
	main.throw_toys = false
	root.add_child(main)


func _process(_d: float) -> bool:
	frames += 1
	if frames == 2:
		main._throw()
		main._drop()
		for k in 12 * 60:
			main.world.step(1.0 / 60.0, [])
		main.hold = true
		main.perf.visible = false
		main.camera.fov = fov
		if main.overlay:
			main.overlay.visible = false
	if frames < 4 or main.warm_frames > 0:
		return false
	if shot < 0:
		var s: Array = PlayScenes.SCENES[scene]
		PlayScenes.place(main, s[5], s[2], s[3], s[4])
		if split:
			_shaders("#define WH_COUNT")
		else:
			main.set_toy_mode(main.TOYS_WHOLE)
			var sh := Shader.new()
			sh.code = main.SHADER_BALLS.code.replace("shader_type spatial;", "shader_type spatial;\n#define WH_COUNT")
			main.material.shader = sh
		shot = frames
		return false
	if frames < shot + 30:
		return false
	if split and counts == null:
		# then which ray tracer each pixel has (split_test.gd's colours): the counts only where the
		# shell's toys are looked for (stencil 2 and 3)
		counts = _picture()
		_shaders("#define WH_KIND_COLOUR %.3f")
		shot = frames
		return false
	if split:
		var cls := _picture()
		cls.save_png("user://kinds_%d.png" % scene)       # what each pixel shows, which ray tracer
		for y in cls.get_height():
			for x in cls.get_width():
				if roundi((cls.get_pixel(x, y).srgb_to_linear().g - 0.1) / 0.2) < 2:
					counts.set_pixel(x, y, Color(0, 0, 0))
		_report(counts, PlayScenes.SCENES[scene][0] + ", split")
	else:
		_report(_picture(), PlayScenes.SCENES[scene][0])
	quit(0)
	return true


func _report(img: Image, name: String) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var tot := Vector3.ZERO
	var tiles := Vector3.ZERO
	var nt := 0
	var dear := []
	for ty in range(0, h - 7, 8):
		for tx in range(0, w - 7, 8):
			var mx := Vector3.ZERO
			for y in range(ty, ty + 8):
				for x in range(tx, tx + 8):
					var c := img.get_pixel(x, y).srgb_to_linear()
					var v := Vector3(roundf(c.r * 255.0), roundf(c.g * 255.0), roundf(c.b * 255.0))
					tot += v
					mx = mx.max(v)
			tiles += mx
			nt += 1
			dear.append([mx.x, tx, ty])
	var n := float(w * h)
	print("count: %s, %dx%d, fov %.0f" % [name, w, h, fov])
	print("count: per pixel: samples %.1f, of the object hit %.1f, candidates %.2f" % [tot.x / n, tot.y / n, tot.z / n])
	print("count: per wave (an 8x8 tile's most): samples %.1f, of the object hit %.1f, candidates %.2f"
			% [tiles.x / nt, tiles.y / nt, tiles.z / nt])
	dear.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var top := []
	for k in mini(8, dear.size()):
		top.append("%d at (%d, %d)" % dear[k])
	print("count: the dearest waves' samples: ", ", ".join(top))
	img.save_png("user://count_%d.png" % scene)


## Every split ray tracer's shader with a define (%.3f: the stencil's colour, as split_test.gd).
func _shaders(define: String) -> void:
	for m in [[main.material, main.SHADER_BALLS, 2], [main.near_material, main.SHADER_BALLS_NEAR, 3],
			[main.flat_material, main.SHADER_BALLS_FLAT, 1], [main.plain_material, main.SHADER_PLAIN, 0]]:
		var sh := Shader.new()
		var d := define % (0.1 + 0.2 * m[2]) if define.contains("%") else define
		sh.code = m[1].code.replace("shader_type spatial;", "shader_type spatial;\n" + d)
		m[0].shader = sh


## What was drawn: the window, or with xr both eyes side by side.
func _picture() -> Image:
	if hmd == null:
		return root.get_texture().get_image()
	var eyes := []
	for layer in 2:
		var img: Image = RenderingServer.texture_2d_layer_get(main.xr_view.get_texture().get_rid(), layer)
		img.convert(Image.FORMAT_RGBA8)
		eyes.append(img)
	var both := Image.create(2 * eyes[0].get_width(), eyes[0].get_height(), false, Image.FORMAT_RGBA8)
	for k in 2:
		both.blit_rect(eyes[k], Rect2i(Vector2i.ZERO, eyes[k].get_size()), Vector2i(k * eyes[0].get_width(), 0))
	return both
