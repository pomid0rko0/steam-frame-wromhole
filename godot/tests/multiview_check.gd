extends SceneTree
## The in-headset stereo check scene (check_scene.gd) through the simulated headset
## (tests/fake_hmd.gd): mode "app" hides Godot's green overlay, "zones" is "app" with foveation's
## coarse texels tinted (Foveation.show), "probe" with foveation's probe (each floor pixel blue,
## red by how far from its place it took its colour: foveation.gd), "lens" is "app" with blue where the
## floor's quad draws what comes through the curved zone (floor.gdshaderinc's lens_mark: the app's
## images of the balls and the cube there have no green, tools/compare/check_scene.py leaves them
## out), "floor" shows only its floor lines,
## "domain" fills the area where it may draw floor lines, "balls" shows only its ball grids, "cube"
## only the cube's edges, "both" all of it. Comparing them shows whether green lands exactly on the
## renderer's white lines, red balls and magenta cube.
##   godot --path . -s res://tests/multiview_check.gd -- out_prefix app|zones|probe|lens|floor|domain|balls|cube|both case [plain|gravity|arrows] [fov]
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
## fov: foveated rendering on (foveation.gd) at FOV_LEVELS[case], in case 1 with the eyes tracked
## looking off the middle (FOV_GAZE); in mode "app" each eye's fovea goes into out_prefix_fovea.json
## (Foveation.fovea: [g's pixel x, y, r0] per eye), for tools/compare/fovea.py.

const U := preload("res://tests/util.gd")
# the overlay's nodes each mode shows (CheckScene.show_only)
const SHOWN := {"app": [], "zones": [], "probe": [], "lens": [], "floor": ["Grid"], "domain": ["Grid"], "balls": ["Ball"], "cube": ["Cube"],
		"both": ["Grid", "Ball", "Cube"]}
# case 2: the head's step in the room each frame
const HEAD_STEP := Transform3D(Basis(Vector3.UP, deg_to_rad(-3.5)), Vector3(0.04, 0.0, -0.05))
# case 3: [frame, key, down]
const KEYS := [[5, KEY_W, true], [5, KEY_D, true], [15, KEY_W, false], [15, KEY_D, false],
		[16, KEY_E, true], [18, KEY_E, false], [19, KEY_TAB, true], [20, KEY_TAB, false],
		[21, KEY_Q, true], [21, KEY_W, true], [31, KEY_Q, false], [31, KEY_W, false]]
# fov: the level by case (Foveation.LEVELS' index + 1), and where the eyes look in case 1 (the
# head's space)
const FOV_LEVELS := [2, 2, 3, 1, 2, 2]
const FOV_GAZE := Vector3(0.25, 0.15, -1.0)
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
	if fov and case == 1:
		hmd.gaze = FOV_GAZE.normalized()
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
		if mode == "zones":
			main.foveation.show = true
		if mode == "probe":
			main.foveation.probe = true
			for m in main.renderer.floor_mats:
				m.set_shader_parameter("fov_probe", true)
		if mode == "lens":
			for m in main.renderer.floor_mats:
				m.set_shader_parameter("lens_mark", true)
		if gravity > 0:
			main.set_gravity_view(gravity)
		CheckScene.show_only(main.overlay, SHOWN[mode])
		if mode == "domain":
			main.overlay.get_node("Grid").material_override.set_shader_parameter("solid", true)
	if frames == 6 and fov:
		# after main's first frames, which set foveation off and on and then the menu's
		main.foveation.set_level(FOV_LEVELS[case])
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
		if fov and mode == "app":
			var f := FileAccess.open(OS.get_cmdline_user_args()[0] + "_fovea.json", FileAccess.WRITE)
			f.store_string(JSON.stringify(Array(main.foveation.fovea)))
		print("saved ", mode)
		U.finish(self, hmd)
		return true
	return false
