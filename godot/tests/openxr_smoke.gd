extends SceneTree
## main through the real OpenXR path (run under Monado's simulated headset): no script errors,
## the check scene and panel exist, refresh rate API answers.
##   godot --path . --rendering-method mobile -s res://tests/openxr_smoke.gd

var main: Node3D
var frames := 0


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 240:
		var oxr := main.xr as OpenXRInterface
		print("in_xr ", main.in_xr, "  session state ", oxr.get_session_state() if oxr else -1,
				"  hands ", main.hands.size(), "  await_pose ", main.await_pose)
		if oxr:
			print("rates ", oxr.get_available_display_refresh_rates(), "  current ", oxr.display_refresh_rate)
		print("panel: ", main.overlay.get_node("Perf").text.replace("\n", " | "))
		print("overlay visible ", main.overlay.visible, "  feet l ", main.foot_l, "  head ", main.camera.transform.origin)
		return true
	return false
