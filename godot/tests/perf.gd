extends SceneTree
## A scene for tools/adreno_stats.sh (what the headset's compiler makes of its ray tracer), and its
## frame time on this machine (software Vulkan: only ratios mean anything, and not for the shader's
## inner costs).
##   godot --path . --resolution 320x180 -s res://tests/perf.gd -- scene [shader]
## plain: the start, no movable objects; balls: the same with the stereo check's three red balls;
## check: the stereo check scene (with its cube); near: 6.5 m from the centre, the wormhole filling
## most of the view (the costly rays); away: the same spot looking away from it. shader: another ray
## tracer's path (res://shaders/ab/1/wormhole.gdshader from tools/ab_shaders.sh), set before
## anything is drawn, so only it is compiled.

var main: Node3D
var frames := 0
var gpu := 0.0
var t0 := 0
var scene: String
var shader_path := ""


func _initialize() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	scene = OS.get_cmdline_user_args()[0]
	if OS.get_cmdline_user_args().size() > 1:
		shader_path = OS.get_cmdline_user_args()[1]
	main = load("res://main.tscn").instantiate()
	main.toys.enabled = false           # the scenes set their own
	main.xr_name = "none"
	main.show_check = scene == "check"
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 1 and shader_path != "":
		main.tracer.material.shader = load(shader_path)
	if frames == 2:
		main.menu.visible = false        # the scene alone
		if scene == "near":
			main.place(Vector3(6.5, 0.0, 0.0), main.START_FORWARD)
		elif scene == "away":
			main.place(Vector3(6.5, 0.0, 0.0), -main.START_FORWARD)
		elif scene == "balls":
			var pos := PackedVector4Array()
			var col := PackedVector4Array()
			for c in CheckScene.BALLS:
				pos.append(Vector4(c.x, c.y, c.z, main.space.h))
				col.append(Vector4(0.85, 0.08, 0.06, CheckScene.BALL_RADIUS))
			main.tracer.set_objects(pos, col)
		RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	if frames == 110:
		t0 = Time.get_ticks_usec()
	if frames > 110:
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
	if frames == 210:
		print("%-16s wall %6.2f ms  gpu %6.2f ms per frame" % [scene, (Time.get_ticks_usec() - t0) / 100000.0, gpu / 100.0])
		return true
	return false
