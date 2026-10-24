extends SceneTree
## GPU time per frame along the walk from the start through the throat, looking ahead, through
## the simulated headset (tests/fake_hmd.gd). Software Vulkan: only the ratios between places
## mean anything. It showed that a frame costs the most at the shell's edge, about twice the start.
##   godot --path . -s res://tests/path_cost.gd -- x_from x_to steps [pitch_deg] [eye_px]
## x: the feet's chart A position on the x axis (the start is 10, the shell's edge 4); negative
## values are the same place in universe B. One line per frame: x, the head's l, GPU ms.

var main: Node3D
var hmd
var frames := 0
var xs: Array[float] = []
var k := 0
var sub := 0


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var n := int(a[2])
	for i in n:
		xs.append(lerpf(float(a[0]), float(a[1]), float(i) / float(maxi(n - 1, 1))))
	var pitch := deg_to_rad(float(a[3])) if a.size() > 3 else 0.0
	var px := int(a[4]) if a.size() > 4 else 480
	hmd = preload("res://tests/fake_hmd.gd").new()
	hmd.size = Vector2i(px, px)
	hmd.setup(Transform3D(Basis.from_euler(Vector3(pitch, 0.0, 0.0)), Vector3(0.0, 1.6, 0.0)), 0.064, 0.0, Vector4(-1.0, 1.0, -1.0, 1.0))
	XRServer.add_interface(hmd)
	hmd.initialize()
	XRServer.primary_interface = hmd
	main = load("res://main.tscn").instantiate()
	main.xr_name = "FakeHMD"
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames < 5:
		return false
	if frames == 5:
		RenderingServer.viewport_set_measure_render_time(main.xr_view.get_viewport_rid(), true)
	if k >= xs.size():
		XRServer.primary_interface = null
		hmd.uninitialize()
		XRServer.remove_interface(hmd)
		quit(0)
		return true
	# each place: put the feet there, then three frames measured after one to settle
	if sub == 0:
		var side := 1.0 if xs[k] >= 0.0 else -1.0
		main.place(side, Vector3(absf(xs[k]) * side, 0.0, 0.0), Vector3(-1.0, 0.0, 0.0))
	elif sub >= 2:
		var gpu := RenderingServer.viewport_get_measured_render_time_gpu(main.xr_view.get_viewport_rid())
		print("x %.3f head_l %.4f gpu %.2f" % [xs[k], main.material.get_shader_parameter("head_l"), gpu])
	sub += 1
	if sub > 4:
		sub = 0
		k += 1
	return false
