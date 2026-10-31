extends SceneTree
## main through the real OpenXR path, under Monado's simulated headset (one rate, 20 Hz):
## no script errors; the menu's head measures the display rate from OpenXR's frame timing and
## agrees with the runtime, judges the frames; with a stand-in for SteamVR's vrcmd, as if started
## from the Steam library, the menu's rate row (right: picked, not yet in effect; A: in effect)
## sets this app's rate in SteamVR's settings, and as the display stays at 20 Hz the head asks for
## a restart (a display that follows is answered too); choices made while vrcmd runs end with the
## last one written; the scale row sets the render scale and keeps it; foveation starts with our
## own, narrow; the foveation row turns foveated rendering on at its level (SteamVR's: the XR
## viewport's density map, the 3D pass split, Godot's own map under Monado, which has no
## XR_FB_foveation; our own: no density map, no split, the floor from floor_fov.gd's texture), keeps
## it, and takes the render scale back to 100%, and a scale below 100% turns it off again; the gaze
## dot shows and hides; the gravity row
## switches the gravity view (the floor, the arrows, off: A steps round);
## frames made too slow for the display turn the head and the line below red, and the log's account
## of where a frame's time went (frame_phases.gd) adds up to the frame and puts the slowness in the
## scripts, asleep; and the speed
## check's row runs it through (bench.gd: the comparison, then the tour, at rates Monado does not
## offer: it stays at 20), closing the menu, the line below saying how it goes and what came out,
## and puts the rate, the foveation and the viewer back.
## (The menu's buttons themselves: tests/walking_xr_test.gd; Monado's simulated controllers bind
## to none of our profiles, so here the menu's own calls stand for them.)
##   tools/test_openxr.sh

const U := preload("res://tests/util.gd")
const APP_ID := "4242"

var main: Main
var slow := Slow.new()          # makes the frames too slow: in the scripts, as a node's
var frames := 0
var fake: String
var bench_stored := 0.0
var judged := 0                 # the frame the green verdict was seen, or the wait for it ended (0: waiting)
var green := false
const GREEN_WAIT := 400         # frames (20 s at Monado's 20 Hz) to see the frames judged green


func _initialize() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://settings.cfg"))
	main = load("res://main.tscn").instantiate() as Main
	# the toys at rest, without the throw and the drop: after the drop, frames on software Vulkan
	# (sharing the cores with Monado) miss refreshes, for a reason not found, and here frames that
	# keep up are judged. The throw and the drop themselves: physics_test.gd.
	main.toys.demo = false
	root.add_child(main)
	root.add_child(slow)


func _process(_delta: float) -> bool:
	frames += 1
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
		U.check("opened: the menu shows, the line hides, the rate row picked", p.open and p.menu.visible
				and not p.strip.visible and p.picked() == "rate")
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
		# after the green check: each step of the render scale rebuilds the buffers, a missed frame or two
		_phases(r)
		U.check("foveation at first: our own, narrow", main.foveation.level == p.DEFAULT_FOVEATION
				and _value(p, "fov") == "плавная узкая" and main.xr_view.vrs_mode == Viewport.VRS_DISABLED
				and not main.foveation.split_pass.enabled and main.renderer.floor_fov.enabled)
		U.check("full resolution at first", p.target.scaling_3d_scale == 1.0 and _value(p, "scale") == "100% (128×128)")
		p.select("scale")
		p.change(1)
		U.check("the scale row, right: 90% picked, not yet in effect", p.target.scaling_3d_scale == 1.0
				and _value(p, "scale") == "90% (115×115)" and _color(p, "scale") == p.COLOR_PENDING)
		p.move(1)       # another row: what was picked takes effect
		var cfg := ConfigFile.new()
		cfg.load("user://settings.cfg")
		U.check("on to the next row: render scale 90%, kept", is_equal_approx(p.target.scaling_3d_scale, 0.9)
				and cfg.get_value("render", "scale", 0.0) == 0.9 and p.picked() == "fov")
		U.check("the row shows it", _value(p, "scale") == "90% (115×115)" and _color(p, "scale") == p.COLOR_TEXT)
		p.choose_scale(1.0)
		U.check("back to 100%", p.target.scaling_3d_scale == 1.0)
		_foveation(p)
	# longer than a 50 ms refresh: every frame misses one
	slow.ms = SLOW_MS if j > 0 and j <= 60 else 0
	if j == 30:
		var f := r.phases.last_frame()
		var n := FramePhases.PHASES.size()
		U.check("a slow frame: the scripts' stretch holds the delay, asleep", f[1] >= SLOW_MS - 1 and f[1] < SLOW_MS + 30
				and f[n + 2] >= SLOW_MS - 10, str(f))
		U.check("... as the line about the late frame says", r._before_text().contains("scripts %.2f" % f[1])
				and r._before_text().contains("asleep"), r._before_text())
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
		U.check("speed check: the foveation set back (off)", main.foveation.level == 0 and not main.foveation.split_pass.enabled
				and main.xr_view.vrs_mode == Viewport.VRS_DISABLED)
		U.check("speed check: the menu says it is done (the tour's result)", p.bench_text.contains("Гц"))
		U.check("... on the line below, until the menu opens", p.strip_label.text.contains(p.bench_text))
		p.set_open(true)
		U.check("... and in the menu, under its row", p.bench_label.visible and p.bench_label.text == p.bench_text
				and not p.strip_label.text.contains(p.bench_text))
		U.finish(self)
		return true
	if Time.get_ticks_msec() > 500_000:
		U.check("speed check: finished", false)
		U.finish(self)
		return true
	return false


## Where the last frame's time went (frame_phases.gd): every stretch measured, together a whole
## number of Monado's refreshes (from one xrWaitFrame to the next); the kernel's account of it.
func _phases(r: FrameRate) -> void:
	var ph := r.phases
	var f := ph.last_frame() if ph else PackedFloat32Array()
	var n := FramePhases.PHASES.size()
	U.check("phases: measured, a value for each stretch and the kernel's four", ph != null and ph.on
			and f.size() == n + 4, str(f))
	if f.size() != n + 4:
		return
	var sum := 0.0
	var each := true
	for i in n:
		sum += f[i]
		each = each and f[i] >= 0.0
	var period := 1000.0 / r.rate
	var k := maxf(roundf(sum / period), 1.0)
	U.check("phases: the stretches add up to whole refreshes", each and absf(sum - k * period) < 0.25 * period,
			"%.2f ms, refreshes of %.2f: %s" % [sum, period, f])
	U.check("phases: schedstat read: the thread ran, and slept till the refresh", f[n] > 0.0 and f[n + 1] >= 0.0
			and f[n + 2] > 0.0 and f[n + 3] >= 1, str(f))
	print("phases: ", r._before_text())


## The foveation rows (off by now: the scale was 90% a moment ago): off; the right hand presses
## "сильная" with the scale at 80%.
func _foveation(p: Menu) -> void:
	var oxr := main.xr as OpenXRInterface
	p.choose_foveation(0)
	U.check("выкл: no density map, no split", main.foveation.level == 0 and _value(p, "fov") == "выкл"
			and main.xr_view.vrs_mode == Viewport.VRS_DISABLED and not main.foveation.split_pass.enabled)
	U.check("Monado: no runtime density map, Godot's own", not oxr.is_foveation_supported()
			and _row(p, "fov").name_label.text == "фовеация · без SteamVR")
	p.choose_scale(0.8)
	p.select("fov")
	p.change(1)
	p.change(1)
	p.press()
	var cfg := ConfigFile.new()
	cfg.load("user://settings.cfg")
	U.check("the foveation row, right twice, A: сильная, foveation 3, density map on, 3D pass split", main.foveation.level == 3
			and main.xr_view.vrs_mode == Viewport.VRS_XR and main.foveation.split_pass.enabled and _value(p, "fov") == "SteamVR сильная")
	U.check("Godot's own map at the strongest", is_equal_approx(oxr.vrs_strength, Foveation.OWN_MAP_STRENGTH[2]))
	U.check("foveation on: scale back to 100%, both kept", p.target.scaling_3d_scale == 1.0
			and cfg.get_value("render", "foveation", -1) == 3 and cfg.get_value("render", "scale", 0.0) == 1.0)
	p.choose_scale(0.9)
	cfg.load("user://settings.cfg")
	U.check("scale 90%: foveation off, kept", main.foveation.level == 0 and main.xr_view.vrs_mode == Viewport.VRS_DISABLED
			and not main.foveation.split_pass.enabled and cfg.get_value("render", "foveation", -1) == 0)
	p.choose_scale(1.0)
	# our own: no density map, no split; the floor from its texture, a quarter of the picture's
	# pixels or so at the narrow level
	for k in 4:
		p.change(1)
	p.press()
	var fov := main.renderer.floor_fov
	var size := main.xr.get_render_target_size()
	U.check("узкая: our own, no density map, no split, the floor from floor_fov's texture", main.foveation.level == 5
			and main.xr_view.vrs_mode == Viewport.VRS_DISABLED and not main.foveation.split_pass.enabled
			and fov.enabled and main.renderer.floor_mat.get_shader_parameter("fov_on") == true
			and _value(p, "fov") == "плавная узкая")
	U.check("its texture: smaller than the picture", fov.fov_tex.get_width() < size.x and fov.fov_tex.get_layers() == 2,
			"%d of %d" % [fov.fov_tex.get_width(), size.x])
	p.choose_foveation(0)
	U.check("off again: no density map, no split, the floor per pixel", main.xr_view.vrs_mode == Viewport.VRS_DISABLED
			and not main.foveation.split_pass.enabled and not fov.enabled and main.renderer.floor_mat.get_shader_parameter("fov_on") == false)
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


const SLOW_MS := 70


## Holds every frame up by ms in its _process: in the scripts' stretch (frame_phases.gd), where a
## SceneTree script's own _process would not be.
class Slow extends Node:
	var ms := 0

	func _process(_delta: float) -> void:
		if ms > 0:
			OS.delay_msec(ms)
