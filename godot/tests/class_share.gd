extends SceneTree
## Scene s of play_scenes.gd: the share of the view in each stencil class, and of class 3 what its
## pixels show (kind colours, as split_test.gd: 100 + a ball's index, 200 + a cube's, below 100
## the sky, the floor, the static objects).
##   godot --path . --rendering-method mobile --resolution 640x640 -s res://tests/class_share.gd -- s
## (under xvfb-run)
var main
var f := 0
var scene := 7
func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0:
		scene = int(a[0])
	main = load("res://main.tscn").instantiate()
	main.xr_name = "none"
	main.physics = true
	main.throw_toys = false
	root.add_child(main)
func _process(_d: float) -> bool:
	f += 1
	if f == 2:
		main._throw(); main._drop()
		for k in 12 * 60: main.world.step(1.0 / 60.0, [])
		main.hold = true
		main.perf.visible = false
		main.camera.fov = 100.0
		if main.overlay: main.overlay.visible = false
		for m in [[main.material, main.SHADER_BALLS, 2], [main.near_material, main.SHADER_BALLS_NEAR, 3],
				[main.flat_material, main.SHADER_BALLS_FLAT, 1], [main.plain_material, main.SHADER_PLAIN, 0]]:
			var s := Shader.new()
			s.code = m[1].code.replace("shader_type spatial;", "shader_type spatial;\n#define WH_KIND_COLOUR %.3f" % (0.1 + 0.2 * m[2]))
			m[0].shader = s
	if f < 4 or main.warm_frames > 0:
		return false
	if f < 40:
		if f == 39:
			var s: Array = PlayScenes.SCENES[scene]
			PlayScenes.place(main, s[5], s[2], s[3], s[4])
		return false
	if f < 45:
		return false
	var img: Image = root.get_texture().get_image()
	var cls := [0, 0, 0, 0]
	var kinds := {}
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y).srgb_to_linear()
			var k := clampi(roundi((c.g - 0.1) / 0.2), 0, 3)
			cls[k] += 1
			if k == 3:
				var kind := roundi(c.r * 255.0)
				kinds[kind] = kinds.get(kind, 0) + 1
	var n := float(img.get_width() * img.get_height())
	print("classes: ", cls.map(func(v): return "%.1f%%" % (100.0 * v / n)))
	var ks := kinds.keys()
	ks.sort()
	for k in ks:
		print("class 3 shows kind %d: %.1f%% of the view" % [k, 100.0 * kinds[k] / n])
	print("near toys: ", main.near_mask)
	quit()
	return true
