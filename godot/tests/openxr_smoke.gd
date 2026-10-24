extends SceneTree
## main through the real OpenXR path, under Monado's simulated headset (one rate, 20 Hz):
## no script errors; the panel measures the display rate from OpenXR's frame timing and agrees
## with the runtime, judges the frames; with a stand-in for SteamVR's vrcmd, as if started from
## the Steam library, a trigger press sets this app's rate in SteamVR's settings, and as the
## display stays at 20 Hz the panel asks for a restart (a display that follows is answered too);
## the left trigger steps the render scale and keeps it; and frames made too slow for the display
## turn the plate red.
##   tools/test_openxr.sh

const APP_ID := "4242"

var main: Node3D
var frames := 0
var fake: String
var ok := true


func _initialize() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://settings.cfg"))
	main = load("res://main.tscn").instantiate()
	root.add_child(main)


func check(what: String, cond: bool) -> void:
	ok = ok and cond
	print("%-60s %s" % [what, "ok" if cond else "WRONG"])


func _process(_delta: float) -> bool:
	frames += 1
	var p: Label3D = main.perf
	if frames > 2 and p == null:
		print("no panel: FAIL")
		return true
	if frames == 2:
		var home := OS.get_environment("HOME")
		_fake_steamvr()
		p.vrcmd = fake + "/vrcmd"
		p.find_app_setting()
		OS.set_environment("HOME", home)     # user:// follows HOME
		check("app setting found: steam.app.%s, 90 Hz" % APP_ID, p.steam_key == "steam.app." + APP_ID and p.stored == 90.0)
	if frames == 100:
		check("panel says the setting and the display differ", p.text.contains("в SteamVR задано 90 Гц, а шлем на 20"))
		check("panel offers the next rate", p.text.contains("курок: 96 Гц"))
		OS.set_environment("LD_PRELOAD", "/nonexistent/overlay.so")    # as Steam sets it
		p.step_rate()
	if frames == 180:
		check("vrcmd stored 96", FileAccess.get_file_as_string(fake + "/value").strip_edges() == "96")
		check("vrcmd ran with SteamVR's library path", FileAccess.get_file_as_string(fake + "/lib").strip_edges() == fake)
		check("vrcmd ran without Steam's preload", FileAccess.get_file_as_string(fake + "/preload").strip_edges() == "")
		check("display stayed: panel asks for a restart", p.stored == 96.0 and p.text.contains("задано 96 Гц: выйди и запусти снова"))
		check("panel offers 108 next", p.text.contains("курок: 108 Гц"))
		OS.set_environment("LD_PRELOAD", "")
		p.requested = 20.0          # as if the setting had been 20 Hz: the display follows
		p.request_age = 0.0
	if frames == 250:
		check("display followed: panel says so", p.text.contains("шлем перешёл на 20 Гц"))
		check("full resolution at first", p.target.scaling_3d_scale == 1.0 and p.text.contains("разрешение 100% (128 на глаз)"))
		p.step_scale()
		var cfg := ConfigFile.new()
		cfg.load("user://settings.cfg")
		check("left trigger: 90% render scale, kept", is_equal_approx(p.target.scaling_3d_scale, 0.9) and cfg.get_value("render", "scale", 0.0) == 0.9)
		check("panel shows it and the next", p.text.contains("разрешение 90% (115 на глаз)") and p.text.contains("левый курок: разрешение 80%"))
		for i in 3:
			p.step_scale()
		check("after 70% back to 100%", p.target.scaling_3d_scale == 1.0)
	if frames == 260:
		var oxr := main.xr as OpenXRInterface
		print("in_xr ", main.in_xr, "  session state ", oxr.get_session_state() if oxr else -1,
				"  hands ", main.hands.size(), "  await_pose ", main.await_pose)
		print("runtime: rates ", oxr.get_available_display_refresh_rates() if oxr else [],
				"  current ", oxr.display_refresh_rate if oxr else 0.0)
		print("measured %.3f Hz, seconds %s" % [p.rate, p.seconds])
		print("panel: ", p.text.replace("\n", " | "))
		check("in XR", main.in_xr and oxr != null)
		if oxr:
			check("measured rate = runtime's", absf(p.rate - oxr.display_refresh_rate) < 0.5)
			check("panel heads with the rate", p.text.begins_with("%.0f Гц · " % oxr.display_refresh_rate))
		check("frames judged, green", p.keeps_up(p.seconds) == true and p.plate_mat.albedo_color == p.COLOR_OK)
	if frames > 260:
		OS.delay_msec(70)           # longer than a 50 ms refresh: every frame misses one
	if frames == 320:
		print("slow frames: ", p.text.replace("\n", " | "), "  seconds ", p.seconds)
		check("too slow: judged, red", p.keeps_up(p.seconds) == false and p.plate_mat.albedo_color == p.COLOR_BAD)
		check("too slow: panel says so", p.text.contains("не успевает"))
		print("PASS" if ok else "FAIL")
		return true
	return false


## A stand-in for SteamVR: its settings file with this app at 90 Hz, and a vrcmd that keeps the
## value in a file and notes the library path and preload it was given.
func _fake_steamvr() -> void:
	fake = ProjectSettings.globalize_path("user://fake_steamvr")
	DirAccess.make_dir_recursive_absolute(fake + "/.config/openvr/config")
	var f := FileAccess.open(fake + "/.config/openvr/config/steamvr.vrsettings", FileAccess.WRITE)
	f.store_string(JSON.stringify({"steam.app." + APP_ID: {"preferredRefreshRate": 90}, "steamvr": {}}))
	f.close()
	f = FileAccess.open(fake + "/vrcmd", FileAccess.WRITE)
	f.store_string("#!/bin/sh\nd=$(dirname \"$0\")\necho \"$LD_LIBRARY_PATH\" > \"$d/lib\"\necho \"$LD_PRELOAD\" > \"$d/preload\"\n"
			+ "case \"$1\" in\n--set-settings-float) echo \"$3\" > \"$d/value\";;\n"
			+ "--settings-float) echo \"$2: $(cat \"$d/value\")\";;\nesac\n")
	f.close()
	OS.execute("chmod", ["+x", fake + "/vrcmd"])
	DirAccess.remove_absolute(fake + "/value")
	OS.set_environment("HOME", fake)
	OS.set_environment("SteamAppId", APP_ID)
