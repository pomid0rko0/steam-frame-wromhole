extends SceneTree
## Stereo correctness through Godot's real multiview path with a simulated headset (util.gd's,
## case 1: canted eyes, asymmetric frusta, a tilted and displaced head). Balls, or
## turned cubes (the toys' kinds; PLACES), or the hands' two beams (BEAMS: straight here), in front
## of the head are drawn either by the app's renderer (mode "app": placed by walking from the feet
## along their play-space offset, a cube's axes carried along; a beam's points so) or by Godot's
## standard renderer (mode "mesh": a beam as a prism of Renderer.BEAM_SIDES sides turned as
## body.gdshaderinc turns the app's). In each eye the silhouettes must coincide.
##   godot --path . -s res://tests/multiview_hmd.gd -- out_prefix app|mesh case balls|cubes|beams

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
var beams := false
# the beams' ends in the head's own coordinates, their radius and points (the app's)
const BEAMS := [[Vector3(-0.9, 0.3, -2.2), Vector3(0.6, 0.55, -2.6)], [Vector3(-0.5, -0.6, -1.6), Vector3(0.8, -0.25, -2.0)]]
const BEAM_RADIUS := 0.08
const BEAM_POINTS := 12


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	mode = args[1]
	cubes = args[3] == "cubes"
	beams = args[3] == "beams"
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
		if beams:
			for i in BEAMS.size():
				var a: Vector3 = head * BEAMS[i][0]
				var b: Vector3 = head * BEAMS[i][1]
				if mode == "mesh":
					var tube := CylinderMesh.new()
					tube.top_radius = BEAM_RADIUS
					tube.bottom_radius = BEAM_RADIUS
					tube.height = (b - a).length()
					tube.radial_segments = Renderer.BEAM_SIDES
					tube.rings = 0
					tube.cap_top = false
					tube.cap_bottom = false
					var m := U.red(tube)
					(m.material_override as StandardMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
					# the mesh's ring starts at its +z: up, made orthogonal to the beam (the app's e1)
					var Y := (b - a).normalized()
					var Z := (Vector3.UP - Vector3.UP.dot(Y) * Y).normalized()
					m.transform = Transform3D(Basis(Y.cross(Z), Y, Z), 0.5 * (a + b))
					main.origin.add_child(m)
					continue
				var pts := PackedVector4Array()
				var radii := PackedFloat32Array()
				for k in BEAM_POINTS:
					var d: Vector3 = a.lerp(b, float(k) / (BEAM_POINTS - 1)) - feet
					var T: Vector4 = d.x * main.viewer.frame[0] + d.y * main.viewer.frame[1] + d.z * main.viewer.frame[2]
					var g: Array = sp.geodesic(main.viewer.l, main.viewer.n, T / T.length(), T.length(), [])
					pts.append(sp.embed(g[0], g[1]))
					radii.append(BEAM_RADIUS)
				main.renderer.set_beam(i, pts, radii, Color(1.0, 0.0, 0.0))
		var pos := PackedVector4Array()
		var axes := PackedVector4Array()
		var col := PackedVector4Array()
		for i in (0 if beams else PLACES.size()):
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
			var T: Vector4 = d.x * main.viewer.frame[0] + d.y * main.viewer.frame[1] + d.z * main.viewer.frame[2]
			var g: Array = sp.geodesic(main.viewer.l, main.viewer.n, T / T.length(), T.length(), main.viewer.frame)
			pos.append(sp.embed(g[0], g[1]))
			if cubes:
				for ax in [turn.x, turn.y]:
					var A: Vector4 = ax.x * g[2][0] + ax.y * g[2][1] + ax.z * g[2][2]
					axes.append(sp.embed_vector(g[0], g[1], A).normalized())
				col.append(Vector4(4.0, 0.0, 0.0, HALF))   # saturated: shading and edges stay red
			else:
				col.append(Vector4(1.0, 0.0, 0.0, RADIUS))
		if mode == "app" and not beams:
			if cubes:
				main.renderer.set_objects(PackedVector4Array(), PackedVector4Array(), pos, axes, col)
			else:
				main.renderer.set_objects(pos, col)
	if frames == 14:
		U.save_eyes(main, OS.get_cmdline_user_args()[0], mode)
		print("saved ", mode, " head ", main.camera.transform.origin, " feet l ", main.viewer.l)
		U.finish(self, hmd)
		return true
	return false
