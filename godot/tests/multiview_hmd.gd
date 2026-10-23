extends SceneTree
## Stereo correctness through Godot's real multiview path with a simulated headset that has
## canted eyes, asymmetric frusta and a tilted, displaced head (tests/fake_hmd.gd).
## Balls in front of the head are drawn either by our ray tracer (mode "ray") or by Godot's
## standard renderer (mode "mesh"). In each eye the silhouettes must coincide.
##   godot --path . -s res://tests/multiview_hmd.gd -- out_prefix ray|mesh case
## case 0: straight head, parallel eyes; 1: turned/tilted head, canted eyes, asymmetric frusta.

const RADIUS := 0.25
# ball centres in the head's own coordinates (x right, y up, -z forward)
const BALLS := [Vector3(0.0, 0.0, -2.0), Vector3(-0.8, 0.45, -2.4), Vector3(0.7, -0.55, -1.8),
		Vector3(-1.3, -0.2, -1.4), Vector3(0.9, 0.35, -1.0)]

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
	main.show_check = false   # its balls and grids would cover the test balls
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1

	if frames == 3:
		# start where main starts, with the head pose now known
		main.place(1.0, main.START_POS, main.START_FORWARD)
	if frames == 4:
		var head: Transform3D = hmd.head
		var feet := Vector3(head.origin.x, 0.0, head.origin.z)
		var pos := PackedVector4Array()
		var col := PackedVector4Array()
		for c in BALLS:
			var p: Vector3 = head * c           # play space
			if mode == "ray":
				# the ball's place in the curved space: walk from the feet along the play-space offset
				var d := p - feet
				var T: Vector4 = d.x * main.frame[0] + d.y * main.frame[1] + d.z * main.frame[2]
				var g: Array = main.space.geodesic(main.foot_l, main.foot_n, T / T.length(), T.length(), main.frame)
				pos.append(main.space.embed(g[0], g[1]))
				col.append(Vector4(1.0, 0.0, 0.0, RADIUS))
			else:
				var m := MeshInstance3D.new()
				var s := SphereMesh.new()
				s.radius = RADIUS
				s.height = 2.0 * RADIUS
				s.radial_segments = 256
				s.rings = 128
				m.mesh = s
				var mat := StandardMaterial3D.new()
				mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				mat.albedo_color = Color(1.0, 0.0, 0.0)
				mat.no_depth_test = true
				mat.render_priority = 10
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				m.material_override = mat
				m.position = p
				main.origin.add_child(m)
		if mode == "ray":
			while pos.size() < 12:
				pos.append(Vector4.ZERO)
				col.append(Vector4.ZERO)
			main.material.set_shader_parameter("wh_ball", pos)
			main.material.set_shader_parameter("wh_ballCol", col)
			main.material.set_shader_parameter("wh_nBall", BALLS.size())
	if frames == 14:
		var rid: RID = main.xr_view.get_texture().get_rid()
		for i in 2:
			var img: Image = RenderingServer.texture_2d_layer_get(rid, i)
			img.convert(Image.FORMAT_RGB8)
			img.save_png(OS.get_cmdline_user_args()[0] + "_" + mode + ("_left.png" if i == 0 else "_right.png"))
		print("saved ", mode, " head ", main.camera.transform.origin, " feet l ", main.foot_l)
		return true
	return false
