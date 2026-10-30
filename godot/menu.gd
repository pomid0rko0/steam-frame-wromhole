class_name Menu
extends Node3D
## The menu, drawn by Godot itself, and the line under it.
##
## The menu is worked with buttons (handle_input; which: README.md, «Управление») and follows the
## head loosely (_follow): there at the wormhole and inside it, without being glued to the view.
## Its head is frame_rate.gd's lines on a plate in the colour of its verdict.
##
## A setting is a row: a subclass of Row (the end of this file) in _make_rows; one kept for the
## next start also in SETTINGS: loaded in _ready, written by _save. A value stepped to takes effect
## only after SETTLE (or with A, another row, closing): stepping through the rates must not switch
## the headset at every step, nor the foveations rebuild the buffers.

const SCALES := [1.0, 0.9, 0.8, 0.7]
# names of Foveation.set_level's levels
const FOVEATIONS := ["выкл", "слабая", "средняя", "сильная", "плавная широкая", "плавная узкая"]
const FOV_LOG := ["off", "low", "medium", "high", "wide", "narrow"]
const FOV_CHOICES := [0, 1, 3, 4, 5]     # the levels the menu offers
# until one is chosen: our narrow map, the width first (its border is not seen in the headset)
const DEFAULT_FOVEATION := 5
const DEFAULT_ORDER := 0
const SETTINGS := "user://settings.cfg"
const ORDERS := ["по горизонтали", "по вертикали"]     # Foveation.order 0 and 1
const GRAVITY_NAMES := ["выкл", "пол", "пол и стрелки"]   # Tracer.GRAVITY_VIEWS' names, one each
const TURNS := ["плавный", "рывком %d°"]           # main.smooth_turn true, false (main.SNAP_ANGLE)
const OFF_ON := ["выкл", "вкл"]
const ON_OFF := ["вкл", "выкл"]
const HINT := "крестовина или левый стик: выбрать, менять\nA — нажать · B — закрыть"
const SETTLE := 0.5             # s a value stepped to waits before it takes effect
const REPEAT_AFTER := 0.4       # s a direction is held before it repeats
const REPEAT := 0.12            # s between repeats
const STICK_ON := 0.6           # the left stick as a D-pad: pushed out this far it points
const STICK_OFF := 0.3          # and let go back under this it doesn't
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

var main: Main                  # the settings the rows change
var rate: FrameRate
var target: Viewport            # the viewport the scene is rendered into (its render scale)
var xr: OpenXRInterface         # null without OpenXR (the desktop, the tests' fake headsets)
var head: Node3D                # the XR camera, a sibling in the play space
var yaw := 0.0                  # the menu's bearing from the head
var turning := false
var placed := false
var render_scale := 1.0         # 3D render scale of the XR viewport chosen (the speed check sets 100% meanwhile)
var foveation := 0              # the foveation level chosen (the speed check sets others meanwhile)
var text := ""                  # the head's lines
var open := false               # the menu is shown
var strip_on := true            # the line below is shown while the menu is closed
var cursor := 0                 # the row picked
var pending := -1               # the picked row's value stepped to, not yet in effect; -1 none
var pending_t := 0.0
var rows: Array[Row] = []       # those shown, top to bottom
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
	assert(GRAVITY_NAMES.size() == Tracer.GRAVITY_VIEWS.size(), "a name for each gravity view")
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

## Each frame, before anything else reads the controllers: opens, works and closes the menu with
## its buttons (README.md, «Управление»; held, a direction repeats). True if the menu was open at
## any point of this frame: then its buttons and the left stick do nothing else (main.gd's rules for
## a new button).
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


## The direction held: the D-pad or arrow keys, else the left stick as a D-pad (pushed out past
## STICK_ON, let go under STICK_OFF, its main axis the direction); y down is +1 (the next row).
func _direction(left: XRController3D) -> Vector2i:
	var d := Vector2i(int(Input.is_key_pressed(KEY_RIGHT)) - int(Input.is_key_pressed(KEY_LEFT)),
			int(Input.is_key_pressed(KEY_DOWN)) - int(Input.is_key_pressed(KEY_UP)))
	if left:
		d += Vector2i(int(left.is_button_pressed(&"dpad_right")) - int(left.is_button_pressed(&"dpad_left")),
				int(left.is_button_pressed(&"dpad_down")) - int(left.is_button_pressed(&"dpad_up")))
		var s := left.get_vector2(&"primary")
		if s.length() > STICK_ON:
			stick_dir = Vector2i(0, -int(signf(s.y))) if absf(s.y) >= absf(s.x) else Vector2i(int(signf(s.x)), 0)
		elif s.length() < STICK_OFF:
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

func toggle() -> void:
	set_open(not open)


## Closing puts a value stepped to into effect.
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
	var r := rows[cursor]
	if not r.enabled():
		return
	var from := pending if pending >= 0 else r.current()
	var to := clampi(from + step, 0, r.count() - 1)
	if to == from:
		return
	pending = -1 if to == r.current() else to
	pending_t = 0.0
	refresh()


## A: the picked row's action (Row.act), or the value stepped to in effect now, or else the next
## value at once (Row.steps_on_a; round at the end: a switch goes on and off).
func press() -> void:
	if not open or rows.is_empty():
		return
	var r := rows[cursor]
	if not r.enabled() or r.act():
		return
	if pending < 0 and r.steps_on_a():
		pending = posmod(r.current() + 1, r.count())
	_apply_pending()


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
	var r := rows[cursor]
	var i := pending
	pending = -1
	if r.enabled():
		r.apply(i)
	refresh()


## Built again when the rate choices change.
func _layout() -> void:
	for r in rows:
		r.name_label.queue_free()
		r.value_label.queue_free()
	rows.clear()
	rate_options = rate.options()
	for r in _make_rows():
		if r.shown():
			rows.append(r)
	# the widest name and value make the columns
	var name_w := 0.0
	var val_w := 0.0
	for r in rows:
		name_w = maxf(name_w, _width(r.name_text(), FONT_ROW))
		for i in r.count():
			val_w = maxf(val_w, _width(r.text(i), FONT_ROW))
	val_w = maxf(val_w, _width("100% (8888×8888)", FONT_ROW) if xr else 0.0)
	var arrow_w := ARROW
	menu_w = 2.0 * PAD + name_w + 2.0 * GAP + 2.0 * (arrow_w + GAP) + val_w
	for s: String in [HINT] + FrameRate.widest_lines():
		menu_w = maxf(menu_w, 2.0 * PAD + _width(s, FONT_STATUS))
	name_x = -0.5 * menu_w + PAD
	value_half = 0.5 * val_w
	value_x = 0.5 * menu_w - PAD - arrow_w - GAP - value_half
	arrows[0].position.x = value_x - value_half - GAP - 0.5 * arrow_w
	arrows[1].position.x = value_x + value_half + GAP + 0.5 * arrow_w
	for r in rows:
		r.name_label = _text(menu, r.name_text(), FONT_ROW, HORIZONTAL_ALIGNMENT_LEFT, VERTICAL_ALIGNMENT_CENTER)
		r.value_label = _text(menu, "", FONT_ROW, HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER)
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
		r.name_label.position = Vector3(name_x, r.y, 0.0)
		r.value_label.position = Vector3(value_x, r.y, 0.0)
		y -= ROW_H
	bench_label.position = Vector3(name_x, y - 0.5 * GAP, 0.0)
	y -= bench_h
	hint_label.position = Vector3(name_x, y - GAP, 0.0)
	(cursor_quad.mesh as QuadMesh).size = Vector2(menu_w - GAP, ROW_H * 0.96)
	refresh()


func refresh() -> void:
	if rows.is_empty():
		return
	for i in rows.size():
		var r := rows[i]
		var here := i == cursor and pending >= 0
		r.value_label.text = r.text(pending if here else r.current())
		r.value_label.modulate = COLOR_OFF if not r.enabled() else (COLOR_PENDING if here or r.waiting() else COLOR_TEXT)
		r.name_label.text = r.name_text()
		r.name_label.modulate = COLOR_TEXT if r.enabled() else COLOR_OFF
	var r := rows[cursor]
	cursor_quad.position = Vector3(0.0, r.y, -0.001)
	var at := pending if pending >= 0 else r.current()
	var movable := r.enabled() and r.count() > 1
	for a: MeshInstance3D in arrows:
		a.position.y = r.y
	arrows[0].visible = movable and at > 0
	arrows[1].visible = movable and at < r.count() - 1


func _show() -> void:
	menu.visible = open
	strip.visible = not open and (strip_on or _bench_below())


## The speed check's line goes on the line below: while it runs (and its countdown) and until the
## menu is opened.
func _bench_below() -> bool:
	return bench_text != "" and (bench_unseen or main.bench.running)


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

## A render scale choice; kept for the next start.
func choose_scale(v: float) -> void:
	if xr == null:
		return
	set_render_scale(v)
	_save()
	print("refresh: render scale %.2f, foveation %d" % [render_scale, foveation])
	_set_text(_compose())


## A foveation choice; kept for the next start.
func choose_foveation(level: int) -> void:
	if xr == null:
		return
	_set_foveation(level)
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


## Where the foveation's sharp middle is: where the eyes look (the gaze tracker has a pose), or
## straight ahead.
func foveation_source() -> String:
	if xr == null:
		return ""
	return "по взгляду" if main.gaze and main.gaze.get_has_tracking_data() else "по центру"


## The XR viewport's render scale.
func set_render_scale(s: float) -> void:
	render_scale = s if SCALES.has(s) else 1.0
	target.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	target.scaling_3d_scale = render_scale


# ---------------------------------------------------------------- the text

func bench_status(s: String) -> void:
	bench_text = s
	bench_unseen = not open
	bench_label.text = s
	_show()
	_set_text(text)


## The frame rate's lines or verdict changed.
func _on_rate() -> void:
	if xr:
		var ok: Variant = rate.verdict()
		plate_mat.albedo_color = COLOR_WAIT if ok == null else (COLOR_OK if ok else COLOR_BAD)
		strip_mat.albedo_color = plate_mat.albedo_color
	_set_text(_compose())


func _compose() -> String:
	var joined := "\n".join(rate.status() + rate.notes())
	while joined.count("\n") < STATUS_LINES - 1:
		joined += "\n"
	return joined


func _compose_line() -> String:
	var s := rate.status()
	var first: String = s[0]
	if xr != null and rate.rate > 0.0:
		first += " · " + rate.gpu_budget()
	elif s.size() > 1:
		first += " · " + s[1]
	var lines := [first] + rate.notes()
	if _bench_below():
		lines.append(bench_text)
	return "\n".join(lines)


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


# ---------------------------------------------------------------- the rows

## Every row, top to bottom; _layout leaves out those not shown here.
func _make_rows() -> Array[Row]:
	return [RateRow.new(self, "rate", "частота"), ScaleRow.new(self, "scale", "разрешение"),
			FovRow.new(self, "fov", "фовеация"), OrderRow.new(self, "order", "плавная грубее"),
			GazeRow.new(self, "gaze", "точка взгляда"), GravRow.new(self, "grav", "гравитация"),
			TurnRow.new(self, "turn", "поворот"), StripRow.new(self, "strip", "строка частоты"),
			BenchRow.new(self, "bench", "замер скорости")]


## A setting: its values 0 .. count() - 1, current() the one in effect.
class Row:
	var menu: Menu
	var key: String                 # its name for the tests and the log
	var title: String               # and in the menu
	var name_label: Label3D
	var value_label: Label3D
	var y := 0.0                    # m: its line in the menu

	func _init(p_menu: Menu, p_key: String, p_title: String) -> void:
		menu = p_menu
		key = p_key
		title = p_title

	## It makes sense here (else it is left out).
	func shown() -> bool:
		return true

	func count() -> int:
		return 2

	## -1: none of them.
	func current() -> int:
		return 0

	func apply(_i: int) -> void:
		pass

	func text(_i: int) -> String:
		return ""

	func name_text() -> String:
		return title

	## It can be changed now. While the speed check holds the viewer (main.hold), what it times or
	## reads stays as it is.
	func enabled() -> bool:
		return true

	## Chosen, not (yet) in effect.
	func waiting() -> bool:
		return false

	## A with nothing stepped to sets the next value.
	func steps_on_a() -> bool:
		return count() > 1

	## A's own action instead of a value: true if there is one (done).
	func act() -> bool:
		return false


## The refresh rate (frame_rate.gd).
class RateRow extends Row:
	func shown() -> bool:
		return menu.xr != null

	func count() -> int:
		return menu.rate_options.size()

	## The one chosen, in effect or not yet.
	func current() -> int:
		var chosen := menu.rate.chosen()
		for i in menu.rate_options.size():
			if absf(menu.rate_options[i] - chosen) < 0.5:
				return i
		return -1

	func apply(i: int) -> void:
		menu.rate.choose(menu.rate_options[i])

	func text(i: int) -> String:
		if i < 0:
			return "%.0f Гц" % menu.rate.rate if menu.rate.rate > 0.0 else "—"
		return "%.0f Гц" % menu.rate_options[i]

	func enabled() -> bool:
		return menu.rate_options.size() > 1 and not menu.main.hold

	## The display has not followed the rate chosen.
	func waiting() -> bool:
		var i := current()
		return i >= 0 and menu.rate.rate > 0.0 and absf(menu.rate_options[i] - menu.rate.rate) > 0.5

	## The next rate on A would be a switch of the display nobody asked for.
	func steps_on_a() -> bool:
		return false


## The 3D render scale: fewer pixels to ray trace, a softer picture (Godot upscales bilinearly).
class ScaleRow extends Row:
	func shown() -> bool:
		return menu.xr != null

	func count() -> int:
		return SCALES.size()

	func current() -> int:
		return maxi(SCALES.find(menu.render_scale), 0)

	func apply(i: int) -> void:
		menu.choose_scale(SCALES[i])

	## With the pixels of each eye's picture at that scale.
	func text(i: int) -> String:
		var px := Vector2i((menu.xr.get_render_target_size() * SCALES[i]).round())
		var pct := roundi(SCALES[i] * 100.0)
		return "%d%% (%d×%d)" % [pct, px.x, px.y] if px.x > 0 else "%d%%" % pct

	func enabled() -> bool:
		return not menu.main.hold


## Foveated rendering (foveation.gd).
class FovRow extends Row:
	func shown() -> bool:
		return menu.xr != null

	func count() -> int:
		return FOV_CHOICES.size()

	func current() -> int:
		var i := FOV_CHOICES.size() - 1
		while i > 0 and FOV_CHOICES[i] > menu.foveation:
			i -= 1
		return i

	func apply(i: int) -> void:
		menu.choose_foveation(FOV_CHOICES[i])

	func text(i: int) -> String:
		return FOVEATIONS[FOV_CHOICES[i]]

	func name_text() -> String:
		return title + " · " + menu.foveation_source()

	func enabled() -> bool:
		return not menu.main.hold


## Which way our own maps coarsen first: the width or the height, to compare by eye.
class OrderRow extends Row:
	func shown() -> bool:
		return menu.xr != null

	func current() -> int:
		return menu.main.foveation.order

	func apply(i: int) -> void:
		menu.choose_order(i)

	func text(i: int) -> String:
		return ORDERS[i]

	func enabled() -> bool:
		return not menu.main.hold


## The dot where SteamVR's eye tracking says the eyes look.
class GazeRow extends Row:
	func shown() -> bool:
		return menu.main.gaze_dot != null

	func current() -> int:
		return 1 if menu.main.gaze_dot.visible else 0

	func apply(i: int) -> void:
		menu.show_gaze(i == 1)

	func text(i: int) -> String:
		return OFF_ON[i]


## How gravity is shown (docs/gravity.md).
class GravRow extends Row:
	func count() -> int:
		return Tracer.GRAVITY_VIEWS.size()

	func current() -> int:
		return menu.main.tracer.gravity_view

	func apply(i: int) -> void:
		menu.main.set_gravity_view(i)

	func text(i: int) -> String:
		return GRAVITY_NAMES[i]

	func enabled() -> bool:
		return not menu.main.hold


## Smooth or snap turns.
class TurnRow extends Row:
	func current() -> int:
		return 0 if menu.main.smooth_turn else 1

	func apply(i: int) -> void:
		menu.main.set_smooth_turn(i == 0)

	func text(i: int) -> String:
		return TURNS[i] if i == 0 else TURNS[i] % roundi(rad_to_deg(Main.SNAP_ANGLE))


## The line below the menu.
class StripRow extends Row:
	func current() -> int:
		return 0 if menu.strip_on else 1

	func apply(i: int) -> void:
		menu.set_strip(i == 0)

	func text(i: int) -> String:
		return ON_OFF[i]


## The speed check (bench.gd); its result goes under this row.
class BenchRow extends Row:
	func count() -> int:
		return 1

	func text(_i: int) -> String:
		if menu.main.bench.running:
			return "идёт"
		return "сравнить с другими" if menu.main.bench.has_ab() else "замерить"

	func enabled() -> bool:
		return not menu.main.bench.running and not menu.main.hold

	func act() -> bool:
		menu.main.bench.start()
		menu.set_open(false)        # eyes closed now: the line below says how it goes
		return true
