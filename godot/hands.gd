class_name Hands
extends RefCounted
## The hands: each a small ball at the controller's grip pose, placed in the curved space as the
## shader places each eye: by the geodesic from the head along the hand's offset in the room, with
## the room's axes carried along it. It pushes the toys; the grip takes the nearest one within reach
## and carries it at its offset and turn in the hand's axes; let go, it flies with the hand's
## velocity and spin. Buttons put a new ball or cube in the hand (README.md, «Управление»).

const RADIUS := 0.04             # m: the ball drawn at each hand's grip; it pushes the toys
const REACH := 0.12              # m from the hand's centre to a toy's surface: the grip takes it
const GRIP_ON := 0.7             # the grip's value that grabs, and the one below which it lets
const GRIP_OFF := 0.45           # go: apart, so a half-closed hand does not grab and drop by turns
const COLOR := Color(0.55, 0.62, 0.75)
const COLOR_READY := Color(0.35, 0.95, 0.5)   # a toy within reach, or held
const VELOCITY_WINDOW := 0.06    # s of recent places a velocity is taken from (_velocity)
const STALE := 0.1               # s: with the newest place older than this, no velocity (tracking lost)
const MAX_THROW_SPEED := 25.0    # m/s: a tracking glitch at the release flings nothing farther
const MAX_THROW_SPIN := 40.0     # rad/s
const SET_DOWN_SPEED := 0.15     # m/s and rad/s: a hand slower than this, turning slower than
const SET_DOWN_SPIN := 1.0       # this, sets its toy down at rest
const NEW_BALL_RADIUS := 0.2     # m: a new ball in the right hand (its button: README.md)
const NEW_CUBE_HALF := 0.15      # m: a new cube in the left hand

var space: WormholeSpace
var world: BallWorld
var list: Array[Hand] = []      # left, right; none on the desktop
var clock := 0.0                # s: the recent places' times


## One hand.
class Hand:
	var grip: XRController3D           # the controller at its grip pose
	# where the hand is in the curved space (l, n) and its velocity U: what it pushes the toys with;
	# held is its own tracker (kinematic)
	var ball := BallWorld.Ball.new()
	var F: Array = []                  # its axes there
	var on := false                    # tracked and active this frame
	var tracked := false
	var closed := false                # the grip, with the gap between GRIP_ON and GRIP_OFF
	var ready := false                 # a toy within reach, or held: drawn in COLOR_READY
	var held: BallWorld.Body           # the toy it holds, or null
	var off := Vector3.ZERO            # the held toy's offset, in the hand's axes
	var rel: Array = []                # a held cube's axes in the hand's axes carried to it
	var hist: Array = []               # the hand's recent places [t, l, n]
	var thist: Array = []              # the held toy's [t, l, n, F]


func _init(p_space: WormholeSpace, p_world: BallWorld) -> void:
	space = p_space
	world = p_world


## A hand at a controller's grip pose (main adds the left one first).
func add(grip: XRController3D) -> void:
	var h := Hand.new()
	h.grip = grip
	h.ball.radius = RADIUS
	h.ball.held = grip.tracker
	list.append(h)


## Each frame, after the free toys moved: each hand where the controller is, the toy it holds with
## it, the grip's take and release, a new ball (right) or cube (left) if asked. hp: the head's
## point (l, n) and the play space's axes [x, up, z] there; head: its pose in the room.
## Not active (the speed check, no tracking yet, no toys): the hands are not drawn and do nothing.
func update(delta: float, hp: Array, head: Transform3D, active: bool, new_ball: bool, new_cube: bool) -> void:
	clock += delta
	for i in list.size():
		var h := list[i]
		var c := h.grip
		if c == null:
			continue                       # placed by its maker and only drawn (tests/emu_dump.gd)
		h.on = false
		if not active:
			_hold_still(h)
			h.tracked = false
			continue
		var tracked := c.get_has_tracking_data()
		if tracked and not h.tracked:
			# back from a gap in tracking: the places before it are no motion
			h.hist.clear()
			h.thist.clear()
		h.tracked = tracked
		if tracked:
			var xf := c.transform
			var off := xf.origin - head.origin
			var at := hp
			if off.length() > 1e-6:
				var dir := WormholeSpace.combine(hp[2], off)
				at = space.geodesic(hp[0], hp[1], dir / dir.length(), dir.length(), hp[2])
			var b := xf.basis.orthonormalized()
			h.ball.l = at[0]
			h.ball.n = at[1]
			h.F = [WormholeSpace.combine(at[2], b.x), WormholeSpace.combine(at[2], b.y),
					WormholeSpace.combine(at[2], b.z)]
			_remember(h.hist, [clock, at[0], at[1]])
			h.ball.U = _velocity(h.hist)[0]
			h.on = true
		# the held toy where the hand is now, also in the frame it lets go
		if h.on:
			_carry(h)
		else:
			_hold_still(h)
		# the grip, with a gap between grabbing and letting go
		var g := c.get_float(&"grip")
		var was := h.closed
		h.closed = g > GRIP_OFF if was else g > GRIP_ON
		if h.closed and not was and h.on:
			var toy := _nearest(h)
			if toy:
				_take(i, toy)
		elif was and not h.closed:
			_release(i)
		if h.on and ((i == 1 and new_ball) or (i == 0 and new_cube)):
			_new_toy(i, i == 0)
		var ready := h.held != null or (h.on and _nearest(h) != null)
		if ready and not h.ready and h.held == null:
			c.trigger_haptic_pulse(&"haptic", 0.0, 0.15, 0.02, 0.0)    # a tick: within reach
		h.ready = ready


## The hands as kinematic balls for the physics: they push the toys.
func balls() -> Array[BallWorld.Ball]:
	var out: Array[BallWorld.Ball] = []
	for h in list:
		if h.on and h.grip:
			out.append(h.ball)
	return out


## The hands to draw: [centre as a point of R^4, colour with the radius] (Toys.draw).
func drawn() -> Array:
	var out := []
	for h in list:
		if h.on:
			var c := COLOR_READY if h.ready else COLOR
			out.append([space.embed(h.ball.l, h.ball.n), Vector4(c.r, c.g, c.b, RADIUS)])
	return out


## Both hands empty (the toys put back).
func empty() -> void:
	for h in list:
		h.held = null


## The viewer was put somewhere else: the hands' and held toys' places before are no motion.
func forget_motion() -> void:
	for h in list:
		h.hist.clear()
		h.thist.clear()


## The toy nearest to hand h's centre within REACH of its surface (not one it holds), or null.
func _nearest(h: Hand) -> BallWorld.Body:
	var P := space.embed(h.ball.l, h.ball.n)
	var best: BallWorld.Body = null
	var best_d := REACH
	for b: BallWorld.Body in world.balls + world.cubes:
		if b.held == h.ball.held:
			continue
		var d := world.distance_to(b, P)
		if d < best_d:
			best_d = d
			best = b
	return best


## Hand i takes the toy where it is: from now on it keeps its place and its turn against the
## hand, as an offset in the hand's axes (the geodesic from the hand that reaches it) and, for a
## cube, its axes in the hand's axes carried there. Taken from the other hand, that one lets go.
func _take(i: int, toy: BallWorld.Body) -> void:
	var h := list[i]
	var other := list[1 - i]
	if other.held == toy:
		other.held = null
	_release(i)
	toy.held = h.ball.held
	toy.ghost = &""
	var D := space.toward(h.ball.l, h.ball.n, toy.l, toy.n)
	h.held = toy
	h.off = BallWorld.to_body(h.F, D)
	h.thist = []
	if toy is BallWorld.Cube:
		var at := _hold_point(h)
		h.rel = []
		for A: Vector4 in (toy as BallWorld.Cube).F:
			h.rel.append(BallWorld.to_body(at[2], A))
	h.grip.trigger_haptic_pulse(&"haptic", 0.0, 0.6, 0.06, 0.0)
	print("grab: %s hand takes a %s (%.2f m from the hand)" % [_name(i), _kind(toy), D.length()])


## Where hand h holds its toy: the end of the geodesic of its offset, with the hand's axes there.
func _hold_point(h: Hand) -> Array:
	var D := WormholeSpace.combine(h.F, h.off)
	if D.length() < 1e-7:
		return [h.ball.l, h.ball.n, h.F]
	return space.geodesic(h.ball.l, h.ball.n, D / D.length(), D.length(), h.F)


## The held toy follows hand h; its velocity (and a cube's spin) from its recent places: what it
## pushes others with.
func _carry(h: Hand) -> void:
	if h.held == null:
		return
	var toy := h.held
	var cube := toy as BallWorld.Cube
	var at := _hold_point(h)
	toy.l = at[0]
	toy.n = at[1]
	var F := []
	if cube:
		F = WormholeSpace.orthonormalize([WormholeSpace.combine(at[2], h.rel[0]),
				WormholeSpace.combine(at[2], h.rel[1]), WormholeSpace.combine(at[2], h.rel[2])])
		cube.F = F
	_remember(h.thist, [clock, at[0], at[1], F])
	var v := _velocity(h.thist)
	toy.U = v[0]
	if cube:
		cube.w = v[1]


## With hand h not tracked its toy stays where it was, at rest: it would push the others with the
## velocity it last had.
func _hold_still(h: Hand) -> void:
	if h.held == null:
		return
	h.held.U = Vector4.ZERO
	if h.held is BallWorld.Cube:
		(h.held as BallWorld.Cube).w = Vector3.ZERO


## Hand i lets its toy go: it flies off with the hand's velocity and turns as the hand turned. Not
## with its own velocity in the hand: held off the hand (up to REACH plus its size from the hand to
## its centre), it also moves with the turn of the wrist times that lever, and a flick of the wrist
## would throw it far too fast.
func _release(i: int) -> void:
	var h := list[i]
	if h.held == null:
		return
	var toy := h.held
	var cube := toy as BallWorld.Cube
	h.held = null
	toy.held = &""
	var v := _velocity(h.thist)
	var U: Vector4 = _velocity(h.hist)[0]
	var D := WormholeSpace.combine(h.F, h.off)
	if D.length() > 1e-7 and U != Vector4.ZERO:
		U = space.geodesic(h.ball.l, h.ball.n, D / D.length(), D.length(), [U])[2][0]    # carried to the toy
	if U.length() > MAX_THROW_SPEED:
		U *= MAX_THROW_SPEED / U.length()
	# a hand held still sets its toy down at rest: the tracking's tremble would push it
	var spin: Vector3 = v[1]
	var gentle := U.length() < SET_DOWN_SPEED and spin.length() < SET_DOWN_SPIN
	toy.U = Vector4.ZERO if gentle else U
	toy.still = 0.0
	if cube:
		cube.w = Vector3.ZERO if gentle else spin.limit_length(MAX_THROW_SPIN)
	toy.ghost = h.ball.held      # this hand does not push it until they are apart
	print("%s: %s hand lets a %s go at %.2f m/s%s" % ["set down" if gentle else "throw", _name(i),
			_kind(toy), toy.U.length(), (", spin %.1f rad/s" % cube.w.length()) if cube else ""])


## A new ball (right) or cube (left) just in front of hand i, moving with it: none while the hand
## holds a toy; held if the grip is closed. The oldest toy goes if there are too many
## (BallWorld.MAX_BALLS, MAX_CUBES), never a held one.
func _new_toy(i: int, cube: bool) -> void:
	var h := list[i]
	if h.held:
		return
	var size := NEW_CUBE_HALF if cube else NEW_BALL_RADIUS
	# 1 cm from the hand's ball: not touching it
	var at := space.geodesic(h.ball.l, h.ball.n, -h.F[2], size + RADIUS + 0.01, h.F + [h.ball.U])
	var toy: BallWorld.Body
	if cube:
		toy = world.add_cube(at[0], at[1], at[2][3], at[2].slice(0, 3), Vector3.ZERO, size,
				Toys.CUBE_COLORS[randi() % Toys.CUBE_COLORS.size()])
	else:
		toy = world.add(at[0], at[1], at[2][3], size, Toys.BALL_COLORS[randi() % Toys.BALL_COLORS.size()])
	print("new %s in the %s hand" % [_kind(toy), _name(i)])
	if h.closed:
		_take(i, toy)


static func _name(i: int) -> String:
	return "left" if i == 0 else "right"


static func _kind(toy: BallWorld.Body) -> String:
	return "cube" if toy is BallWorld.Cube else "ball"


## Adds a sample [t, ...] to hist, keeping the newest one at least VELOCITY_WINDOW old and the ones
## after it.
func _remember(hist: Array, sample: Array) -> void:
	hist.append(sample)
	while hist.size() > 2 and sample[0] - hist[1][0] >= VELOCITY_WINDOW:
		hist.pop_front()


## A body's velocity from its recent places (hist: [t, l, n] or [t, l, n, F], the newest last):
## [the tangent velocity at the newest place, and with axes F the angular velocity in the newest
## body coordinates]. The derivative at the newest of the parabola through it, the oldest kept
## (about VELOCITY_WINDOW back) and the one half way: an average over the window would lag the
## hand by half of it, and a throw, which is an arc, would leave in the wrong direction. Each
## place is seen from the newest one (the chord of R^4 there), each turn as the axes carried
## there along the chord.
func _velocity(hist: Array) -> Array:
	var none := [Vector4.ZERO, Vector3.ZERO]
	var m := hist.size()
	if m < 2 or clock - hist[m - 1][0] > STALE:
		return none
	var s0: Array = hist[m - 1]
	var t0: float = s0[0]
	if t0 - hist[0][0] < 1e-3:
		return none
	var E0 := space.embed(s0[1], s0[2])
	var picks := [0]
	var weights := [1.0 / (hist[0][0] - t0)]
	if m > 2:
		# the one nearest half way
		var k1 := 1
		var mid: float = 0.5 * (t0 + hist[0][0])
		for k in range(1, m - 1):
			if absf(hist[k][0] - mid) < absf(hist[k1][0] - mid):
				k1 = k
		var t1: float = hist[k1][0]
		var t2: float = hist[0][0]
		picks = [k1, 0]
		weights = [(t0 - t2) / ((t1 - t0) * (t1 - t2)), (t0 - t1) / ((t2 - t0) * (t2 - t1))]
	var U := Vector4.ZERO
	var w := Vector3.ZERO
	var spin: bool = s0.size() > 3 and not s0[3].is_empty()
	for j in picks.size():
		var s: Array = hist[picks[j]]
		var Ek := space.embed(s[1], s[2])
		U += weights[j] * space.project(s0[1], s0[2], Ek - E0)
		if spin:
			# the axes then, carried here: their turn to the axes now, as a rotation vector
			var Fk: Array = s[3]
			var D := space.project(s[1], s[2], E0 - Ek)
			if D.length() > 1e-7:
				Fk = space.geodesic(s[1], s[2], D / D.length(), (E0 - Ek).length(), Fk)[2]
			var F0: Array = s0[3]
			var G := Basis(BallWorld.to_body(F0, Fk[0]), BallWorld.to_body(F0, Fk[1]), BallWorld.to_body(F0, Fk[2]))
			w += weights[j] * _rotation_vector(G.orthonormalized().get_rotation_quaternion())
	return [U, w]


static func _rotation_vector(q: Quaternion) -> Vector3:
	if q.w < 0.0:
		q = -q
	var v := Vector3(q.x, q.y, q.z)
	var s := v.length()
	if s < 1e-9:
		return 2.0 * v
	return v * (2.0 * atan2(s, q.w) / s)
