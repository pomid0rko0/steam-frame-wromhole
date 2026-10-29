class_name BallWorld
extends RefCounted
## Balls and cubes moving through the wormhole space.
##
## A ball is a point (l, n) with velocity U = (U_l, u) and a radius. Free motion follows
## geodesics (zero redshift: no gravity from the metric itself) plus gravity, -g grad phi
## (docs/gravity.md; WormholeSpace.potential).
## Collisions use chord distances in R^4, the same definition of a
## ball the shader renders: the points within `radius` of the centre, measured in R^4.
##
## A cube is a 4D box of R^4 cut by the hypersurface, as a box would be in a 4D SDF scene:
## centre C = embed(l, n), axes E1..E3 = its body axes F (tangent vectors, embedded) and
## E4 = the hypersurface normal at C, half size `half` along each. In a flat universe this is
## an ordinary cube. The body axes are parallel-transported with the centre and turn with the
## angular velocity w (body coordinates). Contacts are solved in the tangent space at the
## cube's centre: corners against the floor, with sliding friction, so a cube slides and stops
## instead of rolling; boxes against balls, other cubes and the static objects.

const GRAVITY := 9.81
const DT := 1.0 / 180.0
const RESTITUTION_FLOOR := 0.55
const RESTITUTION_BALL := 0.85
# Rolling friction: a small part that follows the weight, and a part that follows the speed; air
# drag on top. A ball at rest stays where the floor pulls along itself less than ROLLING_RESISTANCE
# times its weight there;
# near the wormhole gravity pulls along the floor toward the throat, so a ball set down at the
# curved zone's edge rolls in by itself (tests/physics_test.gd). A larger part that follows the
# weight would hold such a ball still; a smaller one would let a thrown ball roll very far: the
# part that follows the speed stops it. Air drag (as the square of the speed) slows fast balls, in
# flight too, but hardly a slow roll.
const ROLLING_RESISTANCE := 0.005
const ROLLING_DRAG := 0.1            # 1/s: the deceleration per m/s of rolling speed
const AIR_DENSITY := 1.2             # kg/m^3
const TOY_DENSITY := 25.0            # kg/m^3: big rubber toys (a 50 cm ball 1.6 kg); masses go as size^3
const DRAG_BALL := 0.47              # drag coefficients of a sphere and of a cube
const DRAG_CUBE := 1.05
const MAX_BALLS := 8
const WORLD_RADIUS := 40.0           # chart radius of an invisible wall that keeps balls and cubes nearby
const MAX_CUBES := 6
const RESTITUTION_CUBE := 0.15       # cubes land with a small bounce
const FRICTION_CUBE := 0.5           # sliding friction: a sliding cube decelerates by this times the floor's push
const BOUNCE_SPEED := 0.4            # m/s: slower cube impacts do not bounce (no endless micro-bounces)
const ITERATIONS := 6                # velocity iterations of the contact solver
const KINEMATIC := 1e9               # a held ball's mass against a free one (_pair; hands push without one: _push)
# a hand or a held ball against a free ball (_push, _pair): it moves on regardless, so with
# RESTITUTION_BALL a ball it meets would fly off at 1 + RESTITUTION_BALL times the hand's speed, and one
# pressed against the floor or another ball would gain speed from nothing; this is a soft hand's
const RESTITUTION_KINEMATIC := 0.3

var space: WormholeSpace
var scene: Dictionary
var air := true                      # air drag (tests of the motion itself turn it off)
var balls: Array[Ball] = []
var cubes: Array[Cube] = []
var _acc := 0.0


## A ball, a cube or a hand at (l, n), with velocity U = (U_l, u).
class Body:
	var l := 0.0
	var n := Vector3.RIGHT
	var U := Vector4.ZERO
	var color := Color.WHITE
	# the tracker of the hand that places it: a toy it holds, or the hand's own ball. Such a body is
	# kinematic: it pushes the others and is not pushed back.
	var held := &""
	var ghost := &""                 # the hand that let it go, until they are apart (_ghosted)


class Ball extends Body:
	var radius := 0.0


class Cube extends Body:
	var F: Array = []                # 3 body axes (tangent vectors)
	var w := Vector3.ZERO            # angular velocity, body coordinates (rad/s)
	var half := 0.0                  # half the edge length
	var still := 0.0                 # s it has hardly moved: asleep past SLEEP_TIME


func _init(p_space: WormholeSpace, p_scene: Dictionary) -> void:
	space = p_space
	scene = p_scene


func add(l: float, n: Vector3, U: Vector4, radius: float, color: Color) -> Ball:
	if balls.size() >= MAX_BALLS:
		_drop_oldest(balls)
	var b := Ball.new()
	b.l = l
	b.n = n
	b.U = U
	b.radius = radius
	b.color = color
	balls.append(b)
	return b


## A cube centred at (l, n): body axes F (tangent vectors, made orthonormal), angular velocity
## w in body coordinates (rad/s), half the edge length.
func add_cube(l: float, n: Vector3, U: Vector4, F: Array, w: Vector3, half: float, color: Color) -> Cube:
	if cubes.size() >= MAX_CUBES:
		_drop_oldest(cubes)
	var axes := []
	for A: Vector4 in F:
		axes.append(WormholeSpace.tangent(n, A))
	var c := Cube.new()
	c.l = l
	c.n = n
	c.U = U
	c.F = WormholeSpace.orthonormalize(axes)
	c.w = w
	c.half = half
	c.color = color
	cubes.append(c)
	return c


## Makes room for a new ball or cube: the oldest one goes, unless a hand holds it.
static func _drop_oldest(list: Array) -> void:
	for i in list.size():
		if (list[i] as Body).held == &"":
			list.remove_at(i)
			return
	list.pop_front()


## How far the point P of R^4 is from the surface of a ball or a cube (chord distance; a ball's
## inside is negative, a cube's 0): what a hand reaches.
func distance_to(b: Body, P: Vector4) -> float:
	if b is Ball:
		return (P - space.embed(b.l, b.n)).length() - (b as Ball).radius
	var c := b as Cube
	var box := box4(c)
	var d: Vector4 = P - box[0]
	var a := c.half
	var q := Vector4(clampf(d.dot(box[1]), -a, a), clampf(d.dot(box[2]), -a, a),
			clampf(d.dot(box[3]), -a, a), clampf(d.dot(box[4]), -a, a))
	return (d - q.x * box[1] - q.y * box[2] - q.z * box[3] - q.w * box[4]).length()


## Advance by delta seconds with fixed substeps. hands: the hands' balls (Hands.balls). A held
## ball or cube is kinematic like them: the hand places it and sets its U (and w) before each step.
func step(delta: float, hands: Array[Ball]) -> void:
	_acc = minf(_acc + delta, 0.1)
	while _acc >= DT:
		_acc -= DT
		for b in balls:
			if b.held != &"":
				continue
			var before: Array = [b.l, b.n, b.U]
			var s := space.dynamics_step(b.l, b.n, b.U, DT, GRAVITY)
			b.l = s[0]
			b.n = s[1]
			b.U = _air(s[2], 3.0 * AIR_DENSITY * DRAG_BALL / (8.0 * TOY_DENSITY * b.radius))
			_floor(b, before)
			_statics(b)
		for c in cubes:
			if c.held == &"" and c.still <= SLEEP_TIME:
				_integrate_cube(c)
		for i in balls.size():
			for j in range(i + 1, balls.size()):
				_pair(balls[i], balls[j], RESTITUTION_BALL)
		for hand in hands:
			for b in balls:
				if b.held == &"":
					_push(b, hand)
		if not cubes.is_empty():
			_solve_cubes(hands)


## A step of air drag, -k |U| U (k: drag / mass per metre), integrated implicitly: stable at any speed.
func _air(U: Vector4, k: float) -> Vector4:
	return U / (1.0 + k * U.length() * DT) if air else U


## Bounce, rolling friction and the floor's push. before: [l, n, U] before this step's motion.
func _floor(b: Ball, before: Array) -> void:
	var H := space.height(b.l, b.n)
	var rad: float = b.radius
	if H >= rad:
		return
	var g := space.height_grad(b.l, b.n)
	var gl := g.length()
	var N := g / gl
	var U: Vector4 = b.U
	var vn := U.dot(N)
	if vn < 0.0:
		U -= (1.0 + RESTITUTION_FLOOR) * vn * N
		if absf(vn) < 0.6:
			U -= U.dot(N) * N               # settle instead of micro-bouncing
	var Ut := U - U.dot(N) * N
	var speed := Ut.length()
	if speed > 0.0:
		# rolling friction follows the weight on the floor, which is weaker in the throat
		var weight := GRAVITY * maxf(space.potential_grad(b.l, b.n).dot(N), 0.0)
		var stop := (ROLLING_RESISTANCE * weight + ROLLING_DRAG * speed) * DT
		if speed <= stop and before[2].length() < 1e-6:
			# at rest and held by friction: gravity pulls slightly along the floor near the
			# wormhole, so undo this step's motion instead of letting the ball creep
			b.l = before[0]
			b.n = before[1]
			b.U = Vector4.ZERO
			return
		U -= Ut * (minf(stop, speed) / speed)
	b.U = U
	_move(b, N, (rad - H) / gl)


func _statics(b: Ball) -> void:
	var l: float = b.l
	if absf(l) < space.L:
		return                               # static objects live in the flat universes only
	var side := signf(l)
	var x := space.chart_position(l, b.n)
	var rad: float = b.radius
	var normal := Vector3.ZERO
	var depth := 0.0
	var spheres: Array = scene["spheres_A"] if side > 0.0 else scene["spheres_B"]
	for s in spheres:
		var d := x - Vector3(s[0], s[1], s[2])
		var pen: float = s[3] + rad - d.length()
		if pen > depth:
			depth = pen
			normal = d.normalized()
	if side > 0.0:
		for p in scene["pillars_A"]:
			# closest point of a solid vertical cylinder (radius p[2], height p[3])
			var cxy := Vector2(x.x - p[0], x.y - p[1]).limit_length(p[2]) + Vector2(p[0], p[1])
			var q := Vector3(cxy.x, cxy.y, clampf(x.z, 0.0, p[3]))
			var d := x - q
			var pen: float = rad - d.length()
			if pen > depth and d.length() > 1e-6:
				depth = pen
				normal = d.normalized()
	else:
		for bx in scene["boxes_B"]:
			var c := Vector3(bx[0], bx[1], bx[2])
			var hs := Vector3(bx[3], bx[3], bx[3])
			var q := x.clamp(c - hs, c + hs)
			var d := x - q
			var pen: float = rad - d.length()
			if pen > depth and d.length() > 1e-6:
				depth = pen
				normal = d.normalized()
	var cr := x.length()
	if cr > WORLD_RADIUS - rad:
		var pen := cr - (WORLD_RADIUS - rad)
		if pen > depth:
			depth = pen
			normal = -x / cr
	if depth <= 0.0:
		return
	var N := WormholeSpace.vector_from_chart(side, b.n, normal)
	var U: Vector4 = b.U
	var vn := U.dot(N)
	if vn < 0.0:
		U -= (1.0 + RESTITUTION_BALL) * vn * N
	b.U = U
	_move(b, N, depth)


func _pair(a: Ball, b: Ball, e: float) -> void:
	var Ea := space.embed(a.l, a.n)
	var Eb := space.embed(b.l, b.n)
	var D := Eb - Ea
	var dist := D.length()
	var pen: float = a.radius + b.radius - dist
	if pen <= 0.0 or dist < 1e-6 or (a.held != &"" and b.held != &""):
		return                               # two held balls: the hands place both
	var Na := space.project(a.l, a.n, D).normalized()      # at a, toward b
	var Nb := space.project(b.l, b.n, -D).normalized()     # at b, toward a
	var ma: float = pow(a.radius, 3.0) if a.held == &"" else KINEMATIC
	var mb: float = pow(b.radius, 3.0) if b.held == &"" else KINEMATIC
	if a.held != &"" or b.held != &"":
		e = RESTITUTION_KINEMATIC
	var Ua: Vector4 = a.U
	var Ub: Vector4 = b.U
	var approach := Ua.dot(Na) + Ub.dot(Nb)
	if approach > 0.0:
		var j := (1.0 + e) * approach / (1.0 / ma + 1.0 / mb)
		a.U = Ua - (j / ma) * Na
		b.U = Ub - (j / mb) * Nb
	var wa := mb / (ma + mb)
	if a.held == &"":
		_move(a, -Na, pen * wa)
	if b.held == &"":
		_move(b, -Nb, pen * (1.0 - wa))


## A hand (kinematic sphere) pushing a free ball.
func _push(b: Ball, hand: Ball) -> void:
	if _ghosted(b, hand):
		return
	var Eb := space.embed(b.l, b.n)
	var Eh := space.embed(hand.l, hand.n)
	var D := Eb - Eh
	var dist := D.length()
	var pen: float = b.radius + hand.radius - dist
	if pen <= 0.0 or dist < 1e-6:
		return
	var Nb := space.project(b.l, b.n, D).normalized()      # at the ball, away from the hand
	var Nh := space.project(hand.l, hand.n, D).normalized()
	var Ub: Vector4 = b.U
	var rel: float = hand.U.dot(Nh) - Ub.dot(Nb)
	if rel > 0.0:
		b.U = Ub + (1.0 + RESTITUTION_KINEMATIC) * rel * Nb
	_move(b, Nb, pen)


## A toy just let go is not pushed by the hand that let it go until it is clear of the hand: the
## hand held it touching or inside, and set down gently it would be pushed away at once.
func _ghosted(b: Body, hand: Ball) -> bool:
	var g: StringName = b.ghost
	if g == &"" or g != hand.held:
		return false
	if distance_to(b, space.embed(hand.l, hand.n)) < hand.radius + 0.01:
		return true
	b.ghost = &""
	return false


func _move(b: Body, dir: Vector4, dist: float) -> void:
	if dist <= 0.0 or dir.length() < 1e-9:
		return
	var c := b as Cube
	var carried: Array = [b.U]
	if c:
		carried.append_array(c.F)
	var res: Array
	if dist < 0.005:
		res = space.nudge(b.l, b.n, dir.normalized() * dist, carried)
	else:
		res = space.geodesic(b.l, b.n, dir.normalized(), dist, carried)
	b.l = res[0]
	b.n = res[1]
	b.U = res[2][0]
	if c:
		c.F = WormholeSpace.orthonormalize(res[2].slice(1))


# ---------------------------------------------------------------- cubes

const SLOP := 0.0005                 # overlap left after the position correction (m)
const SLEEP_SPEED := 0.03            # below this speed (m/s) and spin (rad/s) for SLEEP_TIME (s)
const SLEEP_SPIN := 0.06             # a cube falls asleep
const SLEEP_TIME := 0.4
const CORNERS := [Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(-1, 1, -1), Vector3(1, 1, -1),
		Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(-1, 1, 1), Vector3(1, 1, 1)]
# corners and edge midpoints of the unit cube: the points tested against other boxes
const SAMPLES := [Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(-1, 1, -1), Vector3(1, 1, -1),
		Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(-1, 1, 1), Vector3(1, 1, 1),
		Vector3(0, -1, -1), Vector3(0, 1, -1), Vector3(0, -1, 1), Vector3(0, 1, 1),
		Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(-1, 0, 1), Vector3(1, 0, 1),
		Vector3(-1, -1, 0), Vector3(1, -1, 0), Vector3(-1, 1, 0), Vector3(1, 1, 0)]


## Same density as the balls (whose mass is radius^3).
static func cube_mass(c: Cube) -> float:
	return 6.0 / PI * pow(c.half, 3.0)


static func cube_inertia(c: Cube) -> float:
	return 2.0 / 3.0 * cube_mass(c) * c.half * c.half


## Body coordinates of a tangent vector at the cube's centre, and back.
static func to_body(F: Array, V: Vector4) -> Vector3:
	return Vector3(V.dot(F[0]), V.dot(F[1]), V.dot(F[2]))


static func from_body(F: Array, v: Vector3) -> Vector4:
	return v.x * F[0] + v.y * F[1] + v.z * F[2]


## The cube's box in R^4: [centre, E1, E2, E3, E4].
func box4(c: Cube) -> Array:
	var l: float = c.l
	var n: Vector3 = c.n
	var F: Array = c.F
	return [space.embed(l, n), space.embed_vector(l, n, F[0]), space.embed_vector(l, n, F[1]),
			space.embed_vector(l, n, F[2]), space.normal4(l, n)]


## Free motion: the centre moves as a ball does, the axes are transported along and turn by w.
func _integrate_cube(c: Cube) -> void:
	var s := space.dynamics_step(c.l, c.n, c.U, DT, GRAVITY, c.F)
	c.l = s[0]
	c.n = s[1]
	c.U = _air(s[2], AIR_DENSITY * DRAG_CUBE / (4.0 * TOY_DENSITY * c.half))
	var F: Array = s[3]
	var w: Vector3 = c.w
	var rate := w.length()
	if rate > 1e-9:
		var R := Basis(w / rate, rate * DT)
		F = [from_body(F, R.x), from_body(F, R.y), from_body(F, R.z)]
	c.F = WormholeSpace.orthonormalize(F)


## A contact pushes cube a along na at its point ra, and b (a ball, cube or hand; null for the
## floor and static objects) along nb at rb. Three directions: the normal, then two tangents
## for friction, carried over from a to b through R^4. Per direction the arms r x d in body
## coordinates and the effective inverse mass are kept, so the solver only takes dot products.
class Contact:
	var a: Cube
	var b: Body                          # null: the floor or a static object
	var bc: Cube                         # b if it is a cube, else null
	var da: Array[Vector4] = []
	var db: Array[Vector4] = []
	var arm_a: Array[Vector3] = []
	var arm_b: Array[Vector3] = []
	var k: Array[float] = []
	var ima := 0.0                       # inverse mass and inverse moment of inertia of a and b
	var iia := 0.0
	var imb := 0.0
	var iib := 0.0
	var pen := 0.0
	var mu := 0.0
	var target := 0.0
	var jn := 0.0
	var jt := Vector2.ZERO
	var group := ""

	func speed(i: int) -> float:
		var v := a.U.dot(da[i]) + a.w.dot(arm_a[i])
		if b:
			v += b.U.dot(db[i])
			if bc:
				v += bc.w.dot(arm_b[i])
		return v

	func push(i: int, j: float) -> void:
		if ima > 0.0:
			a.U += (j * ima) * da[i]
			a.w += (j * iia) * arm_a[i]
		if imb > 0.0:
			b.U += (j * imb) * db[i]
			if bc:
				bc.w += (j * iib) * arm_b[i]


## Inverse mass and inverse moment of inertia; 0 for the floor, statics, hands, held and
## sleeping things.
func _inverse_mass(b: Body) -> Vector2:
	if b == null or b.held != &"":
		return Vector2.ZERO
	if b is Cube:
		var c := b as Cube
		if c.still > SLEEP_TIME:
			return Vector2.ZERO
		return Vector2(1.0 / cube_mass(c), 1.0 / cube_inertia(c))
	return Vector2(1.0 / pow((b as Ball).radius, 3.0), 0.0)


## The unit normal na at a's centre and two unit tangents orthogonal to it:
## [as tangent vectors, in a's body coordinates].
static func _directions(a: Cube, na: Vector4) -> Array:
	var F: Array = a.F
	var nbody := to_body(F, na)
	var ax := Vector3.RIGHT if absf(nbody.x) < 0.6 else Vector3.UP
	var t1 := (ax - ax.dot(nbody) * nbody).normalized()
	var t2 := nbody.cross(t1)
	return [[na, from_body(F, t1), from_body(F, t2)], [nbody, t1, t2]]


func _contact(a: Cube, ra: Vector3, na: Vector4, b: Body, rb: Vector3, nb: Vector4,
		pen: float, mu: float, e: float, group: String, dirs: Array = []) -> Contact:
	var ct := Contact.new()
	ct.a = a
	ct.pen = pen
	ct.mu = mu
	ct.group = group
	var ma := _inverse_mass(a)
	ct.ima = ma.x
	ct.iia = ma.y
	if dirs.is_empty():
		dirs = _directions(a, na)
	ct.da.assign(dirs[0])
	for d: Vector3 in dirs[1]:
		ct.arm_a.append(ra.cross(d))
	if b != null:
		ct.b = b
		ct.bc = b as Cube
		var mb := _inverse_mass(b)
		ct.imb = mb.x
		ct.iib = mb.y
		ct.db = [nb, Vector4.ZERO, Vector4.ZERO]
		if mu > 0.0:
			for i in [1, 2]:
				var T := space.embed_vector(a.l, a.n, ct.da[i])
				ct.db[i] = -space.project(b.l, b.n, T).normalized()
		for d in ct.db:
			ct.arm_b.append(rb.cross(to_body(ct.bc.F, d)) if ct.bc else Vector3.ZERO)
	for i in 3:
		var kk := ct.ima + ct.iia * ct.arm_a[i].length_squared()
		if b != null:
			kk += ct.imb + ct.iib * ct.arm_b[i].length_squared()
		ct.k.append(kk)
	var vs := ct.speed(0)
	ct.target = -e * vs if vs < -BOUNCE_SPEED else 0.0
	return ct


## Contacts of every cube, then sequential impulses on them, then the overlaps are pushed apart.
func _solve_cubes(hands: Array[Ball]) -> void:
	var contacts: Array[Contact] = []
	var boxes := []
	for c in cubes:
		boxes.append(box4(c))
	for i in cubes.size():
		var c := cubes[i]
		var free: bool = c.held == &""
		if free and c.still <= SLEEP_TIME:
			_floor_contacts(c, "f%d" % i, contacts)
			_static_contacts(c, "s%d" % i, contacts)
		for j in balls.size():
			if free or balls[j].held == &"":
				_ball_contacts(c, boxes[i], balls[j], RESTITUTION_CUBE, "b%d_%d" % [i, j], contacts)
		if free:
			for j in hands.size():
				if not _ghosted(c, hands[j]):
					_ball_contacts(c, boxes[i], hands[j], RESTITUTION_CUBE, "h%d_%d" % [i, j], contacts)
		for j in range(i + 1, cubes.size()):
			if (boxes[i][0] - boxes[j][0]).length() < 2.0 * (c.half + cubes[j].half):
				_points_in_box(c, boxes[i], cubes[j], boxes[j], "c%d_%d" % [i, j], contacts)
				_points_in_box(cubes[j], boxes[j], c, boxes[i], "c%d_%d" % [i, j], contacts)
	for _it in ITERATIONS:
		for ct in contacts:
			if ct.k[0] <= 0.0:
				continue                     # both held (or asleep): nothing to push
			var jn := maxf(ct.jn + (ct.target - ct.speed(0)) / ct.k[0], 0.0)
			ct.push(0, jn - ct.jn)
			ct.jn = jn
			if ct.mu <= 0.0 or (jn <= 0.0 and ct.jt == Vector2.ZERO):
				continue
			var jt := ct.jt - Vector2(ct.speed(1) / ct.k[1], ct.speed(2) / ct.k[2])
			var lim := ct.mu * jn
			if jt.length() > lim:
				jt *= lim / jt.length()
			ct.push(1, jt.x - ct.jt.x)
			ct.push(2, jt.y - ct.jt.y)
			ct.jt = jt
	# overlaps: per group (the floor under one cube, one pair of bodies) the deepest one
	var deepest := {}
	for ct in contacts:
		if not deepest.has(ct.group) or ct.pen > deepest[ct.group].pen:
			deepest[ct.group] = ct
	for ct: Contact in deepest.values():
		var depth: float = ct.pen - SLOP
		var mass_sum := ct.ima + ct.imb
		if depth <= 0.0 or mass_sum <= 0.0:
			continue
		if ct.ima > 0.0:
			_move(ct.a, ct.da[0], depth * ct.ima / mass_sum)
		if ct.imb > 0.0:
			_move(ct.b, ct.db[0], depth * ct.imb / mass_sum)
	# sleep: a cube that has hardly moved for a while stops being simulated until something
	# moving touches it
	for c in cubes:
		if c.held != &"":
			c.still = 0.0                 # let go, it falls at once
			continue
		var U: Vector4 = c.U
		var w: Vector3 = c.w
		if U.length() < SLEEP_SPEED and w.length() < SLEEP_SPIN:
			c.still += DT
		else:
			c.still = 0.0
		if c.still > SLEEP_TIME:
			c.U = Vector4.ZERO
			c.w = Vector3.ZERO


## Wakes a sleeping cube when b, which touches it, moves.
func _wake(c: Cube, b: Body) -> void:
	if c.still <= SLEEP_TIME:
		return
	var moving := b.U.length() > SLEEP_SPEED
	if b is Cube:
		moving = moving or (b as Cube).w.length() > SLEEP_SPIN
	if moving:
		c.still = 0.0


## Corners below the floor. Heights to first order at the centre: H + grad H . r, which is the
## z of the box corner in R^4 (exact in the flat universes).
func _floor_contacts(c: Cube, group: String, contacts: Array[Contact]) -> void:
	var H := space.height(c.l, c.n)
	var a: float = c.half
	if H > 1.8 * a:
		return
	var g4 := space.height_grad(c.l, c.n)
	var gl := g4.length()
	var gb := to_body(c.F, g4)
	var dirs := []
	for s: Vector3 in CORNERS:
		var pen := -(H + gb.dot(a * s)) / gl
		if pen > 0.0:
			if dirs.is_empty():
				dirs = _directions(c, g4 / gl)      # shared by all corners
			contacts.append(_contact(c, a * s, g4 / gl, null, Vector3.ZERO, Vector4.ZERO, pen,
					FRICTION_CUBE, RESTITUTION_CUBE, group, dirs))


## The static objects of the flat universes and the world's wall, in chart coordinates.
func _static_contacts(c: Cube, group: String, contacts: Array[Contact]) -> void:
	var l: float = c.l
	if absf(l) < space.L:
		return
	var side := signf(l)
	var n: Vector3 = c.n
	var x := space.chart_position(l, n)
	var a: float = c.half
	var F: Array = c.F
	var f: Array[Vector3] = [WormholeSpace.vector_to_chart(side, n, F[0]),
			WormholeSpace.vector_to_chart(side, n, F[1]), WormholeSpace.vector_to_chart(side, n, F[2])]
	var reach := 1.7321 * a
	var found := []         # [body point, chart normal pushing the cube out, depth]
	var spheres: Array = scene["spheres_A"] if side > 0.0 else scene["spheres_B"]
	for s in spheres:
		# the point of the cube closest to the sphere's centre
		var S := Vector3(s[0], s[1], s[2])
		var d := S - x
		if d.length() > s[3] + reach:
			continue
		var q := Vector3(clampf(d.dot(f[0]), -a, a), clampf(d.dot(f[1]), -a, a), clampf(d.dot(f[2]), -a, a))
		var D := x + q.x * f[0] + q.y * f[1] + q.z * f[2] - S
		if D.length() < s[3] and D.length() > 1e-6:
			found.append([q, D.normalized(), s[3] - D.length()])
	if side > 0.0:
		for p in scene["pillars_A"]:
			if Vector2(x.x - p[0], x.y - p[1]).length() > p[2] + reach or x.z - reach > p[3]:
				continue
			# closest points of the cube and the pillar's axis, by alternating projections
			var A := Vector3(p[0], p[1], clampf(x.z, 0.0, p[3]))
			var q := Vector3.ZERO
			for _it in 6:
				var d := A - x
				q = Vector3(clampf(d.dot(f[0]), -a, a), clampf(d.dot(f[1]), -a, a), clampf(d.dot(f[2]), -a, a))
				A.z = clampf((x + q.x * f[0] + q.y * f[1] + q.z * f[2]).z, 0.0, p[3])
			var D := x + q.x * f[0] + q.y * f[1] + q.z * f[2] - A
			if D.length() < p[2] and D.length() > 1e-6:
				found.append([q, D.normalized(), p[2] - D.length()])
	else:
		for bx in scene["boxes_B"]:
			var C := Vector3(bx[0], bx[1], bx[2])
			var hs: float = bx[3]
			if (x - C).length() > 1.7321 * hs + reach:
				continue
			for s: Vector3 in SAMPLES:          # the cube's points inside the box
				var d := x + a * (s.x * f[0] + s.y * f[1] + s.z * f[2]) - C
				var o := Vector3(hs - absf(d.x), hs - absf(d.y), hs - absf(d.z))
				if o.x > 0.0 and o.y > 0.0 and o.z > 0.0:
					var k := o.min_axis_index()
					var nrm := Vector3.ZERO
					nrm[k] = signf(d[k])
					found.append([a * s, nrm, o[k]])
			for s: Vector3 in CORNERS:          # the box's corners inside the cube
				var d := C + hs * s - x
				var q := Vector3(d.dot(f[0]), d.dot(f[1]), d.dot(f[2]))
				var o := Vector3(a - absf(q.x), a - absf(q.y), a - absf(q.z))
				if o.x > 0.0 and o.y > 0.0 and o.z > 0.0:
					var k := o.min_axis_index()
					found.append([q, -signf(q[k]) * f[k], o[k]])
	if x.length() > WORLD_RADIUS - reach:
		for s: Vector3 in CORNERS:
			var P: Vector3 = x + a * (s.x * f[0] + s.y * f[1] + s.z * f[2])
			if P.length() > WORLD_RADIUS:
				found.append([a * s, -P.normalized(), P.length() - WORLD_RADIUS])
	for h in found:
		contacts.append(_contact(c, h[0], WormholeSpace.vector_from_chart(side, n, h[1]), null,
				Vector3.ZERO, Vector4.ZERO, h[2], FRICTION_CUBE, RESTITUTION_CUBE, group))


## A ball (or a hand) against the cube: the point of the box closest to the ball's centre, in R^4.
func _ball_contacts(c: Cube, box: Array, b: Ball, e: float, group: String, contacts: Array[Contact]) -> void:
	var B := space.embed(b.l, b.n)
	var C: Vector4 = box[0]
	var d := B - C
	var rad: float = b.radius
	var a: float = c.half
	if d.length() > rad + 2.0 * a:
		return
	var q := Vector4(clampf(d.dot(box[1]), -a, a), clampf(d.dot(box[2]), -a, a),
			clampf(d.dot(box[3]), -a, a), clampf(d.dot(box[4]), -a, a))
	var D: Vector4 = B - (C + q.x * box[1] + q.y * box[2] + q.z * box[3] + q.w * box[4])
	var dist := D.length()
	if dist >= rad or dist < 1e-6:
		return
	_wake(c, b)
	contacts.append(_contact(c, Vector3(q.x, q.y, q.z), space.project(c.l, c.n, -D).normalized(),
			b, Vector3.ZERO, space.project(b.l, b.n, D).normalized(), rad - dist, 0.0, e, group))


## Corners and edge midpoints of cube P inside cube Q's box push P out through Q's nearest face.
func _points_in_box(P: Cube, bp: Array, Q: Cube, bq: Array, group: String, contacts: Array[Contact]) -> void:
	var ap: float = P.half
	var aq: float = Q.half
	for s: Vector3 in SAMPLES:
		var d: Vector4 = bp[0] + ap * (s.x * bp[1] + s.y * bp[2] + s.z * bp[3]) - bq[0]
		if absf(d.dot(bq[4])) >= aq:
			continue
		var q := Vector3(d.dot(bq[1]), d.dot(bq[2]), d.dot(bq[3]))
		var o := Vector3(aq - absf(q.x), aq - absf(q.y), aq - absf(q.z))
		if o.x <= 0.0 or o.y <= 0.0 or o.z <= 0.0:
			continue
		var k := o.min_axis_index()
		var out: Vector4 = signf(q[k]) * bq[1 + k]
		_wake(P, Q)
		_wake(Q, P)
		contacts.append(_contact(P, ap * s, space.project(P.l, P.n, out).normalized(),
				Q, q, -signf(q[k]) * Q.F[k], o[k], FRICTION_CUBE, RESTITUTION_CUBE, group))
