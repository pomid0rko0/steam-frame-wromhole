extends SceneTree
## Dynamic resolution in the real render path: the simulated headset (tests/fake_hmd.gd) at the
## shell's edge, where software Vulkan is far slower than the headset's frame time, so the
## controller must step the resolution down; the eye images keep their size. Exit status 1 on
## any failure:
##   godot --path . -s res://tests/render_scale_xr_test.gd

var main: Node3D
var hmd
var frames := 0
var fails := 0
var gpu_full := 0.0


func _initialize() -> void:
	hmd = preload("res://tests/fake_hmd.gd").new()
	hmd.size = Vector2i(480, 480)
	hmd.setup(Transform3D(Basis.IDENTITY, Vector3(0.0, 1.6, 0.0)), 0.064, 0.0, Vector4(-1.0, 1.0, -1.0, 1.0))
	XRServer.add_interface(hmd)
	hmd.initialize()
	XRServer.primary_interface = hmd
	main = load("res://main.tscn").instantiate()
	main.xr_name = "FakeHMD"
	root.add_child(main)


func _check(name: String, ok: bool, detail: String) -> void:
	print(("PASS " if ok else "FAIL ") + name + "  " + detail)
	if not ok:
		fails += 1


func _gpu() -> float:
	return RenderingServer.viewport_get_measured_render_time_gpu(main.xr_view.get_viewport_rid())


func _process(_delta: float) -> bool:
	frames += 1
	match frames:
		3:
			_check("off unless started (no OpenXR here)", main.render_scale == null, "")
			main.place(1.0, Vector3(4.0, 0.0, 0.0), Vector3(-1.0, 0.0, 0.0))
			RenderingServer.viewport_set_measure_render_time(main.xr_view.get_viewport_rid(), true)
		8:
			gpu_full = _gpu()
			main.start_auto_resolution()
		60:
			var s: float = main.xr_view.scaling_3d_scale
			_check("too slow for 72 Hz: the resolution goes down", s < 1.0, "scale %.1f, GPU %.1f ms at full resolution" % [s, gpu_full])
			_check("and the GPU time with it", _gpu() < 0.8 * gpu_full, "%.1f ms, was %.1f" % [_gpu(), gpu_full])
			var size: Vector2 = main.xr_view.get_texture().get_size()
			_check("the eye images keep their size", size == Vector2(480, 480), "%s" % size)
			print("FAILURES: ", fails)
			XRServer.primary_interface = null
			hmd.uninitialize()
			XRServer.remove_interface(hmd)
			quit(1 if fails > 0 else 0)
	return false
