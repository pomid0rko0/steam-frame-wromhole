class_name FrameRate
extends Node
## The refresh rate the headset really runs at and whether our frames keep up, measured from
## OpenXR's frame timing (rate_meter.gd) rather than taken from what the runtime reports; choosing
## a rate; the "refresh:" lines in the log. The menu shows it (menu.gd: its head and the line below).
##
## Choosing a rate. SteamVR on the Steam Frame accepts an app's own request
## (XR_FB_display_refresh_rate) and ignores it, offering a single rate
## (ValveSoftware/SteamVR-for-Linux#1020). What it follows is the app's own SteamVR setting
## steam.app.<SteamAppId>.preferredRefreshRate, which SteamVR's vrcmd sets while SteamVR runs;
## on our Frame (SteamVR 2.18) the running app switches within a second, others report it only
## from the next start. So when the app was started from the Steam library and vrcmd is there,
## choosing a rate sets that (one vrcmd call on a worker thread; a choice made meanwhile is written
## next), the display's own rate tells when it followed, and if it has not a few seconds after
## the write the menu asks for a restart. Otherwise the choice asks the runtime directly.
##
## The log: every second a line starting with "refresh:", with where one stands and looks, the
## frames, the GPU time and the GPU's clock where the kernel shows it, and a line for every frame
## that came a refresh late, with where and what the GPU and the CPU took for it (a GPU that lowers
## its clock makes the same frame take longer; on the Frame it stayed at its top clock while frames
## were too slow).

signal changed                  # the lines (status, notes) or the verdict changed

const RateMeter := preload("res://rate_meter.gd")
const JUDGE_SECONDS := 5        # the verdict judges up to the last 5 seconds
const MIN_SECONDS := 2          # at a new rate, measure this long before judging
const MISSED_OK := 0.01         # refreshes without a new frame that still count as keeping up
const REQUEST_WAIT := 3.0       # s the headset gets to follow a request
const LATE_LINES := 30          # late frames logged one by one per second, at most
const NOTE_SECONDS := 8         # how long the answer to a choice stays
const FRAME_RATES := [72.0, 80.0, 90.0, 96.0, 108.0, 120.0, 144.0]   # SteamVR's per-app choices on the Frame
const VRCMD := "/opt/steamvr/bin/linuxarm64/vrcmd"
const VRSETTINGS := "/.config/openvr/config/steamvr.vrsettings"     # under $HOME
const SETTING := "preferredRefreshRate"
const DEVFREQ := "/sys/class/devfreq"                             # the kernel's clock-scaled devices
const STEAM_HINT := "частота: SteamVR > Video >\nPer-Application Video Settings"

var main: Node                  # main.gd: where the feet are and the head looks, for the log
var target: Viewport            # the viewport the scene is rendered into
var xr: OpenXRInterface         # null on the desktop
var api: OpenXRAPIExtension     # the frame timing OpenXR predicts
var meter := RateMeter.new()
var seconds: Array = []         # the last few seconds at the current rate: [frames, refreshes, gpu ms sum, gpu ms max, process frames]
var t := 0.0                    # this second so far: s, frames, GPU ms sum and max
var frames := 0
var gpu := 0.0
var gpu_max := 0.0
var rate := 0.0                 # measured, Hz
var reported := 0.0             # what the runtime says, Hz (read once a second)
var vrcmd := VRCMD
var vrsettings := ""
var steam_key := ""             # "steam.app.<SteamAppId>": this app's section of SteamVR's settings
var stored := 0.0               # this app's rate there; 0: not set (72 Hz)
var stored_at_start := 0.0
var writing := false            # vrcmd is setting it
var desired := 0.0              # the rate last chosen; written after the one being written, if it differs
var requested := 0.0            # a rate the display has not followed yet
var request_from := 0.0
var request_age := 0.0
var note := ""                  # what came of the last choice
var note_failed := false
var note_left := 0
var late_lines := 0             # late frames logged this second
var devfreq := DEVFREQ
var gpu_clock := ""             # the GPU's devfreq directory, if the kernel shows one
var clock_min := 0              # MHz, over the second
var clock_max := 0


func _ready() -> void:
	RenderingServer.viewport_set_measure_render_time(target.get_viewport_rid(), true)
	if xr:
		api = OpenXRAPIExtension.new()
		# a method, not a lambda: a lambda left connected to the interface corrupted memory at exit
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
	var bench: Node = main.bench
	if api and api.is_running():
		var now := api.get_predicted_display_time()
		# predicted display time of the next frame minus this one's: the period the runtime paces us at
		var period := api.get_next_frame_time() - now
		var missed_before := meter.missed()
		meter.add(now, period, reported)
		# every late frame gets a line: where, and what the GPU and the CPU took for it
		if meter.missed() > missed_before and late_lines < LATE_LINES and not bench.running:
			late_lines += 1
			var look: Vector2 = main.look_angles()
			print("refresh: late frame, %d refresh(es) without a new one, feet l %.2f m, looking %.0f deg from the throat, %.0f deg up, gpu %.2f ms, cpu %.2f ms render %.2f ms process"
					% [meter.missed() - missed_before, main.foot_l, look.x, look.y,
					RenderingServer.viewport_get_measured_render_time_gpu(target.get_viewport_rid()),
					RenderingServer.viewport_get_measured_render_time_cpu(target.get_viewport_rid()),
					Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0])
		bench.frame_timing(now, period, reported)
	t += delta
	frames += 1
	var g := RenderingServer.viewport_get_measured_render_time_gpu(target.get_viewport_rid())
	gpu += g
	gpu_max = maxf(gpu_max, g)
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
		frames = 0
		gpu = 0.0
		gpu_max = 0.0


## Ask for a rate.
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
		_set_note("не получилось задать частоту", true)
	if absf(desired - r) > 0.5:
		_write()            # chosen again meanwhile
	else:
		request_age = 0.0   # the display gets REQUEST_WAIT from now to follow
	changed.emit()


func _answer_request() -> void:
	var now := meter.rate()
	var followed := absf(now - requested) < 0.5
	if followed:
		_set_note("шлем перешёл на %.0f Гц" % now, false)
	elif steam_key == "":
		_set_note("шлем остался на %.0f Гц" % now, true)
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
static func keeps_up(window: Array) -> Variant:
	if window.size() < MIN_SECONDS:
		return null
	var f := 0
	var r := 0
	for s in window:
		f += s[0]
		r += s[1]
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
		seconds.append([meter.frames, meter.refreshes, gpu, gpu_max, frames])
		if seconds.size() > JUDGE_SECONDS:
			seconds.pop_front()
	meter.reset_window()
	late_lines = 0
	note_left -= 1
	if note_left <= 0:
		note = ""
	changed.emit()
	if gpu_clock != "":
		var mhz := gpu_mhz()
		clock_min = mhz if clock_min == 0 else mini(clock_min, mhz)
		clock_max = maxi(clock_max, mhz)
	if xr:
		_log()


## The GPU time per frame so far this second, ms.
func gpu_ms() -> float:
	return gpu / frames if frames > 0 else 0.0


## The first lines: the rate and the verdict, the frames and the GPU time.
func status() -> Array:
	var fps := frames / t if t > 0.0 else 0.0
	if xr == null:
		return ["%.0f кадр/с" % fps, "GPU %.1f мс" % gpu_ms()]
	if rate <= 0.0:
		return ["%.0f кадр/с" % fps, "GPU %.1f мс" % gpu_ms(), "шлем не даёт время кадров"]
	var ok: Variant = keeps_up(seconds)
	var last: Array = seconds.back() if not seconds.is_empty() else [0, 0]
	return ["%.0f Гц · %s" % [rate, "меряю..." if ok == null else ("успевает" if ok else "не успевает")],
			"кадров %d из %d · %s" % [last[0], last[1], gpu_budget()]]


## "GPU 4.1 из 8.3 мс": the GPU time against the time one frame may take.
func gpu_budget() -> String:
	return "GPU %.1f из %.1f мс" % [gpu_ms(), 1000.0 / rate]


## What came of a rate choice, and what to do about it.
func notes() -> Array:
	var lines := []
	if xr == null or rate <= 0.0:
		return lines
	if requested > 0.0:
		lines.append("переключаю на %.0f Гц..." % requested)
	elif note != "":
		lines.append(note)
	if steam_key != "":
		if stored > 0.0 and absf(stored - rate) > 0.5 and requested == 0.0:
			if stored != stored_at_start:
				lines.append("задано %.0f Гц: выйди и запусти снова" % stored)
			else:
				lines.append("в SteamVR задано %.0f Гц, а шлем на %.0f" % [stored, rate])
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
	var s: Array = seconds.back()
	var eye := xr.get_render_target_size()
	var l: float = main.foot_l
	var edge: float = main.space.L
	var look: Vector2 = main.look_angles()
	var where := "feet l %.1f m (%s), looking %.0f deg from the throat, %.0f deg up, " % [l,
			"world A" if l >= edge else ("world B" if l <= -edge else "in the curved zone"), look.x, look.y]
	var fov: Foveation = main.foveation
	print("refresh: " + where + "display %.2f Hz, paced %.2f Hz, %d frames of %d refreshes (%d missed) in 1 s, gpu %.2f ms avg %.2f max of %.2f, gpu clock %d..%d MHz, runtime says %.1f of %s, stored %.0f, eye %dx%d at scale %.2f, keeps up %s, foveation %d (own maps %s first), gaze %s, gravity view %d, menu %s"
			% [rate, meter.paced_rate(), s[0], s[1], s[1] - s[0], s[2] / s[4] if s[4] > 0 else 0.0, s[3],
			1000.0 / rate if rate > 0.0 else 0.0, clock_min, clock_max, reported,
			xr.get_available_display_refresh_rates(), stored, int(eye.x), int(eye.y), target.scaling_3d_scale,
			keeps_up(seconds), fov.level, "width" if fov.order == 0 else "height", main.gaze_text(),
			main.tracer.gravity_view, "open" if main.menu.open else "closed"])
	clock_min = 0
	clock_max = 0
