extends SceneTree
## main through the real OpenXR path, under Monado's simulated headset (one rate, 20 Hz):
## no script errors; the menu's head measures the display rate from OpenXR's frame timing and
## agrees with the runtime, judges the frames; with a stand-in for SteamVR's vrcmd, as if started
## from the Steam library, the menu's rate row (right: picked, not yet in effect; A: in effect)
## sets this app's rate in SteamVR's settings, and as the display stays at 20 Hz the head asks for
## a restart (a display that follows is answered too); choices made while vrcmd runs end with the
## last one written; the scale row sets the render scale and keeps it; foveation starts with our
## narrow map; the foveation row turns foveated rendering
## on at its level (the XR viewport's density map, the 3D pass split, Godot's own map under Monado,
## which has no XR_FB_foveation), keeps it, and takes the render scale back to 100%, and a scale
## below 100% turns it off again; our own density map comes from a texture, and the order of its
## steps switches (the width or the height first); the gaze dot shows and hides; the gravity row
## switches the gravity view (the floor, the arrows, off: A steps round) and its ray tracers;
## frames made too slow for the display turn the head and the line below red; and the speed
## check's row runs it through (bench.gd: the comparison at 72 Hz, then the tour at 120 Hz, which
## Monado does not offer: it stays at 20), closing the menu, the line below saying how it goes and
## what came out, and puts the rate, the shader and the viewer back.
## (The menu's buttons themselves: tests/walking_xr_test.gd; Monado's simulated controllers bind
## to none of our profiles, so here the menu's own calls stand for them.)
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
	var p: Node3D = main.perf
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
		check("rate choices: SteamVR's per-app ones", p.rate_options == p.FRAME_RATES)
		check("the menu is closed, the line below shows the rate", not p.open and p.strip.visible
				and p.strip_label.text.begins_with("20 Гц · "))
		p.set_open(true)
		check("opened: the menu shows, the line hides, the rate row picked", p.open and p.menu.visible
				and not p.strip.visible and p.picked() == "rate")
		check("20 Hz is not among them, 90 Hz is chosen (yellow)", _value(p, "rate") == "90 Гц" and _color(p, "rate") == p.COLOR_PENDING)
		OS.set_environment("LD_PRELOAD", "/nonexistent/overlay.so")    # as Steam sets it
		p.change(1)
		check("right: 96 picked, nothing written yet", _value(p, "rate") == "96 Гц" and p.pending >= 0
				and not p.writing and p.desired != 96.0)
		p.press()
		check("A: 96 chosen, being written", p.desired == 96.0 and p.writing and p.pending == -1)
		check("panel says it is switching", p.text.contains("переключаю на 96 Гц"))
	if frames == 180:
		check("vrcmd stored 96", FileAccess.get_file_as_string(fake + "/value").strip_edges() == "96")
		check("vrcmd ran with SteamVR's library path", FileAccess.get_file_as_string(fake + "/lib").strip_edges() == fake)
		check("vrcmd ran without Steam's preload", FileAccess.get_file_as_string(fake + "/preload").strip_edges() == "")
		check("display stayed: panel asks for a restart", p.stored == 96.0 and p.text.contains("задано 96 Гц: выйди и запусти снова"))
		check("96 shown chosen, not in effect", _value(p, "rate") == "96 Гц" and _color(p, "rate") == p.COLOR_PENDING)
		OS.set_environment("LD_PRELOAD", "")
		# three choices in a row while vrcmd runs: the last one is what ends up written
		p.choose_rate(108.0)
		p.choose_rate(120.0)
		p.choose_rate(144.0)
	if frames == 230:
		check("quick choices: the last one written", FileAccess.get_file_as_string(fake + "/value").strip_edges() == "144" and p.stored == 144.0 and not p.writing)
		p.requested = 20.0          # as if the setting had been 20 Hz: the display follows
		p.request_age = 0.0
	if frames == 232:
		check("display followed: panel says so at once", p.text.contains("шлем перешёл на 20 Гц"))
		# judge from here: the vrcmd calls just before cost a missed frame or two under software rendering
		p.seconds.clear()
	if frames == 290:
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
		check("frames judged, green", p.keeps_up(p.seconds) == true and p.plate_mat.albedo_color == p.COLOR_OK
				and p.strip_mat.albedo_color == p.COLOR_OK)
		# after the green check: each step of the render scale rebuilds the buffers, a missed frame or two
		check("foveation at first: our narrow map, the width first", main.foveation == p.DEFAULT_FOVEATION
				and main.own_order == p.DEFAULT_ORDER and _value(p, "fov") == "плавная узкая"
				and main.xr_view.vrs_mode == Viewport.VRS_TEXTURE and main.split_pass.enabled)
		check("full resolution at first", p.target.scaling_3d_scale == 1.0 and _value(p, "scale") == "100% (128 точек)")
		p.select("scale")
		p.change(1)
		check("the scale row, right: 90% picked, not yet in effect", p.target.scaling_3d_scale == 1.0
				and _value(p, "scale") == "90% (115 точек)" and _color(p, "scale") == p.COLOR_PENDING)
		p.move(1)       # another row: what was picked takes effect
		var cfg := ConfigFile.new()
		cfg.load("user://settings.cfg")
		check("on to the next row: render scale 90%, kept", is_equal_approx(p.target.scaling_3d_scale, 0.9)
				and cfg.get_value("render", "scale", 0.0) == 0.9 and p.picked() == "fov")
		check("the row shows it", _value(p, "scale") == "90% (115 точек)" and _color(p, "scale") == p.COLOR_TEXT)
		p.choose_scale(1.0)
		check("back to 100%", p.target.scaling_3d_scale == 1.0)
		_foveation(p)
	if frames > 290 and frames <= 350:
		OS.delay_msec(70)           # longer than a 50 ms refresh: every frame misses one
	if frames == 350:
		print("slow frames: ", p.text.replace("\n", " | "), "  seconds ", p.seconds)
		check("too slow: judged, red", p.keeps_up(p.seconds) == false and p.plate_mat.albedo_color == p.COLOR_BAD
				and p.strip_mat.albedo_color == p.COLOR_BAD)
		check("too slow: panel says so", p.text.contains("не успевает"))
	var b: Node = main.bench
	if frames == 360:
		b.warm = 0.1
		b.time = 0.2
		b.tour_scale = 0.15
		bench_stored = p.stored
		if bench_auto:
			b.auto = true
			print("speed check: waiting for it to start by itself")
		else:
			p.set_open(true)
			p.select("bench")
			p.press()
			check("speed check: its row and A start it, ask for 72 Hz, close the menu", b.running and p.desired == 72.0
					and not p.open)
			check("speed check: the line below says how it goes", p.strip.visible and p.strip_label.text.contains("замер:"))
	if frames > 360 and bench_auto and not bench_seen and b.running:
		bench_seen = true
		check("speed check: started by itself, asks for 72 Hz", p.desired == 72.0)
	if frames > 360 and not b.running and (bench_seen or not bench_auto):
		var segs: int = 2 if b.variants.size() > 1 else 1
		check("speed check: every place timed", b.results.size() == b.PLACES.size() and b.results.back().back().size() == segs)
		check("speed check: the tour went round, frames counted", b.tour_results.size() == b.tour.size()
				and b.tour_results.back().refreshes > 0)
		var pose: Array = main.get_pose()
		check("speed check: back where it stood, its shader", absf(pose[0] - b.saved_pose[0]) < 1e-3
				and main.material.shader == b.own_shader and b.own_shader == main.SHADER_PLAIN and main.toys_shown)
		check("speed check: the rate set back", p.desired == bench_stored)
		check("speed check: the foveation set back (off)", main.foveation == 0 and not main.split_pass.enabled
				and main.xr_view.vrs_mode == Viewport.VRS_DISABLED)
		check("speed check: the panel says it is done", p.bench_text.contains("Гц") or p.bench_text.begins_with("замер готов")
				or p.bench_text.begins_with("нов"))
		check("... on the line below, until the menu opens", p.strip_label.text.contains(p.bench_text))
		p.set_open(true)
		check("... and in the menu, under its row", p.bench_label.visible and p.bench_label.text == p.bench_text
				and not p.strip_label.text.contains(p.bench_text))
		print("PASS" if ok else "FAIL")
		return true
	if Time.get_ticks_msec() > 500_000:
		check("speed check: finished", false)
		print("FAIL")
		return true
	return false


## The foveation rows (off by now: the scale was 90% a moment ago): off; the right hand presses
## "сильная" with the scale at 80%.
func _foveation(p: Node3D) -> void:
	var oxr := main.xr as OpenXRInterface
	p.choose_foveation(0)
	check("выкл: no density map, no split", main.foveation == 0 and _value(p, "fov") == "выкл"
			and main.xr_view.vrs_mode == Viewport.VRS_DISABLED and not main.split_pass.enabled)
	check("Monado: no runtime density map, Godot's own", not oxr.is_foveation_supported()
			and _row(p, "fov").name.text == "фовеация · без SteamVR")
	p.choose_scale(0.8)
	p.select("fov")
	p.change(1)
	p.change(1)
	p.press()
	var cfg := ConfigFile.new()
	cfg.load("user://settings.cfg")
	check("the foveation row, right twice, A: сильная, foveation 3, density map on, 3D pass split", main.foveation == 3
			and main.xr_view.vrs_mode == Viewport.VRS_XR and main.split_pass.enabled and _value(p, "fov") == "SteamVR сильная")
	check("Godot's own map at the strongest", is_equal_approx(oxr.vrs_strength, main.OWN_MAP_STRENGTH[2]))
	check("foveation on: scale back to 100%, both kept", p.target.scaling_3d_scale == 1.0
			and cfg.get_value("render", "foveation", -1) == 3 and cfg.get_value("render", "scale", 0.0) == 1.0)
	p.choose_scale(0.9)
	cfg.load("user://settings.cfg")
	check("scale 90%: foveation off, kept", main.foveation == 0 and main.xr_view.vrs_mode == Viewport.VRS_DISABLED
			and not main.split_pass.enabled and cfg.get_value("render", "foveation", -1) == 0)
	p.choose_scale(1.0)
	# our own map: the viewport's density map from a texture, the pass split
	for k in 3:
		p.change(1)
	p.press()
	check("широкая: our own map, from a texture, the pass split", main.foveation == 4
			and main.xr_view.vrs_mode == Viewport.VRS_TEXTURE and main.split_pass.enabled and _value(p, "fov") == "плавная широкая")
	var img: Image = main.own_maps[4 * 2 + 0].get_layer_data(0)
	var mid: Color = img.get_pixel(32, 32)
	var corner: Color = img.get_pixel(0, 0)
	check("its map: full rate in the middle, 4x2 in the corner", mid.r8 == 0 and mid.g8 == 0 and corner.r8 == 192 and corner.g8 == 128)
	# the height first: the same map turned, 2x4 in the corner, at once and kept
	p.move(1)
	p.change(1)
	p.press()
	var img2: Image = main.own_maps[4 * 2 + 1].get_layer_data(0)
	var corner2: Color = img2.get_pixel(0, 0)
	var ring2: Color = img2.get_pixel(32 + 26, 32)    # r 0.83: the ring after full rate
	cfg.load("user://settings.cfg")
	check("по вертикали: 2x4 in the corner, 1x2 next to the middle, kept", main.own_order == 1 and corner2.r8 == 128
			and corner2.g8 == 192 and ring2.r8 == 0 and ring2.g8 == 128 and cfg.get_value("render", "own_order", -1) == 1
			and p.picked() == "order" and _value(p, "order") == "по вертикали" and main.foveation == 4)
	p.choose_order(0)
	check("по горизонтали again", main.own_order == 0 and _value(p, "order") == "по горизонтали")
	p.choose_foveation(0)
	check("off again: no density map, no split", main.xr_view.vrs_mode == Viewport.VRS_DISABLED and not main.split_pass.enabled)
	# the gaze dot: Monado has no eye tracking, so the gaze is "none"; the dot shows and hides
	p.move(1)
	p.press()
	check("точка взгляда, A: the gaze dot shows; Monado: no gaze", p.picked() == "gaze" and main.gaze_dot.visible
			and _value(p, "gaze") == "вкл" and main.gaze_angles() == null)
	p.show_gaze(false)
	check("the gaze dot hides", not main.gaze_dot.visible)
	_gravity(p)


## The gravity row: right and A ("пол"), right and A ("стрелки"), then A alone steps round ("выкл").
func _gravity(p: Node3D) -> void:
	var seen := []
	p.select("grav")
	for v in [1, 2, 0]:
		if v > 0:
			p.change(1)
		p.press()
		seen.append([main.gravity_view, main.material.shader.resource_path.get_file(),
				main.toys_shell_mat.shader.resource_path.get_file(), _value(p, "grav") == p.GRAVITY_VIEWS[v]])
	# the demo's balls and cubes are there: the toys' passes draw the arrows over them in view 2
	var want := [[1, "wormhole_gravity.gdshader", "toys_shell.gdshader", true],
			[2, "wormhole_arrows.gdshader", "toys_shell_arrows.gdshader", true],
			[0, "wormhole.gdshader", "toys_shell.gdshader", true]]
	check("гравитация: пол, стрелки, выкл", seen == want)
	if seen != want:
		print("  ", seen)


func _row(p: Node3D, key: String) -> Dictionary:
	for r: Dictionary in p.rows:
		if r.key == key:
			return r
	return {}


## The menu row's value as shown, and its colour.
func _value(p: Node3D, key: String) -> String:
	return _row(p, key).value.text


func _color(p: Node3D, key: String) -> Color:
	return _row(p, key).value.modulate


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
