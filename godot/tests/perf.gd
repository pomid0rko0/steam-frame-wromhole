extends SceneTree
## Relative frame cost on this machine (software Vulkan, so only ratios mean anything).
##   godot --path . --resolution 640x360 -s res://tests/perf.gd -- variant
## plain: the normal scene; check: the stereo check scene; check_noballs: without its ray-traced
## balls; check_nooverlay: without Godot's green overlay; plain_balls: normal scene + the balls;
## near: 6.5 m from the centre, the wormhole filling most of the view (the costly rays);
## away: the same spot looking away from it. A suffix _scale80 or _scale70 renders at 80% / 70%
## 3D render scale (plain_scale80, near_scale70, ...). A second argument, a shader's path (such
## as res://shaders/ab/1/wormhole.gdshader from tools/ab_shaders.sh), replaces the ray tracer.
## A suffix _xr: through the scripted headset (fake_hmd.gd), as in the headset: multiview, the
## shaders compiled as the Frame runs them (tools/adreno_stats.sh plain_xr).

var main: Node3D
var frames := 0
var t0 := 0
var gpu := 0.0
var variant: String
var shader_path := ""


func _initialize() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	variant = OS.get_cmdline_user_args()[0]
	if OS.get_cmdline_user_args().size() > 1:
		shader_path = OS.get_cmdline_user_args()[1]
	main = load("res://main.tscn").instantiate()
	main.physics = false            # the scenes set their own balls
	main.xr_name = "none"
	if variant.ends_with("_xr"):
		variant = variant.trim_suffix("_xr")
		var hmd = preload("res://tests/fake_hmd.gd").new()
		hmd.size = Vector2i(256, 256)
		hmd.setup(Transform3D(Basis.IDENTITY, Vector3(0.0, 1.6, 0.0)), 0.064, 0.0, Vector4(-1.25, 0.95, -1.15, 1.05))
		XRServer.add_interface(hmd)
		hmd.initialize()
		XRServer.primary_interface = hmd
		main.xr_name = "FakeHMD"
	main.show_check = variant.begins_with("check")
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 1 and shader_path != "":
		main.material.shader = load(shader_path)     # before anything is drawn: only it is compiled
	if frames == 2:
		main.perf.visible = false        # the scene alone
		for sc in [80, 70]:
			if variant.ends_with("_scale%d" % sc):
				root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
				root.scaling_3d_scale = sc / 100.0
		if variant.begins_with("near"):
			main.place(1.0, Vector3(6.5, 0.0, 0.0), main.START_FORWARD)
		elif variant.begins_with("away"):
			main.place(1.0, Vector3(6.5, 0.0, 0.0), -main.START_FORWARD)
		match variant:
			"check_noballs":
				main.set_balls(PackedVector4Array(), PackedVector4Array())
			"check_nooverlay":
				main.overlay.visible = false
			"check_nogrid":
				main.overlay.get_node("Grid").visible = false
			"check_nowire":
				for c in main.overlay.get_children():
					c.visible = c.name == "Grid"
			"plain_balls":
				var pos := PackedVector4Array()
				var col := PackedVector4Array()
				for c in main.CHECK_BALLS:
					pos.append(Vector4(c.x, c.y, c.z, main.space.h))
					col.append(Vector4(0.85, 0.08, 0.06, main.CHECK_BALL_RADIUS))
				main.set_balls(pos, col)
		RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	if frames == 110:
		t0 = Time.get_ticks_usec()
	if frames > 110:
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
	if frames == 210:
		print("%-16s wall %6.2f ms  gpu %6.2f ms per frame" % [variant, (Time.get_ticks_usec() - t0) / 100000.0, gpu / 100.0])
		return true
	return false
