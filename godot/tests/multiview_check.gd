extends SceneTree
## The in-headset stereo check scene through the simulated headset (tests/fake_hmd.gd):
## mode "ray" hides Godot's green overlay, "floor" shows only its floor lines, "domain" fills
## the area where it may draw floor lines, "balls" shows only its ball grids, "both" all of it.
## Comparing them shows whether green lands exactly on the ray-traced white lines and red balls.
##   godot --path . -s res://tests/multiview_check.gd -- out_prefix ray|floor|domain|balls|both case
## case 0: straight head, parallel eyes; 1: turned/tilted head, canted eyes, asymmetric frusta;
## 2: as 1, then the head walks 0.7 m and turns 35 degrees over ten frames before the capture;
## 3: as 1, then the left stick walks forward and right (keys W, D) and the right stick turns
## 30 degrees right (key E): the overlay must follow the world. Run with --fixed-fps 60, so
## every mode walks the same distance.

var main: Node3D
var hmd
var frames := 0
var mode: String
var case := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	mode = args[1]
	hmd = preload("res://tests/fake_hmd.gd").new()
	case = int(args[2])
	if case == 0:
		hmd.setup(Transform3D(Basis.IDENTITY, Vector3(0.0, 1.6, 0.0)), 0.064, 0.0, Vector4(-1.0, 1.0, -1.1, 1.1))
	else:
		var b := Basis.from_euler(Vector3(deg_to_rad(-25.0), deg_to_rad(30.0), deg_to_rad(8.0)))
		hmd.setup(Transform3D(b, Vector3(0.35, 1.5, -0.25)), 0.064, 10.0, Vector4(-1.2, 0.9, -1.15, 1.0))
	XRServer.add_interface(hmd)
	hmd.initialize()
	XRServer.primary_interface = hmd
	main = load("res://main.tscn").instantiate()
	main.xr_name = "FakeHMD"
	main.show_check = true
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 3:
		# then the head turns back to the start yaw: the view should face the throat
		main.place(1.0, main.START_POS, main.START_FORWARD)
	if frames == 4:
		var grid: MeshInstance3D = main.overlay.get_node("Grid")
		match mode:
			"ray":
				for c in main.overlay.get_children():
					c.visible = false
			"floor":
				for c in main.overlay.get_children():
					c.visible = c == grid
			"domain":
				for c in main.overlay.get_children():
					c.visible = c == grid
				grid.material_override.set_shader_parameter("solid", true)
			"balls":
				grid.visible = false
	if case == 2 and frames >= 5 and frames < 15:
		hmd.head = Transform3D(Basis(Vector3.UP, deg_to_rad(-3.5)), Vector3(0.04, 0.0, -0.05)) * hmd.head
	if case == 3:
		match frames:
			5:
				_key(KEY_W, true)
				_key(KEY_D, true)
			15:
				_key(KEY_W, false)
				_key(KEY_D, false)
			16:
				_key(KEY_E, true)
			18:
				_key(KEY_E, false)
	if frames == 24:
		var rid: RID = main.xr_view.get_texture().get_rid()
		for i in 2:
			var img: Image = RenderingServer.texture_2d_layer_get(rid, i)
			img.convert(Image.FORMAT_RGB8)
			img.save_png(OS.get_cmdline_user_args()[0] + "_" + mode + ("_left.png" if i == 0 else "_right.png"))
		print("saved ", mode)
		return true
	return false


func _key(code: Key, down: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = down
	Input.parse_input_event(ev)
