class_name Viewer
extends RefCounted
## The viewer's body: the room (the play space) carried through the curved space as a ship. Its
## point is the feet, the point of the room's floor under the head (the head's room x and z, y = 0),
## with the room's axes there, frame = [x, up, z] (tangent vectors, orthonormal); the head is the
## head's room height along up from the feet (head). main.gd reads the buttons and moves it.
##
## Standing, the feet are on the floor, the plane z = 0 of their flat universe's chart (WormholeSpace's
## top: it keeps out of the curved zone), with up the chart's up, and every move is a straight line
## of that chart along it, the axes as they are in it (stand_at). Flying, the body is the head: it
## moves, falls and turns, and the feet follow it as the room hangs from it (_set_head). Every move
## is a geodesic of the head with the room's axes parallel-transported along it: a flight with the
## stick held and the head still is one geodesic, through the throat as light goes. The room pitches
## and rolls about the head (tilt_at_head: the eyes stay where they are, the feet swing round them).
## What the sticks push moves at the speed they ask for, as a ship's thrusters that hold it up
## would; nothing pushed, the body hovers without gravity and with it falls freely from the velocity
## it had (WormholeSpace.dynamics_step: the geodesic and -g grad phi, the toys' gravity,
## docs/gravity.md: weaker in the throat, and on the throat's top, n = +z, along the throat toward
## its middle, where it is zero). No air: a fall keeps its energy.
##
## Up is carried along like any other axis, so a flight through the curved zone comes out tilted
## against the floor: the path and up turn together in the path's plane. Straight along -x from chart
## A (10, 0, z), with the throat's centre at z = 5: through it the flight comes out into universe B
## upright (a radial path carries every vector as it is); at z = 4 or 6, 3 or 7, 2.5 or 7.5 it comes
## out with up 100, 122 and 12 degrees from B's; at 2 or 8 it goes round the throat and back into A,
## 148 degrees; at 1.5 or 8.5 it passes the rim, 5 degrees (tests/flight_test.gd prints these). Up
## from the floor right under the throat's centre goes straight in and comes out in B upside down,
## head first toward B's floor.
##
## With gravity, flying and not pitched or rolled, the room turns about the head toward up against
## gravity there, as Portal turns the player upright after a portal (right_up): the least turn
## (upside down: a roll), approaching as exp(-t / RIGHT_TIME) and at most RIGHT_MAX a second, both
## slower where gravity is weaker than RIGHT_G (near its zeros, at the top and the bottom of the
## throat's middle, it would turn fast and every way).
##
## The head does not go into the floor: within HEAD_CLEAR of it (the eyes must stay above it: the
## renderer draws from above it only), the body is pushed back out along the floor's normal at the
## head (keep_head_up). Where the feet reach the floor, the body lands: the frame turns the least way
## that stands it up and the feet go straight up onto the floor (touch_down; below the floor is only
## ever in a flat universe). With gravity it has mostly turned upright by then; a landing still
## tilted (without gravity, or falling too soon) moves the view at once, as a snap turn does
## (main.gd: hands.forget_motion). The feet stay within LIMIT of the throat's centre.

const GRAVITY := BallWorld.GRAVITY
const HEAD_MIN := 0.05          # m: the head at least this far above the feet along up (the room's floor)
const HEAD_CLEAR := 0.04        # m: the head this close to the floor (height, WormholeSpace.height) is pushed out
const FALL_DT := 1.0 / 120.0    # s: a free fall's longest RK4 step
const LIMIT := BallWorld.WORLD_RADIUS   # m: the feet this far from the throat's centre at most (the toys' wall)
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


## Stand on the floor of universe side (+1 A, -1 B) at chart point (xy, 0), the room's x and z
## along the chart directions fx and fz made level (their parts along the floor), up the chart's up.
func stand_at(side: float, xy: Vector2, fx: Vector3, fz: Vector3) -> void:
	var p := space.point_from_chart(side, Vector3(xy.x, xy.y, 0.0))
	l = p[0]
	n = p[1]
	frame = WormholeSpace.orthonormalize([WormholeSpace.vector_from_chart(side, n, Vector3(fx.x, fx.y, 0.0)),
			WormholeSpace.vector_from_chart(side, n, Vector3(0.0, 0.0, 1.0)),
			WormholeSpace.vector_from_chart(side, n, Vector3(fz.x, fz.y, 0.0))])
	V = Vector4.ZERO
	standing = true


## Flying, at rest, with the head at (hl, hn), the room's axes fh there, height (m, the head's in the
## room) above the feet.
func fly_at(hl: float, hn: Vector3, fh: Array, height: float) -> void:
	standing = false
	V = Vector4.ZERO
	_set_head(hl, hn, fh, height)


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
## standing, along the floor (T's part across it dropped): a straight line of the chart.
func move(T: Vector4) -> void:
	var dist := T.length()
	if dist < 1e-7:
		return
	if standing:
		var side := signf(l)
		var x := space.chart_position(l, n)
		var d := WormholeSpace.vector_to_chart(side, n, T)
		var xy := (Vector2(x.x, x.y) + Vector2(d.x, d.y)).limit_length(sqrt(LIMIT * LIMIT - space.lift * space.lift))
		stand_at(side, xy, WormholeSpace.vector_to_chart(side, n, frame[0]), WormholeSpace.vector_to_chart(side, n, frame[2]))
		return
	var res := space.geodesic(l, n, T / dist, dist, frame)
	l = res[0]
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
	var side := signf(l)
	var f := turn_up(frame, WormholeSpace.vector_from_chart(side, n, Vector3(0.0, 0.0, 1.0)))
	var x := space.chart_position(l, n)
	stand_at(side, Vector2(x.x, x.y), WormholeSpace.vector_to_chart(side, n, f[0]),
			WormholeSpace.vector_to_chart(side, n, f[2]))
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


## Where the body is in terms every shape of the throat has, for a change of shape (main._reshape;
## height: the head's in the room): standing, the feet's place on the floor and the room's axes in
## its chart (the floor stays where it is, the throat changes over it); flying, the head's place
## against the curved zone (WormholeSpace.zone_place: its share of the zone, or as far beyond it) and
## its n, with the room's axes and the velocity there as they are, (U_l, u) being orthonormal in every
## shape.
func shape_free(height: float) -> Array:
	if standing:
		var side := signf(l)
		var c := space.chart_position(l, n)
		return [true, side, Vector2(c.x, c.y), WormholeSpace.vector_to_chart(side, n, frame[0]),
				WormholeSpace.vector_to_chart(side, n, frame[2])]
	var hp := head(height)
	return [false, space.zone_place(hp[0]), hp[1], hp[2], V]


## Back where shape_free said, in the space's shape now.
func put_back(p: Array, height: float) -> void:
	_head_of = []                   # the head's place was the old shape's
	if p[0]:
		stand_at(p[1], p[2], p[3], p[4])
		return
	fly_at(space.l_of(p[1]), p[2], p[3], height)
	V = p[4]


## Flying, the feet within LIMIT of the throat's centre: back on that sphere, the velocity's part
## outward taken away (standing: move keeps them in).
func _keep_in() -> void:
	if absf(l) <= space.L or space.r(l) <= LIMIT:
		return
	var side := signf(l)
	l = side * (LIMIT - space.Rout + space.L)
	if V.x * side > 0.0:
		V.x = 0.0
