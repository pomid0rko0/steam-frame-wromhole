extends SceneTree
## The stencil's split against the whole view in motion, through Godot's real multiview path
## (tests/fake_hmd.gd: two eyes with asymmetric frusta, the head posed by the test) and two
## controllers (trackers with poses and buttons): walking from the start to the shell's edge, round
## its fillet, through the throat into universe B, while the head turns and nods and the hands swing
## a new ball and a new cube, throw them, and pass the demo's cubes set down at the edge. Every few
## frames the world is held (main.hold) and that frame drawn twice, split by the stencil and with
## the toys' ray tracer over the whole view (main.TOYS_WHOLE); the ray tracers colour each pixel
## only by what its ray ends on (WH_KIND_COLOUR, as tests/split_test.gd). Both eyes must match bit
## for bit wherever either shows a toy: a toy that blinks out in play is one the split gave, for a
## frame, to a ray tracer that cannot see it.
##   godot --path . --rendering-method mobile -s res://tests/blink_test.gd [-- quick] [colour]
## (under xvfb-run; quick: a check every 4th time; colour: the pictures as they are, within 3/255
## where a toy is: what the ray tracers make of the same ray must not differ either)

const SIZE := 96
const IPD := 0.064
const FRUSTUM := Vector4(-1.25, 0.95, -1.15, 1.05)     # tan of the left eye's half angles
const HEAD := Vector3(0.0, 1.6, 0.0)
# [feet l, yaw from the throat, seconds, stick forward, what the hands do]; the head turns and
# nods over each, the hands swing
const LEGS := [
	[11.6, 0.0, 3.0, 1.0, "ball"],          # from the start toward the shell, a new ball in the right hand
	[6.0, 10.0, 3.0, 0.6, "throw"],         # into the shell's edge, the ball thrown
	[5.0, 70.0, 4.0, 0.0, "cube"],          # at the edge looking round, a new cube in the left hand
	[4.6, 80.0, 3.0, 0.3, "edge"],          # along the fillet over the demo's cubes set down there
	[3.0, 0.0, 4.0, 1.0, "ball"],           # through the throat with a ball
	[-5.0, 160.0, 3.0, 0.5, "throw"],       # world B at the edge
]
const CHECK_EVERY := 5          # frames between checks (quick: 4 times that)

var hmd
var left: XRControllerTracker
var right: XRControllerTracker
var main: Node3D
var every := CHECK_EVERY
var checks := 0
var bad := 0
var toy_pixels := 0
var pixels := 0
var first := ""
var colour := false


func _initialize() -> void:
	if OS.get_cmdline_user_args().has("quick"):
		every = 4 * CHECK_EVERY
	colour = OS.get_cmdline_user_args().has("colour")
	hmd = preload("res://tests/fake_hmd.gd").new()
	hmd.size = Vector2i(SIZE, SIZE)
	hmd.setup(Transform3D(Basis.IDENTITY, HEAD), IPD, 0.0, FRUSTUM)
	XRServer.add_interface(hmd)
	hmd.initialize()
	XRServer.primary_interface = hmd
	left = _controller(&"left_hand")
	right = _controller(&"right_hand")
	main = load("res://main.tscn").instantiate()
	main.xr_name = "FakeHMD"
	main.throw_toys = false
	root.add_child(main)
	_run()


func _controller(tracker_name: StringName) -> XRControllerTracker:
	var t := XRControllerTracker.new()
	t.name = tracker_name
	t.profile = "/interaction_profiles/khr/generic_controller"
	for b in [&"primary_click", &"ax_button", &"by_button", &"menu_button", &"dpad_down"]:
		t.set_input(b, false)
	t.set_input(&"primary", Vector2.ZERO)
	t.set_input(&"trigger", 0.0)
	t.set_input(&"grip", 0.0)
	XRServer.add_tracker(t)
	return t


func _step(n := 1) -> void:
	for _k in n:
		await process_frame


func _run() -> void:
	await _step(3)
	main.perf.visible = false
	# the demo after the throw and the drop, at rest
	main._throw()
	main._drop()
	for k in 12 * 60:
		main.world.step(1.0 / 60.0, [])
	# the toys' ray tracers colour by what a ray ends on, green by which (the stencil's value)
	for m in [[main.material, main.SHADER_BALLS, 2], [main.near_material, main.SHADER_BALLS_NEAR, 3],
			[main.flat_material, main.SHADER_BALLS_FLAT, 1], [main.plain_material, main.SHADER_PLAIN, 0]]:
		if colour:
			break
		var s := Shader.new()
		s.code = m[1].code.replace("shader_type spatial;", "shader_type spatial;\n#define WH_KIND_COLOUR %.3f" % (0.1 + 0.2 * m[2]))
		m[0].shader = s
	main.warm_frames = main.WARM_FRAMES
	while main.warm_frames > 0:
		await _step()
	var frame := 0
	for leg in LEGS:
		await _leg(leg, frame)
		frame += 1000
	var ok := checks > 0 and bad == 0
	print("blink test: %d checks of both eyes, %d of %d pixels show a toy, %d differ there%s"
			% [checks, toy_pixels, pixels, bad, first])
	print("blink test: ", "ok" if ok else "FAILED")
	XRServer.remove_tracker(left)
	XRServer.remove_tracker(right)
	XRServer.primary_interface = null
	hmd.uninitialize()
	XRServer.remove_interface(hmd)
	quit(0 if ok else 1)


## One leg: the feet placed, then walked by the stick while the head turns and nods and the hands
## swing; every `every` frames a check.
func _leg(leg: Array, seed: int) -> void:
	hmd.head = Transform3D(Basis.IDENTITY, HEAD)
	_hands(0.0, false)
	await _step(2)
	if leg[4] == "edge":
		var sc: Array = PlayScenes.SCENES[5]
		PlayScenes.place(main, sc[5], leg[0], leg[1], 0.0)
	else:
		main.place_on_axis(leg[0], leg[1], 0.0)
	await _step(2)
	var frames := int(leg[2] * 60.0)
	for f in frames:
		var t := float(f) / 60.0
		# the head: yaw sweeping +-50 degrees, nodding +-25, swaying a little; the stick forward
		var yaw := deg_to_rad(50.0 * sin(t * 0.9 + 0.3 * seed))
		var pitch := deg_to_rad(25.0 * sin(t * 1.7))
		var roll := deg_to_rad(8.0 * sin(t * 1.1))
		var sway := Vector3(0.08 * sin(t * 1.3), 0.03 * sin(t * 2.1), 0.06 * sin(t * 0.7))
		hmd.head = Transform3D(Basis.from_euler(Vector3(pitch, yaw, roll)), HEAD + sway)
		left.set_input(&"primary", Vector2(0.0, leg[3]))
		_hands(t, true)
		_act(leg[4], f, frames)
		await _step()
		if f % every == every - 1:
			await _check(leg, t)
	left.set_input(&"primary", Vector2.ZERO)
	for b in [&"by_button", &"ax_button"]:
		right.set_input(b, false)
		left.set_input(b, false)
	right.set_input(&"grip", 0.0)
	left.set_input(&"grip", 0.0)


## The hands in front of the head, swinging in circles of 25 cm (out of reach of each other).
func _hands(t: float, tracked: bool) -> void:
	var h: Transform3D = hmd.head
	var r := h * Vector3(0.25 + 0.15 * cos(t * 3.0), -0.35 + 0.15 * sin(t * 3.0), -0.45 + 0.1 * sin(t * 1.9))
	var l := h * Vector3(-0.25 + 0.12 * sin(t * 2.3), -0.3 + 0.12 * cos(t * 2.3), -0.4 + 0.1 * cos(t * 1.5))
	for p in [[right, r], [left, l]]:
		if tracked:
			p[0].set_pose(&"grip", Transform3D(h.basis, p[1]), Vector3.ZERO, Vector3.ZERO,
					XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		else:
			p[0].invalidate_pose(&"grip")


## What the hands do over a leg: a new ball in the right hand (grip, then B), thrown halfway (the
## grip let go while it swings), a new cube in the left (grip, then X).
func _act(what: String, f: int, frames: int) -> void:
	var hand: XRControllerTracker = left if what == "cube" else right
	var button := &"ax_button" if what == "cube" else &"by_button"
	if what == "edge":
		return
	if f == 2:
		hand.set_input(&"grip", 1.0)
	if f == 4:
		hand.set_input(button, true)
	if f == 6:
		hand.set_input(button, false)
	if what == "throw" and f == frames / 2:
		hand.set_input(&"grip", 0.0)


## Held, the same frame split and over the whole view; both eyes compared.
func _check(leg: Array, t: float) -> void:
	main.hold = true
	main.set_toy_mode(main.TOYS_SPLIT)
	await _step(3)
	var split := [_eye(0), _eye(1)]
	main.set_toy_mode(main.TOYS_WHOLE)
	await _step(3)
	var whole := [_eye(0), _eye(1)]
	main.set_toy_mode(main.TOYS_SPLIT)
	main.hold = false
	checks += 1
	for e in 2:
		_compare(split[e], whole[e], "leg from l %.1f, %.2f s, %s eye" % [leg[0], t, ["left", "right"][e]])


func _eye(layer: int) -> Image:
	var img: Image = RenderingServer.texture_2d_layer_get(main.xr_view.get_texture().get_rid(), layer)
	img.convert(Image.FORMAT_RGB8)
	return img


func _compare(a: Image, b: Image, where: String) -> void:
	for y in a.get_height():
		for x in a.get_width():
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			pixels += 1
			if colour:
				var dc := maxf(maxf(absf(ca.r - cb.r), absf(ca.g - cb.g)), absf(ca.b - cb.b))
				if dc > 3.5 / 255.0:
					bad += 1
					if first == "":
						first = "; the first: %s, pixel (%d, %d), split %s, whole %s" % [where, x, y, ca, cb]
						if OS.get_cmdline_user_args().has("save"):
							a.save_png("user://blink_split.png")
							b.save_png("user://blink_whole.png")
				continue
			# a toy's kind is 100 or more (sRGB above 0.6); the others' at most 5 (below 0.2)
			var toy := ca.r > 0.4 or cb.r > 0.4
			if cb.r > 0.4:
				toy_pixels += 1
			if toy and (not is_equal_approx(ca.r, cb.r) or not is_equal_approx(ca.b, cb.b)):
				bad += 1
				if first == "":
					first = "; the first: %s, pixel (%d, %d), split %s, whole %s" % [where, x, y, _kind(ca), _kind(cb)]


static func _kind(c: Color) -> String:
	var lin := c.srgb_to_linear()
	return "kind %d by ray tracer %d" % [roundi(lin.r * 255.0), roundi((lin.g - 0.1) / 0.2)]
