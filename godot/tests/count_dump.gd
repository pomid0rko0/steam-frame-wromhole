extends SceneTree
## What the curved region's toy search does per pixel at a scene of play_scenes.gd: the ray tracer
## with every toy over the whole view (main.TOYS_WHOLE), compiled with WH_COUNT, colours each pixel
## by its search's counts (wormhole_core.gdshaderinc: samples of the path, window solves,
## candidates searched). Prints their means over the view and over its waves (an 8x8 tile runs as
## long as its dearest pixel), and where the dearest are.
##   godot --path . --rendering-method mobile --resolution 256x256 -s res://tests/count_dump.gd -- scene [fov]
## (under xvfb-run; scene: an index into PlayScenes.SCENES)

var main: Node3D
var frames := 0
var scene := 0
var fov := 100.0
var shot := -1


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	scene = int(a[0]) if a.size() > 0 else 7
	if a.size() > 1:
		fov = float(a[1])
	main = load("res://main.tscn").instantiate()
	main.xr_name = "none"
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
		main.set_toy_mode(main.TOYS_WHOLE)
		var sh := Shader.new()
		sh.code = main.SHADER_BALLS.code.replace("shader_type spatial;", "shader_type spatial;\n#define WH_COUNT")
		main.material.shader = sh
		shot = frames
		return false
	if frames < shot + 30:
		return false
	_report(root.get_texture().get_image(), PlayScenes.SCENES[scene][0])
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
