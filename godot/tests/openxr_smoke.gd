extends SceneTree
## main through the real OpenXR path, under Monado's simulated headset (one rate, 20 Hz):
## no script errors; the panel measures the display rate from OpenXR's frame timing and agrees
## with the runtime, judges the frames; with a stand-in for SteamVR's vrcmd, as if started from
## the Steam library, a ray pointed at a rate button and a trigger pull set this app's rate in
## SteamVR's settings, and as the display stays at 20 Hz the panel asks for a restart (a display
## that follows is answered too); choices made while vrcmd runs end with the last one written;
## a scale button sets the render scale and keeps it; foveation starts with our narrow map; a
## foveation button turns foveated rendering
## on at its level (the XR viewport's density map, the 3D pass split, Godot's own map under Monado,
## which has no XR_FB_foveation), keeps it, and takes the render scale back to 100%, and a scale
## below 100% turns it off again; our own density map comes from a texture, and the order of its
## steps switches (the width or the height first); the gaze dot shows and hides; the gravity row
## switches the gravity view (the floor, the arrows, off) and its ray tracers; frames made too slow for the display
## turn the plate red; and the speed check's button runs it through (bench.gd: the comparison at
## 72 Hz, then the tour at 120 Hz, which Monado does not offer: it stays at 20) and puts the
## rate, the shader and the viewer back.
##   tools/test_openxr.sh

const APP_ID := "4242"

var main: Node3D
var frames := 0
var fake: String
var ok := true
var bench_stored := 0.0
var bench_auto := false
var bench_seen := false


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
		# a build made for measuring starts the speed check by itself: not before its turn here
		bench_auto = main.bench.auto
		main.bench.auto = false
		var home := OS.get_environment("HOME")
		_fake_steamvr()
		p.vrcmd = fake + "/vrcmd"
		p.find_app_setting()
		OS.set_environment("HOME", home)     # user:// follows HOME
		check("app setting found: steam.app.%s, 90 Hz" % APP_ID, p.steam_key == "steam.app." + APP_ID and p.stored == 90.0)
	if frames == 60:
		p.seconds.clear()       # judge after the start: loading and compiling cost frames there
	if frames == 100:
		check("panel says the setting and the display differ", p.text.contains("в SteamVR задано 90 Гц, а шлем на 20"))
		check("rate buttons: SteamVR's per-app choices", p.rate_options == p.FRAME_RATES)
		check("20 Hz is not among them, 90 Hz is chosen (yellow)", _color(p, "rate", 90.0) == p.COLOR_PENDING)
		OS.set_environment("LD_PRELOAD", "/nonexistent/overlay.so")    # as Steam sets it
		# the right hand points at the 96 button from 0.8 m in front of the panel and pulls the trigger
		var at := _button_point(p, "rate", 96.0)
		var from := at + p.transform.basis.z * 0.8
		p.point(1, from, (at - from).normalized(), 0.0)
		check("ray on the 96 button: hovered, the ray drawn", p.hover[1] == _index(p, "rate", 96.0) and p.rays[1].visible)
		p.point(1, from, (at - from).normalized(), 1.0)
		p.point(1, from, (at - from).normalized(), 0.0)
		check("trigger pulled: 96 chosen, being written", p.desired == 96.0 and p.writing)
		check("panel says it is switching", p.text.contains("переключаю на 96 Гц"))
	if frames == 180:
		check("vrcmd stored 96", FileAccess.get_file_as_string(fake + "/value").strip_edges() == "96")
		check("vrcmd ran with SteamVR's library path", FileAccess.get_file_as_string(fake + "/lib").strip_edges() == fake)
		check("vrcmd ran without Steam's preload", FileAccess.get_file_as_string(fake + "/preload").strip_edges() == "")
		check("display stayed: panel asks for a restart", p.stored == 96.0 and p.text.contains("задано 96 Гц: выйди и запусти снова"))
		check("96 shown chosen, not in effect", _color(p, "rate", 96.0) == p.COLOR_PENDING)
		OS.set_environment("LD_PRELOAD", "")
		# three choices in a row while vrcmd runs: the last one is what ends up written
		p.choose_rate(108.0)
		p.choose_rate(120.0)
		p.choose_rate(144.0)
	if frames == 230:
		check("quick choices: the last one written", FileAccess.get_file_as_string(fake + "/value").strip_edges() == "144" and p.stored == 144.0 and not p.writing)
		p.point(1, Vector3.ZERO, Vector3.FORWARD, 0.0)      # the ray off the panel
		p.requested = 20.0          # as if the setting had been 20 Hz: the display follows
		p.request_age = 0.0
	if frames == 232:
		check("display followed: panel says so at once", p.text.contains("шлем перешёл на 20 Гц"))
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
		# after the green check: each step of the render scale rebuilds the buffers, a missed frame or two
		check("foveation at first: our narrow map, the width first", main.foveation == p.DEFAULT_FOVEATION
				and main.own_order == p.DEFAULT_ORDER and _color(p, "fov", 5.0) == p.COLOR_ON
				and main.xr_view.vrs_mode == Viewport.VRS_TEXTURE and main.split_pass.enabled)
		check("full resolution at first", p.target.scaling_3d_scale == 1.0 and _color(p, "scale", 1.0) == p.COLOR_ON
				and p.titles[1].text.contains("128 точек на глаз"))
		var at := _button_point(p, "scale", 0.9)
		var from := at + p.transform.basis.z * 0.8
		p.point(0, from, (at - from).normalized(), 0.0)
		p.point(0, from, (at - from).normalized(), 1.0)
		p.point(0, from, (at - from).normalized(), 0.0)
		var cfg := ConfigFile.new()
		cfg.load("user://settings.cfg")
		check("left hand on 90%: render scale 90%, kept", is_equal_approx(p.target.scaling_3d_scale, 0.9) and cfg.get_value("render", "scale", 0.0) == 0.9)
		check("panel shows it", _color(p, "scale", 0.9) != p.COLOR_BTN and p.titles[1].text.contains("115 точек на глаз"))
		p.point(0, Vector3.ZERO, Vector3.FORWARD, 0.0)
		p.choose_scale(1.0)
		check("back to 100%", p.target.scaling_3d_scale == 1.0)
		_foveation(p)
	if frames > 260 and frames <= 320:
		OS.delay_msec(70)           # longer than a 50 ms refresh: every frame misses one
	if frames == 320:
		print("slow frames: ", p.text.replace("\n", " | "), "  seconds ", p.seconds)
		check("too slow: judged, red", p.keeps_up(p.seconds) == false and p.plate_mat.albedo_color == p.COLOR_BAD)
		check("too slow: panel says so", p.text.contains("не успевает"))
	var b: Node = main.bench
	if frames == 330:
		b.warm = 0.1
		b.time = 0.2
		b.tour_scale = 0.15
		bench_stored = p.stored
		if bench_auto:
			b.auto = true
			print("speed check: waiting for it to start by itself")
		else:
			var at := _button_point(p, "bench", 0.0)
			var from := at + Vector3(0.1, -0.3, 0.4)
			p.point(1, from, (at - from).normalized(), 0.0)
			p.point(1, from, (at - from).normalized(), 1.0)
			p.point(1, from, (at - from).normalized(), 0.0)
			p.point(1, Vector3.ZERO, Vector3.FORWARD, 0.0)
			check("speed check: its button starts it, asks for 72 Hz", b.running and p.desired == 72.0)
	if frames > 330 and bench_auto and not bench_seen and b.running:
		bench_seen = true
		check("speed check: started by itself, asks for 72 Hz", p.desired == 72.0)
	if frames > 330 and not b.running and (bench_seen or not bench_auto):
		var segs: int = 2 if b.variants.size() > 1 else 1
		check("speed check: every place timed", b.results.size() == b.PLACES.size() and b.results.back().back().size() == segs)
		check("speed check: the tour went round, frames counted", b.tour_results.size() == b.tour.size()
				and b.tour_results.back().refreshes > 0)
		var pose: Array = main.get_pose()
		check("speed check: back where it stood, its shader", absf(pose[0] - b.saved_pose[0]) < 1e-3
				and main.material.shader == b.own_shader and b.own_shader == main.SHADER_BALLS)
		check("speed check: the rate set back", p.desired == bench_stored)
		check("speed check: the foveation set back (off)", main.foveation == 0 and not main.split_pass.enabled
				and main.xr_view.vrs_mode == Viewport.VRS_DISABLED)
		check("speed check: the panel says it is done", p.bench_text.contains("Гц") or p.bench_text.begins_with("замер готов")
				or p.bench_text.begins_with("нов"))
		print("PASS" if ok else "FAIL")
		return true
	if Time.get_ticks_msec() > 500_000:
		check("speed check: finished", false)
		print("FAIL")
		return true
	return false


## The foveation rows (off by now: the scale was 90% a moment ago): off; the right hand presses
## "сильная" with the scale at 80%.
func _foveation(p: Label3D) -> void:
	var oxr := main.xr as OpenXRInterface
	p.choose_foveation(0)
	check("выкл: no density map, no split", main.foveation == 0 and _color(p, "fov", 0.0) == p.COLOR_ON
			and main.xr_view.vrs_mode == Viewport.VRS_DISABLED and not main.split_pass.enabled)
	check("Monado: no runtime density map, Godot's own", not oxr.is_foveation_supported() and p.fov_title.text == "фовеация SteamVR · нет, своя карта Godot")
	p.choose_scale(0.8)
	var at := _button_point(p, "fov", 3.0)
	var from := at + p.transform.basis.z * 0.8
	p.point(1, from, (at - from).normalized(), 0.0)
	p.point(1, from, (at - from).normalized(), 1.0)
	p.point(1, from, (at - from).normalized(), 0.0)
	p.point(1, Vector3.ZERO, Vector3.FORWARD, 0.0)
	var cfg := ConfigFile.new()
	cfg.load("user://settings.cfg")
	check("right hand on сильная: foveation 3, density map on, 3D pass split", main.foveation == 3
			and main.xr_view.vrs_mode == Viewport.VRS_XR and main.split_pass.enabled and _color(p, "fov", 3.0) == p.COLOR_ON)
	check("Godot's own map at the strongest", is_equal_approx(oxr.vrs_strength, main.OWN_MAP_STRENGTH[2]))
	check("foveation on: scale back to 100%, both kept", p.target.scaling_3d_scale == 1.0
			and cfg.get_value("render", "foveation", -1) == 3 and cfg.get_value("render", "scale", 0.0) == 1.0)
	p.choose_scale(0.9)
	cfg.load("user://settings.cfg")
	check("scale 90%: foveation off, kept", main.foveation == 0 and main.xr_view.vrs_mode == Viewport.VRS_DISABLED
			and not main.split_pass.enabled and cfg.get_value("render", "foveation", -1) == 0)
	p.choose_scale(1.0)
	# our own map: the viewport's density map from a texture, the pass split
	at = _button_point(p, "fov", 4.0)
	from = at + p.transform.basis.z * 0.8
	p.point(1, from, (at - from).normalized(), 0.0)
	p.point(1, from, (at - from).normalized(), 1.0)
	p.point(1, from, (at - from).normalized(), 0.0)
	p.point(1, Vector3.ZERO, Vector3.FORWARD, 0.0)
	check("широкая: our own map, from a texture, the pass split", main.foveation == 4
			and main.xr_view.vrs_mode == Viewport.VRS_TEXTURE and main.split_pass.enabled and _color(p, "fov", 4.0) == p.COLOR_ON)
	var img: Image = main.own_maps[4 * 2 + 0].get_layer_data(0)
	var mid: Color = img.get_pixel(32, 32)
	var corner: Color = img.get_pixel(0, 0)
	check("its map: full rate in the middle, 4x2 in the corner", mid.r8 == 0 and mid.g8 == 0 and corner.r8 == 192 and corner.g8 == 128)
	# the height first: the same map turned, 2x4 in the corner, at once and kept
	var at2 := _button_point(p, "order", 1.0)
	var from2 := at2 + p.transform.basis.z * 0.8
	p.point(0, from2, (at2 - from2).normalized(), 0.0)
	p.point(0, from2, (at2 - from2).normalized(), 1.0)
	p.point(0, from2, (at2 - from2).normalized(), 0.0)
	p.point(0, Vector3.ZERO, Vector3.FORWARD, 0.0)
	var img2: Image = main.own_maps[4 * 2 + 1].get_layer_data(0)
	var corner2: Color = img2.get_pixel(0, 0)
	var ring2: Color = img2.get_pixel(32 + 26, 32)    # r 0.83: the ring after full rate
	cfg.load("user://settings.cfg")
	check("по вертикали: 2x4 in the corner, 1x2 next to the middle, kept", main.own_order == 1 and corner2.r8 == 128
			and corner2.g8 == 192 and ring2.r8 == 0 and ring2.g8 == 128 and cfg.get_value("render", "own_order", -1) == 1
			and _color(p, "order", 1.0) == p.COLOR_ON and main.foveation == 4)
	p.choose_order(0)
	check("по горизонтали again", main.own_order == 0 and _color(p, "order", 0.0) == p.COLOR_ON)
	p.choose_foveation(0)
	check("off again: no density map, no split", main.xr_view.vrs_mode == Viewport.VRS_DISABLED and not main.split_pass.enabled)
	# the gaze dot: Monado has no eye tracking, so the gaze is "none"; the dot shows and hides
	at = _button_point(p, "fov", p.GAZE_BUTTON)
	from = at + p.transform.basis.z * 0.8
	p.point(1, from, (at - from).normalized(), 0.0)
	p.point(1, from, (at - from).normalized(), 1.0)
	p.point(1, from, (at - from).normalized(), 0.0)
	p.point(1, Vector3.ZERO, Vector3.FORWARD, 0.0)
	check("точка: the gaze dot shows; Monado: no gaze", main.gaze_dot.visible and _color(p, "fov", p.GAZE_BUTTON) == p.COLOR_ON
			and main.gaze_angles() == null)
	p.show_gaze(false)
	check("the gaze dot hides", not main.gaze_dot.visible)
	_gravity(p)


## The gravity row: the right hand presses "пол", then "стрелки", then "выкл".
func _gravity(p: Label3D) -> void:
	var seen := []
	for v in [1.0, 2.0, 0.0]:
		var at := _button_point(p, "grav", v)
		var from := at + p.transform.basis.z * 0.8
		p.point(1, from, (at - from).normalized(), 0.0)
		p.point(1, from, (at - from).normalized(), 1.0)
		p.point(1, from, (at - from).normalized(), 0.0)
		p.point(1, Vector3.ZERO, Vector3.FORWARD, 0.0)
		seen.append([main.gravity_view, main.material.shader.resource_path.get_file(), _color(p, "grav", v) == p.COLOR_ON])
	# the demo's balls and cubes are there: the ray tracers with them
	var want := [[1, "wormhole_balls_gravity.gdshader", true], [2, "wormhole_balls_arrows.gdshader", true],
			[0, "wormhole_balls.gdshader", true]]
	check("гравитация: пол, стрелки, выкл", seen == want)
	if seen != want:
		print("  ", seen)


func _index(p: Label3D, kind: String, value: float) -> int:
	for i in p.buttons.size():
		if p.buttons[i].kind == kind and is_equal_approx(p.buttons[i].value, value):
			return i
	return -1


## A button's centre in the play space.
func _button_point(p: Label3D, kind: String, value: float) -> Vector3:
	var c: Vector2 = p.buttons[_index(p, kind, value)].rect.get_center()
	return p.transform * Vector3(c.x, c.y, 0.0)


func _color(p: Label3D, kind: String, value: float) -> Color:
	var c: Color = p.buttons[_index(p, kind, value)].mat.albedo_color
	return c


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
