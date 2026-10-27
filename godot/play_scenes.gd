class_name PlayScenes
## Scenes of play where the headset found frames dear, for the speed check (bench.gd) and the cost
## model (tests/emu_dump.gd): the viewer at a pose (main.place_on_axis), the demo's toys at rest,
## some of them moved to where they were when the frames were late. Toys a scene adds are tagged
## "scene" (take_away removes them); the demo's cubes a scene moves come back with main's reset.
##
## SCENES: [name, words for the panel, l, degrees right of the throat, degrees up, what is placed]
##   none          the demo at rest where it lies
##   edge_cubes    the demo's cubes on the floor in front, along the shell's edge (the owner's log:
##                 standing on the fillet at l 4.6, looking along it at the cubes set down there,
##                 72 Hz did not hold)
##   held_cubes    the two big cubes in the hands in front of the chest, both hands' balls
##   held_ball     a big ball held at the chest and both hands' balls
const SCENES := [
	["start", "старт", 11.6, 0.0, 0.0, "none"],
	["edge facing the throat", "край, на горло", 5.0, 0.0, 0.0, "none"],
	["outside the edge facing the throat", "снаружи края, на горло", 6.2, 0.0, 0.0, "none"],
	["the throat sideways", "горло вбок", 0.0, 90.0, 0.0, "none"],
	["world B outside the edge", "мир B у края", -5.7, 160.0, -5.0, "none"],
	["cubes on the floor at the edge", "кубы на полу у края", 4.6, 80.0, -30.0, "edge_cubes"],
	["cubes at the edge, looking along", "кубы у края, взгляд вдоль", 4.6, 80.0, -5.0, "edge_cubes"],
	["two cubes in the hands at the edge", "два куба в руках у края", 4.6, 80.0, -5.0, "held_cubes"],
	["a ball in the hand at the edge", "мяч в руке у края", 5.0, 0.0, 0.0, "held_ball"],
]
# the hands' balls and what they hold, from the head in the room's axes: [offset, radius]
const HANDS := [[Vector3(0.22, -0.35, -0.3), 0.04], [Vector3(-0.22, -0.35, -0.3), 0.04]]
const HELD_BALL := [Vector3(0.22, -0.35, -0.6), 0.25]
# the cubes in the hands: [offset of the centre from the head, half size]
const HELD_CUBES := [[Vector3(0.33, -0.3, -0.8), 0.3], [Vector3(-0.33, -0.3, -0.8), 0.3]]
# m along the floor in front of the feet where the demo's cubes lie in edge_cubes, nearest first
const EDGE_CUBES := [0.9, 1.6, 2.3, 3.0]


## Place scene i (an index into SCENES, or a name of what is placed): the viewer and the toys.
static func place(main: Node, what: String, l: float, yaw: float, pitch: float) -> void:
	take_away(main)
	main.place_on_axis(l, yaw, pitch)
	var w: BallWorld = main.world
	if w == null:
		return
	match what:
		"edge_cubes":
			_cubes_ahead(main)
		"held_cubes":
			_cubes_ahead(main)
			for k in HELD_CUBES.size():
				_near_cube(main, HELD_CUBES[k][0], HELD_CUBES[k][1], k)
			for t in HANDS:
				_near_ball(main, t[0], t[1])
		"held_ball":
			_near_ball(main, HELD_BALL[0], HELD_BALL[1])
			for t in HANDS:
				_near_ball(main, t[0], t[1])
	main._upload_toys()


## Remove what a scene added (the demo's cubes it moved stay where it put them).
static func take_away(main: Node) -> void:
	var w: BallWorld = main.world
	if w == null:
		return
	w.balls = w.balls.filter(func(b: Dictionary) -> bool: return not b.has("scene"))
	w.cubes = w.cubes.filter(func(c: Dictionary) -> bool: return not c.has("scene"))


## The head's place and frame now (as main._update_hands has them).
static func _head(main: Node) -> Array:
	var sp: WormholeSpace = main.space
	var head: Vector3 = main.camera.transform.origin
	return sp.geodesic(main.foot_l, main.foot_n, main.frame[1], maxf(head.y, 0.05), main.frame,
			WormholeSpace.STEP_FRAME)


## Where an offset from the head in the room's axes lands: [l, n, frame].
static func _from_head(main: Node, off: Vector3) -> Array:
	var sp: WormholeSpace = main.space
	var hp := _head(main)
	var dir := WormholeSpace.combine(hp[2], off)
	return sp.geodesic(hp[0], hp[1], dir / dir.length(), dir.length(), hp[2], WormholeSpace.STEP_FRAME)


static func _near_ball(main: Node, off: Vector3, radius: float) -> void:
	var at := _from_head(main, off)
	var b: Dictionary = main.world.add(at[0], at[1], Vector4.ZERO, radius, Color(0.95, 0.95, 0.97))
	b["scene"] = true


static func _near_cube(main: Node, off: Vector3, half: float, k: int) -> void:
	var at := _from_head(main, off)
	var F: Array = at[2]
	var c: Dictionary = main.world.add_cube(at[0], at[1], Vector4.ZERO, [F[0], F[1], F[2]], Vector3.ZERO, half,
			main.CUBE_COLORS[(2 * k + 1) % main.CUBE_COLORS.size()])
	c["scene"] = true


## The demo's cubes moved onto the floor in front of the feet, along the view (EDGE_CUBES), each
## resting there, its sides along and across the radius.
static func _cubes_ahead(main: Node) -> void:
	var sp: WormholeSpace = main.space
	var w: BallWorld = main.world
	var f: Vector3 = -main.camera.transform.basis.z
	var d := Vector3(f.x, 0.0, f.z).normalized()
	var dir := WormholeSpace.combine(main.frame, d)
	var old := w.cubes.duplicate()
	w.cubes = w.cubes.filter(func(c: Dictionary) -> bool: return c.has("scene"))
	for k in mini(old.size(), EDGE_CUBES.size()):
		var c: Dictionary = old[k]
		var at: Array = sp.geodesic(main.foot_l, main.foot_n, dir, EDGE_CUBES[k], main.frame, WormholeSpace.STEP_FRAME)
		var n: Vector3 = at[1]
		main._cube_in_throat(at[0], atan2(n.y, n.x), c["half"], c["color"])
