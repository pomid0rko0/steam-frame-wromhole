extends SceneTree
## Same check as multiview_sphere.gd, its ball, without multiview: an ordinary camera at the head.
##   godot --path . --resolution 960x1080 -s res://tests/desktop_sphere.gd -- out_prefix app|mesh

const U := preload("res://tests/util.gd")
const CHART := preload("res://tests/multiview_sphere.gd").CHART
const RADIUS := preload("res://tests/multiview_sphere.gd").RADIUS

var main: Main
var frames := 0
var mode: String


func _initialize() -> void:
	mode = OS.get_cmdline_user_args()[1]
	main = load("res://main.tscn").instantiate() as Main
	main.toys.enabled = false            # this test draws its own ball
	main.xr_name = "none"
	main.show_check = false             # its balls and grids would cover the test ball
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 2:
		main.menu.visible = false     # nothing but the ball under test
		main.camera.position = Vector3(0.0, 1.6, 0.0)
		main.camera.basis = Basis.IDENTITY
		main.place(main.START_POS, main.START_FORWARD)      # chart to play: multiview_sphere.gd
	if frames == 3:
		if mode == "app":
			var pos := PackedVector4Array([Vector4(CHART.x, CHART.y, CHART.z, main.space.h)])
			main.renderer.set_objects(pos, PackedVector4Array([Vector4(1.0, 0.0, 0.0, RADIUS)]))
		else:
			var m := U.red(U.sphere(RADIUS))
			m.position = Vector3(CHART.y, CHART.z, CHART.x - main.START_POS.x)
			main.origin.add_child(m)
	if frames == 10:
		var img := root.get_texture().get_image()
		img.convert(Image.FORMAT_RGB8)
		img.save_png(OS.get_cmdline_user_args()[0] + "_" + mode + ".png")
		U.finish(self)
		return true
	return false
