class_name Toys
extends RefCounted
## The demo's balls and cubes (docs/physics.md, «Мячи и кубы»): the physics is BallWorld's, this sets the
## scene. At rest in front of the wormhole: five balls and two cubes, a third cube in the throat. A
## moment after the start a cube and a ball are thrown from chest height; the ball rolls through
## the throat into universe B. Then two balls are dropped together from the same height: one beside
## the wormhole, one in the middle of the throat, where gravity is about a fifth. A puts it all
## back and does it again.

const BALL_COLORS := [Color(0.92, 0.25, 0.2), Color(0.2, 0.6, 0.95), Color(0.98, 0.8, 0.2),
		Color(0.3, 0.85, 0.4), Color(0.75, 0.35, 0.9), Color(0.95, 0.55, 0.15)]
const CUBE_COLORS := [Color(0.93, 0.93, 0.88), Color(0.95, 0.45, 0.55), Color(0.35, 0.8, 0.75),
		Color(0.95, 0.7, 0.3), Color(0.55, 0.6, 0.95), Color(0.6, 0.85, 0.35)]
const LAUNCH_DELAY := 1.5       # s after the start or a reset: the throw
const DROP_DELAY := 6.5         # and the drop, after the thrown ball has rolled through the throat
const DROP_HEIGHT := 2.0
const DROP_COLOR := Color(0.95, 0.95, 0.97)
const DROP_SPOT_A := Vector3(4.5, 4.2, DROP_HEIGHT)   # to the right of the wormhole
const DROP_RADIUS := 0.35

var space: WormholeSpace
var world: BallWorld
var enabled := true             # simulate and draw them; the stereo check and tests that draw their own turn it off
var demo := true                # the throw and the drop after the start and each reset
var launch_in := -1.0           # s until the throw; < 0: none pending
var drop_in := -1.0             # s until the drop; < 0: none pending


func _init(p_space: WormholeSpace, scene: Dictionary) -> void:
	space = p_space
	world = BallWorld.new(space, scene)


## Everything back in place: the balls and cubes at rest, the throw LAUNCH_DELAY s later, the
## drop DROP_DELAY s later.
func spawn() -> void:
	world.balls.clear()
	world.cubes.clear()
	var spots := [Vector2(7.0, -1.5), Vector2(7.0, 0.0), Vector2(7.0, 1.5), Vector2(6.0, -0.75), Vector2(6.0, 0.75)]
	for i in spots.size():
		var rad := 0.25 if i < 3 else 0.35
		var p := space.point_from_chart(1.0, Vector3(spots[i].x, spots[i].y, rad))
		world.add(p[0], p[1], Vector4.ZERO, rad, BALL_COLORS[i % BALL_COLORS.size()])
	cube_on_floor(Vector2(5.4, -2.5), 0.3, 0.35, CUBE_COLORS[0])
	cube_on_floor(Vector2(6.2, 3.6), 0.25, -0.5, CUBE_COLORS[2])
	cube_in_throat(0.8, -0.45, 0.3, CUBE_COLORS[5])
	launch_in = LAUNCH_DELAY if demo else -1.0
	drop_in = DROP_DELAY if demo else -1.0


## The throw and the drop when due, then the physics (hands: the hands' balls, which push).
func step(delta: float, hands: Array) -> void:
	if launch_in >= 0.0:
		launch_in -= delta
		if launch_in < 0.0:
			throw()
	if drop_in >= 0.0:
		drop_in -= delta
		if drop_in < 0.0:
			drop()
	world.step(delta, hands)


## From chest height in front of the start: a tumbling cube that lands to the left of the balls
## and slides to a stop, and a ball that bounces, rolls on and goes through to universe B.
func throw() -> void:
	var p := space.point_from_chart(1.0, Vector3(9.0, -1.9, 1.4))
	var b := Basis.from_euler(Vector3(0.4, 0.3, 0.2))
	var F := []
	for ax in [b.x, b.y, b.z]:
		F.append(WormholeSpace.vector_from_chart(1.0, p[1], ax))
	world.add_cube(p[0], p[1], WormholeSpace.vector_from_chart(1.0, p[1], Vector3(-2.8, -0.55, 1.0)),
			F, Vector3(2.5, -3.0, 1.5), 0.25, CUBE_COLORS[1])
	var q := space.point_from_chart(1.0, Vector3(9.0, 2.4, 1.4))
	# fast enough to climb out of the throat's well into B against the rolling and the air's drag
	world.add(q[0], q[1], WormholeSpace.vector_from_chart(1.0, q[1], Vector3(-5.4, -0.36, 1.8)), 0.25, BALL_COLORS[5])
	print("toys: thrown")


## Two white balls let go at the same moment from the same height: one beside the wormhole,
## where gravity is ordinary, and one in the middle of the throat, where it is about a fifth of
## that. The second is straight ahead in the throat (azimuth 0): from the start it is seen in the
## middle of the wormhole against universe B's sky, and falls and bounces in slow motion.
func drop() -> void:
	var p := space.point_from_chart(1.0, DROP_SPOT_A)
	world.add(p[0], p[1], Vector4.ZERO, DROP_RADIUS, DROP_COLOR)
	world.add(0.0, throat_point(0.0, DROP_HEIGHT), Vector4.ZERO, DROP_RADIUS, DROP_COLOR)
	print("toys: two balls dropped")


## The direction n at height H = r(0) n.z above the floor in the middle of the throat, at azimuth phi.
func throat_point(phi: float, height: float) -> Vector3:
	var z := height / space.r(0.0)
	return Vector3(cos(phi) * sqrt(1.0 - z * z), sin(phi) * sqrt(1.0 - z * z), z)


## A cube resting on the floor of universe A at chart position pos, turned by yaw.
func cube_on_floor(pos: Vector2, half: float, yaw: float, color: Color) -> Dictionary:
	var p := space.point_from_chart(1.0, Vector3(pos.x, pos.y, half))
	var F := []
	for ax in [Vector3(cos(yaw), sin(yaw), 0.0), Vector3(-sin(yaw), cos(yaw), 0.0), Vector3(0.0, 0.0, 1.0)]:
		F.append(WormholeSpace.vector_from_chart(1.0, p[1], ax))
	return world.add_cube(p[0], p[1], Vector4.ZERO, F, Vector3.ZERO, half, color)


## A cube resting on the floor inside the throat, at l and azimuth phi.
func cube_in_throat(l: float, phi: float, half: float, color: Color) -> Dictionary:
	var z := half / space.r(l)
	var n := Vector3(cos(phi) * sqrt(1.0 - z * z), sin(phi) * sqrt(1.0 - z * z), z)
	var up := space.height_grad(l, n).normalized()
	var across := WormholeSpace.tangent(n, Vector4(0.0, -sin(phi), cos(phi), 0.0))
	return world.add_cube(l, n, Vector4.ZERO, [Vector4(1.0, 0.0, 0.0, 0.0), up, across], Vector3.ZERO, half, color)


## The balls and cubes to the ray tracer (Tracer.set_objects): a ball's centre as a point of R^4
## and its radius, then the hands' balls (hands: [centre, colour with the radius]); a cube's 4D box
## (centre, four axes over the half size) and colour.
func draw(tracer: Tracer, hands: Array) -> void:
	var pos := PackedVector4Array()
	var col := PackedVector4Array()
	for b in world.balls:
		pos.append(space.embed(b["l"], b["n"]))
		var c: Color = b["color"]
		col.append(Vector4(c.r, c.g, c.b, b["radius"]))
	for h in hands:
		pos.append(h[0])
		col.append(h[1])
	var cpos := PackedVector4Array()
	var axes := PackedVector4Array()
	var ccol := PackedVector4Array()
	for c in world.cubes:
		var box := world.box4(c)
		var half: float = c["half"]
		cpos.append(box[0])
		for k in 4:
			axes.append(box[1 + k] / half)
		var cc: Color = c["color"]
		ccol.append(Vector4(cc.r, cc.g, cc.b, half))
	tracer.set_objects(pos, col, cpos, axes, ccol)
