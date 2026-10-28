extends SceneTree
## The XR view through the simulated headset (fake_hmd.gd, two eyes in one multiview pass) with
## foveation off, with the 3D pass split alone, on (the runtime's map), or own (our map,
## Foveation.OWN_MAPS): tools/fdm_check.sh runs it on the Steam
## Frame's GPU driver (Turnip, no GPU) and reads from the driver's trace how it rendered the pass.
## The simulated headset hands Godot a density map of its own making (XRVRS, the one Godot makes
## where the runtime has none), so the viewport has a density map to attach. The eyes' size in
## pixels is the second argument (tools/fdm_check.sh: 1728, as on the Frame).
##   godot --path . -s res://tests/fdm_check.gd -- off|split|on|own [eye size in pixels]

const U := preload("res://tests/util.gd")


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
	var n := int(OS.get_cmdline_user_args()[1]) if OS.get_cmdline_user_args().size() > 1 else 1000
	hmd = U.headset(0, 0.0, Vector2i(n, n), Headset.new())
	main = load("res://main.tscn").instantiate()
	main.toys.enabled = false            # the driver's passes, the same with or without toys
	main.xr_name = "FakeHMD"
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 2:
		main.foveation.set_level({"on": Foveation.LEVELS, "own": 4}.get(mode, 0), mode == "split")
		print("fdm_check: %s, vrs_mode %d, split %s, view %dx%d" % [mode, main.xr_view.vrs_mode,
				main.foveation.split_pass.enabled, hmd.size.x, hmd.size.y])
	if frames == 14:
		U.finish(self, hmd)
		return true
	return false
