extends Node3D
## The menu, drawn by Godot itself, and the line under it. The menu is hidden until the menu
## button opens it (main._menu_input: Menu on the right controller, View on the left, or a click
## of the left stick; M on the desktop) and is worked with buttons, nothing pointed at: the D-pad
## (or the left stick) up and down picks a row, left and right change its value, A presses, B
## closes. It opens 1.1 m in front of where the head looks, a little below the eyes, and follows:
## as the head walks, at once; as it turns, only once it has turned well away, then smoothly. So
## it is there at the wormhole and inside it, without being glued to the view.
##
## Its head: the refresh rate the headset really runs at, measured from OpenXR's frame timing
## (rate_meter.gd) rather than taken from what the runtime reports, whether frames keep up, the
## frames we delivered of the refreshes in the last second, and the GPU time per frame against the
## time one frame may take; on a plate green while the display gets a new frame from us at
## (nearly) every refresh, red when it does not, grey while it is measuring.
##
## Its rows: the refresh rate, the 3D render scale, foveated rendering (main.set_foveation: off,
## SteamVR's density map low or high, our own softer ones wide or narrow), which way our maps
## coarsen first (main.set_own_order: the width or the height, to compare by eye), the gaze dot
## where SteamVR's eye tracking says the eyes look (main.gaze_dot), how gravity is shown
## (main.set_gravity_view: off, the floor coloured by it, also arrows of its field), smooth or
## snap turns (main.set_smooth_turn), the line below on or off, and the speed check (bench.gd; its
## result under its row). A value stepped to with left and right takes effect once it has stayed
## SETTLE seconds, or at once with A, on going to another row or on closing: stepping through the
## rates does not switch the headset at every step, nor the foveations rebuild the buffers. A on
## a value that is in effect steps to the next one at once (a switch: on, off). Yellow: chosen, not
## (yet) in effect; grey: nothing to change here now (during the speed check, which sets these).
##
## While the menu is closed, a line low in the view shows the rate, whether frames keep up and the
## GPU time on the same colours, and what came of a choice; also the speed check while it runs and
## its result until the menu is opened. The menu's row "строка частоты" turns it off (kept in
## user://settings.cfg).
##
## The refresh rate. SteamVR on the Steam Frame accepts an app's own request
## (XR_FB_display_refresh_rate) and ignores it, offering a single rate
## (ValveSoftware/SteamVR-for-Linux#1020). What it follows is the app's own SteamVR setting
## steam.app.<SteamAppId>.preferredRefreshRate, which SteamVR's vrcmd sets while SteamVR runs;
## on our Frame (SteamVR 2.18) the running app switches within a second, others report it only
## from the next start. So when the app was started from the Steam library and vrcmd is there,
## choosing a rate sets that (one vrcmd call on a worker thread; a choice made meanwhile is written
## next), the display's own rate tells when it followed, and if it has not a few seconds after
## the write the head asks for a restart. Otherwise the choice asks the runtime directly.
##
## The render scale of the XR viewport (100, 90, 80, 70%; Godot upscales bilinearly to the
## headset's size): fewer pixels to ray trace, a softer picture. Kept in user://settings.cfg,
## as is the foveation (until one is chosen: DEFAULT_FOVEATION). The two don't go together: one of them is chosen, the other goes back to
## 100% / off. (Godot asks for the eye-tracked density map's offsets in the headset's full-size
## pixels, so at a lower scale the sharp spot would sit beside where one looks.)
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
const NOTE_SECONDS := 8         # how long the answer to a choice stays up
const FRAME_RATES := [72.0, 80.0, 90.0, 96.0, 108.0, 120.0, 144.0]   # SteamVR's per-app choices on the Frame
const VRCMD := "/opt/steamvr/bin/linuxarm64/vrcmd"
const VRSETTINGS := "/.config/openvr/config/steamvr.vrsettings"     # under $HOME
const SETTING := "preferredRefreshRate"
const DEVFREQ := "/sys/class/devfreq"                             # the kernel's clock-scaled devices
const STEAM_HINT := "частота: SteamVR > Video >\nPer-Application Video Settings"
const SCALES := [1.0, 0.9, 0.8, 0.7]
# main.set_foveation's levels: 0 off, 1..3 SteamVR's map, 4 and 5 our own (main.OWN_MAPS)
const FOVEATIONS := ["выкл", "SteamVR слабая", "SteamVR средняя", "SteamVR сильная", "плавная широкая", "плавная узкая"]
const FOV_LOG := ["off", "SteamVR low", "SteamVR medium", "SteamVR high", "own wide", "own narrow"]
const FOV_CHOICES := [0, 1, 3, 4, 5]     # the menu's: off, SteamVR low and high, our own wide and narrow
# until one is chosen: our narrow map, the width first (in the headset: no border to see, 144 Hz holds)
const DEFAULT_FOVEATION := 5
const DEFAULT_ORDER := 0
const SETTINGS := "user://settings.cfg"
const ORDERS := ["по горизонтали", "по вертикали"]     # main.set_own_order's 0 and 1
const GRAVITY_VIEWS := ["выкл", "пол", "стрелки"]   # main.set_gravity_view's 0, 1, 2
const TURNS := ["плавный", "рывком 30°"]           # main.smooth_turn true, false
const OFF_ON := ["выкл", "вкл"]
const ON_OFF := ["вкл", "выкл"]
# the rows, top to bottom (those that make no sense here are left out: _layout)
const ROWS := ["rate", "scale", "fov", "order", "gaze", "grav", "turn", "strip", "bench"]
const NAMES := {"rate": "частота", "scale": "разрешение", "fov": "фовеация", "order": "плавная грубее",
	"gaze": "точка взгляда", "grav": "гравитация", "turn": "поворот", "strip": "строка частоты",
	"bench": "замер скорости"}
const HINT := "крестовина или левый стик: выбрать, менять\nA — нажать · B — закрыть"
const SETTLE := 0.5             # s a value stepped to waits before it takes effect
const STATUS_LINES := 4         # the head's lines at least: the rows below stay put
const PIXEL := 0.001            # m per font pixel
const FONT_STATUS := 24
const FONT_ROW := 26
const FONT_SMALL := 19          # the speed check's result, the hint
const FONT_STRIP := 22
const ROW_H := 0.038            # m
const PAD := 0.02
const GAP := 0.012
const ARROW := 0.012            # m: the arrows by the picked row's value
const STRIP_WRAP := 0.6         # m: the line below wraps at this width
const MENU_DIST := 1.1          # m in front of the head
const MENU_DROP := 0.3          # m below the eyes
const STRIP_DIST := 1.3
const STRIP_DROP := 0.55
const TURN := deg_to_rad(30.0)  # the head turned this far from the menu: it comes round
const COLOR_TEXT := Color(1.0, 0.97, 0.88)
const COLOR_PENDING := Color(1.0, 0.8, 0.25)        # chosen, not (yet) in effect
const COLOR_OFF := Color(0.5, 0.5, 0.52)            # nothing to change here now
const COLOR_PANEL := Color(0.05, 0.06, 0.09, 0.97)
const COLOR_CURSOR := Color(0.2, 0.3, 0.48, 0.96)
const COLOR_OK := Color(0.05, 0.33, 0.12, 0.92)
const COLOR_BAD := Color(0.45, 0.06, 0.05, 0.92)
const COLOR_WAIT := Color(0.05, 0.06, 0.09, 0.9)

var target: Viewport            # the viewport the scene is rendered into
var viewer: Node                # main: where the feet are (foot_l, space.L), for the log; its settings
var head: Node3D                # the XR camera, a sibling in the play space; null: stay put
var yaw := 0.0                  # the menu's bearing from the head
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
var cpu_sum := 0                  # main's scripts this second (main.cpu_us): us, summed and the most
var cpu_max := 0
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
var note := ""                  # what came of the last choice
var note_failed := false
var note_left := 0
var logged := 0
var late_lines := 0             # late frames logged this second
var devfreq := DEVFREQ
var gpu_clock := ""             # the GPU's devfreq directory, if the kernel shows one
var clock_min := 0              # MHz, over the log window
var clock_max := 0
var render_scale := 1.0         # 3D render scale of the XR viewport
var foveation := 0              # the foveation level chosen (main.set_foveation)
var text := ""                  # the head's lines
var open := false               # the menu is shown
var strip_on := true            # the line below is shown while the menu is closed
var cursor := 0                 # the row picked
var pending := -1               # the picked row's value stepped to, not yet in effect; -1 none
var pending_t := 0.0
var rows: Array = []            # {key, name: Label3D, value: Label3D, y}
var rate_options: Array = []
var bench_text := ""            # the speed check's line: how it goes, what came out
var bench_unseen := false       # the line below shows it until the menu is opened
var menu: Node3D
var strip: Node3D
var plate: MeshInstance3D       # behind the head's lines, coloured by the verdict
var plate_mat: StandardMaterial3D
var panel: MeshInstance3D       # behind all of the menu
var cursor_quad: MeshInstance3D
var status_label: Label3D
var bench_label: Label3D
var hint_label: Label3D
var arrows: Array = []          # MeshInstance3D: left and right of the picked row's value
var strip_label: Label3D
var strip_plate: MeshInstance3D
var strip_mat: StandardMaterial3D
var menu_w := 0.5               # m
var name_x := 0.0               # the names' left edge, the values' column: centre and half width
var value_x := 0.0
var value_half := 0.0


func _ready() -> void:
	menu = Node3D.new()
	menu.transform = Transform3D(Basis(Vector3.RIGHT, -atan2(MENU_DROP, MENU_DIST)), Vector3(0.0, -MENU_DROP, -MENU_DIST))
	add_child(menu)
	strip = Node3D.new()
	strip.transform = Transform3D(Basis(Vector3.RIGHT, -atan2(STRIP_DROP, STRIP_DIST)), Vector3(0.0, -STRIP_DROP, -STRIP_DIST))
	add_child(strip)
	panel = _quad(menu, _flat(COLOR_PANEL, 19))
	plate_mat = _flat(COLOR_WAIT, 20)
	plate = _quad(menu, plate_mat)
	cursor_quad = _quad(menu, _flat(COLOR_CURSOR, 21))
	status_label = _text(menu, "", FONT_STATUS, HORIZONTAL_ALIGNMENT_LEFT, VERTICAL_ALIGNMENT_TOP)
	bench_label = _text(menu, "", FONT_SMALL, HORIZONTAL_ALIGNMENT_LEFT, VERTICAL_ALIGNMENT_TOP)
	bench_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint_label = _text(menu, HINT, FONT_SMALL, HORIZONTAL_ALIGNMENT_LEFT, VERTICAL_ALIGNMENT_TOP)
	hint_label.modulate = COLOR_OFF.lerp(COLOR_TEXT, 0.5)
	for side in [-1.0, 1.0]:
		arrows.append(_arrow(side))
	strip_mat = _flat(COLOR_WAIT, 20)
	strip_plate = _quad(strip, strip_mat)
	strip_label = _text(strip, "", FONT_STRIP, HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER)
	strip_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	strip_label.width = STRIP_WRAP / PIXEL
	RenderingServer.viewport_set_measure_render_time(target.get_viewport_rid(), true)
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	strip_on = bool(cfg.get_value("ui", "strip", true))
	if xr:
		api = OpenXRAPIExtension.new()
		# a method, not a lambda: a lambda left connected to the interface corrupted memory at exit
		xr.refresh_rate_changed.connect(_on_runtime_rate)
		_find_gpu_clock()
		_set_scale(float(cfg.get_value("render", "scale", 1.0)))
		if viewer:
			viewer.own_order = clampi(int(cfg.get_value("render", "own_order", DEFAULT_ORDER)), 0, 1)
		_set_foveation(int(cfg.get_value("render", "foveation", DEFAULT_FOVEATION)))
		if foveation > 0:
			_set_scale(1.0)
		find_app_setting()
		_log_foveation()
	_set_text("...")
	_show()


func _flat(c: Color, priority: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	m.render_priority = priority
	return m


func _quad(parent: Node3D, mat: StandardMaterial3D) -> MeshInstance3D:
	var q := MeshInstance3D.new()
	q.mesh = QuadMesh.new()
	q.material_override = mat
	parent.add_child(q)
	return q


func _text(parent: Node3D, s: String, size: int, h: HorizontalAlignment, v: VerticalAlignment) -> Label3D:
	var l := Label3D.new()
	l.text = s
	l.font_size = size
	l.pixel_size = PIXEL
	l.outline_size = 0
	l.no_depth_test = true
	l.render_priority = 22
	l.modulate = COLOR_TEXT
	l.horizontal_alignment = h
	l.vertical_alignment = v
	parent.add_child(l)
	return l


## A small triangle pointing left (side -1) or right (+1): the picked row's value can go there.
func _arrow(side: float) -> MeshInstance3D:
	var m := ArrayMesh.new()
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	var s := 0.5 * ARROW
	a[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(side * s, 0.0, 0.0), Vector3(-side * s, 0.7 * ARROW, 0.0),
			Vector3(-side * s, -0.7 * ARROW, 0.0)])
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = _flat(COLOR_TEXT, 22)
	mi.material_override.cull_mode = BaseMaterial3D.CULL_DISABLED
	menu.add_child(mi)
	return mi


static func _font() -> Font:
	return ThemeDB.fallback_font


static func _width(s: String, size: int) -> float:
	var w := 0.0
	for line in s.split("\n"):
		w = maxf(w, _font().get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x * PIXEL)
	return w


static func _line(size: int) -> float:
	return _font().get_height(size) * PIXEL


## The rate choices: SteamVR's per-app ones on the Frame, else what the runtime offers.
func _rate_options() -> Array:
	if steam_key != "":
		return FRAME_RATES
	if xr == null:
		return []
	var offered: Array = xr.get_available_display_refresh_rates()
	offered.sort()
	return offered


# ---------------------------------------------------------------- the menu

## Open or close the menu (the menu button). Closing puts a value stepped to into effect.
func toggle() -> void:
	set_open(not open)


func set_open(on: bool) -> void:
	if on == open:
		return
	if not on:
		_apply_pending()
	open = on
	if open:
		bench_unseen = false    # it is under its row now
		_follow(0.0, true)      # in front of where the head looks now
		refresh()
	_show()
	_update_strip()
	print("menu: %s" % ("open" if open else "closed"))


## The picked row up (step -1) or down (+1), round at the ends. What was stepped to on the row
## left takes effect.
func move(step: int) -> void:
	if not open or rows.is_empty():
		return
	_apply_pending()
	cursor = posmod(cursor + step, rows.size())
	refresh()


## The picked row's value one to the left (step -1) or right (+1); it takes effect SETTLE s later
## (or at once with A, on another row, on closing).
func change(step: int) -> void:
	if not open or rows.is_empty():
		return
	var k: String = rows[cursor].key
	if not _enabled(k):
		return
	var from := pending if pending >= 0 else _current(k)
	var to := clampi(from + step, 0, _count(k) - 1)
	if to == from:
		return
	pending = -1 if to == _current(k) else to
	pending_t = 0.0
	refresh()


## A: the picked row's action (the speed check), or the value stepped to in effect now, or else
## the next value at once (round at the end: a switch goes on and off; not the rate, whose next
## one is a switch of the display nobody asked for).
func press() -> void:
	if not open or rows.is_empty():
		return
	var k: String = rows[cursor].key
	if not _enabled(k):
		return
	if k == "bench":
		viewer.bench.start()
		set_open(false)         # eyes closed now: the line below says how it goes
		return
	if pending < 0 and _count(k) > 1 and k != "rate":
		pending = posmod(_current(k) + 1, _count(k))
	_apply_pending()


## B: close.
func back() -> void:
	set_open(false)


## Pick the row with this key (tests).
func select(key: String) -> bool:
	for i in rows.size():
		if rows[i].key == key:
			_apply_pending()
			cursor = i
			refresh()
			return true
	return false


func picked() -> String:
	return rows[cursor].key if not rows.is_empty() else ""


func _apply_pending() -> void:
	if pending < 0 or rows.is_empty():
		return
	var k: String = rows[cursor].key
	var i := pending
	pending = -1
	if _enabled(k):
		_apply(k, i)
	refresh()


## How many values a row has (the speed check's: one, its action).
func _count(k: String) -> int:
	match k:
		"rate": return rate_options.size()
		"scale": return SCALES.size()
		"fov": return FOV_CHOICES.size()
		"grav": return GRAVITY_VIEWS.size()
		"bench": return 1
	return 2


## The value in effect (the rate: the one chosen, in effect or not yet).
func _current(k: String) -> int:
	match k:
		"rate":
			var chosen := requested if requested > 0.0 else (desired if writing else (stored if stored > 0.0 else rate))
			for i in rate_options.size():
				if absf(rate_options[i] - chosen) < 0.5:
					return i
			return -1
		"scale": return maxi(SCALES.find(render_scale), 0)
		"fov":
			var i := FOV_CHOICES.size() - 1
			while i > 0 and FOV_CHOICES[i] > foveation:
				i -= 1
			return i
		"order": return viewer.own_order
		"gaze": return 1 if viewer.gaze_dot.visible else 0
		"grav": return viewer.gravity_view
		"turn": return 0 if viewer.smooth_turn else 1
		"strip": return 0 if strip_on else 1
	return 0


func _apply(k: String, i: int) -> void:
	match k:
		"rate": choose_rate(rate_options[i])
		"scale": choose_scale(SCALES[i])
		"fov": choose_foveation(FOV_CHOICES[i])
		"order": choose_order(i)
		"gaze": show_gaze(i == 1)
		"grav": choose_gravity(i)
		"turn": viewer.set_smooth_turn(i == 0)
		"strip": set_strip(i == 0)


## Whether the row can be changed now: not what the speed check sets while it runs.
func _enabled(k: String) -> bool:
	var held: bool = viewer != null and viewer.get("hold")
	match k:
		"rate": return xr != null and rate_options.size() > 1 and not held
		"scale", "fov", "order": return xr != null and not held
		"grav": return not held
		"bench": return not viewer.bench.running and not held
	return true


## The row's i-th value in words.
func _value_text(k: String, i: int) -> String:
	if i < 0:
		return "%.0f Гц" % rate if k == "rate" and rate > 0.0 else "—"
	match k:
		"rate": return "%.0f Гц" % rate_options[i]
		"scale":
			var px := roundi(xr.get_render_target_size().x * SCALES[i]) if xr else 0
			return "%d%% (%d точек)" % [roundi(SCALES[i] * 100.0), px] if px > 0 else "%d%%" % roundi(SCALES[i] * 100.0)
		"fov": return FOVEATIONS[FOV_CHOICES[i]]
		"order": return ORDERS[i]
		"gaze": return OFF_ON[i]
		"grav": return GRAVITY_VIEWS[i]
		"turn": return TURNS[i]
		"strip": return ON_OFF[i]
		"bench":
			if viewer.bench.running:
				return "идёт"
			return "сравнить с прежним" if viewer.bench.has_ab() else "замерить"
	return ""


func _name_text(k: String) -> String:
	if k == "fov" and _foveation_source() != "":
		return NAMES[k] + " · " + _foveation_source()
	return NAMES[k]


## A value chosen but not (yet) in effect: the rate the display has not followed.
func _waiting(k: String) -> bool:
	if k == "rate":
		var i := _current(k)
		return i >= 0 and rate > 0.0 and absf(rate_options[i] - rate) > 0.5
	return false


## The rows and their labels. Built again when the rate choices change.
func _layout() -> void:
	for r in rows:
		r.name.queue_free()
		r.value.queue_free()
	rows.clear()
	rate_options = _rate_options()
	var keys := []
	for k: String in ROWS:
		var here := true
		match k:
			"rate", "scale", "fov", "order": here = xr != null
			"gaze": here = viewer != null and viewer.get("gaze_dot") != null
			"grav": here = viewer != null and "gravity_view" in viewer
			"turn": here = viewer != null and "smooth_turn" in viewer
			"bench": here = viewer != null and viewer.get("bench") != null
		if here:
			keys.append(k)
	# the widest name and value make the columns
	var name_w := 0.0
	var val_w := 0.0
	for k: String in keys:
		name_w = maxf(name_w, _width(_name_text(k), FONT_ROW))
		for i in _count(k):
			val_w = maxf(val_w, _width(_value_text(k, i), FONT_ROW))
	val_w = maxf(val_w, _width("100% (8888 точек)", FONT_ROW) if xr else 0.0)
	var arrow_w := ARROW
	menu_w = 2.0 * PAD + name_w + 2.0 * GAP + 2.0 * (arrow_w + GAP) + val_w
	for s: String in [HINT, "кадров 144 из 144 · GPU 13.9 из 13.9 мс", "в SteamVR задано 144 Гц, а шлем на 144",
			"задано 144 Гц: выйди и запусти снова", STEAM_HINT]:
		menu_w = maxf(menu_w, 2.0 * PAD + _width(s, FONT_STATUS))
	name_x = -0.5 * menu_w + PAD
	value_half = 0.5 * val_w
	value_x = 0.5 * menu_w - PAD - arrow_w - GAP - value_half
	arrows[0].position.x = value_x - value_half - GAP - 0.5 * arrow_w
	arrows[1].position.x = value_x + value_half + GAP + 0.5 * arrow_w
	for k: String in keys:
		rows.append({"key": k, "y": 0.0,
				"name": _text(menu, _name_text(k), FONT_ROW, HORIZONTAL_ALIGNMENT_LEFT, VERTICAL_ALIGNMENT_CENTER),
				"value": _text(menu, "", FONT_ROW, HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER)})
	cursor = clampi(cursor, 0, maxi(rows.size() - 1, 0))
	pending = -1
	bench_label.width = (menu_w - 2.0 * PAD) / PIXEL
	_place()


## Where everything in the menu goes, top to bottom: the head's lines on their plate, the rows,
## the speed check's result, the hint. Again when the head or the result grows.
func _place() -> void:
	if rows.is_empty():
		return
	var head_h := maxi(STATUS_LINES, status_label.text.count("\n") + 1) * _line(FONT_STATUS) + 2.0 * GAP
	var bench_h := 0.0
	bench_label.visible = bench_text != ""
	if bench_label.visible:
		bench_h = _font().get_multiline_string_size(bench_text, HORIZONTAL_ALIGNMENT_LEFT,
				bench_label.width, FONT_SMALL).y * PIXEL + GAP
	var hint_h := (HINT.count("\n") + 1) * _line(FONT_SMALL)
	var h := head_h + GAP + rows.size() * ROW_H + bench_h + GAP + hint_h + PAD
	var top := 0.5 * h
	(panel.mesh as QuadMesh).size = Vector2(menu_w, h)
	panel.position = Vector3(0.0, 0.0, -0.003)
	(plate.mesh as QuadMesh).size = Vector2(menu_w, head_h)
	plate.position = Vector3(0.0, top - 0.5 * head_h, -0.002)
	status_label.position = Vector3(name_x, top - GAP, 0.0)
	var y := top - head_h - GAP
	for r in rows:
		r.y = y - 0.5 * ROW_H
		r.name.position = Vector3(name_x, r.y, 0.0)
		r.value.position = Vector3(value_x, r.y, 0.0)
		y -= ROW_H
	bench_label.position = Vector3(name_x, y - 0.5 * GAP, 0.0)
	y -= bench_h
	hint_label.position = Vector3(name_x, y - GAP, 0.0)
	(cursor_quad.mesh as QuadMesh).size = Vector2(menu_w - GAP, ROW_H * 0.96)
	refresh()


## The rows' values and colours, the picked row.
func refresh() -> void:
	if rows.is_empty():
		return
	for i in rows.size():
		var r: Dictionary = rows[i]
		var k: String = r.key
		var here := i == cursor and pending >= 0
		r.value.text = _value_text(k, pending if here else _current(k))
		r.value.modulate = COLOR_OFF if not _enabled(k) else (COLOR_PENDING if here or _waiting(k) else COLOR_TEXT)
		r.name.text = _name_text(k)
		r.name.modulate = COLOR_TEXT if _enabled(k) else COLOR_OFF
	var r: Dictionary = rows[cursor]
	var k: String = r.key
	cursor_quad.position = Vector3(0.0, r.y, -0.001)
	var at := pending if pending >= 0 else _current(k)
	var movable := _enabled(k) and _count(k) > 1
	for a: MeshInstance3D in arrows:
		a.position.y = r.y
	arrows[0].visible = movable and at > 0
	arrows[1].visible = movable and at < _count(k) - 1


func _show() -> void:
	menu.visible = open
	strip.visible = strip_on and not open


## The line below on or off; kept for the next start.
func set_strip(on: bool) -> void:
	strip_on = on
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	cfg.set_value("ui", "strip", strip_on)
	cfg.save(SETTINGS)
	print("menu: the line below %s" % ("on" if on else "off"))
	_show()
	refresh()


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
	_follow(delta)
	if pending >= 0:
		pending_t += delta
		if pending_t >= SETTLE:
			_apply_pending()
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
			print("refresh: late frame, %d refresh(es) without a new one, feet l %.2f m, looking %.0f deg from the throat, %.0f deg up, gpu %.2f ms, cpu %.2f ms render %.2f ms process (the second's most), main's scripts %.2f ms"
					% [meter.missed() - missed_before, viewer.foot_l if viewer else 0.0, look.x, look.y,
					RenderingServer.viewport_get_measured_render_time_gpu(target.get_viewport_rid()),
					RenderingServer.viewport_get_measured_render_time_cpu(target.get_viewport_rid()),
					Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
					viewer.cpu_us / 1000.0 if viewer and viewer.get("cpu_us") != null else 0.0])
		if viewer and viewer.get("bench"):
			viewer.bench.frame_timing(now, period, reported)
	t += delta
	frames += 1
	if viewer and viewer.get("cpu_us") != null:
		cpu_sum += viewer.cpu_us
		cpu_max = maxi(cpu_max, viewer.cpu_us)
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
		cpu_sum = 0
		cpu_max = 0


## The menu and the line hang in the room ahead of the head, turned to its bearing: they follow
## its steps at once, and its turns once it has turned TURN away (or at once: snap).
func _follow(delta: float, snap := false) -> void:
	if head == null:
		return
	var h := head.transform
	var f := -h.basis.z
	var head_yaw := atan2(-f.x, -f.z) if Vector2(f.x, f.z).length() > 0.2 else yaw
	var d := wrapf(head_yaw - yaw, -PI, PI)
	if not placed or snap:
		yaw = head_yaw
		turning = false
	elif turning or absf(d) > TURN:
		turning = absf(d) > 0.05
		yaw += d * minf(1.0, 5.0 * delta)
	position = h.origin if not placed or snap else position.lerp(h.origin, minf(1.0, 10.0 * delta))
	basis = Basis(Vector3.UP, yaw)
	placed = true


## A rate choice.
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


## A render scale choice; kept for the next start. Below 100% the foveation goes off.
func choose_scale(v: float) -> void:
	if xr == null:
		return
	_set_scale(v)
	if render_scale < 1.0 and foveation > 0:
		_set_foveation(0)
	_save_render()
	print("refresh: render scale %.2f, foveation %d" % [render_scale, foveation])
	_set_text(_compose())


## A foveation choice; kept for the next start. On, the render scale goes back to 100%.
func choose_foveation(level: int) -> void:
	if xr == null:
		return
	_set_foveation(level)
	if foveation > 0 and render_scale < 1.0:
		_set_scale(1.0)
	_save_render()
	print("refresh: foveation %d (%s), render scale %.2f" % [foveation, FOV_LOG[foveation], render_scale])
	_set_text(_compose())


## Which way our own maps coarsen first; kept for the next start.
func choose_order(order: int) -> void:
	if xr == null or viewer == null:
		return
	viewer.set_own_order(order)
	_save_render()
	print("refresh: own maps coarsen the %s first, foveation %d (%s)"
			% ["width" if viewer.own_order == 0 else "height", foveation, FOV_LOG[foveation]])
	refresh()


## How gravity is shown (main.set_gravity_view). Not during the speed check, which times what it
## set up.
func choose_gravity(view: int) -> void:
	if viewer == null or viewer.hold:
		return
	viewer.set_gravity_view(view)
	refresh()


## The gaze dot: where SteamVR's eye tracking says the eyes look (main.gaze_dot).
func show_gaze(on: bool) -> void:
	if viewer == null or viewer.gaze_dot == null:
		return
	viewer.gaze_dot.visible = on
	print("refresh: gaze dot %s, gaze %s" % ["on" if on else "off", _gaze_text()])
	refresh()


## Where the eyes look against the head, for the log.
func _gaze_text() -> String:
	var g: Variant = viewer.gaze_angles() if viewer else null
	return "none" if g == null else "%.0f deg right %.0f deg up" % [g.x, g.y]


func _save_render() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	cfg.set_value("render", "scale", render_scale)
	cfg.set_value("render", "foveation", foveation)
	if viewer:
		cfg.set_value("render", "own_order", viewer.own_order)
	cfg.save(SETTINGS)


func _set_foveation(level: int) -> void:
	foveation = clampi(level, 0, FOVEATIONS.size() - 1)
	if viewer:
		viewer.set_foveation(foveation)


## What the runtime offers for foveated rendering, once at the start (Godot's own lines above
## it in the log, with verbose_stdout: "OpenXR: Enabled extension ...", "Vulkan Fragment Density
## Map supported ...").
func _log_foveation() -> void:
	print("refresh: foveation %d at the start; runtime density map (XR_FB_foveation) %s, eye gaze (XR_EXT_eye_gaze_interaction) %s, eye-tracked foveation asked %s, render scale %.2f"
			% [foveation, xr.is_foveation_supported(), xr.is_eye_gaze_interaction_supported(),
			ProjectSettings.get_setting("xr/openxr/foveation_eye_tracked", false), render_scale])


## Where SteamVR's density map is: where the eyes look, the middle, or none (Godot's own then).
func _foveation_source() -> String:
	if xr == null:
		return ""
	if not xr.is_foveation_supported():
		return "без SteamVR"
	return "по взгляду" if xr.is_eye_gaze_interaction_supported() else "по центру"


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


func _stored_set(r: float, code: int, text_out: String) -> void:
	writing = false
	print("refresh: vrcmd set %.0f: exit %d [%s]" % [r, code, text_out.strip_edges().replace("\n", " | ")])
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


## The speed check's line: under its row in the menu, and below while it runs or until the menu
## is opened.
func bench_status(s: String) -> void:
	bench_text = s
	bench_unseen = not open
	bench_label.text = s
	_set_text(text)


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
		seconds.append([meter.frames, meter.refreshes, gpu, gpu_max, frames, cpu_sum, cpu_max])
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
		strip_mat.albedo_color = plate_mat.albedo_color
	_set_text(_compose())
	if gpu_clock != "":
		var mhz := _gpu_mhz()
		clock_min = mhz if clock_min == 0 else mini(clock_min, mhz)
		clock_max = maxi(clock_max, mhz)
	logged += 1
	if xr and logged >= LOG_EVERY:
		logged = 0
		_log()


## The head's first lines: the rate and the verdict, the frames and the GPU time.
func _status() -> Array:
	var fps := frames / t if t > 0.0 else 0.0
	var g := gpu / frames if frames > 0 else 0.0
	if xr == null:
		return ["%.0f кадр/с" % fps, "GPU %.1f мс" % g]
	if rate <= 0.0:
		return ["%.0f кадр/с" % fps, "GPU %.1f мс" % g, "шлем не даёт время кадров"]
	var ok: Variant = keeps_up(seconds)
	var last: Array = seconds.back() if not seconds.is_empty() else [0, 0]
	return ["%.0f Гц · %s" % [rate, "меряю..." if ok == null else ("успевает" if ok else "не успевает")],
			"кадров %d из %d · GPU %.1f из %.1f мс" % [last[0], last[1], g, 1000.0 / rate]]


## What came of a rate choice, and what to do about it.
func _notes() -> Array:
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
	elif rate_options.size() < 2 or (note_failed and note != ""):
		lines.append(STEAM_HINT)
	return lines


## The menu's head, padded to STATUS_LINES lines.
func _compose() -> String:
	var joined := "\n".join(_status() + _notes())
	while joined.count("\n") < STATUS_LINES - 1:
		joined += "\n"
	return joined


## The line below the view: the head in one line, what came of a choice, the speed check.
func _compose_line() -> String:
	var s := _status()
	var first: String = s[0]
	if xr != null and rate > 0.0:
		var g := gpu / frames if frames > 0 else 0.0
		first += " · GPU %.1f из %.1f мс" % [g, 1000.0 / rate]
	elif s.size() > 1:
		first += " · " + s[1]
	var lines := [first] + _notes()
	if bench_text != "" and (bench_unseen or (viewer and viewer.get("bench") and viewer.bench.running)):
		lines.append(bench_text)
	return "\n".join(lines)


## The last second, in one line of the log: where the feet are and where the head looks, the
## frames and refreshes, the GPU time, and the verdict over the last few seconds.
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
	print("refresh: " + where + "display %.2f Hz, paced %.2f Hz, %d frames of %d refreshes (%d missed) in 1 s, gpu %.2f ms avg %.2f max of %.2f, main's scripts %.2f ms avg %.2f max, gpu clock %d..%d MHz, runtime says %.1f of %s, stored %.0f, eye %dx%d at scale %.2f, keeps up %s, foveation %d (own maps %s first), gaze %s, gravity view %d, menu %s"
			% [rate, meter.paced_rate(), s[0], s[1], s[1] - s[0], s[2] / s[4] if s[4] > 0 else 0.0, s[3],
			s[5] / 1000.0 / s[4] if s[4] > 0 else 0.0, s[6] / 1000.0,
			1000.0 / rate if rate > 0.0 else 0.0, clock_min, clock_max, reported,
			xr.get_available_display_refresh_rates(), stored, int(eye.x), int(eye.y), render_scale, keeps_up(seconds), foveation, "width" if viewer and viewer.own_order == 0 else "height", _gaze_text(),
			viewer.gravity_view if viewer else 0, "open" if open else "closed"])
	clock_min = 0
	clock_max = 0


## New head lines: into the menu's head and the line below; the rows again if the rate choices
## changed, the menu's places again if its parts grew or shrank.
func _set_text(s: String) -> void:
	text = s
	var lines_before := status_label.text.count("\n")
	status_label.text = s
	_update_strip()
	if _rate_options() != rate_options or rows.is_empty():
		_layout()
	elif s.count("\n") != lines_before or bench_text != "" or bench_label.visible:
		_place()
	else:
		refresh()


func _update_strip() -> void:
	strip_label.text = _compose_line()
	var size := _font().get_multiline_string_size(strip_label.text, HORIZONTAL_ALIGNMENT_CENTER,
			strip_label.width, FONT_STRIP) * PIXEL
	(strip_plate.mesh as QuadMesh).size = size + Vector2(2.0 * GAP, GAP)
	strip_plate.position = Vector3(0.0, 0.0, -0.002)
