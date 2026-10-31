extends SceneTree
## The fillet's tables as the app builds them (WormholeSpace.shader_tables), raw float32 into one
## file each: ref/test_space_gpu.py checks the shader with exactly these and compares them with
## ref/tables.py's.
##   godot --headless --path . -s res://tests/dump_tables.gd -- out_prefix [rho0 h R]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var p := [Main.THROAT_RADIUS, Main.HALF_LENGTH, Main.FILLET]
	if args.size() >= 4:
		p = [float(args[1]), float(args[2]), float(args[3])]
	var space := WormholeSpace.new(p[0], p[1], p[2])
	var names := ["tab", "ptab", "ytab"]
	var imgs := space.shader_tables()
	for i in 3:
		var f := FileAccess.open(args[0] + "_" + names[i] + ".f32", FileAccess.WRITE)
		f.store_buffer(imgs[i].get_data())
		f.close()
	quit(0)
