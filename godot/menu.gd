class_name Menu
extends Node3D
## The menu, drawn by Godot itself, and the line under it.
##
## The menu is hidden until its button opens it and is worked with buttons (handle_input; which:
## README.md, «Управление»). It opens 1.1 m in front of where the head looks, a little below the eyes, and
## follows: as the head walks, quickly; as it turns, only once it has turned well away, then
## smoothly. So it is there at the wormhole and inside it, without being glued to the view.
##
## Its head: the refresh rate the headset really runs at and whether frames keep up, the frames of
## the refreshes in the last second and the GPU time against the time one frame may take
## (frame_rate.gd), on a plate green while the display gets a new frame from us at (nearly) every
## refresh, red when it does not, the panel's own colour while it is measuring; under it what came
## of a choice.
##
## A setting is a row: ROWS, NAMES, _count, _current, _apply, _enabled, _value_text. Its rows: the
## refresh rate, the 3D render scale, foveated rendering (off, SteamVR's density map
## low or high, our own softer ones wide or narrow), which way our maps coarsen first (the width or
## the height, to compare by eye), the gaze dot where SteamVR's eye tracking says the eyes look, how
## gravity is shown (off, the floor coloured by it, also arrows of its field), smooth or snap turns,
## the line below on or off, and the speed check (bench.gd; its result under its row). A value
## stepped to with left and right takes effect once it has stayed SETTLE seconds, or at once with
## A, on going to another row or on closing: stepping through the rates does not switch the headset
## at every step, nor the foveations rebuild the buffers. A on a value that is in effect steps to
## the next one at once (a switch: on, off). Yellow: chosen, not (yet) in effect; grey: nothing to
## change here now (during the speed check, which sets these).
##
## While the menu is closed, a line low in the view shows the rate, whether frames keep up and the
## GPU time on the same colours, and what came of a choice; also the speed check while it runs and
## its result until the menu is opened.
##
## The render scale of the XR viewport (100, 90, 80, 70%; Godot upscales bilinearly to the
## headset's size): fewer pixels to ray trace, a softer picture. It and foveation don't go
## together: one of them is chosen, the other goes back to 100% / off (Godot asks for the
## eye-tracked density map's offsets in the headset's full-size pixels, so at a lower scale the
## sharp spot would sit beside where one looks). Both, our maps' order and the line below are kept
## in user://settings.cfg.

const SCALES := [1.0, 0.9, 0.8, 0.7]
# names of Foveation.set_level's levels
const FOVEATIONS := ["выкл", "SteamVR слабая", "SteamVR средняя", "SteamVR сильная", "плавная широкая", "плавная узкая"]
const FOV_LOG := ["off", "SteamVR low", "SteamVR medium", "SteamVR high", "own wide", "own narrow"]
const FOV_CHOICES := [0, 1, 3, 4, 5]     # the menu's: off, SteamVR low and high, our own wide and narrow
# until one is chosen: our narrow map, the width first (its border is not seen in the headset)
const DEFAULT_FOVEATION := 5
const DEFAULT_ORDER := 0
const SETTINGS := "user://settings.cfg"
const ORDERS := ["по горизонтали", "по вертикали"]     # Foveation.order 0 and 1
const GRAVITY_VIEWS := ["выкл", "пол", "стрелки"]   # Tracer.gravity_view 0, 1, 2
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
const REPEAT_AFTER := 0.4       # s a direction is held before it repeats
const REPEAT := 0.12            # s between repeats
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

var main: Node                  # main.gd: the settings the rows change
var rate: FrameRate
var target: Viewport            # the viewport the scene is rendered into (its render scale)
var xr: OpenXRInterface         # null on the desktop
var head: Node3D                # the XR camera, a sibling in the play space
var yaw := 0.0                  # the menu's bearing from the head
var turning := false
var placed := false
var render_scale := 1.0         # 3D render scale of the XR viewport
var foveation := 0              # the foveation level chosen (the speed check sets others meanwhile)
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
var was := {}                   # buttons down last frame (handle_input)
var dir_held := Vector2i.ZERO   # the direction held (_direction)
var held_for := 0.0             # s it has been held: then it repeats
var armed := true               # a direction let go once since the menu opened (a stick out to walk does not act)
var stick_dir := Vector2i.ZERO  # the left stick as a D-pad, with hysteresis
var menu: Node3D
var strip: Node3D
var plate: MeshInstance3D       # behind the head's lines, coloured by the verdict
var plate_mat: StandardMaterial3D
var back_quad: MeshInstance3D    # behind all of the menu
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
	back_quad = _quad(menu, _flat(COLOR_PANEL, 19))
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
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	strip_on = bool(cfg.get_value("ui", "strip", true))
	if xr:
		set_render_scale(float(cfg.get_value("render", "scale", 1.0)))
		main.foveation.set_order(int(cfg.get_value("render", "own_order", DEFAULT_ORDER)))
		_set_foveation(int(cfg.get_value("render", "foveation", DEFAULT_FOVEATION)))
		if foveation > 0:
			set_render_scale(1.0)
		print("refresh: foveation %d at the start; runtime density map (XR_FB_foveation) %s, eye gaze (XR_EXT_eye_gaze_interaction) %s, eye-tracked foveation asked %s, render scale %.2f"
				% [foveation, xr.is_foveation_supported(), xr.is_eye_gaze_interaction_supported(),
				ProjectSettings.get_setting("xr/openxr/foveation_eye_tracked", false), render_scale])
	rate.changed.connect(_on_rate)
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
## (The default font has no arrows.)
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


# ---------------------------------------------------------------- the buttons

## Each frame, before anything else reads the controllers. Menu on the right controller or View on
## the left (the Steam Frame's own profile; Touch: the left menu button), or a click of the left
## stick (every profile: the KHR generic one has no menu button), M on the desktop, opens and
## closes the menu. While it is open: the D-pad or the left stick (arrow keys) up and down picks a
## row, left and right change its value, held they repeat; A (Enter) presses, B (Backspace)
## closes. True if the menu was open at any point of this frame: then those buttons and the left
## stick do nothing else (a B that closes it makes no ball).
func handle_input(dt: float) -> bool:
	var was_open := open
	var left: XRController3D = main.left_hand
	var right: XRController3D = main.right_hand
	var toggle_down := Input.is_key_pressed(KEY_M)
	var a := Input.is_key_pressed(KEY_ENTER)
	var b := Input.is_key_pressed(KEY_BACKSPACE)
	if left:
		toggle_down = toggle_down or left.is_button_pressed(&"menu_button") or right.is_button_pressed(&"menu_button") \
				or left.is_button_pressed(&"primary_click")
		a = a or right.is_button_pressed(&"ax_button")
		b = b or right.is_button_pressed(&"by_button")
	var dir := _direction(left)
	if _pressed("menu", toggle_down):
		toggle()
		armed = false           # what is held now (the stick out to walk) waits to be let go
	var pressed_a := _pressed("a", a)
	var pressed_b := _pressed("b", b)
	if open and was_open:
		if not armed:
			armed = dir == Vector2i.ZERO
		elif dir != Vector2i.ZERO:
			var fire := dir != dir_held
			held_for = 0.0 if fire else held_for + dt
			if held_for >= REPEAT_AFTER:
				held_for -= REPEAT
				fire = true
			if fire:
				if dir.y != 0:
					move(dir.y)
				else:
					change(dir.x)
				_tick(left)
		if pressed_a:
			press()
			_tick(right)
		elif pressed_b:
			back()
			_tick(right)
	dir_held = dir
	return was_open or open


func _pressed(key: String, down: bool) -> bool:
	var before: bool = was.get(key, false)
	was[key] = down
	return down and not before


## The direction held: the D-pad or arrow keys, else the left stick as a D-pad (pushed out past 0.6,
## let go under 0.3, its main axis the direction); y down is +1 (the next row).
func _direction(left: XRController3D) -> Vector2i:
	var d := Vector2i(int(Input.is_key_pressed(KEY_RIGHT)) - int(Input.is_key_pressed(KEY_LEFT)),
			int(Input.is_key_pressed(KEY_DOWN)) - int(Input.is_key_pressed(KEY_UP)))
	if left:
		d += Vector2i(int(left.is_button_pressed(&"dpad_right")) - int(left.is_button_pressed(&"dpad_left")),
				int(left.is_button_pressed(&"dpad_down")) - int(left.is_button_pressed(&"dpad_up")))
		var s := left.get_vector2(&"primary")
		if s.length() > 0.6:
			stick_dir = Vector2i(0, -int(signf(s.y))) if absf(s.y) >= absf(s.x) else Vector2i(int(signf(s.x)), 0)
		elif s.length() < 0.3:
			stick_dir = Vector2i.ZERO
		if d == Vector2i.ZERO:
			d = stick_dir
	d = d.clamp(Vector2i(-1, -1), Vector2i(1, 1))
	return Vector2i(0, d.y) if d.y != 0 else d


## A light tick in the hand that pressed something.
static func _tick(hand: XRController3D) -> void:
	if hand:
		hand.trigger_haptic_pulse(&"haptic", 0.0, 0.25, 0.015, 0.0)


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
		main.bench.start()
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
			var chosen := rate.chosen()
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
		"order": return main.foveation.order
		"gaze": return 1 if main.gaze_dot.visible else 0
		"grav": return main.tracer.gravity_view
		"turn": return 0 if main.smooth_turn else 1
		"strip": return 0 if strip_on else 1
	return 0


func _apply(k: String, i: int) -> void:
	match k:
		"rate": rate.choose(rate_options[i])
		"scale": choose_scale(SCALES[i])
		"fov": choose_foveation(FOV_CHOICES[i])
		"order": choose_order(i)
		"gaze": show_gaze(i == 1)
		"grav": main.set_gravity_view(i)
		"turn": main.set_smooth_turn(i == 0)
		"strip": set_strip(i == 0)


## Whether the row can be changed now: not what the speed check sets while it runs.
func _enabled(k: String) -> bool:
	var held: bool = main.hold
	match k:
		"rate": return xr != null and rate_options.size() > 1 and not held
		"scale", "fov", "order": return xr != null and not held
		"grav": return not held
		"bench": return not main.bench.running and not held
	return true


## The row's i-th value in words.
func _value_text(k: String, i: int) -> String:
	if i < 0:
		return "%.0f Гц" % rate.rate if k == "rate" and rate.rate > 0.0 else "—"
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
			if main.bench.running:
				return "идёт"
			return "сравнить с другими" if main.bench.has_ab() else "замерить"
	return ""


func _name_text(k: String) -> String:
	if k == "fov" and _foveation_source() != "":
		return NAMES[k] + " · " + _foveation_source()
	return NAMES[k]


## A value chosen but not (yet) in effect: the rate the display has not followed.
func _waiting(k: String) -> bool:
	if k == "rate":
		var i := _current(k)
		return i >= 0 and rate.rate > 0.0 and absf(rate_options[i] - rate.rate) > 0.5
	return false


## The rows and their labels. Built again when the rate choices change.
func _layout() -> void:
	for r in rows:
		r.name.queue_free()
		r.value.queue_free()
	rows.clear()
	rate_options = rate.options()
	var keys := []
	for k: String in ROWS:
		var here := true
		match k:
			"rate", "scale", "fov", "order": here = xr != null
			"gaze": here = main.gaze_dot != null
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
			"задано 144 Гц: выйди и запусти снова", FrameRate.STEAM_HINT]:
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
	(back_quad.mesh as QuadMesh).size = Vector2(menu_w, h)
	back_quad.position = Vector3(0.0, 0.0, -0.003)
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


func _process(delta: float) -> void:
	_follow(delta)
	if pending >= 0:
		pending_t += delta
		if pending_t >= SETTLE:
			_apply_pending()


## The menu and the line hang in the room ahead of the head, turned to its bearing: they follow
## its steps quickly, and its turns once it has turned TURN away (or at once: snap).
func _follow(delta: float, snap := false) -> void:
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


# ---------------------------------------------------------------- the settings

## A render scale choice; kept for the next start. Below 100% the foveation goes off.
func choose_scale(v: float) -> void:
	if xr == null:
		return
	set_render_scale(v)
	if render_scale < 1.0 and foveation > 0:
		_set_foveation(0)
	_save()
	print("refresh: render scale %.2f, foveation %d" % [render_scale, foveation])
	_set_text(_compose())


## A foveation choice; kept for the next start. On, the render scale goes back to 100%.
func choose_foveation(level: int) -> void:
	if xr == null:
		return
	_set_foveation(level)
	if foveation > 0 and render_scale < 1.0:
		set_render_scale(1.0)
	_save()
	print("refresh: foveation %d (%s), render scale %.2f" % [foveation, FOV_LOG[foveation], render_scale])
	_set_text(_compose())


## Which way our own maps coarsen first; kept for the next start.
func choose_order(order: int) -> void:
	if xr == null:
		return
	main.foveation.set_order(order)
	_save()
	print("refresh: own maps coarsen the %s first, foveation %d (%s)"
			% ["width" if main.foveation.order == 0 else "height", foveation, FOV_LOG[foveation]])
	refresh()


## The gaze dot: where SteamVR's eye tracking says the eyes look (main.gaze_dot).
func show_gaze(on: bool) -> void:
	if main.gaze_dot == null:
		return
	main.gaze_dot.visible = on
	print("refresh: gaze dot %s, gaze %s" % ["on" if on else "off", main.gaze_text()])
	refresh()


## The line below on or off; kept for the next start.
func set_strip(on: bool) -> void:
	strip_on = on
	_save()
	print("menu: the line below %s" % ("on" if on else "off"))
	_show()
	refresh()


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	cfg.set_value("ui", "strip", strip_on)
	if xr:
		cfg.set_value("render", "scale", render_scale)
		cfg.set_value("render", "foveation", foveation)
		cfg.set_value("render", "own_order", main.foveation.order)
	cfg.save(SETTINGS)


func _set_foveation(level: int) -> void:
	foveation = clampi(level, 0, FOVEATIONS.size() - 1)
	main.foveation.set_level(foveation)


## Where SteamVR's density map is: where the eyes look, the middle, or none (Godot's own then).
func _foveation_source() -> String:
	if xr == null:
		return ""
	if not xr.is_foveation_supported():
		return "без SteamVR"
	return "по взгляду" if xr.is_eye_gaze_interaction_supported() else "по центру"


## The XR viewport's render scale.
func set_render_scale(s: float) -> void:
	render_scale = s if SCALES.has(s) else 1.0
	target.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	target.scaling_3d_scale = render_scale


# ---------------------------------------------------------------- the text

## The speed check's line: under its row in the menu, and below while it runs or until the menu
## is opened.
func bench_status(s: String) -> void:
	bench_text = s
	bench_unseen = not open
	bench_label.text = s
	_set_text(text)


## The frame rate's lines or verdict changed.
func _on_rate() -> void:
	if xr:
		var ok: Variant = rate.verdict()
		plate_mat.albedo_color = COLOR_WAIT if ok == null else (COLOR_OK if ok else COLOR_BAD)
		strip_mat.albedo_color = plate_mat.albedo_color
	_set_text(_compose())


## The menu's head, padded to STATUS_LINES lines.
func _compose() -> String:
	var joined := "\n".join(rate.status() + rate.notes())
	while joined.count("\n") < STATUS_LINES - 1:
		joined += "\n"
	return joined


## The line below the view: the head in one line, what came of a choice, the speed check.
func _compose_line() -> String:
	var s := rate.status()
	var first: String = s[0]
	if xr != null and rate.rate > 0.0:
		first += " · " + rate.gpu_budget()
	elif s.size() > 1:
		first += " · " + s[1]
	var lines := [first] + rate.notes()
	if bench_text != "" and (bench_unseen or main.bench.running):
		lines.append(bench_text)
	return "\n".join(lines)


## New head lines: into the menu's head and the line below; the rows again if the rate choices
## changed, the menu's places again if its parts grew or shrank.
func _set_text(s: String) -> void:
	text = s
	var lines_before := status_label.text.count("\n")
	status_label.text = s
	_update_strip()
	if rate.options() != rate_options or rows.is_empty():
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
