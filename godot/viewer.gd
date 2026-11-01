class_name Viewer
extends RefCounted
## The viewer's body: the room (the play space) carried through the curved space as a ship. Its
## point is the feet, the point of the room's floor under the head (the head's room x and z, y = 0),
## with the room's axes there, frame = [x, up, z] (tangent vectors, orthonormal); the head is the
## head's room height along up from the feet (head). main.gd reads the buttons and moves it.
##
## Standing, the feet are on the floor (n.z = 0, up its normal) and every move goes along the
## floor, which keeps them on it (the floor is totally geodesic). Flying, the body is the head: it
## moves, falls and turns, and the feet follow it as the room hangs from it (_set_head). Every move
## is a geodesic of the head with the room's axes parallel-transported along it: a flight with the
## stick held and the head still is one geodesic, through the throat as light goes. The room pitches
## and rolls about the head (tilt_at_head: the eyes stay where they are, the feet swing round them).
## What the sticks push moves at the speed they ask for, as a ship's thrusters that hold it up
## would; nothing pushed, the body hovers without gravity and with it falls freely from the velocity
## it had (WormholeSpace.dynamics_step: the geodesic and -g grad phi, the toys' gravity,
## docs/gravity.md: weaker in the throat, and over the throat's top, n = +z, along the throat toward
## its middle, where it is zero). No air: a fall keeps its energy.
##
## Up is carried along like any other axis, so a flight off the floor through the curved zone comes
## out tilted against the floor: the path and up turn together in the path's plane. Straight from
## 10 m out at the throat's middle with the feet 0.25, 0.5, 1 and 1.5 m over the floor, a flight
## comes out into universe B turned 24, 48, 100 and 160 degrees up; at 2 m it comes down onto B's
## floor, at 3 m back onto A's (tests/flight_test.gd prints these). With gravity, flying and not
## pitched or rolled, the room turns about the head toward up against gravity there, as Portal turns
## the player upright after a portal (right_up): the least turn (upside down: a roll), approaching as
## exp(-t / RIGHT_TIME) and at most RIGHT_MAX a second, both slower where gravity is weaker than
## RIGHT_G (near the zero over the throat's middle it would turn fast and every way).
##
## The head does not go into the floor: within HEAD_CLEAR of it (the eyes must stay above it: the
## renderer draws from above it only), the body is pushed back out along the floor's normal at the
## head (keep_head_up). Where the feet reach the floor, the body lands: the feet go onto the floor
## below them and the frame turns the least way that stands up along the floor's normal. With
## gravity it has mostly turned upright by then; a landing still tilted (without gravity, or
## falling too soon) moves the view at once, as a snap turn does (main.gd: hands.forget_motion). The
## feet stay within LIMIT of their world's origin in the flat universes while flying (_keep_in).

const GRAVITY := BallWorld.GRAVITY
const HEAD_MIN := 0.05          # m: the head at least this far above the feet along up (the room's floor)
const HEAD_CLEAR := 0.04        # m: the head this close to the floor (height, WormholeSpace.height) is pushed out
const FALL_DT := 1.0 / 120.0    # s: a free fall's longest RK4 step
const LIMIT := BallWorld.WORLD_RADIUS   # m from the world's origin: the feet at most (the toys' wall)
const RIGHT_TIME := 0.35        # s: turning upright with gravity (right_up)
const RIGHT_MAX := deg_to_rad(120.0)    # per second
const RIGHT_G := 0.15           # g: weaker gravity turns it slower, in proportion

var space: WormholeSpace
var l := 0.0                    # the feet (l, n)
var n := Vector3.RIGHT
var frame: Array = []           # the room's axes at the feet [x, up, z]
var V := Vector4.ZERO           # flying: the head's velocity (a tangent vector there), m/s
var standing := true
var gravity := true             # flying with nothing pushed: falls (else hovers), and turns upright
var _head_of := []              # head's last [l, n, frame, height] and what it gave: the steps of a
var _head_was := []             # frame ask for the same head


func _init(p_space: WormholeSpace) -> void:
	space = p_space


## Stand at (pl, pn) of the floor with the room's axes f (up along the floor's normal).
func stand(pl: float, pn: Vector3, f: Array) -> void:
	l = pl
	n = Vector3(pn.x, pn.y, 0.0).normalized()
	frame = f.duplicate()
	V = Vector4.ZERO
	standing = true


## Off the floor (standing: else nothing changes), at rest.
func take_off() -> void:
	standing = false
	V = Vector4.ZERO


## The head's step in the room (x, z; its height: height) taken along: standing, the feet's along
## the floor; flying, the head's.
func step_room(step: Vector2, height: float) -> void:
	if standing:
		move(step.x * frame[0] + step.y * frame[2])
		return
	var hp := head(height)
	_move_head(hp, WormholeSpace.combine(hp[2], Vector3(step.x, 0.0, step.y)), height)


## Pushed at velocity v (in the room, m/s) for dt s: standing, the feet along the floor (v's part
## along up is dropped); flying, the head along v's geodesic, and v is the velocity a fall starts
## from (coast). height: the head's in the room.
func push(v: Vector3, dt: float, height: float) -> void:
	if standing:
		V = Vector4.ZERO
		move(WormholeSpace.combine(frame, Vector3(v.x, 0.0, v.z)) * dt)
		return
	var hp := head(height)
	V = WormholeSpace.combine(hp[2], v)
	_move_head(hp, V * dt, height)


## Nothing pushed for dt s: flying, a free fall of the head with gravity, else at rest. True if it
## moved.
func coast(dt: float, height: float) -> bool:
	if standing or dt <= 0.0:
		return false
	if not gravity:
		V = Vector4.ZERO
		return false
	var hp := head(height)
	var hl: float = hp[0]
	var hn: Vector3 = hp[1]
	var fh: Array = hp[2]
	var steps := maxi(ceili(dt / FALL_DT - 1e-9), 1)
	var h := dt / steps
	for _i in steps:
		var s := space.dynamics_step(hl, hn, V, h, GRAVITY, fh)
		hl = s[0]
		hn = s[1]
		V = s[2]
		fh = WormholeSpace.orthonormalize(s[3])
	_set_head(hl, hn, fh, height)
	return true


## Move the feet by the tangent displacement T there along its geodesic, the frame carried along;
## standing, they stay exactly on the floor (removes round-off only).
func move(T: Vector4) -> void:
	var dist := T.length()
	if dist < 1e-7:
		return
	var res := space.geodesic(l, n, T / dist, dist, frame)
	l = res[0]
	if standing:
		n = Vector3(res[1].x, res[1].y, 0.0).normalized()
		var fx: Vector4 = WormholeSpace.tangent(n, Vector4(res[2][0].x, res[2][0].y, res[2][0].z, 0.0))
		var fz: Vector4 = WormholeSpace.tangent(n, Vector4(res[2][2].x, res[2][2].y, res[2][2].z, 0.0))
		frame = WormholeSpace.orthonormalize([fx, Vector4(0.0, 0.0, 0.0, 1.0), fz])
		return
	n = res[1]
	frame = WormholeSpace.orthonormalize(res[2])
	_keep_in()


## The head (hp, as head gives it) moved by the tangent displacement T there, its axes and its
## velocity carried along.
func _move_head(hp: Array, T: Vector4, height: float) -> void:
	var dist := T.length()
	if dist < 1e-7:
		return
	var res := space.geodesic(hp[0], hp[1], T / dist, dist, hp[2] + [V])
	V = res[2][3]
	_set_head(res[0], res[1], res[2].slice(0, 3), height)


## Turn the frame about up; a positive angle turns the view to the right.
func turn(angle: float) -> void:
	var c := cos(angle)
	var s := sin(angle)
	var fx: Vector4 = frame[0]
	var fz: Vector4 = frame[2]
	# a smooth turn rotates a little every frame: keep round-off from adding up
	frame = WormholeSpace.orthonormalize([c * fx + s * fz, frame[1], c * fz - s * fx])


## Flying: pitch and roll the room about the head (at height in the room) as tilt turns axes: a head
## looking along fwd (the room's x, z) looks pitch higher and is rolled roll about its line of sight
## (right side up).
func tilt_at_head(height: float, pitch: float, roll: float, fwd: Vector2) -> void:
	if standing:
		return
	var hp := head(height)
	_set_head(hp[0], hp[1], tilt(hp[2], pitch, roll, fwd), height)


## With gravity, flying: dt s of turning toward up against gravity at the head (this file's top).
func right_up(dt: float, height: float) -> void:
	if standing or not gravity:
		return
	var hp := head(height)
	var G := space.potential_grad(hp[0], hp[1])    # up, its length in g
	var g := G.length()
	if g < 1e-9:
		return
	var a := acos(clampf((hp[2][1] as Vector4).dot(G / g), -1.0, 1.0))
	if a < 1e-7:
		return
	var w := minf(g / RIGHT_G, 1.0)
	var b := minf(a * (1.0 - exp(-dt * w / RIGHT_TIME)), RIGHT_MAX * w * dt)
	_set_head(hp[0], hp[1], turn_up(hp[2], G / g, b), height)


## Flying with the head (at height in the room) within HEAD_CLEAR of the floor: the body pushed out
## along the floor's normal there, the velocity's part into the floor taken away. True if it was.
func keep_head_up(height: float) -> bool:
	if standing:
		return false
	var hp := head(height)
	var H := space.height(hp[0], hp[1])
	if H >= HEAD_CLEAR:
		return false
	var g := space.height_grad(hp[0], hp[1])
	var gl := g.length()
	# H grows by gl a metre along its gradient (1 on the floor)
	_move_head(hp, g * ((HEAD_CLEAR - H) / (gl * gl)), height)
	hp = head(height)
	var N := space.height_grad(hp[0], hp[1]).normalized()
	if V.dot(N) < 0.0:
		V -= V.dot(N) * N
	return true


## The head at height (m, the head's in the room) above the feet along up: [l, n, frame] (not to be
## changed: the same Array comes back while nothing moved).
func head(height: float) -> Array:
	var key := [l, n, frame, height]
	if key != _head_of:
		_head_of = [l, n, frame.duplicate(), height]
		_head_was = space.geodesic(l, n, frame[1], maxf(height, HEAD_MIN), frame)
	return _head_was


## The head put at (hl, hn) with the room's axes fh there: the feet height (in the room) down along
## up from it, the axes carried back; the head kept for head.
func _set_head(hl: float, hn: Vector3, fh: Array, height: float) -> void:
	var fo := WormholeSpace.orthonormalize(fh)
	var res := space.geodesic(hl, hn, -(fo[1] as Vector4), maxf(height, HEAD_MIN), fo)
	l = res[0]
	n = res[1]
	frame = WormholeSpace.orthonormalize(res[2])
	_head_of = [l, n, frame.duplicate(), height]
	_head_was = [hl, hn, fo]
	_keep_in()


## The feet's height above the floor (WormholeSpace.height).
func height() -> float:
	return space.height(l, n)


## Flying with the feet below the floor: land (this file's top). True if it landed.
func touch_down() -> bool:
	if standing or space.height(l, n) > 0.0:
		return false
	# the feet onto the floor along the great circle at their l, the floor's normal geodesic
	var u := Vector3(0.0, 0.0, 1.0) - n.z * n
	var ul := u.length()
	var dist := space.r(l) * asin(clampf(absf(n.z), 0.0, 1.0))
	if ul > 1e-9 and dist > 1e-9:
		var d := (-signf(n.z) / ul) * u
		var res := space.geodesic(l, n, Vector4(0.0, d.x, d.y, d.z), dist, frame)
		l = res[0]
		n = res[1]
		frame = res[2]
	n = Vector3(n.x, n.y, 0.0).normalized()
	var f := turn_up(frame, Vector4(0.0, 0.0, 0.0, 1.0))
	var fx: Vector4 = WormholeSpace.tangent(n, Vector4(f[0].x, f[0].y, f[0].z, 0.0))
	var fz: Vector4 = WormholeSpace.tangent(n, Vector4(f[2].x, f[2].y, f[2].z, 0.0))
	frame = WormholeSpace.orthonormalize([fx, Vector4(0.0, 0.0, 0.0, 1.0), fz])
	V = Vector4.ZERO
	standing = true
	return true


## The frame f turned by angle (at most all the way) the least way that takes its up to N (a unit
## tangent vector); up opposite N: about the frame's z (a roll for a head looking along -z).
static func turn_up(f: Array, N: Vector4, angle := INF) -> Array:
	var a: Vector4 = f[1]
	var c := clampf(a.dot(N), -1.0, 1.0)
	var p := N - c * a
	if p.length() < 1e-6:
		if c > 0.0:
			return f.duplicate()
		p = f[0]
	p = p.normalized()
	var t := minf(angle, acos(c))
	var ct := cos(t)
	var st := sin(t)
	var out := []
	for X: Vector4 in f:
		var xa := X.dot(a)
		var xp := X.dot(p)
		out.append(X + (xa * (ct - 1.0) - xp * st) * a + (xa * st + xp * (ct - 1.0)) * p)
	return out


## The room's axes in the curved space, f = [x, up, z], turned so that a head looking along fwd
## (the room's x, z) looks pitch higher and is rolled about its line of sight (right side up):
## about the head's own right and back, not the room's x and z.
static func tilt(f: Array, pitch: float, roll: float, fwd: Vector2) -> Array:
	var r := Vector2(-fwd.y, fwd.x)                  # the head's right in the room (x, z)
	var right: Vector4 = r.x * f[0] + r.y * f[2]
	var back: Vector4 = -fwd.x * f[0] - fwd.y * f[2]
	var c := cos(pitch)
	var s := sin(pitch)
	var up: Vector4 = c * f[1] + s * back
	back = c * back - s * f[1]
	var cr := cos(roll)
	var sr := sin(roll)
	var right2: Vector4 = cr * right + sr * up
	up = cr * up - sr * right
	# back from the head's axes to the room's: x = r.x right - fwd.x back, z = r.y right - fwd.y back
	return [r.x * right2 - fwd.x * back, up, r.y * right2 - fwd.y * back]


## Where it is, to come back to (set).
func get_state() -> Array:
	return [l, n, frame.duplicate(), standing, V]


func set_state(p: Array) -> void:
	l = p[0]
	n = p[1]
	frame = p[2].duplicate()
	standing = p[3]
	V = p[4]


## The feet within LIMIT of their world's origin in a flat universe: back on its sphere, the
## velocity's part outward taken away (V is the head's, read at the feet: off by the angle the
## head's height makes seen from the throat's centre).
func _keep_in() -> void:
	if absf(l) <= space.L:
		return
	var side := signf(l)
	var x := space.world_position(l, n)
	if x.length() <= LIMIT:
		return
	var out := x / x.length()
	var p := space.point_from_world(side, out * LIMIT)
	if p[0] * side <= space.L:
		return                  # the mouth at the wall: its curved zone keeps the feet
	var d := space.vector_to_world(side, n, V)
	d -= maxf(d.dot(out), 0.0) * out
	var f := []
	for A: Vector4 in frame:
		f.append(space.vector_from_world(side, p[1], space.vector_to_world(side, n, A)))
	l = p[0]
	n = p[1]
	frame = WormholeSpace.orthonormalize(f)
	V = space.vector_from_world(side, n, d)
