extends SceneTree
## main through the real OpenXR path, under Monado's simulated headset (one rate, 20 Hz):
## no script errors; the panel measures the display rate from OpenXR's frame timing and agrees
## with the runtime, judges the frames; the desktop window's V-Sync is off while the session
## runs; with a stand-in for SteamVR's vrcmd, as if started from the Steam library, a trigger
## press sets this app's rate in SteamVR's settings and the panel asks for a restart; and frames
## made too slow for the display turn the plate red.
##   tools/test_openxr.sh

const APP_ID := "4242"

var main: Node3D
var frames := 0
var fake: String
var ok := true


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)


func check(what: String, cond: bool) -> void:
	ok = ok and cond
	print("%-60s %s" % [what, "ok" if cond else "WRONG"])


func _process(_delta: float) -> bool:
	frames += 1
	var p: Label3D = main.perf
	if frames == 2:
		_fake_steamvr()
		p.vrcmd = fake + "/vrcmd"
		p.find_app_setting()
		check("app setting found: steam.app.%s, 90 Hz" % APP_ID, p.steam_key == "steam.app." + APP_ID and p.stored == 90.0)
	if frames == 100:
		check("panel says the setting and the display differ", p.text.contains("в SteamVR задано 90 Гц, а шлем на 20"))
		check("panel offers the next rate", p.text.contains("курок: задать 96 Гц"))
		p.step_rate()
	if frames == 140:
		check("vrcmd stored 96", FileAccess.get_file_as_string(fake + "/value").strip_edges() == "96")
		check("vrcmd ran with SteamVR's library path", FileAccess.get_file_as_string(fake + "/lib").strip_edges() == fake)
		check("panel: 96 Hz from the next start", p.stored == 96.0 and p.text.contains("задано 96 Гц: выйди и запусти снова"))
		check("panel offers 108 next", p.text.contains("курок: задать 108 Гц"))
	if frames == 200:
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
		check("window V-Sync off", DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_DISABLED)
	if frames > 200:
		OS.delay_msec(70)           # longer than a 50 ms refresh: every frame misses one
	if frames == 260:
		print("slow frames: ", p.text.replace("\n", " | "), "  seconds ", p.seconds)
		check("too slow: judged, red", p.keeps_up(p.seconds) == false and p.plate_mat.albedo_color == p.COLOR_BAD)
		check("too slow: panel says so", p.text.contains("не успевает"))
		print("PASS" if ok else "FAIL")
		return true
	return false


## A stand-in for SteamVR: its settings file with this app at 90 Hz, and a vrcmd that keeps the
## value in a file and notes the library path it was given.
func _fake_steamvr() -> void:
	fake = ProjectSettings.globalize_path("user://fake_steamvr")
	DirAccess.make_dir_recursive_absolute(fake + "/.config/openvr/config")
	var f := FileAccess.open(fake + "/.config/openvr/config/steamvr.vrsettings", FileAccess.WRITE)
	f.store_string(JSON.stringify({"steam.app." + APP_ID: {"preferredRefreshRate": 90}, "steamvr": {}}))
	f.close()
	f = FileAccess.open(fake + "/vrcmd", FileAccess.WRITE)
	f.store_string("#!/bin/sh\nd=$(dirname \"$0\")\necho \"$LD_LIBRARY_PATH\" > \"$d/lib\"\n"
			+ "case \"$1\" in\n--set-settings-float) echo \"$3\" > \"$d/value\";;\n"
			+ "--settings-float) echo \"$2: $(cat \"$d/value\")\";;\nesac\n")
	f.close()
	OS.execute("chmod", ["+x", fake + "/vrcmd"])
	DirAccess.remove_absolute(fake + "/value")
	OS.set_environment("HOME", fake)
	OS.set_environment("SteamAppId", APP_ID)
