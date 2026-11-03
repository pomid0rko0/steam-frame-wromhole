class_name Toys
extends RefCounted
## The demo's balls and cubes: the physics is BallWorld's, this sets the scene, laid out for the
## view from main.START_POS (facing the wormhole, its mouth hanging over the floor ahead). At rest:
## balls and cubes on universe A's floor in front of the mouth and under it, and in universe B a ball
## on the line of sight from the start through the throat's centre (ring_point) with a cube beside
## it. A ball rests on the floor only where gravity pushes along it less than rolling friction holds
## (BallWorld.ROLLING_RESISTANCE: under the mouth only right under the throat's centre), a cube
## anywhere. A moment after the start a cube and a ball are thrown from chest height: the cube lands
## in front of the mouth and slides to a stop, the ball flies up into the mouth, through the throat,
## and comes out in universe B, where it lands on the floor. Then a ball is dropped into the throat's
## top (drop_place). The reset (main._turns_and_reset) puts it all back and does it again. Places are in
## charts (WormholeSpace's top: the floor at z = 0) and keep out of the curved zone and scene.json's
## objects.
##
## The line of sight from the head at the start (HEAD_HEIGHT over START_POS) through the throat's
## centre is a radial geodesic: it goes on in universe B at the same direction n from the centre,
## which chart B shows mirrored in x, and comes down to B's floor in front of B's mouth. A ball with
## its centre on it is seen from the start in the middle of the throat and again, all round, as rings
## (light that goes round the throat once, twice, ... on its way: every plane through that line holds
## such a path); the cube beside it, off the line, as two arcs on opposite sides.
##
## The drop: along the axis over the throat's centre the potential is even in l (docs/gravity.md,
## «Сквозь горло»): dropped straight there, a ball falls through the throat into universe B, rises over
## B's mouth as high as it fell from, falls back and so on, A and B by turns. That way is unstable
## across: the drop is DROP_OFF off it, and the ball, through to B and rising there, tips off the throat's
## top and falls past B's mouth onto B's floor, and the floor's push rolls it away from under the
## mouth (tests/physics_test.gd, 7).
##
## The throw and the drop are aimed at the throat's shape (main.set_shape: the toys start over then):
## the ball's flight, as without air, passes over the throat's centre at THROW_AIM times its radius,
## the drop starts DROP_OVER over the curved zone. At the video's throat (main.SHAPE) that is what
## tests/physics_test.gd checks.

const BALL_COLORS := [Color(0.92, 0.25, 0.2), Color(0.2, 0.6, 0.95), Color(0.98, 0.8, 0.2),
		Color(0.3, 0.85, 0.4), Color(0.75, 0.35, 0.9), Color(0.95, 0.55, 0.15)]
const CUBE_COLORS := [Color(0.93, 0.93, 0.88), Color(0.95, 0.45, 0.55), Color(0.35, 0.8, 0.75),
		Color(0.95, 0.7, 0.3), Color(0.55, 0.6, 0.95), Color(0.6, 0.85, 0.35)]
const GLOW := Color(1.0, 0.55, 0.1)     # a toy a hand aims at or pulls is drawn toward this (glow)
const GLOW_NEAR := Color(0.2, 0.85, 1.0)  # or toward this, if its own colour is near GLOW
const LAUNCH_DELAY := 1.5       # s after the start or a reset: the throw
const DROP_DELAY := 6.5         # and the drop, late enough that the throw knocks nothing dropped (tests/physics_test.gd, 7)
const DROP_OVER := 1.5         # m over the curved zone's top (chart A), DROP_OFF along y off the throat's axis
const DROP_OFF := -0.2          # m
const DROP_RADIUS := 0.35       # m
const DROP_COLOR := Color(0.95, 0.95, 0.97)
# at rest, chart A: balls [x, y, radius] (in front, 8.5 m off the point under the throat's centre,
# and right under it), cubes [x, y, half size, yaw]
const BALLS_A := [[8.4, -1.5, 0.25], [8.4, 1.5, 0.25], [0.0, 0.0, 0.35]]
const CUBES_A := [[5.5, 2.4, 0.3, 0.35], [3.0, -2.2, 0.3, -0.5], [-2.0, 1.8, 0.25, 0.8]]
# the throw from chest height in front of the start (chart A): the cube [where, velocity, its spin
# (rad/s, its axes), half size, a turn of its axes (euler)], the ball [where, radius] and its flight
# THROW_TIME s to the plane over the throat's centre (x = 0), there THROW_AIM throat radii off the
# centre (chart y, z), as without air
const THROW_CUBE := [Vector3(9.0, -1.9, 1.4), Vector3(-2.8, -0.55, 1.0), Vector3(2.5, -3.0, 1.5), 0.25, Vector3(0.4, 0.3, 0.2)]
const THROW_BALL := [Vector3(9.0, -2.0, 1.4), 0.25]
const THROW_TIME := 0.9         # s
const THROW_AIM := Vector2(0.4, 0.3)
const HEAD_HEIGHT := 1.6        # m: the head at the start, for the line of sight through the throat
const RING_RADIUS := 0.4        # m: the ball on that line in universe B
const RING_CUBE_Y := 1.3        # m: the cube beside it, along chart B's y,
const RING_CUBE_HALF := 0.3     # and its half size

var space: WormholeSpace
var world: BallWorld
var enabled := true             # simulate and draw them
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
	for i in BALLS_A.size():
		var b: Array = BALLS_A[i]
		ball_on_floor(1.0, Vector2(b[0], b[1]), b[2], BALL_COLORS[i % BALL_COLORS.size()])
	for i in CUBES_A.size():
		var c: Array = CUBES_A[i]
		cube_on_floor(1.0, Vector2(c[0], c[1]), c[2], c[3], CUBE_COLORS[[0, 2, 5][i]])
	var ring := ring_point()
	ball_on_floor(-1.0, Vector2(ring.x, ring.y), RING_RADIUS, BALL_COLORS[3])
	cube_on_floor(-1.0, Vector2(ring.x, RING_CUBE_Y), RING_CUBE_HALF, 0.3, CUBE_COLORS[3])
	launch_in = LAUNCH_DELAY if demo else -1.0
	drop_in = DROP_DELAY if demo else -1.0


## Where the line of sight from the head at the start through the throat's centre is RING_RADIUS
## over universe B's floor (this file's top): chart B.
func ring_point() -> Vector3:
	var eye := Main.START_POS + Vector3(0.0, 0.0, HEAD_HEIGHT)
	var n: Vector3 = space.point_from_chart(1.0, eye)[1]
	# on from the centre along n in universe B: chart B height lift + r n.z
	var r := (RING_RADIUS - space.lift) / n.z
	return space.chart_position(-(r - space.Rout + space.L), n)


## The throw and the drop when due, then the physics (hands: the hands' balls, which push).
func step(delta: float, hands: Array[BallWorld.Ball]) -> void:
	if launch_in >= 0.0:
		launch_in -= delta
		if launch_in < 0.0:
			throw()
	if drop_in >= 0.0:
		drop_in -= delta
		if drop_in < 0.0:
			drop()
	world.step(delta, hands)


## From chest height in front of the start: a tumbling cube that lands in front of the mouth and
## slides to a stop, and a ball, from the left, up into the mouth and through the throat (this
## file's top).
func throw() -> Array[BallWorld.Body]:
	var p := space.point_from_chart(1.0, THROW_CUBE[0])
	var b := Basis.from_euler(THROW_CUBE[4])
	var F := []
	for ax in [b.x, b.y, b.z]:
		F.append(WormholeSpace.vector_from_chart(1.0, p[1], ax))
	var cube := world.add_cube(p[0], p[1], WormholeSpace.vector_from_chart(1.0, p[1], THROW_CUBE[1]),
			F, THROW_CUBE[2], THROW_CUBE[3], CUBE_COLORS[1])
	var from: Vector3 = THROW_BALL[0]
	var aim := Vector3(0.0, THROW_AIM.x * space.rho0, space.lift + THROW_AIM.y * space.rho0)
	var v := (aim - from) / THROW_TIME + Vector3(0.0, 0.0, 0.5 * BallWorld.GRAVITY * THROW_TIME)
	var q := space.point_from_chart(1.0, from)
	var ball := world.add(q[0], q[1], WormholeSpace.vector_from_chart(1.0, q[1], v), THROW_BALL[1], BALL_COLORS[5])
	print("toys: thrown")
	var out: Array[BallWorld.Body] = [cube, ball]
	return out


## Where the throw's cube and ball start (chart A) and how far they reach (a cube's half diagonal, a
## ball's radius): out of the curved zone at every shape (tests/shape_test.gd).
static func throw_starts() -> Array:
	return [[THROW_CUBE[0], THROW_CUBE[3] * sqrt(3.0)], [THROW_BALL[0], THROW_BALL[1]]]


## A white ball let go over the throat's top (this file's top).
func drop() -> BallWorld.Ball:
	var p := space.point_from_chart(1.0, drop_place())
	print("toys: a ball dropped into the throat's top")
	return world.add(p[0], p[1], Vector4.ZERO, DROP_RADIUS, DROP_COLOR)


## Where the drop starts, chart A: DROP_OVER over the curved zone's top, DROP_OFF off its axis.
func drop_place() -> Vector3:
	return Vector3(0.0, DROP_OFF, space.lift + space.Rout + DROP_OVER)


## A ball at rest on the floor of universe side at chart position pos.
func ball_on_floor(side: float, pos: Vector2, radius: float, color: Color) -> BallWorld.Ball:
	var p := space.point_from_chart(side, Vector3(pos.x, pos.y, radius))
	return world.add(p[0], p[1], Vector4.ZERO, radius, color)


## A cube resting on the floor of universe side at chart position pos, turned by yaw.
func cube_on_floor(side: float, pos: Vector2, half: float, yaw: float, color: Color) -> BallWorld.Cube:
	var p := space.point_from_chart(side, Vector3(pos.x, pos.y, half))
	var F := []
	for ax in [Vector3(cos(yaw), sin(yaw), 0.0), Vector3(-sin(yaw), cos(yaw), 0.0), Vector3(0.0, 0.0, 1.0)]:
		F.append(WormholeSpace.vector_from_chart(side, p[1], ax))
	return world.add_cube(p[0], p[1], Vector4.ZERO, F, Vector3.ZERO, half, color)


## The balls and cubes (those in lit, Hands.lit, glowing), the hands' balls (hands: [centre, colour
## with the radius]) and the speed check's cube (extra: Bench.near_cube's, or []), to the renderer
## (Renderer.set_objects).
func draw(renderer: Renderer, hands: Array, extra := [], lit := {}) -> void:
	var pos := PackedVector4Array()
	var col := PackedVector4Array()
	for b in world.balls:
		var c := glow(b.color, lit[b]) if lit.has(b) else b.color
		pos.append(space.embed(b.l, b.n))
		col.append(Vector4(c.r, c.g, c.b, b.radius))
	for h in hands:
		pos.append(h[0])
		col.append(h[1])
	var cpos := PackedVector4Array()
	var axes := PackedVector4Array()
	var ccol := PackedVector4Array()
	for c in world.cubes:
		var box := world.box4(c)
		var k := glow(c.color, lit[c]) if lit.has(c) else c.color
		cpos.append(box[0])
		axes.append(box[1])
		axes.append(box[2])
		ccol.append(Vector4(k.r, k.g, k.b, c.half))
	if not extra.is_empty():
		cpos.append(extra[0])
		axes.append(extra[1])
		axes.append(extra[2])
		ccol.append(extra[3])
	renderer.set_objects(pos, col, cpos, axes, ccol)


## Colour c a fraction k of the way to GLOW (GLOW_NEAR for a colour near it): a toy aimed at.
static func glow(c: Color, k: float) -> Color:
	var near := Vector3(c.r - GLOW.r, c.g - GLOW.g, c.b - GLOW.b).length() < 0.5
	return c.lerp(GLOW_NEAR if near else GLOW, k)
