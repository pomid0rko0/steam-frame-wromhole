extends SceneTree
## Stereo in the curved zone, where there is no Godot geometry to compare with: the simulated
## headset (util.gd's case 1: canted eyes, asymmetric frusta, a turned and displaced head) stands or
## flies at a place of PLACES with red balls and green cubes round the head, and each eye's picture is saved
## with what tools/compare/curved.py needs to trace that eye's rays itself, independently of the
## shaders: the head as the renderer got it, each eye's pose and frustum, the bodies, where the
## mouths stand (MOUTHS: moved and turned, so the floor's checker in the flat universes is checked in
## their worlds). The scene's static objects are hidden: the traced rays don't know them, and a
## reddish one would count as a ball.
##   godot --path . -s res://tests/curved_check.gd -- out_prefix place
## Writes out_prefix_app_left.png, _right.png and out_prefix.json.

const U := preload("res://tests/util.gd")
# [the feet's l, degrees right of the throat (place_on_axis), flights from there (main.viewer: off
# the floor, then each a geodesic along the head's x right, y up, -z ahead, the room's axes carried
# along), the head's pitch in degrees (util.gd's headset)]: standing in the throat looking along it
# and sideways round it, at the curved zone's edge, inside universe B's fillet facing the throat, in
# the flat universe the same way as a control; flying 2 m up round the throat's middle, 5.5 m up
# round it at l 1 (past its top), high above universe A looking down into the throat, and through
# the throat 0.5 m over the floor into universe B, looking down to B's floor (up turned about 48
# degrees: tests/flight_test.gd)
const PLACES := [[0.0, 10.0, [], -10.0], [0.3, 95.0, [], -10.0], [5.0, 15.0, [], -10.0], [-4.6, 170.0, [], -10.0],
		[12.0, 40.0, [], -10.0], [0.0, 10.0, [Vector3(0.0, 2.0, 0.0)], -10.0], [1.0, 30.0, [Vector3(0.0, 5.5, 0.0)], -10.0],
		[12.0, 0.0, [Vector3(0.0, 6.0, -9.0)], -60.0], [12.0, 0.0, [Vector3(0.0, 0.5, 0.0), Vector3(0.0, 0.0, -20.0)], -55.0]]
# bodies in the head's coordinates (x right, y up, -z forward): balls [place, radius], cubes
# [place, half size, turn (euler)]; one ball and one cube near the eyes
const BALLS := [[Vector3(0.0, -0.1, -0.45), 0.12], [Vector3(-0.7, 0.2, -1.6), 0.25], [Vector3(0.9, -0.6, -2.2), 0.3]]
# scene.json's mouths for this test: A's and B's [x, y, degrees]
const MOUTHS := {"A": [1.3, -0.7, 23.0], "B": [-2.1, 1.6, -51.0]}
const CUBES := [[Vector3(0.35, 0.15, -0.6), 0.1, Vector3(0.4, 0.6, 0.1)], [Vector3(-0.4, -0.5, -2.6), 0.28, Vector3(-0.2, 0.9, 0.3)]]

var main: Main
var hmd
var frames := 0
var place: Array


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	place = PLACES[int(args[1])]
	hmd = U.headset(1, place[3], Vector2i(640, 640))
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "FakeHMD"
	main.show_check = false
	main.toys.enabled = false            # this test draws its own
	main.scene["mouths"] = MOUTHS
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 3:
		main.menu.visible = false
		main.renderer.show_scene(false)
		main.place_on_axis(place[0], place[1], 0.0)
		var v: Viewer = main.viewer
		var fwd := main._head_forward_xz()
		for d: Vector3 in place[2]:
			v.take_off()
			v.move(WormholeSpace.combine(v.frame, Vector3(-d.x * fwd.y - d.z * fwd.x, d.y, d.x * fwd.x - d.z * fwd.y)))
		if not place[2].is_empty():
			var hp := v.head(hmd.head.origin.y)
			print("flying: the feet %.2f m over the floor, the head %.2f m, up %.0f deg from the floor's normal there"
					% [v.height(), main.space.height(hp[0], hp[1]),
					rad_to_deg(acos(clampf((v.frame[1] as Vector4).dot(main.space.height_grad(v.l, v.n).normalized()), -1.0, 1.0)))])
		main.hold = true
	if frames == 5:
		_bodies()
	if frames == 14:
		var prefix: String = OS.get_cmdline_user_args()[0]
		U.save_eyes(main, prefix, "app")
		_dump(prefix + ".json")
		print("saved place ", place)
		U.finish(self, hmd)
		return true
	return false


## The bodies at their places round the head: walk from the head along the play-space offset,
## carrying the play-space axes (the head as main has it now).
func _bodies() -> void:
	var sp: WormholeSpace = main.space
	var hp: Array = main._head_pose
	var head: Transform3D = hmd.head
	var pos := PackedVector4Array()
	var col := PackedVector4Array()
	var cpos := PackedVector4Array()
	var axes := PackedVector4Array()
	var ccol := PackedVector4Array()
	for b: Array in BALLS:
		var g := _walk(sp, hp, head.basis * b[0])
		pos.append(sp.embed(g[0], g[1]))
		col.append(Vector4(4.0, 0.0, 0.0, b[1]))    # saturated: shading and the rim stay red
	for c: Array in CUBES:
		var turn: Basis = head.basis * Basis.from_euler(c[2])
		var g := _walk(sp, hp, head.basis * c[0])
		cpos.append(sp.embed(g[0], g[1]))
		for ax in [turn.x, turn.y]:
			var A: Vector4 = ax.x * g[2][0] + ax.y * g[2][1] + ax.z * g[2][2]
			axes.append(sp.embed_vector(g[0], g[1], A).normalized())
		ccol.append(Vector4(0.0, 4.0, 0.0, c[1]))
	main.toys.enabled = false
	main.renderer.set_objects(pos, col, cpos, axes, ccol)
	_objects = [pos, col, cpos, axes, ccol]


var _objects := []


static func _walk(sp: WormholeSpace, hp: Array, d: Vector3) -> Array:
	var f: Array = hp[2]
	var T: Vector4 = d.x * f[0] + d.y * f[1] + d.z * f[2]
	return sp.geodesic(hp[0], hp[1], T / T.length(), T.length(), f)


func _dump(path: String) -> void:
	var hp: Array = main._head_pose
	var f: Array = hp[2]
	var eyes := []
	for v in 2:
		var t: Transform3D = hmd.head * hmd.eyes[v]
		eyes.append({"basis": [_v3(t.basis.x), _v3(t.basis.y), _v3(t.basis.z)], "origin": _v3(t.origin),
				"frustum": [hmd.frusta[v].x, hmd.frusta[v].y, hmd.frusta[v].z, hmd.frusta[v].w]})
	var sp: WormholeSpace = main.space
	var d := {"profile": [sp.rho0, sp.h, sp.fillet], "size": [hmd.size.x, hmd.size.y],
		"head": {"l": hp[0], "n": _v3(hp[1]), "frame": [_v4(f[0]), _v4(f[1]), _v4(f[2])],
			"pos": _v3(main.camera.transform.origin)},
		"eyes": eyes, "balls": [], "cubes": [], "mouths": [_v3(sp.mouths[0]), _v3(sp.mouths[1])]}
	for i in _objects[0].size():
		d.balls.append({"c": _v4(_objects[0][i]), "r": _objects[1][i].w})
	for i in _objects[2].size():
		d.cubes.append({"c": _v4(_objects[2][i]), "e1": _v4(_objects[3][2 * i]), "e2": _v4(_objects[3][2 * i + 1]),
				"half": _objects[4][i].w})
	var fa := FileAccess.open(path, FileAccess.WRITE)
	fa.store_string(JSON.stringify(d, "\t"))


static func _v3(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


static func _v4(v: Vector4) -> Array:
	return [v.x, v.y, v.z, v.w]
