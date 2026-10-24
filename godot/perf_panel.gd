extends Label3D
## The frame rate panel: a small menu drawn by Godot itself on a plate. It hangs in the room
## 1.3 m in front of the head and a little below the eyes, and follows: as the head walks, at
## once; as it turns, only once it has turned well away, then smoothly; not while a controller
## points at it. So it is there at the wormhole and inside it, without being glued to the view.
##
## This label is its head: the refresh rate the headset really runs at, measured from OpenXR's
## frame timing (rate_meter.gd) rather than taken from what the runtime reports, whether frames
## keep up, the frames we delivered of the refreshes in the last second, and the GPU time per
## frame against the time one frame may take. The plate is green while the display gets a new
## frame from us at (nearly) every refresh, red when it does not, grey while it is measuring.
##
## Below, two rows of buttons: the refresh rate and the 3D render scale. A controller points
## with a ray from its aim pose; its trigger presses the button the ray is on. Green: in effect;
## yellow: chosen, not (yet) in effect.
##
## The refresh rate. SteamVR on the Steam Frame accepts an app's own request
## (XR_FB_display_refresh_rate) and ignores it, offering a single rate
## (ValveSoftware/SteamVR-for-Linux#1020). What it follows is the app's own SteamVR setting
## steam.app.<SteamAppId>.preferredRefreshRate, which SteamVR's vrcmd sets while SteamVR runs;
## on our Frame (SteamVR 2.18) the running app switches within a second, others report it only
## from the next start. So when the app was started from the Steam library and vrcmd is there,
## a rate button sets that (one vrcmd call on a worker thread; a choice made meanwhile is written
## next), the display's own rate tells when it followed, and if it has not a few seconds after
## the write the panel asks for a restart. Otherwise the button asks the runtime directly.
##
## The last row starts the speed check (bench.gd); its title shows how it goes and what came out.
##
## The render scale of the XR viewport (100, 90, 80, 70%; Godot upscales bilinearly to the
## headset's size): fewer pixels to ray trace, a softer picture. Kept in user://settings.cfg.
##
## Every second a line starting with "refresh:" goes to the log, for checking afterwards, with
## where one stands and looks and the GPU's clock where the kernel shows it, and a line for every
## frame that came a refresh late, with where and what the GPU and the CPU took for it (a GPU that lowers its clock makes the same
## frame take longer; on the Frame it stayed at its top clock while frames were too slow).

const RateMeter := preload("res://rate_meter.gd")
const JUDGE_SECONDS := 5        # the colour judges up to the last 5 seconds
const MIN_SECONDS := 2          # at a new rate, measure this long before judging
const MISSED_OK := 0.01         # refreshes without a new frame that still count as keeping up
const REQUEST_WAIT := 3.0       # seconds the headset gets to follow a request
const LOG_EVERY := 1            # seconds between log lines
const LATE_LINES := 30          # late frames logged one by one per second, at most
const NOTE_SECONDS := 8         # how long the answer to a press stays on the panel
const FRAME_RATES := [72.0, 80.0, 90.0, 96.0, 108.0, 120.0, 144.0]   # SteamVR's per-app choices on the Frame
const VRCMD := "/opt/steamvr/bin/linuxarm64/vrcmd"
const VRSETTINGS := "/.config/openvr/config/steamvr.vrsettings"     # under $HOME
const SETTING := "preferredRefreshRate"
const DEVFREQ := "/sys/class/devfreq"                             # the kernel's clock-scaled devices
const STEAM_HINT := "частота: SteamVR > Video >\nPer-Application Video Settings"
const SCALES := [1.0, 0.9, 0.8, 0.7]
const SETTINGS := "user://settings.cfg"
const STATUS_LINES := 4         # the head text, padded: the buttons below stay put
const BTN_H := 0.06             # m
const BTN_GAP := 0.01
const RATE_W := 0.08
const SCALE_W := 0.12
const BENCH_W := 0.36
const COLOR_BTN := Color(0.17, 0.19, 0.24, 0.96)
const COLOR_ON := Color(0.12, 0.50, 0.22, 0.96)       # in effect
const COLOR_PENDING := Color(0.62, 0.50, 0.08, 0.96)  # chosen, not (yet) in effect
const COLOR_RAY := Color(0.55, 0.85, 1.0, 0.6)
const DIST := 1.3               # m in front of the head
const DROP := 0.45              # m below the eyes
const TURN := deg_to_rad(30.0)  # the head turned this far from the panel: it comes round
const COLOR_OK := Color(0.05, 0.33, 0.12, 0.92)
const COLOR_BAD := Color(0.45, 0.06, 0.05, 0.92)
const COLOR_WAIT := Color(0.05, 0.06, 0.09, 0.9)

var target: Viewport            # the viewport the scene is rendered into
var viewer: Node                # main: where the feet are (foot_l, space.L), for the log
var head: Node3D                # the XR camera, a sibling in the play space; null: stay put
var yaw := 0.0                  # the panel's bearing from the head
var turning := false
var placed := false
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
var desired := 0.0              # the rate last chosen; written after the one being written, if it differs
var requested := 0.0            # a rate the display has not followed yet
var request_from := 0.0
var request_age := 0.0
var note := ""                  # what came of the last press
var note_failed := false
var note_left := 0
var logged := 0
var late_lines := 0             # late frames logged this second
var devfreq := DEVFREQ
var gpu_clock := ""             # the GPU's devfreq directory, if the kernel shows one
var clock_min := 0              # MHz, over the log window
var clock_max := 0
var render_scale := 1.0         # 3D render scale of the XR viewport
var plate: MeshInstance3D
var plate_mat: StandardMaterial3D
var buttons: Array = []         # {kind "rate" / "scale", value, rect (panel x, y), mat, label}
var rate_options: Array = []
var titles: Array = []          # Label3D: the rows' titles and the hint under them
var bench_text := "замер скорости"
var bench_title: Label3D
var plate_rect := Rect2()
var hover := [-1, -1]           # per hand (left, right): the button its ray is on, -1 none
var on_plate := [false, false]  # per hand: its ray is on the panel
var trigger_down := [false, false]
var rays: Array = []            # per hand: the ray drawn from the controller


func _ready() -> void:
	no_depth_test = true
	render_priority = 22
	pixel_size = 0.001
	font_size = 40
	outline_size = 0
	modulate = Color(1.0, 0.97, 0.88)
	horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vertical_alignment = VERTICAL_ALIGNMENT_TOP
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
	for i in 2:
		var ray := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.004, 0.004, 1.0)
		ray.mesh = box
		ray.material_override = _flat(COLOR_RAY, 23)
		ray.top_level = true
		ray.visible = false
		add_child(ray)
		rays.append(ray)
	RenderingServer.viewport_set_measure_render_time(target.get_viewport_rid(), true)
	if xr:
		api = OpenXRAPIExtension.new()
		# a method, not a lambda: a lambda left connected to the interface corrupted memory at exit
		xr.refresh_rate_changed.connect(_on_runtime_rate)
		_find_gpu_clock()
		var cfg := ConfigFile.new()
		cfg.load(SETTINGS)
		_set_scale(float(cfg.get_value("render", "scale", 1.0)))
		find_app_setting()
	_set_text("...")


func _flat(c: Color, priority: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	m.render_priority = priority
	return m


func _text(t: String, size: int, pos: Vector3) -> Label3D:
	var l := Label3D.new()
	l.text = t
	l.font_size = size
	l.pixel_size = pixel_size
	l.outline_size = 0
	l.no_depth_test = true
	l.render_priority = 22
	l.modulate = modulate
	l.position = pos
	add_child(l)
	return l


## The rate choices: SteamVR's per-app ones on the Frame, else what the runtime offers.
func _rate_options() -> Array:
	if steam_key != "":
		return FRAME_RATES
	if xr == null:
		return []
	var offered: Array = xr.get_available_display_refresh_rates()
	offered.sort()
	return offered


## The menu below the head text: titles, button rows, a hint; and the plate under all of it.
## Built again when the rate choices change.
func _layout() -> void:
	for b in buttons:
		b.mesh.queue_free()
		b.label.queue_free()
	for l in titles:
		l.queue_free()
	buttons.clear()
	titles.clear()
	rate_options = _rate_options()
	var f: Font = font if font else ThemeDB.fallback_font
	var line := f.get_height(font_size) * pixel_size
	var y := -STATUS_LINES * line - 0.02
	var rows := [["частота, Гц", "rate", rate_options, RATE_W], ["разрешение", "scale", SCALES, SCALE_W]]
	if viewer and viewer.get("bench"):
		rows.append([bench_text, "bench", [0.0], BENCH_W])
	var width := 0.0
	for row in rows:
		titles.append(_text(row[0], 30, Vector3(0.0, y - 0.015, 0.0)))
		if row[1] == "bench":
			bench_title = titles.back()
		y -= 0.045
		var n: int = row[2].size()
		var w: float = row[3]
		var row_w := n * w + (n - 1) * BTN_GAP
		width = maxf(width, row_w)
		for i in n:
			var v: float = row[2][i]
			var x := -0.5 * row_w + 0.5 * w + i * (w + BTN_GAP)
			var mesh := MeshInstance3D.new()
			var q := QuadMesh.new()
			q.size = Vector2(w, BTN_H)
			mesh.mesh = q
			var mat := _flat(COLOR_BTN, 21)
			mesh.material_override = mat
			mesh.position = Vector3(x, y - 0.5 * BTN_H, -0.002)
			add_child(mesh)
			var t := "%.0f" % v if row[1] == "rate" else "%d%%" % roundi(v * 100.0)
			if row[1] == "bench":
				t = "сравнить с прежним" if viewer.bench.has_ab() else "замерить"
			var label := _text(t, 32, Vector3(x, y - 0.5 * BTN_H, 0.0))
			buttons.append({"kind": row[1], "value": v, "mat": mat, "mesh": mesh, "label": label,
					"rect": Rect2(x - 0.5 * w, y - BTN_H, w, BTN_H)})
		y -= BTN_H + 0.02
	titles.append(_text("наведи контроллер на кнопку и нажми курок", 26, Vector3(0.0, y - 0.01, 0.0)))
	y -= 0.04
	width = maxf(width, 0.66) + 0.06
	plate_rect = Rect2(-0.5 * width, y - 0.01, width, -y + 0.03)
	(plate.mesh as QuadMesh).size = plate_rect.size
	plate.position = Vector3(plate_rect.get_center().x, plate_rect.get_center().y, -0.005)


## Colour the buttons: in effect, chosen and pending, under a ray.
func _paint() -> void:
	for i in buttons.size():
		var b: Dictionary = buttons[i]
		var c := COLOR_BTN
		if b.kind == "rate":
			var chosen := requested if requested > 0.0 else (desired if writing else stored)
			if rate > 0.0 and absf(b.value - rate) < 0.5:
				c = COLOR_ON
			elif chosen > 0.0 and absf(b.value - chosen) < 0.5:
				c = COLOR_PENDING
		elif b.kind == "bench":
			if viewer.bench.running:
				c = COLOR_PENDING
		elif is_equal_approx(b.value, render_scale):
			c = COLOR_ON
		if hover.has(i):
			c = c.lerp(Color(1.0, 1.0, 1.0, c.a), 0.3)
		b.mat.albedo_color = c


## A hand's ray this frame: from, a unit direction (both in the play space, the panel's parent's
## space), and its trigger. Hovers the button the ray is on; a trigger press presses it.
func point(hand: int, from: Vector3, dir: Vector3, trigger: float, tracked := true) -> void:
	var was: int = hover[hand]
	hover[hand] = -1
	on_plate[hand] = false
	var hit := Vector3.ZERO
	if tracked and dir.length() > 0.5:
		var inv := transform.affine_inverse()
		var o := inv * from
		var d := inv.basis * dir
		if d.z < -1e-4 and o.z > 0.0:
			hit = o - d * (o.z / d.z)
			var p := Vector2(hit.x, hit.y)
			on_plate[hand] = plate_rect.grow(0.15).has_point(p)
			for i in buttons.size():
				if buttons[i].rect.has_point(p):
					hover[hand] = i
	var ray: MeshInstance3D = rays[hand]
	ray.visible = on_plate[hand]
	if on_plate[hand]:
		var end := transform * hit
		var len := from.distance_to(end)
		var up := Vector3.UP if absf(dir.y) < 0.95 else Vector3.BACK
		ray.global_transform = get_parent().global_transform * Transform3D(
				Basis.looking_at(dir, up) * Basis.from_scale(Vector3(1.0, 1.0, len)), from + 0.5 * len * dir)
	if trigger_down[hand]:
		trigger_down[hand] = trigger > 0.3
	elif trigger >= 0.7:
		trigger_down[hand] = true
		if hover[hand] >= 0:
			var b: Dictionary = buttons[hover[hand]]
			if b.kind == "rate":
				choose_rate(b.value)
			elif b.kind == "scale":
				choose_scale(b.value)
			else:
				viewer.bench.start()
				_paint()
	if hover[hand] != was:
		_paint()


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
	if not (on_plate[0] or on_plate[1]):
		_follow(delta)
	if api and api.is_running():
		var now := api.get_predicted_display_time()
		# predicted display time of the next frame minus this one's: the period the runtime paces us at
		var period := api.get_next_frame_time() - now
		var missed_before := meter.missed()
		meter.add(now, period, reported)
		# every late frame gets a line: where, and what the GPU and the CPU took for it
		if meter.missed() > missed_before and late_lines < LATE_LINES and not (viewer and viewer.get("bench") and viewer.bench.running):
			late_lines += 1
			var look: Vector2 = viewer.look_angles() if viewer else Vector2.ZERO
			print("refresh: late frame, %d refresh(es) without a new one, feet l %.2f m, looking %.0f deg from the throat, %.0f deg up, gpu %.2f ms, cpu %.2f ms render %.2f ms process"
					% [meter.missed() - missed_before, viewer.foot_l if viewer else 0.0, look.x, look.y,
					RenderingServer.viewport_get_measured_render_time_gpu(target.get_viewport_rid()),
					RenderingServer.viewport_get_measured_render_time_cpu(target.get_viewport_rid()),
					Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0])
		if viewer and viewer.get("bench"):
			viewer.bench.frame_timing(now, period, reported)
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


func _follow(delta: float) -> void:
	if head == null:
		return
	var h := head.transform
	var f := -h.basis.z
	var head_yaw := atan2(-f.x, -f.z) if Vector2(f.x, f.z).length() > 0.2 else yaw
	var d := wrapf(head_yaw - yaw, -PI, PI)
	if not placed:
		yaw = head_yaw
	elif turning or absf(d) > TURN:
		turning = absf(d) > 0.05
		yaw += d * minf(1.0, 5.0 * delta)
	var want := h.origin + Basis(Vector3.UP, yaw) * Vector3(0.0, 0.0, -DIST) + Vector3(0.0, -DROP, 0.0)
	position = want if not placed else position.lerp(want, minf(1.0, 10.0 * delta))
	# text toward the head, tilted up to the eyes
	basis = Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, -atan2(DROP, DIST))
	placed = true


## A rate button.
func choose_rate(r: float) -> void:
	if xr == null:
		return
	note = ""
	desired = r
	requested = r
	request_from = rate
	request_age = 0.0
	if steam_key != "":
		if not writing:
			_write_rate()
	else:
		print("refresh: asking for %.1f Hz (measured %.1f, runtime says %.1f, offers %s)"
				% [r, rate, xr.display_refresh_rate, xr.get_available_display_refresh_rates()])
		xr.display_refresh_rate = r
	_set_text(_compose())


func _write_rate() -> void:
	writing = true
	# Steam preloads its overlay into everything it starts; vrcmd needs none of it, and the
	# loader would only fill the log with complaints
	OS.unset_environment("LD_PRELOAD")
	print("refresh: setting %s.%s to %.0f" % [steam_key, SETTING, desired])
	WorkerThreadPool.add_task(_set_stored.bind(desired))


## A render scale button; kept for the next start.
func choose_scale(v: float) -> void:
	if xr == null:
		return
	_set_scale(v)
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	cfg.set_value("render", "scale", render_scale)
	cfg.save(SETTINGS)
	print("refresh: render scale %.2f" % render_scale)
	_set_text(_compose())


func _set_scale(s: float) -> void:
	render_scale = s if SCALES.has(s) else 1.0
	target.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	target.scaling_3d_scale = render_scale


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


func _stored_set(r: float, code: int, text: String) -> void:
	writing = false
	print("refresh: vrcmd set %.0f: exit %d [%s]" % [r, code, text.strip_edges().replace("\n", " | ")])
	if code == 0:
		stored = r
	elif absf(desired - r) < 0.5:
		requested = 0.0
		_set_note("не получилось задать частоту", true)
	if absf(desired - r) > 0.5:
		_write_rate()       # chosen again meanwhile
	else:
		request_age = 0.0   # the display gets REQUEST_WAIT from now to follow
	_set_text(_compose())


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
	_set_text(_compose())


## The speed check's line, the title of its row.
func bench_status(s: String) -> void:
	bench_text = s
	if bench_title:
		bench_title.text = s
	_paint()


func _set_note(s: String, failed: bool) -> void:
	note = s
	note_failed = failed
	note_left = NOTE_SECONDS
	_set_text(_compose())


func _on_runtime_rate(r: float) -> void:
	print("refresh: runtime event, rate %.1f Hz" % r)


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


func _gpu_mhz() -> int:
	if gpu_clock == "":
		return 0
	return read_line(gpu_clock + "/cur_freq").to_int() / 1_000_000


## The first line of a kernel file. A sysfs file says it holds 4096 bytes whatever it holds, and
## FileAccess.get_file_as_string reads that many: garbage after the value, and the log filled
## with Unicode errors.
static func read_line(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_line().strip_edges() if f else ""


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
	late_lines = 0
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
	var lines := []
	if xr == null:
		lines = ["%.0f кадр/с" % fps, "GPU %.1f мс" % g]
	elif rate <= 0.0:
		lines = ["%.0f кадр/с" % fps, "GPU %.1f мс" % g, "шлем не даёт время кадров"]
	else:
		var ok: Variant = keeps_up(seconds)
		var last: Array = seconds.back() if not seconds.is_empty() else [0, 0]
		lines = [
			"%.0f Гц · %s" % [rate, "меряю..." if ok == null else ("успевает" if ok else "не успевает")],
			"кадров %d из %d · GPU %.1f из %.1f мс" % [last[0], last[1], g, 1000.0 / rate],
		]
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
		elif rate_options.size() < 2 or (note_failed and note != ""):
			lines.append(STEAM_HINT)
	var joined := "\n".join(lines)
	while joined.count("\n") < STATUS_LINES - 1:
		joined += "\n"
	return joined


## The last second, in one line of the log: where the feet are and where the head looks, the
## frames and refreshes, the GPU time, and the panel's verdict over the last few seconds.
func _log() -> void:
	if seconds.is_empty():
		return
	var s: Array = seconds.back()
	var eye := xr.get_render_target_size()
	var where := ""
	if viewer:
		var l: float = viewer.foot_l
		var edge: float = viewer.space.L
		var look: Vector2 = viewer.look_angles()
		where = "feet l %.1f m (%s), looking %.0f deg from the throat, %.0f deg up, " % [l,
				"world A" if l >= edge else ("world B" if l <= -edge else "in the curved zone"), look.x, look.y]
	print("refresh: " + where + "display %.2f Hz, paced %.2f Hz, %d frames of %d refreshes (%d missed) in 1 s, gpu %.2f ms avg %.2f max of %.2f, gpu clock %d..%d MHz, runtime says %.1f of %s, stored %.0f, eye %dx%d at scale %.2f, keeps up %s"
			% [rate, meter.paced_rate(), s[0], s[1], s[1] - s[0], s[2] / s[4] if s[4] > 0 else 0.0, s[3],
			1000.0 / rate if rate > 0.0 else 0.0, clock_min, clock_max, reported,
			xr.get_available_display_refresh_rates(), stored, int(eye.x), int(eye.y), render_scale, keeps_up(seconds)])
	clock_min = 0
	clock_max = 0


func _set_text(s: String) -> void:
	text = s
	if _rate_options() != rate_options or buttons.is_empty():
		_layout()
	if xr and titles.size() > 1:
		titles[1].text = "разрешение · %d точек на глаз" % roundi(xr.get_render_target_size().x * render_scale)
	_paint()
