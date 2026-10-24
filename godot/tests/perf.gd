extends SceneTree
## Relative frame cost on this machine (software Vulkan, so only ratios mean anything).
##   godot --path . --resolution 640x360 -s res://tests/perf.gd -- variant
## plain: the normal scene; check: the stereo check scene; check_noballs: without its ray-traced
## balls; check_nooverlay: without Godot's green overlay; plain_balls: normal scene + the balls;
## plain_scale80, plain_scale70: the normal scene at 80% / 70% 3D render scale.

var main: Node3D
var frames := 0
var t0 := 0
var gpu := 0.0
var variant: String


func _initialize() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	variant = OS.get_cmdline_user_args()[0]
	main = load("res://main.tscn").instantiate()
	main.xr_name = "none"
	main.show_check = variant.begins_with("check")
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 2:
		match variant:
			"plain_scale80", "plain_scale70":
				root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
				root.scaling_3d_scale = 0.8 if variant == "plain_scale80" else 0.7
			"check_noballs":
				main.material.set_shader_parameter("wh_nBall", 0)
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
				while pos.size() < 12:
					pos.append(Vector4.ZERO)
					col.append(Vector4.ZERO)
				main.material.set_shader_parameter("wh_ball", pos)
				main.material.set_shader_parameter("wh_ballCol", col)
				main.material.set_shader_parameter("wh_nBall", 3)
		RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	if frames == 110:
		t0 = Time.get_ticks_usec()
	if frames > 110:
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
	if frames == 210:
		print("%-16s wall %6.2f ms  gpu %6.2f ms per frame" % [variant, (Time.get_ticks_usec() - t0) / 100000.0, gpu / 100.0])
		return true
	return false
