extends SceneTree
## Stereo correctness of the cubes through Godot's real multiview path with the simulated
## headset of multiview_hmd.gd (canted eyes, asymmetric frusta, a tilted, displaced head).
## Turned cubes in front of the head are drawn either by our ray tracer (mode "ray": a 4D box
## placed by walking from the feet, its axes parallel-transported along) or by Godot's standard
## renderer (mode "mesh": a BoxMesh). In each eye the silhouettes must coincide.
##   godot --path . -s res://tests/multiview_cubes.gd -- out_prefix ray|mesh case

const HALF := 0.22
# cube centres in the head's own coordinates (x right, y up, -z forward) and their turns
const CUBES := [Vector3(0.0, 0.0, -2.0), Vector3(-0.8, 0.45, -2.4), Vector3(0.7, -0.55, -1.8),
		Vector3(-1.3, -0.2, -1.4), Vector3(0.9, 0.35, -1.0)]
const TURNS := [Vector3(0.3, 0.5, 0.1), Vector3(-0.4, 0.2, 0.7), Vector3(0.9, -0.3, 0.2),
		Vector3(0.1, 0.8, -0.5), Vector3(-0.6, -0.7, 0.3)]

var main: Node3D
var hmd
var frames := 0
var mode: String


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	mode = args[1]
	hmd = preload("res://tests/fake_hmd.gd").new()
	if int(args[2]) == 0:
		hmd.setup(Transform3D(Basis.IDENTITY, Vector3(0.0, 1.6, 0.0)), 0.064, 0.0, Vector4(-1.0, 1.0, -1.1, 1.1))
	else:
		var b := Basis.from_euler(Vector3(deg_to_rad(-12.0), deg_to_rad(30.0), deg_to_rad(8.0)))
		hmd.setup(Transform3D(b, Vector3(0.35, 1.5, -0.25)), 0.064, 10.0, Vector4(-1.2, 0.9, -1.15, 1.0))
	XRServer.add_interface(hmd)
	hmd.initialize()
	XRServer.primary_interface = hmd
	main = load("res://main.tscn").instantiate()
	main.xr_name = "FakeHMD"
	main.show_check = false
	main.physics = false            # this test draws its own cubes
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 3:
		main.place(1.0, main.START_POS, main.START_FORWARD)
	if frames == 4:
		var head: Transform3D = hmd.head
		var feet := Vector3(head.origin.x, 0.0, head.origin.z)
		var pos := PackedVector4Array()
		var axes := PackedVector4Array()
		var col := PackedVector4Array()
		var sp: WormholeSpace = main.space
		for i in CUBES.size():
			var p: Vector3 = head * CUBES[i]                        # play space
			var turn := head.basis * Basis.from_euler(TURNS[i])     # cube axes in play space
			if mode == "ray":
				# the cube's place in the curved space: walk from the feet along the play-space
				# offset, carrying the play-space axes; its axes are combinations of those
				var d := p - feet
				var T: Vector4 = d.x * main.frame[0] + d.y * main.frame[1] + d.z * main.frame[2]
				var g: Array = sp.geodesic(main.foot_l, main.foot_n, T / T.length(), T.length(), main.frame)
				pos.append(sp.embed(g[0], g[1]))
				for ax in [turn.x, turn.y, turn.z]:
					var A: Vector4 = ax.x * g[2][0] + ax.y * g[2][1] + ax.z * g[2][2]
					axes.append(sp.embed_vector(g[0], g[1], A) / HALF)
				axes.append(sp.normal4(g[0], g[1]) / HALF)
				col.append(Vector4(4.0, 0.0, 0.0, HALF))   # saturated: shading and edges stay red
			else:
				var m := MeshInstance3D.new()
				var box := BoxMesh.new()
				box.size = Vector3.ONE * 2.0 * HALF
				m.mesh = box
				var mat := StandardMaterial3D.new()
				mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				mat.albedo_color = Color(1.0, 0.0, 0.0)
				mat.no_depth_test = true
				mat.render_priority = 10
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				m.material_override = mat
				m.transform = Transform3D(turn, p)
				main.origin.add_child(m)
		if mode == "ray":
			while pos.size() < 6:
				pos.append(Vector4.ZERO)
				col.append(Vector4.ZERO)
			while axes.size() < 24:
				axes.append(Vector4.ZERO)
			main.material.set_shader_parameter("wh_cube", pos)
			main.material.set_shader_parameter("wh_cubeE", axes)
			main.material.set_shader_parameter("wh_cubeCol", col)
			main.material.set_shader_parameter("wh_nCube", CUBES.size())
	if frames == 14:
		var rid: RID = main.xr_view.get_texture().get_rid()
		for i in 2:
			var img: Image = RenderingServer.texture_2d_layer_get(rid, i)
			img.convert(Image.FORMAT_RGB8)
			img.save_png(OS.get_cmdline_user_args()[0] + "_" + mode + ("_left.png" if i == 0 else "_right.png"))
		print("saved ", mode, " head ", main.camera.transform.origin, " feet l ", main.foot_l)
		return true
	return false
