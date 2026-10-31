class_name FrameRate
extends Node
## The refresh rate the headset really runs at and whether our frames keep up, measured from
## OpenXR's frame timing (rate_meter.gd; the runtime's reported rate only picks among the rates the
## timing fits); choosing a rate; the log's "refresh:" lines about these (the menu's own are about
## its settings).
##
## Choosing a rate. SteamVR on the Steam Frame accepts an app's own request
## (XR_FB_display_refresh_rate) and ignores it, offering a single rate
## (ValveSoftware/SteamVR-for-Linux#1020). What it follows is the app's own SteamVR setting
## steam.app.<SteamAppId>.preferredRefreshRate, which SteamVR's vrcmd sets while SteamVR runs; on
## the owner's Frame (SteamVR 2.18; the headset log's "refresh:" lines, which tools/frame_logs.ps1
## fetches) the running app switches within a second, others report it only from the next start.
## So a choice sets that setting where it can (find_app_setting), else asks the runtime.
## Until a rate is stored for the app SteamVR runs it at 72 Hz (the log's "refresh:" lines). It has
## no XR_EXT_performance_settings.
##
## Half rate. A late frame sends SteamVR to every second refresh for a second to 18 s (the log's
## "refresh:" lines): it fills in the frames between on the same GPU, so our frame at the same pose
## costs more, and it can stay there until the frame gets cheaper or the rate is switched there and
## back. The Steam overlay and SteamVR's camera view do the same. The app could end it at once only
## by switching the rate there and back; it doesn't (docs/wishlist.md); cheaper frames make it
## rarer.
##
## The log has the GPU's clock because a GPU that lowers it makes the same frame take longer; on
## the Frame the readings (one a second) showed its top clock while frames were too slow. The GPU
## and render CPU times it prints are the last ones Godot hands back: RenderingDevice returns a
## frame's GPU timestamps, and the CPU ticks taken with them, only when that frame's slot is used
## again, so both belong to the frame two before the one that prints them (two slots: project.godot
## leaves frame_queue_size at its default). "process" (Performance.TIME_PROCESS) is the longest
## stretch of Godot's main loop over about the last second, from the scripts' processing through
## the rendering's sync and draw, updated once a second. main's script (Main.scripts_ms,
## main._process alone) is given for this frame (main is processed before this node, its child), and
## the frame before's way on the main thread by stretch, running, waiting for a core or asleep
## (frame_phases.gd), its scripts with main's script by part (Main.PARTS).
## project.godot keeps application/run/flush_stdout_on_print on: an export otherwise buffers
## print(), and an abort at exit loses the log's end.

signal changed                  # the lines (status, notes) or the verdict changed

const RateMeter := preload("res://rate_meter.gd")
const JUDGE_SECONDS := 5        # the verdict judges up to this many last seconds
const MIN_SECONDS := 2          # at a new rate, measure this long before judging
const MISSED_OK := 0.01         # share of the refreshes without a new frame that still counts as keeping up
const REQUEST_WAIT := 3.0       # s the headset gets to follow a request
const LATE_LINES := 30          # late frames logged one by one per second, at most
const NOTE_SECONDS := 8         # how long the answer to a choice stays
const FRAME_RATES := [72.0, 80.0, 90.0, 96.0, 108.0, 120.0, 144.0]   # SteamVR's per-app choices on the Frame
const VRCMD := "/opt/steamvr/bin/linuxarm64/vrcmd"
const VRSETTINGS := "/.config/openvr/config/steamvr.vrsettings"     # under $HOME
const SETTING := "preferredRefreshRate"
const DEVFREQ := "/sys/class/devfreq"                             # the kernel's clock-scaled devices
const STEAM_HINT := "частота: SteamVR > Video >\nPer-Application Video Settings"
# the lines status() and notes() give: here, so widest_lines() takes them all
const LINE_FPS := "%.0f кадр/с"
const LINE_GPU := "GPU %.1f мс"
const NO_TIMING := "шлем не даёт время кадров"
const LINE_RATE := "%.0f Гц · %s"
const VERDICTS := ["меряю...", "успевает", "не успевает"]    # too little to judge, keeps up, not
const LINE_FRAMES := "кадров %d из %d · %s"
const LINE_BUDGET := "GPU %.1f из %.1f мс"
const NOTE_SWITCHING := "переключаю на %.0f Гц..."
const NOTE_RESTART := "задано %.0f Гц: выйди и запусти снова"
const NOTE_MISMATCH := "в SteamVR задано %.0f Гц, а шлем на %.0f"
const NOTE_FOLLOWED := "шлем перешёл на %.0f Гц"
const NOTE_STAYED := "шлем остался на %.0f Гц"
const NOTE_NOT_SET := "не получилось задать частоту"

var main: Main                  # where the feet are and the head looks, for the log
var target: Viewport            # the viewport the scene is rendered into
var xr: OpenXRInterface         # null without OpenXR (the desktop, the tests' fake headsets)
var api: OpenXRAPIExtension     # the frame timing OpenXR predicts
var meter := RateMeter.new()
var seconds: Array[Second] = []   # the last few at the current rate
var t := 0.0                    # s of this second so far
var now := Second.new()         # and its counts (shown and refreshes: _second)
var rate := 0.0                 # measured, Hz
var reported := 0.0             # what the runtime says, Hz (read once a second)
var vrcmd := VRCMD
var vrsettings := ""
var steam_key := ""             # "steam.app.<SteamAppId>": this app's section of SteamVR's settings
var stored := 0.0               # this app's rate there; 0: not set
var stored_at_start := 0.0
var writing := false            # vrcmd is setting it
var desired := 0.0              # the rate last chosen; written after the one being written, if it differs
var requested := 0.0            # a rate the display has not followed yet
var request_from := 0.0
var request_age := 0.0
var phases: FramePhases         # where the frame before's time went (OpenXR only)
var before: Array = []          # the frame before: [main's script ms, its parts ms]
var note := ""                  # what came of the last choice
var note_failed := false
var note_left := 0
var late_lines := 0             # late frames logged this second
var devfreq := DEVFREQ
var gpu_clock := ""             # the GPU's devfreq directory, if the kernel shows one
var clock_mhz := 0              # read once a second: a kernel file each frame is not free
var compiled := 0               # pipelines Godot had compiled at the last second's line (compilations())


func _ready() -> void:
	RenderingServer.viewport_set_measure_render_time(target.get_viewport_rid(), true)
	if xr:
		api = OpenXRAPIExtension.new()
		if not api.is_running():
			phases = FramePhases.new()
			phases.start(api)
		# a method, not a lambda (main.gd, _ready)
		xr.refresh_rate_changed.connect(_on_runtime_rate)
		_find_gpu_clock()
		find_app_setting()


## The rate choices: SteamVR's per-app ones on the Frame, else what the runtime offers.
func options() -> Array:
	if steam_key != "":
		return FRAME_RATES
	if xr == null:
		return []
	var offered: Array = xr.get_available_display_refresh_rates()
	offered.sort()
	return offered


## The rate chosen, in effect or not yet.
func chosen() -> float:
	return requested if requested > 0.0 else (desired if writing else (stored if stored > 0.0 else rate))


## Started from the Steam library (SteamAppId set) with SteamVR's vrcmd at hand: this app's rate
## is its SteamVR setting.
func find_app_setting() -> void:
	vrsettings = OS.get_environment("HOME") + VRSETTINGS
	var app_id := OS.get_environment("SteamAppId")
	steam_key = ""
	if app_id.is_valid_int() and FileAccess.file_exists(vrcmd):
		steam_key = "steam.app." + app_id
		stored = _stored_rate()
		stored_at_start = stored
	print("refresh: SteamAppId '%s', vrcmd %s, %s.%s = %.1f"
			% [app_id, FileAccess.file_exists(vrcmd), steam_key, SETTING, stored])


func _process(delta: float) -> void:
	var bench := main.bench
	if api and api.is_running():
		var now := api.get_predicted_display_time()
		# predicted display time of the next frame minus this one's: the period the runtime paces us at
		var period := api.get_next_frame_time() - now
		var missed_before := meter.missed()
		meter.add(now, period, reported)
		# a late frame gets a line: where, what is before the eyes (main.view_text), the times this
		# file's top describes and the pipelines compiled so far
		if meter.missed() > missed_before and late_lines < LATE_LINES and not bench.running:
			late_lines += 1
			var look: Vector2 = main.look_angles()
			print("refresh: late frame, %d refresh(es) without a new one, feet l %.2f m, looking %.0f deg from the throat, %.0f deg up, gpu %.2f ms, cpu %.2f ms render %.2f ms process, main's script %.2f ms; %s; pipelines compiled %d; %s"
					% [meter.missed() - missed_before, main.foot_l, look.x, look.y,
					RenderingServer.viewport_get_measured_render_time_gpu(target.get_viewport_rid()),
					RenderingServer.viewport_get_measured_render_time_cpu(target.get_viewport_rid()),
					Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, main.scripts_ms, _before_text(),
					compilations(), main.view_text()])
		bench.frame_timing(now, period, reported)
	before = [main.scripts_ms, main.parts_ms.duplicate()]
	t += delta
	now.drawn += 1
	var g := RenderingServer.viewport_get_measured_render_time_gpu(target.get_viewport_rid())
	now.gpu += g
	now.gpu_max = maxf(now.gpu_max, g)
	if requested > 0.0:
		if absf(meter.rate() - requested) < 0.5:
			_answer_request()
		elif not writing:
			request_age += delta
			if request_age >= REQUEST_WAIT:
				_answer_request()
	if t >= 1.0:
		_second()
		t = 0.0
		now = Second.new()


func choose(r: float) -> void:
	if xr == null:
		return
	note = ""
	desired = r
	requested = r
	request_from = rate
	request_age = 0.0
	if steam_key != "":
		if not writing:
			_write()
	else:
		print("refresh: asking for %.1f Hz (measured %.1f, runtime says %.1f, offers %s)"
				% [r, rate, xr.display_refresh_rate, xr.get_available_display_refresh_rates()])
		xr.display_refresh_rate = r
	changed.emit()


func _write() -> void:
	writing = true
	# Steam preloads its overlay into everything it starts; vrcmd needs none of it, and the
	# loader would only fill the log with complaints
	OS.unset_environment("LD_PRELOAD")
	print("refresh: setting %s.%s to %.0f" % [steam_key, SETTING, desired])
	WorkerThreadPool.add_task(_set_stored.bind(desired))


## This app's rate in SteamVR's settings file (read only: SteamVR rewrites it from memory).
func _stored_rate() -> float:
	if not FileAccess.file_exists(vrsettings):
		return 0.0
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(vrsettings))
	if data is Dictionary and data.get(steam_key) is Dictionary:
		print("refresh: SteamVR settings for this app: ", data[steam_key])
		return float(data[steam_key].get(SETTING, 0.0))
	return 0.0


## On a worker thread: set this app's rate through vrcmd.
func _set_stored(r: float) -> void:
	var key := "%s.%s" % [steam_key, SETTING]
	var out := []
	var code := OS.execute("/usr/bin/env", ["LD_PRELOAD=", "LD_LIBRARY_PATH=" + vrcmd.get_base_dir(), vrcmd,
			"--set-settings-float", key, "%.0f" % r], out, true)
	_stored_set.call_deferred(r, code, "".join(out))


func _stored_set(r: float, code: int, text_out: String) -> void:
	writing = false
	print("refresh: vrcmd set %.0f: exit %d [%s]" % [r, code, text_out.strip_edges().replace("\n", " | ")])
	if code == 0:
		stored = r
	elif absf(desired - r) < 0.5:
		requested = 0.0
		_set_note(NOTE_NOT_SET, true)
	if absf(desired - r) > 0.5:
		_write()            # chosen again meanwhile
	else:
		request_age = 0.0   # the display gets REQUEST_WAIT from now to follow
	changed.emit()


func _answer_request() -> void:
	var now := meter.rate()
	var followed := absf(now - requested) < 0.5
	if followed:
		_set_note(NOTE_FOLLOWED % now, false)
	elif steam_key == "":
		_set_note(NOTE_STAYED % now, true)
	print("refresh: asked for %.1f Hz, the display runs at %.1f Hz (was %.1f), runtime says %.1f"
			% [requested, now, request_from, xr.display_refresh_rate])
	requested = 0.0
	changed.emit()


func _set_note(s: String, failed: bool) -> void:
	note = s
	note_failed = failed
	note_left = NOTE_SECONDS


func _on_runtime_rate(r: float) -> void:
	print("refresh: runtime event, rate %.1f Hz" % r)


## Up to the last JUDGE_SECONDS seconds: true if at most MISSED_OK of the refreshes went without
## a new frame, false if more, null while there is too little to judge.
static func keeps_up(window: Array[Second]) -> Variant:
	if window.size() < MIN_SECONDS:
		return null
	var f := 0
	var r := 0
	for s in window:
		f += s.shown
		r += s.refreshes
	if r == 0:
		return null
	return float(r - f) <= MISSED_OK * r


## The verdict now: true, false, or null (too little to judge, or no headset).
func verdict() -> Variant:
	return keeps_up(seconds) if xr else null


## The GPU's clock-scaling device: its name has "gpu" in it (on msm: <address>.gpu).
func _find_gpu_clock() -> void:
	if not DirAccess.dir_exists_absolute(devfreq):
		print("refresh: no %s, no GPU clock" % devfreq)
		return
	var names := DirAccess.get_directories_at(devfreq) + DirAccess.get_files_at(devfreq)
	for n in names:
		var dir := devfreq + "/" + n
		if n.to_lower().contains("gpu") and FileAccess.file_exists(dir + "/cur_freq"):
			gpu_clock = dir
			print("refresh: GPU clock %s: governor %s, %s..%s Hz, steps %s"
					% [dir, read_line(dir + "/governor"), read_line(dir + "/min_freq"),
					read_line(dir + "/max_freq"), read_line(dir + "/available_frequencies")])
			return
	print("refresh: no GPU among %s: %s" % [devfreq, names])


## The GPU's clock now, MHz; 0 where the kernel does not show it.
func gpu_mhz() -> int:
	if gpu_clock == "":
		return 0
	return read_line(gpu_clock + "/cur_freq").to_int() / 1_000_000


## The first line of a kernel file. A sysfs file says it holds 4096 bytes whatever it holds, and
## FileAccess.get_file_as_string reads that many: garbage after the value, and the log filled
## with Unicode errors.
static func read_line(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_line().strip_edges() if f else ""


## Once a second: close the second's counts, tell the menu, log.
func _second() -> void:
	if xr:
		reported = xr.display_refresh_rate
	var r := meter.rate()
	if absf(r - rate) > 0.5:
		if rate > 0.0:
			print("refresh: the display went from %.1f to %.1f Hz" % [rate, r])
		rate = r
		seconds.clear()
	else:
		now.shown = meter.frames
		now.refreshes = meter.refreshes
		seconds.append(now)
		if seconds.size() > JUDGE_SECONDS:
			seconds.pop_front()
	meter.reset_window()
	late_lines = 0
	note_left -= 1
	if note_left <= 0:
		note = ""
	changed.emit()
	if gpu_clock != "":
		clock_mhz = gpu_mhz()
	if xr:
		_log()


## The frame before by stretch (frame_phases.gd), main's script in its scripts by part.
func _before_text() -> String:
	var mains := ""
	if not before.is_empty():
		var parts := []
		for i in Main.PARTS.size():
			parts.append("%s %.2f" % [Main.PARTS[i], before[1][i]])
		mains = "main's %.2f: %s" % [before[0], ", ".join(parts)]
	return phases.text(mains) if phases else "the frame before: not measured"


## main's script in the frame before, ms (0 before there is one).
func before_script_ms() -> float:
	return before[0] if not before.is_empty() else 0.0


## Pipelines Godot has compiled so far, of every kind (its PIPELINE_COMPILATIONS_* monitors). A
## compilation happens the first time something is drawn in a new way (a material, the gravity view,
## a variant of a pass) and holds that frame up: a late frame next to new ones was a compile.
static func compilations() -> int:
	var n := 0
	for m in [Performance.PIPELINE_COMPILATIONS_CANVAS, Performance.PIPELINE_COMPILATIONS_MESH,
			Performance.PIPELINE_COMPILATIONS_SURFACE, Performance.PIPELINE_COMPILATIONS_DRAW,
			Performance.PIPELINE_COMPILATIONS_SPECIALIZATION]:
		n += int(Performance.get_monitor(m))
	return n


## The GPU time per frame so far this second, ms.
func gpu_ms() -> float:
	return now.gpu / now.drawn if now.drawn > 0 else 0.0


## The first lines: the rate and the verdict, the frames and the GPU time.
func status() -> Array:
	var fps := now.drawn / t if t > 0.0 else 0.0
	if xr == null:
		return [LINE_FPS % fps, LINE_GPU % gpu_ms()]
	if rate <= 0.0:
		return [LINE_FPS % fps, LINE_GPU % gpu_ms(), NO_TIMING]
	var ok: Variant = keeps_up(seconds)
	var last: Second = seconds.back() if not seconds.is_empty() else Second.new()
	return [LINE_RATE % [rate, VERDICTS[0 if ok == null else (1 if ok else 2)]],
			LINE_FRAMES % [last.shown, last.refreshes, gpu_budget()]]


## "GPU <ms> из <ms> мс": the GPU time against the time one frame may take.
func gpu_budget() -> String:
	return LINE_BUDGET % [gpu_ms(), 1000.0 / rate]


## Lines as wide as the widest that status() and notes() give, for the menu's width: their formats
## with the widest numbers (three digits a rate or the frames in a second, four the desktop's frames
## a second, two before the point a time).
static func widest_lines() -> Array:
	var lines := [LINE_FPS % 8888.0, LINE_GPU % 88.8, NO_TIMING,
			LINE_FRAMES % [888, 888, LINE_BUDGET % [88.8, 88.8]], NOTE_SWITCHING % 888.0,
			NOTE_RESTART % 888.0, NOTE_MISMATCH % [888.0, 888.0], NOTE_FOLLOWED % 888.0,
			NOTE_STAYED % 888.0, NOTE_NOT_SET, STEAM_HINT]
	for v: String in VERDICTS:
		lines.append(LINE_RATE % [888.0, v])
	return lines


## What came of a rate choice, and what to do about it.
func notes() -> Array:
	var lines := []
	if xr == null or rate <= 0.0:
		return lines
	if requested > 0.0:
		lines.append(NOTE_SWITCHING % requested)
	elif note != "":
		lines.append(note)
	if steam_key != "":
		if stored > 0.0 and absf(stored - rate) > 0.5 and requested == 0.0:
			if stored != stored_at_start:
				lines.append(NOTE_RESTART % stored)
			else:
				lines.append(NOTE_MISMATCH % [stored, rate])
		if note_failed and note != "":
			lines.append(STEAM_HINT)
	elif options().size() < 2 or (note_failed and note != ""):
		lines.append(STEAM_HINT)
	return lines


## The last second, in one line of the log: where the feet are and where the head looks, the
## frames and refreshes, the GPU time, the verdict over the last few seconds and the settings.
func _log() -> void:
	if seconds.is_empty():
		return
	var s: Second = seconds.back()
	var eye := xr.get_render_target_size()
	var l: float = main.foot_l
	var edge: float = main.space.L
	var look: Vector2 = main.look_angles()
	var where := "feet l %.1f m (%s), looking %.0f deg from the throat, %.0f deg up, " % [l,
			"world A" if l >= edge else ("world B" if l <= -edge else "in the curved zone"), look.x, look.y]
	var f: Vector4 = main.renderer.frustum(0)
	var n := compilations()
	print("refresh: " + where + "display %.2f Hz, paced %.2f Hz, %d frames of %d refreshes (%d missed) in 1 s, gpu %.2f ms avg %.2f max of %.2f, gpu clock %d MHz, runtime says %.1f of %s, stored %.0f, eye %dx%d at scale %.2f, its frustum %.1f..%.1f deg up, keeps up %s, gaze %s, pipelines compiled %d in 1 s (%d in all); %s"
			% [rate, meter.paced_rate(), s.shown, s.refreshes, s.refreshes - s.shown, s.gpu / s.drawn if s.drawn > 0 else 0.0, s.gpu_max,
			1000.0 / rate if rate > 0.0 else 0.0, clock_mhz, reported,
			xr.get_available_display_refresh_rates(), stored, int(eye.x), int(eye.y), target.scaling_3d_scale,
			rad_to_deg(atan(f.z)), rad_to_deg(atan(f.w)), keeps_up(seconds), main.gaze_text(),
			n - compiled, n, main.view_text()])
	compiled = n


## A second's counts.
class Second:
	var shown := 0                  # frames the display showed (rate_meter.gd)
	var refreshes := 0              # and its refreshes
	var drawn := 0                  # frames Godot drew
	var gpu := 0.0                  # their GPU ms, summed
	var gpu_max := 0.0


	## As the tests print it.
	func _to_string() -> String:
		return "%d of %d refreshes shown, %d drawn, GPU %.1f ms avg %.1f max" % [shown, refreshes, drawn,
				gpu / drawn if drawn > 0 else 0.0, gpu_max]
