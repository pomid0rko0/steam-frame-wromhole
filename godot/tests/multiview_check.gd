extends SceneTree
## The in-headset stereo check scene (check_scene.gd) through the simulated headset
## (tests/fake_hmd.gd): mode "app" hides Godot's green overlay, "lens" is "app" with blue where the
## floor's quad draws what comes through the curved zone (floor.gdshaderinc's lens_mark: the app's
## images of the balls and the cube there have no green, tools/compare/check_scene.py leaves them
## out), "floor" shows only its floor lines,
## "domain" fills the area where it may draw floor lines, "balls" shows only its ball grids, "cube"
## only the cube's edges, "both" all of it. Comparing them shows whether green lands exactly on the
## renderer's white lines, red balls and magenta cube.
##   godot --path . -s res://tests/multiview_check.gd -- out_prefix app|floor|domain|balls|cube|both case [plain|gravity|arrows] [fov]
## case 0 and 1: util.gd's headset; 2: as 1, then the head walks and turns in the room for ten
## frames (HEAD_STEP each) before the capture; 3: as 1, then the left stick walks forward and right
## (keys W, D), the right stick snaps right (key E), and after a switch to smooth turns (Tab) turns
## left while walking forward (Q, W; KEYS): the overlay must follow the world; 4: as 1, without
## gravity in flight, then flies up (Space) and forward (W), and in the air snaps right (E), pitches
## down (K) and rolls right (L) about the head, and hovers there (KEYS_4); 5: as 1, flying 1 m up
## with the room's axes
## pitched 20 degrees and rolled 15 (as a flight through the curved zone leaves them). Run with
## --fixed-fps 60, so every mode walks and turns the same.
## plain: without the renderer's balls and cube; only the floor lines can be compared then.
## gravity, arrows: the gravity views "floor" and "floor and field lines" (Renderer.GRAVITY_VIEWS: the
## floor coloured by gravity, also the field lines with their arrows).
## fov: foveated rendering on (the runtime's strongest in even cases: the 3D scene in a render pass
## of its own, the viewport asking for a density map; software Vulkan has none, so what this tests
## is that the split pass draws everything where it was; our own in odd ones: narrow in 1, wide in 3).

const U := preload("res://tests/util.gd")
# the overlay's nodes each mode shows (CheckScene.show_only)
const SHOWN := {"app": [], "lens": [], "floor": ["Grid"], "domain": ["Grid"], "balls": ["Ball"], "cube": ["Cube"],
		"both": ["Grid", "Ball", "Cube"]}
# case 2: the head's step in the room each frame
const HEAD_STEP := Transform3D(Basis(Vector3.UP, deg_to_rad(-3.5)), Vector3(0.04, 0.0, -0.05))
# case 3: [frame, key, down]
const KEYS := [[5, KEY_W, true], [5, KEY_D, true], [15, KEY_W, false], [15, KEY_D, false],
		[16, KEY_E, true], [18, KEY_E, false], [19, KEY_TAB, true], [20, KEY_TAB, false],
		[21, KEY_Q, true], [21, KEY_W, true], [31, KEY_Q, false], [31, KEY_W, false]]
const KEYS_4 := [[5, KEY_SPACE, true], [5, KEY_W, true], [15, KEY_W, false], [16, KEY_E, true], [18, KEY_E, false],
		[19, KEY_K, true], [21, KEY_K, false], [22, KEY_L, true], [24, KEY_L, false], [25, KEY_SPACE, false]]

var main: Main
var hmd
var frames := 0
var mode: String
var case := 0
var plain := false
var gravity := 0
var fov := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	mode = args[1]
	case = int(args[2])
	plain = args.slice(3).has("plain")
	gravity = 1 if args.slice(3).has("gravity") else (2 if args.slice(3).has("arrows") else 0)
	fov = args.slice(3).has("fov")
	hmd = U.headset(mini(case, 1), -25.0)
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "FakeHMD"
	main.show_check = true
	if case == 3 or case == 4:
		main.smooth_turn = false
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 3:
		# then back at the start, turned to the head's yaw: the view should face the throat
		main.place(main.START_POS, main.START_FORWARD)
		main.set_fall(false)
		if case == 5:
			var v: Viewer = main.viewer
			v.take_off()
			v.move(WormholeSpace.combine(v.frame, Vector3(0.0, 1.0, 0.0)))
			v.frame = Viewer.tilt(v.frame, deg_to_rad(20.0), deg_to_rad(15.0), main._head_forward_xz())
			main._update_chart_map()
	if frames == 4:
		main.menu.visible = false        # it follows the head: in every view
		if plain:
			main.renderer.set_objects(PackedVector4Array(), PackedVector4Array())
		if mode == "lens":
			for m in main.renderer.floor_mats:
				m.set_shader_parameter("lens_mark", true)
		if gravity > 0:
			main.set_gravity_view(gravity)
		CheckScene.show_only(main.overlay, SHOWN[mode])
		if mode == "domain":
			main.overlay.get_node("Grid").material_override.set_shader_parameter("solid", true)
	if frames == 6 and fov:
		# after main's first frames, which set each kind of foveation in turn and then the menu's:
		# SteamVR's level in even cases, our own (floor_fov.gd) in odd ones: narrow, the menu's
		# default, in case 1, wide in case 3
		main.foveation.set_level(Foveation.LEVELS if case % 2 == 0 else (Menu.DEFAULT_FOVEATION if case == 1 else 4))
		print("foveation ", main.foveation.level)
	if case == 2 and frames >= 5 and frames < 15:
		hmd.head = HEAD_STEP * hmd.head
	if case == 3 or case == 4:
		for k in KEYS if case == 3 else KEYS_4:
			if k[0] == frames:
				U.key(k[1], k[2])
	if frames == (34 if case == 3 or case == 4 else 24):
		if case >= 4:
			print("flying %s, the feet %.3f m over the floor" % [not main.viewer.standing, main.viewer.height()])
		U.save_eyes(main, OS.get_cmdline_user_args()[0], mode)
		print("saved ", mode)
		U.finish(self, hmd)
		return true
	return false
