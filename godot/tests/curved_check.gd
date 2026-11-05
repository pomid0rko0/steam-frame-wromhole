extends SceneTree
## Stereo where light is bent by the wormhole, where there is no Godot geometry to compare with: the
## simulated headset (util.gd's case 1: canted eyes, asymmetric frusta, a turned and displaced
## head) stands or flies at a place of PLACES with red balls and green cubes round the head and at
## fixed places of the space (WORLD: in the throat, on its far side, in universe B, behind the
## mouth: seen through the lens and in the zone, every image), and each eye's picture is saved with
## what tools/compare/curved.py needs to trace that eye's rays itself, independently of the shaders:
## the head as the renderer got it, each eye's pose and frustum, the bodies. The scene's static
## objects are hidden: the traced rays don't know them, and a reddish one would count as a ball.
## With fov, foveation (foveation.gd, the menu's default level) draws the floor and what is
## seen through the lens, and a ball crosses the edge of the zone's disc in the picture from the start
## (EDGE_BALL): drawn by its mesh outside the disc and by the filtered texture inside it, it must not
## part there. tools/compare/curved.py then allows each pixel's texel size more (the json's fovea).
##   godot --path . -s res://tests/curved_check.gd -- out_prefix place [fov]
## Writes out_prefix_app_left.png, _right.png and out_prefix.json.

const U := preload("res://tests/util.gd")
# [the feet's place on universe A's floor (chart x, y), the direction they face (chart x, y),
# flights from there (main.viewer: off the floor, then each a geodesic along the head's x right, y
# up, -z ahead, the room's axes carried along), a turn of the room to the right after, in degrees,
# the head's pitch in degrees (util.gd's headset)]: standing at the start looking up at the mouth;
# level with the throat's centre 9 m out; at the curved zone's edge; in A's fillet; in the throat
# looking along it and sideways; out in universe B looking back at the mouth; far off, a control;
# under the mouth looking up into it
const PLACES := [[Vector2(10.0, 0.0), Vector2(-1.0, 0.0), [], 0.0, 15.0],
		[Vector2(9.0, 0.0), Vector2(-1.0, 0.0), [Vector3(0.0, 3.4, 0.0)], 0.0, 0.0],
		[Vector2(9.0, 0.3), Vector2(-1.0, 0.0), [Vector3(0.0, 3.4, 0.0), Vector3(0.0, 0.0, -4.6)], 0.0, -5.0],
		[Vector2(9.0, 0.3), Vector2(-1.0, 0.0), [Vector3(0.0, 3.4, 0.0), Vector3(0.0, 0.0, -5.6)], 0.0, -5.0],
		[Vector2(9.0, 0.0), Vector2(-1.0, 0.0), [Vector3(0.0, 3.4, 0.0), Vector3(0.0, 0.0, -9.0)], 0.0, -10.0],
		[Vector2(9.0, 0.0), Vector2(-1.0, 0.0), [Vector3(0.0, 3.4, 0.0), Vector3(0.0, 0.0, -9.0)], 90.0, -10.0],
		[Vector2(9.0, 0.0), Vector2(-1.0, 0.0), [Vector3(0.0, 3.4, 0.0), Vector3(0.0, 0.0, -21.0)], 180.0, 0.0],
		[Vector2(24.0, 9.0), Vector2(1.0, 0.3), [], 0.0, -10.0],
		[Vector2(0.6, 0.4), Vector2(-1.0, 0.0), [], 0.0, 75.0]]
# bodies in the head's coordinates (x right, y up, -z forward): balls [place, radius], cubes
# [place, half size, turn (euler)]; one ball and one cube near the eyes
const BALLS := [[Vector3(0.0, -0.1, -0.45), 0.12], [Vector3(-0.7, 0.2, -1.6), 0.25], [Vector3(0.9, -0.6, -2.2), 0.3]]
const CUBES := [[Vector3(0.35, 0.15, -0.6), 0.1, Vector3(0.4, 0.6, 0.1)], [Vector3(-0.4, -0.5, -2.6), 0.28, Vector3(-0.2, 0.9, 0.3)]]
# bodies at points (l, n) of the space: balls [l, n, radius], cubes [l, n, half size, a turn about
# n's tangent plane]: on the throat's far side from the start, in it near its top, in B's fillet,
# out in B through the throat from the start, out in A behind the mouth
const WORLD_BALLS := [[0.3, Vector3(-1.0, 0.05, 0.1), 0.4], [1.5, Vector3(0.1, -0.2, 1.0), 0.3],
		[-9.0, Vector3(1.0, 0.25, -0.35), 0.45]]
# with fov: out in A behind the mouth across the edge of the zone's disc in the picture from the
# start (part of it seen straight, part through the lens); its images near the photon sphere, thin
# rings, are left to the places without
const EDGE_BALL := [11.62, Vector3(-6.64, 7.2, 2.26), 1.2]
const WORLD_CUBES := [[-3.0, Vector3(0.3, 1.0, 0.2), 0.3, 0.5], [7.5, Vector3(-1.0, 0.35, 0.15), 0.4, 0.3]]
# and on the line through the head and the throat's centre, where a body's images close into rings:
# [m toward the centre from the head (l less), radius or half size, a turn about that line]
const AXIS_BALL := [1.1, 0.1, 0.0]
const AXIS_CUBE := [0.7, 0.12, 0.4]
# and next to one eye's line through the throat's centre (its axis: there the space's curve takes a
# cube's edge back round the axis, and a section cuts it twice), and with a corner on it or a hair
# off it (issue #147's cubes: a section of two parts, the mesh's axis turned off the corner):
# [the eye (0 left, 1 right), m toward the centre from the eye, half size, the cube's edge across the
# axis (0) or its corner (1) toward it, how far from the axis (negative: the axis through the cube)]
const NEAR_AXIS_CUBES := [[0, 1.7, 0.2, 0, 0.003], [1, 2.4, 0.15, 1, -0.003], [0, 2.6, 0.2, 1, 0.0],
		[1, 3.0, 0.2, 1, 0.0003]]

var main: Main
var hmd
var frames := 0
var place: Array


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	place = PLACES[int(args[1])]
	hmd = U.headset(1, place[4], Vector2i(640, 640))
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "FakeHMD"
	main.show_check = false
	main.toys.enabled = false            # this test draws its own
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 3:
		main.menu.visible = false
		main.renderer.show_scene(false)
		main.place(Vector3(place[0].x, place[0].y, 0.0), Vector3(place[1].x, place[1].y, 0.0))
		var v: Viewer = main.viewer
		var fwd := main._head_forward_xz()
		for d: Vector3 in place[2]:
			v.take_off()
			v.move(WormholeSpace.combine(v.frame, Vector3(-d.x * fwd.y - d.z * fwd.x, d.y, d.x * fwd.x - d.z * fwd.y)))
		v.turn(deg_to_rad(place[3]))
		if not place[2].is_empty():
			var hp := v.head(hmd.head.origin.y)
			print("flying: the head at l %.2f, %.2f m over the floor" % [hp[0], main.space.height(hp[0], hp[1])])
		main.hold = true
	if frames == 5:
		_bodies()
	if frames == 6 and _fov():
		# after main's first frames, which set each kind of foveation in turn
		main.foveation.set_level(Menu.DEFAULT_FOVEATION)
		print("foveation ", main.foveation.level)
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
	# on the axis, a little off it (the line still through them)
	var hl: float = hp[0]
	var hn: Vector3 = hp[1]
	var side := signf(hl)
	var off := _normal_to(hn) * 0.02
	var ab := sp.embed(hl - side * AXIS_BALL[0], (hn + off).normalized())
	pos.append(ab)
	col.append(Vector4(4.0, 0.0, 0.0, AXIS_BALL[1]))
	var al: float = hl - side * AXIS_CUBE[0]
	var an := (hn - off).normalized()
	var ae1 := _normal_to(an)
	var ae2 := an.cross(ae1)
	var aa: float = AXIS_CUBE[2]
	axes.append(sp.embed_vector(al, an, Vector4(0.0, cos(aa) * ae1.x + sin(aa) * ae2.x, cos(aa) * ae1.y + sin(aa) * ae2.y, cos(aa) * ae1.z + sin(aa) * ae2.z)).normalized())
	axes.append(sp.embed_vector(al, an, Vector4(0.6, 0.8 * (-sin(aa) * ae1.x + cos(aa) * ae2.x), 0.8 * (-sin(aa) * ae1.y + cos(aa) * ae2.y), 0.8 * (-sin(aa) * ae1.z + cos(aa) * ae2.z))).normalized())
	cpos.append(sp.embed(al, an))
	ccol.append(Vector4(0.0, 4.0, 0.0, AXIS_CUBE[1]))
	for c: Array in NEAR_AXIS_CUBES:
		_near_axis_cube(sp, hp, head, c, cpos, axes, ccol)
	for b: Array in WORLD_BALLS + ([EDGE_BALL] if _fov() else []):
		pos.append(sp.embed(b[0], (b[1] as Vector3).normalized()))
		col.append(Vector4(4.0, 0.0, 0.0, b[2]))
	for c: Array in WORLD_CUBES:
		var n: Vector3 = (c[1] as Vector3).normalized()
		var C := sp.embed(c[0], n)
		var e1 := _normal_to(n)
		var e2 := n.cross(e1)
		var a: float = c[3]
		for ax in [cos(a) * e1 + sin(a) * e2, -sin(a) * e1 + cos(a) * e2]:
			axes.append(sp.embed_vector(c[0], n, Vector4(0.0, ax.x, ax.y, ax.z)).normalized())
		cpos.append(C)
		ccol.append(Vector4(0.0, 4.0, 0.0, c[2]))
	main.toys.enabled = false
	main.renderer.set_objects(pos, col, cpos, axes, ccol)
	_objects = [pos, col, cpos, axes, ccol]


var _objects := []


static func _fov() -> bool:
	return OS.get_cmdline_user_args().has("fov")


## A cube next to eye c[0]'s axis (NEAR_AXIS_CUBES): its centre c[1] toward the throat's centre from
## the eye, moved off the axis so that its edge across the axis (c[3] 0: the edge along the first
## axis, the other two at 45 degrees to the axis) or its corner (1: the body diagonal across it)
## is c[4] from it.
func _near_axis_cube(sp: WormholeSpace, hp: Array, head: Transform3D, c: Array, cpos: PackedVector4Array,
		axes: PackedVector4Array, ccol: PackedVector4Array) -> void:
	var eye := _walk(sp, hp, head.basis * (hmd.eyes[c[0]] as Transform3D).origin)
	var el: float = eye[0]
	var en: Vector3 = eye[1]
	var side := signf(el)
	var half: float = c[2]
	var al: float = el - side * float(c[1])
	var reach: float = half * (sqrt(2.0) if c[3] == 0 else sqrt(3.0))
	var e1 := _normal_to(en)
	var nc := (en * cos((reach + c[4]) / sp.r(al)) + e1 * sin((reach + c[4]) / sp.r(al))).normalized()
	# at the centre: along l, away from the axis, across both
	var a := (e1 - e1.dot(nc) * nc).normalized()
	var b := nc.cross(a)
	var L := Vector4(1.0, 0.0, 0.0, 0.0)
	var A := Vector4(0.0, a.x, a.y, a.z)
	var B := Vector4(0.0, b.x, b.y, b.z)
	var ax: Array
	if c[3] == 0:
		ax = [B, (L + A) / sqrt(2.0)]           # the edge along B at -half (both others): toward -A
	else:
		# three axes whose sum is along A: the corner at -half (all three) toward -A
		ax = []
		for k in 2:
			var ph := TAU * k / 3.0
			ax.append(A / sqrt(3.0) + sqrt(2.0 / 3.0) * (cos(ph) * L + sin(ph) * B))
	for x: Vector4 in ax:
		axes.append(sp.embed_vector(al, nc, x).normalized())
	cpos.append(sp.embed(al, nc))
	ccol.append(Vector4(0.0, 4.0, 0.0, half))


static func _normal_to(n: Vector3) -> Vector3:
	return (Vector3(0.0, 0.0, 1.0) if absf(n.z) < 0.9 else Vector3(1.0, 0.0, 0.0)).cross(n).normalized()


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
	var d := {"profile": [sp.rho0, sp.h, sp.fillet], "lift": sp.lift, "size": [hmd.size.x, hmd.size.y],
		"head": {"l": hp[0], "n": _v3(hp[1]), "frame": [_v4(f[0]), _v4(f[1]), _v4(f[2])],
			"pos": _v3(main.camera.transform.origin)},
		"eyes": eyes, "balls": [], "cubes": [],
		"fovea": Array(main.foveation.fovea) if main.foveation.level > 0 else []}
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
