extends SceneTree
## Stereo correctness through Godot's real multiview path with a simulated headset (util.gd's,
## case 1: canted eyes, asymmetric frusta, a tilted and displaced head). Balls, or
## turned cubes (the toys' kinds; PLACES), in front of the head are drawn either by our ray tracer
## (mode "ray": placed by walking from the feet along their play-space offset, a cube's axes carried
## along) or by Godot's standard renderer (mode "mesh"). In each eye the silhouettes must coincide.
##   godot --path . -s res://tests/multiview_hmd.gd -- out_prefix ray|mesh case balls|cubes

const U := preload("res://tests/util.gd")
const RADIUS := 0.25
const HALF := 0.22
# centres in the head's own coordinates (x right, y up, -z forward), and the cubes' turns
const PLACES := [Vector3(0.0, 0.0, -2.0), Vector3(-0.8, 0.45, -2.4), Vector3(0.7, -0.55, -1.8),
		Vector3(-1.3, -0.2, -1.4), Vector3(0.9, 0.35, -1.0)]
const TURNS := [Vector3(0.3, 0.5, 0.1), Vector3(-0.4, 0.2, 0.7), Vector3(0.9, -0.3, 0.2),
		Vector3(0.1, 0.8, -0.5), Vector3(-0.6, -0.7, 0.3)]

var main: Main
var hmd
var frames := 0
var mode: String
var cubes := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	mode = args[1]
	cubes = args[3] == "cubes"
	hmd = U.headset(int(args[2]))
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "FakeHMD"
	main.show_check = false             # its balls and grids would cover the ones under test
	main.toys.enabled = false            # this test draws its own
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 3:
		# start where main starts, with the head pose now known
		main.place(main.START_POS, main.START_FORWARD)
	if frames == 4:
		main.menu.visible = false        # it follows the head: in every view
		var head: Transform3D = hmd.head
		var feet := Vector3(head.origin.x, 0.0, head.origin.z)
		var sp: WormholeSpace = main.space
		var pos := PackedVector4Array()
		var axes := PackedVector4Array()
		var col := PackedVector4Array()
		for i in PLACES.size():
			var p: Vector3 = head * PLACES[i]                        # play space
			var turn := head.basis * Basis.from_euler(TURNS[i])      # a cube's axes in play space
			if mode == "mesh":
				var m: MeshInstance3D
				if cubes:
					var box := BoxMesh.new()
					box.size = Vector3.ONE * 2.0 * HALF
					m = U.red(box)
					m.transform = Transform3D(turn, p)
				else:
					m = U.red(U.sphere(RADIUS))
					m.position = p
				main.origin.add_child(m)
				continue
			# the place in the curved space: walk from the feet along the play-space offset, carrying
			# the play-space axes; a cube's axes are combinations of those
			var d := p - feet
			var T: Vector4 = d.x * main.frame[0] + d.y * main.frame[1] + d.z * main.frame[2]
			var g: Array = sp.geodesic(main.foot_l, main.foot_n, T / T.length(), T.length(), main.frame)
			pos.append(sp.embed(g[0], g[1]))
			if cubes:
				for ax in [turn.x, turn.y, turn.z]:
					var A: Vector4 = ax.x * g[2][0] + ax.y * g[2][1] + ax.z * g[2][2]
					axes.append(sp.embed_vector(g[0], g[1], A) / HALF)
				axes.append(sp.normal4(g[0], g[1]) / HALF)
				col.append(Vector4(4.0, 0.0, 0.0, HALF))   # saturated: shading and edges stay red
			else:
				col.append(Vector4(1.0, 0.0, 0.0, RADIUS))
		if mode == "ray":
			if cubes:
				main.tracer.set_objects(PackedVector4Array(), PackedVector4Array(), pos, axes, col)
			else:
				main.tracer.set_objects(pos, col)
	if frames == 14:
		U.save_eyes(main, OS.get_cmdline_user_args()[0], mode)
		print("saved ", mode, " head ", main.camera.transform.origin, " feet l ", main.foot_l)
		U.finish(self, hmd)
		return true
	return false
