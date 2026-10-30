extends SceneTree
## The in-headset stereo check scene (check_scene.gd) through the simulated headset
## (tests/fake_hmd.gd): mode "ray" hides Godot's green overlay, "floor" shows only its floor lines,
## "domain" fills the area where it may draw floor lines, "balls" shows only its ball grids, "cube"
## only the cube's edges, "both" all of it. Comparing them shows whether green lands exactly on the
## ray-traced white lines, red balls and magenta cube.
##   godot --path . -s res://tests/multiview_check.gd -- out_prefix ray|floor|domain|balls|cube|both case [plain|gravity|arrows] [fov]
## case 0 and 1: util.gd's headset; 2: as 1, then the head walks and turns in the room for ten
## frames (HEAD_STEP each) before the capture; 3: as 1, then the left stick walks forward and right
## (keys W, D), the right stick snaps right (key E), and after a switch to smooth turns (Tab) turns
## left while walking forward (Q, W; KEYS): the overlay must follow the world. Run with
## --fixed-fps 60, so every mode walks and turns the same.
## plain: without the ray-traced balls and cube, i.e. with the shader the normal scene uses where
## no toy can be seen (no toys' code); only the floor lines can be compared then. gravity, arrows:
## the gravity views "floor" and "floor and arrows" (Tracer.GRAVITY_VIEWS: the floor coloured by
## gravity, also the field's arrows), their own ray tracers with the balls and the cube (with
## plain, without them).
## fov: foveated rendering on (level 3 in even cases, 4 in odd ones): the ray tracer traces cells
## coarser away from the middle of each eye's picture (ray_pass.gd); Godot's overlay must still lie
## on what they show.

const U := preload("res://tests/util.gd")
# the overlay's nodes each mode shows (CheckScene.show_only)
const SHOWN := {"ray": [], "floor": ["Grid"], "domain": ["Grid"], "balls": ["Ball"], "cube": ["Cube"],
		"both": ["Grid", "Ball", "Cube"]}
# case 2: the head's step in the room each frame
const HEAD_STEP := Transform3D(Basis(Vector3.UP, deg_to_rad(-3.5)), Vector3(0.04, 0.0, -0.05))
# case 3: [frame, key, down]
const KEYS := [[5, KEY_W, true], [5, KEY_D, true], [15, KEY_W, false], [15, KEY_D, false],
		[16, KEY_E, true], [18, KEY_E, false], [19, KEY_TAB, true], [20, KEY_TAB, false],
		[21, KEY_Q, true], [21, KEY_W, true], [31, KEY_Q, false], [31, KEY_W, false]]

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
	if case == 3:
		main.smooth_turn = false
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 3:
		# then back at the start, turned to the head's yaw: the view should face the throat
		main.place(main.START_POS, main.START_FORWARD)
	if frames == 4:
		main.menu.visible = false        # it follows the head: in every view
		if plain:
			main.tracer.set_objects(PackedVector4Array(), PackedVector4Array())
		if gravity > 0:
			main.set_gravity_view(gravity)
		if fov:
			# SteamVR's level in even cases, our own map in odd ones
			main.foveation.set_level(Foveation.LEVELS if case % 2 == 0 else 4)
		CheckScene.show_only(main.overlay, SHOWN[mode])
		if mode == "domain":
			main.overlay.get_node("Grid").material_override.set_shader_parameter("solid", true)
	if case == 2 and frames >= 5 and frames < 15:
		hmd.head = HEAD_STEP * hmd.head
	if case == 3:
		for k in KEYS:
			if k[0] == frames:
				U.key(k[1], k[2])
	if frames == (34 if case == 3 else 24):
		U.save_eyes(main, OS.get_cmdline_user_args()[0], mode)
		print("saved ", mode)
		U.finish(self, hmd)
		return true
	return false
