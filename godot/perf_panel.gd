extends Label3D
## The frame rate panel: text drawn by Godot itself, fixed in the world, on a plate.
##
## In the headset the plate is green while the display gets a new frame from us at (nearly)
## every refresh, red when it does not, grey while it is still measuring. The text gives the
## refresh rate the headset really runs at, measured from OpenXR's frame timing (rate_meter.gd)
## rather than taken from what the runtime reports, the frames we delivered of the refreshes in
## the last second, and the GPU time per frame against the time one frame may take.
##
## A trigger press picks the next refresh rate. SteamVR on the Steam Frame accepts an app's own
## request (XR_FB_display_refresh_rate) and ignores it, offering a single rate
## (ValveSoftware/SteamVR-for-Linux#1020). What it follows is the app's own SteamVR setting
## steam.app.<SteamAppId>.preferredRefreshRate, which SteamVR's vrcmd sets while SteamVR runs;
## on our Frame (SteamVR 2.18) the running app switches within a second, others report it only
## from the next start. So when the app was started from the Steam library and vrcmd is there,
## the press sets that, and the panel says whether the display followed or asks for a restart.
## Otherwise the press asks the runtime directly and the panel says whether the display followed.
##
## Every few seconds a line starting with "refresh:" goes to the log, for checking afterwards,
## with the GPU's clock where the kernel shows it: a GPU that lowers its clock under a light load
## makes the same frame take longer.
##
## Once the session runs, the panel asks the runtime to keep the GPU and CPU at a sustained high
## performance level (XR_EXT_performance_settings), if the runtime offers that.

const RateMeter := preload("res://rate_meter.gd")
const JUDGE_SECONDS := 5        # the colour judges up to the last 5 seconds
const MIN_SECONDS := 2          # at a new rate, measure this long before judging
const MISSED_OK := 0.01         # refreshes without a new frame that still count as keeping up
const REQUEST_WAIT := 3.0       # seconds the headset gets to follow a request
const LOG_EVERY := 5            # seconds between log lines
const NOTE_SECONDS := 8         # how long the answer to a press stays on the panel
const FRAME_RATES := [72.0, 80.0, 90.0, 96.0, 108.0, 120.0, 144.0]   # SteamVR's per-app choices on the Frame
const VRCMD := "/opt/steamvr/bin/linuxarm64/vrcmd"
const VRSETTINGS := "/.config/openvr/config/steamvr.vrsettings"     # under $HOME
const SETTING := "preferredRefreshRate"
const DEVFREQ := "/sys/class/devfreq"                             # the kernel's clock-scaled devices
const STEAM_HINT := "частота: SteamVR > Video >\nPer-Application Video Settings"
const COLOR_OK := Color(0.05, 0.33, 0.12, 0.92)
const COLOR_BAD := Color(0.45, 0.06, 0.05, 0.92)
const COLOR_WAIT := Color(0.05, 0.06, 0.09, 0.9)

var target: Viewport            # the viewport the scene is rendered into
var xr: OpenXRInterface         # null on the desktop
var api: OpenXRAPIExtension     # the frame timing OpenXR predicts
var meter := RateMeter.new()
var seconds: Array = []         # the last few seconds at the current rate: [frames, refreshes, gpu ms sum, gpu ms max, process frames]
var t := 0.0
var frames := 0
var gpu := 0.0
var gpu_max := 0.0
var rate := 0.0                 # measured, Hz
var reported := 0.0             # what the runtime says, Hz (read once a second)
var vrcmd := VRCMD
var vrsettings := ""
var steam_key := ""             # "steam.app.<SteamAppId>": this app's section of SteamVR's settings
var stored := 0.0               # this app's rate there, used from its next start; 0: not set (72 Hz)
var stored_at_start := 0.0
var writing := false            # vrcmd is setting it
var requested := 0.0            # a runtime request the display has not answered yet
var request_from := 0.0
var request_age := 0.0
var note := ""                  # what came of the last press
var note_failed := false
var note_left := 0
var logged := 0
var devfreq := DEVFREQ
var gpu_clock := ""             # the GPU's devfreq directory, if the kernel shows one
var clock_min := 0              # MHz, over the log window
var clock_max := 0
var perf_asked := false
var plate: MeshInstance3D
var plate_mat: StandardMaterial3D


func _ready() -> void:
	no_depth_test = true
	render_priority = 20
	pixel_size = 0.0014
	font_size = 40
	outline_size = 0
	modulate = Color(1.0, 0.97, 0.88)
	horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	plate_mat = StandardMaterial3D.new()
	plate_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	plate_mat.albedo_color = COLOR_WAIT
	plate_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	plate_mat.no_depth_test = true
	plate_mat.render_priority = 19
	plate = MeshInstance3D.new()
	plate.mesh = QuadMesh.new()
	plate.material_override = plate_mat
	add_child(plate)
	RenderingServer.viewport_set_measure_render_time(target.get_viewport_rid(), true)
	if xr:
		api = OpenXRAPIExtension.new()
		# a method, not a lambda: a lambda left connected to the interface corrupted memory at exit
		xr.refresh_rate_changed.connect(_on_runtime_rate)
		xr.gpu_level_changed.connect(_on_gpu_level)
		_find_gpu_clock()
		find_app_setting()
	_set_text("...")


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
	if api and api.is_running():
		if not perf_asked:
			_ask_performance()
		var now := api.get_predicted_display_time()
		# predicted display time of the next frame minus this one's: the period the runtime paces us at
		meter.add(now, api.get_next_frame_time() - now, reported)
	t += delta
	frames += 1
	var g := RenderingServer.viewport_get_measured_render_time_gpu(target.get_viewport_rid())
	gpu += g
	gpu_max = maxf(gpu_max, g)
	if requested > 0.0:
		request_age += delta
		if request_age >= REQUEST_WAIT:
			_answer_request()
	if t >= 1.0:
		_second()
		t = 0.0
		frames = 0
		gpu = 0.0
		gpu_max = 0.0


## A trigger press: pick the next refresh rate.
func step_rate() -> void:
	if xr == null or writing or requested > 0.0:
		return
	note = ""
	if steam_key != "":
		var next := next_rate(FRAME_RATES, stored if stored > 0.0 else rate)
		writing = true
		# Steam preloads its overlay into everything it starts; vrcmd needs none of it, and the
		# loader would only fill the log with complaints
		OS.unset_environment("LD_PRELOAD")
		print("refresh: setting %s.%s to %.0f" % [steam_key, SETTING, next])
		WorkerThreadPool.add_task(_set_stored.bind(next))
		_set_text(_compose())
		return
	var offered: Array = xr.get_available_display_refresh_rates()
	if offered.size() < 2:
		print("refresh: trigger, the runtime offers %s, nothing to ask for" % [offered])
		_set_note("шлем не даёт сменить частоту", true)
		return
	request_from = rate if rate > 0.0 else xr.display_refresh_rate
	requested = next_rate(offered, request_from)
	request_age = 0.0
	print("refresh: asking for %.1f Hz (measured %.1f, runtime says %.1f, offers %s)"
			% [requested, rate, xr.display_refresh_rate, offered])
	xr.display_refresh_rate = requested
	_set_text(_compose())


## The next rate above current, or the lowest after the highest.
static func next_rate(rates: Array, current: float) -> float:
	var sorted := rates.duplicate()
	sorted.sort()
	for r in sorted:
		if r > current + 0.5:
			return r
	return sorted[0]


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


## The last number in a tool's output, or -1.
static func last_number(text: String) -> float:
	var words := text.replace("\n", " ").replace("=", " ").replace(":", " ").split(" ", false)
	for i in range(words.size() - 1, -1, -1):
		if words[i].is_valid_float():
			return words[i].to_float()
	return -1.0


## This app's rate in SteamVR's settings file (read only: SteamVR rewrites it from memory).
func _stored_rate() -> float:
	if not FileAccess.file_exists(vrsettings):
		return 0.0
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(vrsettings))
	if data is Dictionary and data.get(steam_key) is Dictionary:
		print("refresh: SteamVR settings for this app: ", data[steam_key])
		return float(data[steam_key].get(SETTING, 0.0))
	return 0.0


## On a worker thread: set this app's rate through vrcmd, then read it back.
func _set_stored(r: float) -> void:
	var key := "%s.%s" % [steam_key, SETTING]
	var env := ["LD_PRELOAD=", "LD_LIBRARY_PATH=" + vrcmd.get_base_dir(), vrcmd]
	var out := []
	var code := OS.execute("/usr/bin/env", env + ["--set-settings-float", key, "%.0f" % r], out, true)
	var back := []
	var back_code := OS.execute("/usr/bin/env", env + ["--settings-float", key], back, true)
	_stored_set.call_deferred(r, code, "".join(out), back_code, "".join(back))


func _stored_set(r: float, code: int, text: String, back_code: int, back: String) -> void:
	writing = false
	var got := last_number(back)
	print("refresh: vrcmd set exit %d [%s], read back exit %d [%s] -> %.1f"
			% [code, text.strip_edges().replace("\n", " | "), back_code, back.strip_edges().replace("\n", " | "), got])
	if absf(got - r) < 0.5 or (got < 0.0 and code == 0):
		stored = r
		# SteamVR 2.18 on the Frame switches the running app within a second; others may only
		# from the next start. Give the display a moment, then say which.
		request_from = rate
		requested = r
		request_age = 0.0
	else:
		_set_note("не получилось задать частоту", true)
	_set_text(_compose())


func _answer_request() -> void:
	var now := rate
	var followed := absf(now - requested) < 0.5
	if followed:
		_set_note("шлем перешёл на %.0f Гц" % now, false)
	elif steam_key == "":
		_set_note("шлем остался на %.0f Гц" % now, true)
	print("refresh: asked for %.1f Hz, after %.0f s the display runs at %.1f Hz (was %.1f), runtime says %.1f"
			% [requested, REQUEST_WAIT, now, request_from, xr.display_refresh_rate])
	requested = 0.0
	_set_text(_compose())


func _set_note(s: String, failed: bool) -> void:
	note = s
	note_failed = failed
	note_left = NOTE_SECONDS
	_set_text(_compose())


func _on_runtime_rate(r: float) -> void:
	print("refresh: runtime event, rate %.1f Hz" % r)


func _on_gpu_level(sub_domain: int, from_level: int, to_level: int) -> void:
	print("refresh: runtime event, GPU %s level %d -> %d" % [sub_domain, from_level, to_level])


## Keep the GPU and CPU clocks up, if the runtime takes such a request.
func _ask_performance() -> void:
	perf_asked = true
	if api.get_instance_proc_addr("xrPerfSettingsSetPerformanceLevelEXT") == 0:
		print("refresh: the runtime does not offer XR_EXT_performance_settings")
		return
	print("refresh: XR_EXT_performance_settings: asking for sustained high GPU and CPU")
	xr.set_gpu_level(OpenXRInterface.PERF_SETTINGS_LEVEL_SUSTAINED_HIGH)
	xr.set_cpu_level(OpenXRInterface.PERF_SETTINGS_LEVEL_SUSTAINED_HIGH)


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
			var read := func(f: String) -> String:
				return FileAccess.get_file_as_string(dir + "/" + f).strip_edges()
			print("refresh: GPU clock %s: governor %s, %s..%s Hz, steps %s"
					% [dir, read.call("governor"), read.call("min_freq"), read.call("max_freq"),
					read.call("available_frequencies")])
			return
	print("refresh: no GPU among %s: %s" % [devfreq, names])


func _gpu_mhz() -> int:
	if gpu_clock == "":
		return 0
	return FileAccess.get_file_as_string(gpu_clock + "/cur_freq").strip_edges().to_int() / 1_000_000


## Once a second: close the second's counts, recolour, retext, and now and then log.
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
	note_left -= 1
	if note_left <= 0:
		note = ""
	if xr:
		var ok: Variant = keeps_up(seconds)
		plate_mat.albedo_color = COLOR_WAIT if ok == null else (COLOR_OK if ok else COLOR_BAD)
	_set_text(_compose())
	if gpu_clock != "":
		var mhz := _gpu_mhz()
		clock_min = mhz if clock_min == 0 else mini(clock_min, mhz)
		clock_max = maxi(clock_max, mhz)
	logged += 1
	if xr and logged >= LOG_EVERY:
		logged = 0
		_log()


func _compose() -> String:
	var fps := frames / t if t > 0.0 else 0.0
	var g := gpu / frames if frames > 0 else 0.0
	if xr == null:
		return "%.0f кадр/с\nGPU %.1f мс" % [fps, g]
	if rate <= 0.0:
		return "%.0f кадр/с\nGPU %.1f мс\nшлем не даёт время кадров" % [fps, g]
	var ok: Variant = keeps_up(seconds)
	var last: Array = seconds.back() if not seconds.is_empty() else [0, 0]
	var lines := [
		"%.0f Гц · %s" % [rate, "меряю..." if ok == null else ("успевает" if ok else "не успевает")],
		"кадров %d из %d" % [last[0], last[1]],
		"GPU %.1f из %.1f мс" % [g, 1000.0 / rate],
	]
	if requested > 0.0:
		lines.append("переключаю на %.0f Гц..." % requested)
	elif writing:
		lines.append("задаю частоту...")
	elif note != "":
		lines.append(note)
	if steam_key != "":
		if stored > 0.0 and absf(stored - rate) > 0.5 and requested == 0.0:
			if stored != stored_at_start:
				lines.append("задано %.0f Гц: выйди и запусти снова" % stored)
			else:
				lines.append("в SteamVR задано %.0f Гц, а шлем на %.0f" % [stored, rate])
		if not writing and requested == 0.0:
			lines.append("курок: %.0f Гц" % next_rate(FRAME_RATES, stored if stored > 0.0 else rate))
		if note_failed and note != "":
			lines.append(STEAM_HINT)
	else:
		var offered: Array = xr.get_available_display_refresh_rates()
		if offered.size() >= 2 and requested == 0.0:
			lines.append("курок: %.0f Гц" % next_rate(offered, rate))
		if offered.size() < 2 or (note_failed and note != ""):
			lines.append(STEAM_HINT)
	return "\n".join(lines)


## The last few seconds at the current rate, in one line of the log.
func _log() -> void:
	var f := 0
	var r := 0
	var n := 0
	var g := 0.0
	var gm := 0.0
	for s in seconds:
		f += s[0]
		r += s[1]
		g += s[2]
		gm = maxf(gm, s[3])
		n += s[4]
	var eye := xr.get_render_target_size()
	print("refresh: display %.2f Hz, paced %.2f Hz, %d frames of %d refreshes (%d missed) in %d s, gpu %.2f ms avg %.2f max of %.2f, gpu clock %d..%d MHz, runtime says %.1f of %s, stored %.0f, eye %dx%d, keeps up %s"
			% [rate, meter.paced_rate(), f, r, r - f, seconds.size(), g / n if n > 0 else 0.0, gm,
			1000.0 / rate if rate > 0.0 else 0.0, clock_min, clock_max, reported,
			xr.get_available_display_refresh_rates(), stored, int(eye.x), int(eye.y), keeps_up(seconds)])
	clock_min = 0
	clock_max = 0


func _set_text(s: String) -> void:
	text = s
	# the plate covers the (centred) text with a margin; sized from the font, since the label
	# rebuilds its own geometry only later
	var f: Font = font if font else ThemeDB.fallback_font
	var size := f.get_multiline_string_size(s, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size) * pixel_size
	(plate.mesh as QuadMesh).size = size + Vector2(0.08, 0.06)
	plate.position = Vector3(0.0, 0.0, -0.005)
