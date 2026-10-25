extends SceneTree
## The XR view through the simulated headset (fake_hmd.gd, two eyes in one multiview pass) with
## foveation off, with the 3D pass split alone, or on: tools/fdm_check.sh runs it on the Steam
## Frame's GPU driver (Turnip, no GPU) and reads from the driver's trace how it rendered the pass.
## The simulated headset hands Godot a density map of its own making (XRVRS, the one Godot makes
## where the runtime has none), so the viewport has a density map to attach. The eyes' size in
## pixels is the second argument (tools/fdm_check.sh: 1728, as on the Frame).
##   godot --path . -s res://tests/fdm_check.gd -- off|split|on [eye size in pixels]

class Headset extends "res://tests/fake_hmd.gd":
	var vrs := XRVRS.new()

	func _get_vrs_texture() -> RID:
		return vrs.make_vrs_texture(Vector2(size), PackedVector2Array([Vector2(0.1, 0.0), Vector2(-0.1, 0.0)]))

var main: Node3D
var hmd: Headset
var frames := 0
var mode: String


func _initialize() -> void:
	mode = OS.get_cmdline_user_args()[0]
	hmd = Headset.new()
	if OS.get_cmdline_user_args().size() > 1:
		var n := int(OS.get_cmdline_user_args()[1])
		hmd.size = Vector2i(n, n)
	hmd.setup(Transform3D(Basis.IDENTITY, Vector3(0.0, 1.6, 0.0)), 0.064, 0.0, Vector4(-1.0, 1.0, -1.1, 1.1))
	XRServer.add_interface(hmd)
	hmd.initialize()
	XRServer.primary_interface = hmd
	main = load("res://main.tscn").instantiate()
	main.xr_name = "FakeHMD"
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 2:
		main.set_foveation(main.FOVEATION_LEVELS if mode == "on" else 0, mode == "split")
		print("fdm_check: %s, vrs_mode %d, split %s, view %dx%d" % [mode, main.xr_view.vrs_mode,
				main.split_pass.enabled, hmd.size.x, hmd.size.y])
	if frames == 14:
		hmd.uninitialize()
		XRServer.primary_interface = null
		XRServer.remove_interface(hmd)
		return true
	return false
