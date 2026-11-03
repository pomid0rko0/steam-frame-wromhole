extends SceneTree
## Stereo correctness through Godot's real multiview path with a simulated headset (util.gd's,
## case 1: canted eyes, asymmetric frusta, a tilted and displaced head). Balls, turned cubes (the
## toys' kinds; PLACES) and the hands' two beams (BEAMS: straight here) in front of the head, each
## kind drawn by Godot's standard renderer (mode "mesh": a beam as a prism of Renderer.BEAM_SIDES
## sides turned as body.gdshaderinc turns the app's) and by the app's renderer (mode "app": placed
## by walking from the feet along their play-space offset, a cube's axes carried along; a beam's
## points so). In each eye the silhouettes must coincide where light goes straight: Godot draws no
## image of them through the curved zone. Mode "lens" is "app" with blue where the floor's quad
## draws what comes through the zone (floor.gdshaderinc's lens_mark), for
## tools/compare/silhouettes.py to leave out.
## One case in one run: every kind's "mesh" first, the app drawing nothing, then each kind's "app"
## and "lens"; each picture SETTLE frames after its state is set (the first FIRST frames in), saved
## as <dir>/<prefix>_<mode>_left.png and _right.png. A picture is the same as a run with that
## picture alone gives.
##   godot --path . --resolution 640x360 -s res://tests/multiview_hmd.gd -- dir case kind:prefix...
## kind: balls, cubes or beams.

const U := preload("res://tests/util.gd")
const RADIUS := 0.25
const HALF := 0.22
# centres in the head's own coordinates (x right, y up, -z forward), and the cubes' turns
const PLACES := [Vector3(0.0, 0.0, -2.0), Vector3(-0.8, 0.45, -2.4), Vector3(0.7, -0.55, -1.8),
		Vector3(-1.3, -0.2, -1.4), Vector3(0.9, 0.35, -1.0)]
const TURNS := [Vector3(0.3, 0.5, 0.1), Vector3(-0.4, 0.2, 0.7), Vector3(0.9, -0.3, 0.2),
		Vector3(0.1, 0.8, -0.5), Vector3(-0.6, -0.7, 0.3)]
# the beams' ends in the head's own coordinates, their radius and points (the app's)
const BEAMS := [[Vector3(-0.9, 0.3, -2.2), Vector3(0.6, 0.55, -2.6)], [Vector3(-0.5, -0.6, -1.6), Vector3(0.8, -0.25, -2.0)]]
const BEAM_RADIUS := 0.08
const BEAM_POINTS := 12
const KINDS := ["balls", "cubes", "beams"]
const FIRST := 14
const SETTLE := 2

var main: Main
var hmd
var frames := 0
var dir: String
var shots: Array = []           # [kind, prefix, mode]: each kind's "mesh", then each one's "app" and "lens"
var shot := 0
var due := FIRST                # the frame the picture drawn now is saved at
var meshes := {}                # kind -> Godot's nodes of it
var bodies := {}                # kind -> what the app draws of it: set_objects' arguments, or each beam's points
var drawn := ""                 # the kind the app draws now


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	dir = args[0]
	var kinds := []
	for a in args.slice(2):
		var k: PackedStringArray = a.split(":")
		if not KINDS.has(k[0]):
			printerr("multiview_hmd.gd: no kind ", k[0])
			quit(2)
			return
		kinds.append(k)
		shots.append([k[0], k[1], "mesh"])
	for k in kinds:
		for mode in ["app", "lens"]:
			shots.append([k[0], k[1], mode])
	hmd = U.headset(int(args[1]))
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "FakeHMD"
	main.show_check = false             # its balls and grids would cover the ones under test
	main.toys.enabled = false            # this test draws its own
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 3:
		# start where main starts, with the head pose now known, the back to the wormhole: what is
		# compared here is where light goes straight (tests/curved_check.gd takes the rest)
		main.place(main.START_POS, -main.START_FORWARD)
	if frames == 4:
		main.menu.visible = false        # it follows the head: in every view
		main.renderer.show_scene(false)  # the scene's reddish sphere would count as a ball
		for s in shots:
			if s[2] == "mesh":
				_build(s[0])
		_show(shots[0])
	if frames == due:
		var s: Array = shots[shot]
		U.save_eyes(main, dir.path_join(s[1]), s[2])
		print("saved ", s[1], " ", s[2], " head ", main.camera.transform.origin, " feet l ", main.viewer.l)
		shot += 1
		if shot == shots.size():
			U.finish(self, hmd)
			return true
		_show(shots[shot])
		due = frames + SETTLE
	return false


## Godot's nodes of a kind, hidden, and what the app draws of it.
func _build(kind: String) -> void:
	var head: Transform3D = hmd.head
	var feet := Vector3(head.origin.x, 0.0, head.origin.z)
	var sp: WormholeSpace = main.space
	var nodes: Array[MeshInstance3D] = []
	if kind == "beams":
		var app := []
		for i in BEAMS.size():
			var a: Vector3 = head * BEAMS[i][0]
			var b: Vector3 = head * BEAMS[i][1]
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
			nodes.append(m)
			var pts := PackedVector4Array()
			var radii := PackedFloat32Array()
			for k in BEAM_POINTS:
				var d: Vector3 = a.lerp(b, float(k) / (BEAM_POINTS - 1)) - feet
				var T: Vector4 = d.x * main.viewer.frame[0] + d.y * main.viewer.frame[1] + d.z * main.viewer.frame[2]
				var g: Array = sp.geodesic(main.viewer.l, main.viewer.n, T / T.length(), T.length(), [])
				pts.append(sp.embed(g[0], g[1]))
				radii.append(BEAM_RADIUS)
			app.append([pts, radii])
		bodies[kind] = app
	else:
		var pos := PackedVector4Array()
		var axes := PackedVector4Array()
		var col := PackedVector4Array()
		for i in PLACES.size():
			var p: Vector3 = head * PLACES[i]                        # play space
			var turn := head.basis * Basis.from_euler(TURNS[i])      # a cube's axes in play space
			var m: MeshInstance3D
			if kind == "cubes":
				var box := BoxMesh.new()
				box.size = Vector3.ONE * 2.0 * HALF
				m = U.red(box)
				m.transform = Transform3D(turn, p)
			else:
				m = U.red(U.sphere(RADIUS))
				m.position = p
			nodes.append(m)
			# the place in the curved space: walk from the feet along the play-space offset, carrying
			# the play-space axes; a cube's axes are combinations of those
			var d := p - feet
			var T: Vector4 = d.x * main.viewer.frame[0] + d.y * main.viewer.frame[1] + d.z * main.viewer.frame[2]
			var g: Array = sp.geodesic(main.viewer.l, main.viewer.n, T / T.length(), T.length(), main.viewer.frame)
			pos.append(sp.embed(g[0], g[1]))
			if kind == "cubes":
				for ax in [turn.x, turn.y]:
					var A: Vector4 = ax.x * g[2][0] + ax.y * g[2][1] + ax.z * g[2][2]
					axes.append(sp.embed_vector(g[0], g[1], A).normalized())
				col.append(Vector4(4.0, 0.0, 0.0, HALF))   # saturated: shading and edges stay red
			else:
				col.append(Vector4(1.0, 0.0, 0.0, RADIUS))
		var none := PackedVector4Array()
		bodies[kind] = [none, none, pos, axes, col] if kind == "cubes" else [pos, col, none, none, none]
	for m in nodes:
		m.visible = false
		main.origin.add_child(m)
	meshes[kind] = nodes


## What picture s draws: Godot's nodes of its kind (mesh) or the app's (app, lens), and lens_mark.
func _show(s: Array) -> void:
	var kind: String = s[0]
	var mode: String = s[2]
	for k in meshes:
		for m: MeshInstance3D in meshes[k]:
			m.visible = mode == "mesh" and k == kind
	var want := "" if mode == "mesh" else kind
	if want != drawn:
		var none := PackedVector4Array()
		var b: Array = bodies.get(want, [none, none, none, none, none]) if want != "beams" else [none, none, none, none, none]
		main.renderer.set_objects(b[0], b[1], b[2], b[3], b[4])
		for i in BEAMS.size():
			if want == "beams":
				main.renderer.set_beam(i, bodies[want][i][0], bodies[want][i][1], Color(1.0, 0.0, 0.0))
			elif drawn == "beams":
				main.renderer.set_beam(i, none, PackedFloat32Array(), Color(1.0, 0.0, 0.0))
		drawn = want
	for m in main.renderer.floor_mats:
		m.set_shader_parameter("lens_mark", mode == "lens")
