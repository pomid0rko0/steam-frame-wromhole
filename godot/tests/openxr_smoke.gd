extends SceneTree
## main through the real OpenXR path, under Monado's simulated headset (one rate, 20 Hz):
## no script errors; the menu's head measures the display rate from OpenXR's frame timing and
## agrees with the runtime, judges the frames; with a stand-in for SteamVR's vrcmd, as if started
## from the Steam library, the menu's rate row (right: picked, not yet in effect; A: in effect)
## sets this app's rate in SteamVR's settings, and as the display stays at 20 Hz the head asks for
## a restart (a display that follows is answered too); choices made while vrcmd runs end with the
## last one written; settings written before the eye's size was the app's own go, and the eye
## starts at its full size (under Monado the runtime's own), foveation at its default level, neither
## written till chosen; the resolution row sets the size of the images OpenXR takes from the next
## frame on, the XR viewport follows, also when the menu takes a value by itself, and keeps it, and
## every frame the XR viewport is as big as those images; the foveation row turns foveated
## rendering on at its level (the floor from foveation.gd's texture, made for the picture's size)
## and keeps it, at any size, its fovea ahead without eye tracking (Monado has none); the zones row
## tints its coarse texels; the gaze dot shows and hides; the gravity row
## switches the gravity view (the floor, the arrows, off: A steps round);
## frames made too slow for the display turn the head and the line below red; and the speed
## check's row runs it through (bench.gd: the comparison, then the tour, at rates Monado does not
## offer: it stays at 20), closing the menu, the line below saying how it goes and what came out,
## and puts the rate, the foveation and the viewer back.
## (The menu's buttons themselves: tests/walking_xr_test.gd; Monado's simulated controllers bind
## to none of our profiles, so here the menu's own calls stand for them.)
##   tools/test_openxr.sh

const U := preload("res://tests/util.gd")
const APP_ID := "4242"

var main: Main
var frames := 0
var fake: String
var bench_stored := 0.0
var judged := 0                 # the frame the green verdict was seen, or the wait for it ended (0: waiting)
var green := false
var mismatched := []            # frames drawn with the XR viewport not the size of the images OpenXR takes
var full_n := 0                 # foveation's texels across at 100%
const GREEN_WAIT := 400         # frames (20 s at Monado's 20 Hz) to see the frames judged green


func _initialize() -> void:
	# settings as written before the eye's size was the app's own (Menu._load)
	var old := ConfigFile.new()
	old.set_value("ui", "strip", true)
	old.set_value("render", "scale", 0.8)
	old.set_value("render", "foveation", 4)
	old.save("user://settings.cfg")
	main = load("res://main.tscn").instantiate() as Main
	# the toys at rest, without the throw and the drop: after the drop, frames on software Vulkan
	# (sharing the cores with Monado) miss refreshes, for a reason not found, and here frames that
	# keep up are judged. The throw and the drop themselves: physics_test.gd.
	main.toys.demo = false
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	# the frame before was drawn at these sizes (Menu.set_eye changes them at a frame's start)
	if frames > 2 and main.in_xr and Vector2i(main.xr.get_render_target_size()) != main.xr_view.size:
		mismatched.append([frames - 1, Vector2i(main.xr.get_render_target_size()), main.xr_view.size])
	var p: Menu = main.menu
	var r: FrameRate = main.rate
	if frames == 2:
		var home := OS.get_environment("HOME")
		_fake_steamvr()
		r.vrcmd = fake + "/vrcmd"
		r.find_app_setting()
		OS.set_environment("HOME", home)     # user:// follows HOME
		U.check("app setting found: steam.app.%s, 90 Hz" % APP_ID, r.steam_key == "steam.app." + APP_ID and r.stored == 90.0)
	if frames == 60:
		r.seconds.clear()       # judge after the start: loading and compiling cost frames there
	if frames == 100:
		U.check("the menu says the setting and the display differ", p.text.contains("в SteamVR задано 90 Гц, а шлем на 20"))
		U.check("rate choices: SteamVR's per-app ones", p.rate_options == FrameRate.FRAME_RATES)
		U.check("the menu is closed, the line below shows the rate", not p.open and p.strip.visible
				and p.strip_label.text.begins_with("20 Гц · "))
		p.set_open(true)
		U.check("opened: the menu shows, the line hides", p.open and p.menu.visible and not p.strip.visible)
		U.check("the rate row picked", p.select("rate") and p.picked() == "rate")
		U.check("20 Hz is not among them, 90 Hz is chosen (yellow)", _value(p, "rate") == "90 Гц" and _color(p, "rate") == p.COLOR_PENDING)
		OS.set_environment("LD_PRELOAD", "/nonexistent/overlay.so")    # as Steam sets it
		p.change(1)
		U.check("right: 96 picked, nothing written yet", _value(p, "rate") == "96 Гц" and p.pending >= 0
				and not r.writing and r.desired != 96.0)
		p.press()
		U.check("A: 96 chosen, being written", r.desired == 96.0 and r.writing and p.pending == -1)
		U.check("the menu says it is switching", p.text.contains("переключаю на 96 Гц"))
	if frames == 180:
		U.check("vrcmd stored 96", FileAccess.get_file_as_string(fake + "/value").strip_edges() == "96")
		U.check("vrcmd ran with SteamVR's library path", FileAccess.get_file_as_string(fake + "/lib").strip_edges() == fake)
		U.check("vrcmd ran without Steam's preload", FileAccess.get_file_as_string(fake + "/preload").strip_edges() == "")
		U.check("display stayed: the menu asks for a restart", r.stored == 96.0 and p.text.contains("задано 96 Гц: выйди и запусти снова"))
		U.check("96 shown chosen, not in effect", _value(p, "rate") == "96 Гц" and _color(p, "rate") == p.COLOR_PENDING)
		OS.set_environment("LD_PRELOAD", "")
		# three choices in a row while vrcmd runs: the last one is what ends up written
		r.choose(108.0)
		r.choose(120.0)
		r.choose(144.0)
	if frames == 230:
		U.check("quick choices: the last one written", FileAccess.get_file_as_string(fake + "/value").strip_edges() == "144" and r.stored == 144.0 and not r.writing)
		r.requested = 20.0          # as if the setting had been 20 Hz: the display follows
		r.request_age = 0.0
	if frames == 232:
		U.check("display followed: the menu says so at once", p.text.contains("шлем перешёл на 20 Гц"))
		# judge from here: the vrcmd calls just before cost a missed frame or two under software rendering
		r.seconds.clear()
	if frames > 232 and judged == 0:
		# The rate changes just before cost software rendering a missed refresh now and then, and one
		# miss in a window of MIN_SECONDS at this rate is over the MISSED_OK the verdict allows. So:
		# judge windows of MIN_SECONDS,
		# each started afresh, until one keeps up and the head and the line show it green. Frames made
		# too slow never get there (they are checked red below).
		green = FrameRate.keeps_up(r.seconds) == true and p.plate_mat.albedo_color == p.COLOR_OK \
				and p.strip_mat.albedo_color == p.COLOR_OK
		if green or frames >= 232 + GREEN_WAIT:
			judged = frames
		elif r.seconds.size() >= FrameRate.MIN_SECONDS:
			r.seconds.clear()
	var j := frames - judged if judged > 0 else -1     # frames since the green check
	if j == 0:
		var oxr := main.xr as OpenXRInterface
		print("in_xr ", main.in_xr, "  session state ", oxr.get_session_state() if oxr else -1,
				"  hands ", main.hands.list.size(), "  await_pose ", main.await_pose)
		print("runtime: rates ", oxr.get_available_display_refresh_rates() if oxr else [],
				"  current ", oxr.display_refresh_rate if oxr else 0.0)
		print("measured %.3f Hz, seconds %s" % [r.rate, r.seconds])
		print("menu: ", p.text.replace("\n", " | "))
		U.check("in XR", main.in_xr and oxr != null)
		if oxr:
			U.check("measured rate = runtime's", absf(r.rate - oxr.display_refresh_rate) < 0.5)
			U.check("the menu heads with the rate", p.text.begins_with("%.0f Гц · " % oxr.display_refresh_rate))
		U.check("frames judged, green", green, "after %d frames, seconds %s" % [frames - 232, r.seconds])
		# after the green check: each change of the eye's size makes the images again, a missed frame or two
		U.check("the old settings' scale and foveation gone: neither chosen", not p.scale_chosen
				and not p.foveation_chosen)
		U.check("foveation at first: предельная, the default, the floor from its texture", main.foveation.level == p.DEFAULT_FOVEATION
				and _value(p, "fov") == "предельная" and main.foveation.enabled
				and main.renderer.floor_quad.material_override == main.renderer.floor_sample_mat)
		U.check("the eye at its full size at first: Monado's own", p.full_eye == 128 and _eye() == Vector2i(128, 128)
				and main.xr_view.size == Vector2i(128, 128) and _value(p, "scale") == "100% (128×128)",
				"%s, viewport %s" % [_eye(), main.xr_view.size])
		p.select("scale")
		p.change(1)
		U.check("the resolution row, right: 110% picked, not yet in effect", _eye() == Vector2i(128, 128)
				and _value(p, "scale") == "110% (141×141)" and _color(p, "scale") == p.COLOR_PENDING)
		p.move(1)       # another row: what was picked takes effect
		var cfg := ConfigFile.new()
		cfg.load("user://settings.cfg")
		U.check("on to the next row: 110% chosen, kept, the foveation as it was; the size from the next frame on",
				p.render_scale == 1.1 and cfg.get_value("render", "eye", 0.0) == 1.1 and p.picked() == "fov"
				and main.foveation.level == p.DEFAULT_FOVEATION and _eye() == Vector2i(128, 128))
		U.check("the old settings gone from the file, the foveation not written till chosen",
				not cfg.has_section_key("render", "scale") and not cfg.has_section_key("render", "foveation")
				and not cfg.has_section_key("render", "foveation_level"))
		U.check("the row shows it", _value(p, "scale") == "110% (141×141)" and _color(p, "scale") == p.COLOR_TEXT)
	if j == 2:
		var fov := main.foveation
		U.check("the next frame: the images OpenXR takes 141×141, the XR viewport too, foveation made for them",
				_eye() == Vector2i(141, 141) and main.xr_view.size == Vector2i(141, 141) and fov._size == Vector2i(141, 141),
				"%s, viewport %s, foveation %s" % [_eye(), main.xr_view.size, fov._size])
		# the menu takes a value by itself after SETTLE, in its own _process: after the XR viewport's
		# (the size changing there was the headset's lost frames)
		p.select("scale")
		p.change(-1)
	if j == 20:
		U.check("left, then nothing: the menu took 100% by itself, the images and the XR viewport 128×128",
				p.pending == -1 and p.render_scale == 1.0 and _eye() == Vector2i(128, 128)
				and main.xr_view.size == Vector2i(128, 128), "%s, viewport %s" % [_eye(), main.xr_view.size])
		_foveation(p, 0)
	if j == 22:
		_foveation(p, 1)
	if j == 24:
		_foveation(p, 2)
	if j == 26:
		_foveation(p, 3)
	if j > 0 and j <= 60:
		OS.delay_msec(70)           # longer than a 50 ms refresh: every frame misses one
	if j == 60:
		print("slow frames: ", p.text.replace("\n", " | "), "  seconds ", r.seconds)
		U.check("too slow: judged, red", FrameRate.keeps_up(r.seconds) == false and p.plate_mat.albedo_color == p.COLOR_BAD
				and p.strip_mat.albedo_color == p.COLOR_BAD)
		U.check("too slow: the menu says so", p.text.contains("не успевает"))
	var b: Bench = main.bench
	if j == 70:
		b.warm = 0.1
		b.time = 0.2
		b.tour_scale = 0.15
		bench_stored = r.stored
		p.set_open(true)
		p.select("bench")
		p.press()
		U.check("speed check: its row and A start it, ask for 72 Hz, close the menu", b.running and r.desired == 72.0
				and not p.open)
		U.check("speed check: the line below says how it goes", p.strip.visible and p.strip_label.text.contains("замер:"))
	if j > 70 and not b.running:
		var segs: int = 2 if b.variants.size() > 1 else 1
		var timed: bool = b.results.all(func(r: Array) -> bool: return r.all(func(v: Array) -> bool: return v.size() == segs))
		U.check("speed check: every place timed", timed)
		U.check("speed check: the tour went round, frames counted", b.tour_results.size() == b.tour.size()
				and b.tour_results.back().refreshes > 0)
		var pose: Array = main.get_pose()
		U.check("speed check: back where it stood, no cube before the eyes", absf(pose[0] - b.saved_pose[0]) < 1e-3 and not b.near)
		U.check("speed check: the rate set back", r.desired == bench_stored)
		U.check("speed check: the foveation set back (off)", main.foveation.level == 0 and not main.foveation.enabled)
		U.check("speed check: the menu says it is done (the tour's result)", p.bench_text.contains("Гц"))
		U.check("... on the line below, until the menu opens", p.strip_label.text.contains(p.bench_text))
		p.set_open(true)
		U.check("... and in the menu, under its row", p.bench_label.visible and p.bench_label.text == p.bench_text
				and not p.strip_label.text.contains(p.bench_text))
		U.check("every frame: the XR viewport as big as the images OpenXR takes", mismatched.is_empty(), str(mismatched))
		U.finish(self)
		return true
	if Time.get_ticks_msec() > 500_000:
		U.check("speed check: finished", false)
		U.finish(self)
		return true
	return false


## The foveation rows, a step every other frame (a size chosen takes effect at the next frame):
## 0, off; the right hand presses "средняя" with the eye at 80%; 1, both stay, also at another size;
## "сильная" at 100%; 2, its texture for the picture, made again at 80%; 3, made again, then off,
## the zones row, the gaze dot and the gravity row.
func _foveation(p: Menu, step: int) -> void:
	var fov := main.foveation
	var cfg := ConfigFile.new()
	if step == 0:
		p.choose_foveation(0)
		U.check("выкл: the floor per pixel", fov.level == 0 and _value(p, "fov") == "выкл" and not fov.enabled
				and main.renderer.floor_quad.material_override == main.renderer.floor_mat)
		U.check("Monado: no eye tracking, the fovea ahead", not fov.gaze_on
				and _row(p, "fov").name_label.text == "фовеация · по центру")
		p.choose_scale(0.8)
		p.select("fov")
		p.change(1)
		p.change(1)
		p.press()
		cfg.load("user://settings.cfg")
		U.check("the foveation row, right twice, A: средняя, foveation 2, the floor from its texture", fov.level == 2
				and fov.enabled and main.renderer.floor_quad.material_override == main.renderer.floor_sample_mat and _value(p, "fov") == "средняя")
		U.check("foveation on: the eye stays at 80%, both kept", p.render_scale == 0.8
				and cfg.get_value("render", "foveation_level", -1) == 2 and cfg.get_value("render", "eye", 0.0) == 0.8)
	elif step == 1:
		U.check("... the images 102×102", _eye() == Vector2i(102, 102) and main.xr_view.size == Vector2i(102, 102), str(_eye()))
		p.choose_scale(0.9)
		cfg.load("user://settings.cfg")
		U.check("another size: the foveation stays, kept", fov.level == 2 and fov.enabled
				and cfg.get_value("render", "foveation_level", -1) == 2)
		p.choose_scale(1.0)
		p.change(1)
		p.press()
		U.check("right, A: сильная, the floor from its texture", fov.level == 3 and fov.enabled and _value(p, "fov") == "сильная"
				and main.renderer.floor_quad.material_override == main.renderer.floor_sample_mat)
	elif step == 2:
		var size := main.xr.get_render_target_size()
		U.check("its texture: made for the picture's 128 pixels, smaller than it", fov._size == Vector2i(128, 128)
				and fov.fov_tex.get_width() < size.x and fov.fov_tex.get_layers() == 2,
				"%s, %d of %d" % [fov._size, fov.fov_tex.get_width(), size.x])
		full_n = fov.fov_tex.get_width()
		p.choose_scale(0.8)
	else:
		U.check("at 80%: its texture made again for the picture's 102 pixels", fov._size == Vector2i(102, 102)
				and fov.fov_tex.get_width() < full_n and fov.enabled,
				"%s, %d texels" % [fov._size, fov.fov_tex.get_width()])
		p.choose_scale(1.0)
		p.choose_foveation(0)
		U.check("off again: the floor per pixel", not fov.enabled
				and main.renderer.floor_quad.material_override == main.renderer.floor_mat)
		# the zones: the coarse texels tinted, not kept
		p.move(1)
		p.press()
		U.check("зоны фовеации, A: tinted", p.picked() == "zones" and fov.show and _value(p, "zones") == "вкл")
		p.show_foveation(false)
		U.check("... and not", not fov.show and _value(p, "zones") == "выкл")
		# the gaze dot: Monado has no eye tracking, so the gaze is "none"; the dot shows and hides
		p.move(1)
		p.press()
		U.check("точка взгляда, A: the gaze dot shows; Monado: no gaze", p.picked() == "gaze" and main.gaze_dot.visible
				and _value(p, "gaze") == "вкл" and main.gaze_angles() == null)
		p.show_gaze(false)
		U.check("the gaze dot hides", not main.gaze_dot.visible)
		_gravity(p)


## The gravity row: right and A, right and A, then A alone steps round (its values: Menu.GRAVITY_NAMES).
func _gravity(p: Menu) -> void:
	var seen := []
	p.select("grav")
	for v in [1, 2, 0]:
		if v > 0:
			p.change(1)
		p.press()
		seen.append([main.renderer.gravity_view, main.renderer.floor_mat.shader.resource_path.get_file(), main.renderer.arrows.visible,
				_value(p, "grav") == p.GRAVITY_NAMES[v]])
	var want := [[1, "floor_gravity.gdshader", false, true], [2, "floor_gravity.gdshader", true, true],
			[0, "floor.gdshader", false, true]]
	U.check("the gravity row: each view, then off", seen == want)
	if seen != want:
		print("  ", seen)


## The images OpenXR takes for each eye, as Godot makes them (truncated).
func _eye() -> Vector2i:
	return Vector2i(main.xr.get_render_target_size())


func _row(p: Menu, key: String) -> Menu.Row:
	for r in p.rows:
		if r.key == key:
			return r
	return null


## The menu row's value as shown, and its colour.
func _value(p: Menu, key: String) -> String:
	return _row(p, key).value_label.text


func _color(p: Menu, key: String) -> Color:
	return _row(p, key).value_label.modulate


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
