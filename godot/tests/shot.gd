extends SceneTree
## A picture on the desktop: the scene at a pose, saved after a few frames (looking at a change).
##   godot --path . --resolution 1280x720 -s res://tests/shot.gd -- out.png [l yaw pitch [cube_dist]]

var main: Main
var frames := 0
var args: PackedStringArray


func _initialize() -> void:
	args = OS.get_cmdline_user_args()
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "none"
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 2:
		main.menu.visible = false
		main.camera.position = Vector3(0.0, 1.6, 0.0)
		if args.size() >= 4:
			main.hold = true
			main.place_on_axis(float(args[1]), float(args[2]), float(args[3]))
	if frames == 4 and args.size() >= 5:
		main.bench._cube(float(args[4]))
	if frames == 12:
		var img := root.get_texture().get_image()
		img.convert(Image.FORMAT_RGB8)
		img.save_png(args[0])
		return true
	return false
