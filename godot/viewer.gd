class_name Viewer
extends RefCounted
## The viewer's body: the room (the play space) carried through the curved space as a ship. Its
## point is the feet, the point of the room's floor under the head (the head's room x and z, y = 0),
## with the room's axes there, frame = [x, up, z] (tangent vectors, orthonormal); the head is the
## head's room height along up from the feet (head). main.gd reads the buttons and moves it.
##
## Standing, the feet are on the floor (WormholeSpace's top: height 0, wherever the throat hangs:
## in a flat universe the chart's plane z = 0, in the curved zone a bent surface, through the throat
## a way from one universe to the other), with up the floor's normal there (the height's unit
## gradient). A move goes along the floor's own geodesic (_walk): where the floor is flat, a straight
## line of the chart, the axes as they are in it (stand_at); where it bends, in pieces of PIECE, each
## along the space's geodesic with the axes carried, then dropped back onto the floor along the
## height's gradient, the axes turned the least way that makes up the floor's normal again, and the
## way to go kept in those axes: to second order in the piece that is the floor's geodesic with its
## own parallel transport. The head is the head's room height up the space's geodesic along up, or
## as far up it as stays HEAD_CLEAR over the floor (head: where the floor comes round over the feet
## nearer than the body is tall, as in a throat whose floor runs near its top), and from there there
## is no taking off. Where the floor leaves the head no room at all (_fits: the throat's top a few
## centimetres over the floor) nobody stands: a walk stops before it (it looks every FIT_EVERY and
## where it ends), a landing there is none, and stand_at takes the nearest place out from the axis
## that has room. Flying, the body is the head: it
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
## renderer draws from above it only), the body is pushed back out along the height's gradient at the
## head (keep_head_up). Where the feet reach the floor, the body lands: the feet go onto the floor
## along the height's gradient (straight up where the floor is flat) and the frame turns the least
## way that stands it up there (touch_down). With gravity it has mostly turned upright by then; a
## landing still tilted (without gravity, or falling too soon) moves the view at once, as a snap
## turn does (main.gd: hands.forget_motion). The feet stay within LIMIT of the throat's centre.
## tests/floor_test.gd walks, lands and stands at every kind of lift.

const GRAVITY := BallWorld.GRAVITY
const HEAD_MIN := 0.05          # m: the head at least this far above the feet along up (the room's floor)
const HEAD_CLEAR := 0.04        # m: the head this close to the floor (height, WormholeSpace.height) is pushed out
const HEAD_PROBE := 0.1         # m: the steps up from the feet that look for the floor coming round (head)
const FIT_HEIGHT := 1.0         # m: a place to stand has room for a head this high, or as high as it is (_fits)
const FIT_STEP := 0.05          # m: stand_at's steps out from the axis to a place with room
const FIT_EVERY := 0.1          # m: a walk over a bent floor looks for the head's room this often (_walk)
const PIECE := 0.02             # m: a walk's longest piece where the floor bends (_walk)
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
var _head_of := []              # head's last [l, n, frame, height, standing] and what it gave: the
var _head_was := []             # steps of a frame ask for the same head
var _head_up := 0.0             # m: how far up from the feet that head is
var _height := 1.6              # m: the head's height in the room head was last asked for


func _init(p_space: WormholeSpace) -> void:
	space = p_space


## Stand on the floor of universe side (+1 A, -1 B) at chart point (xy, 0) (WormholeSpace.
## floor_point: in the curved zone the bent floor's point there; inside the floor's hole, where the
## throat is, its rim), up the floor's normal, the room's x and z along the chart directions fx and
## fz made level with the floor there (their parts along it). Where the head has no room there
## (_fits), at the nearest place straight out from the axis that has, in steps of FIT_STEP.
func stand_at(side: float, xy: Vector2, fx: Vector3, fz: Vector3) -> void:
	_stand(side, xy, fx, fz)
	var rho := maxf(xy.length(), space.floor_hole())
	var out := xy.normalized() if xy.length() > 1e-6 else Vector2(1.0, 0.0)
	for k in range(1, 81):
		if _fits():
			break
		_stand(side, out * (rho + FIT_STEP * k), fx, fz)


func _stand(side: float, xy: Vector2, fx: Vector3, fz: Vector3) -> void:
	var p := space.floor_point(side, xy)
	l = p[0]
	n = p[1]
	var up := space.height_grad(l, n)       # the chart's up where the floor is flat
	if up.length() < 1e-6:
		# on the cylinder's bottom or top line, where the floor only touches it: as at a pit's bottom
		up = Vector4((1.0 if side >= 0.0 else -1.0) * signf(n.z), 0.0, 0.0, 0.0)
	frame = WormholeSpace.orthonormalize([WormholeSpace.vector_from_chart(side, n, Vector3(fx.x, fx.y, 0.0)),
			up, WormholeSpace.vector_from_chart(side, n, Vector3(fz.x, fz.y, 0.0))])
	V = Vector4.ZERO
	standing = true


## Flying, at rest, with the head at (hl, hn), the room's axes fh there, height (m, the head's in the
## room) above the feet.
func fly_at(hl: float, hn: Vector3, fh: Array, height: float) -> void:
	standing = false
	V = Vector4.ZERO
	_set_head(hl, hn, fh, height)


## Off the floor (standing: else nothing changes), at rest. With height (the head's in the room)
## not where the floor over the feet leaves the body no room (head): flying, its feet would be under
## the floor at once. True if it took off.
func take_off(height := -1.0) -> bool:
	if not standing:
		return false
	if height >= 0.0:
		head(height)
		if _head_up < maxf(height, HEAD_MIN) - 1e-6:
			return false
	standing = false
	V = Vector4.ZERO
	return true


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
## standing, along the floor (T's part across it dropped), by the floor's geodesic (_walk).
func move(T: Vector4) -> void:
	var dist := T.length()
	if dist < 1e-7:
		return
	if standing:
		_walk(T)
		return
	var res := space.geodesic(l, n, T / dist, dist, frame)
	l = res[0]
	n = res[1]
	frame = WormholeSpace.orthonormalize(res[2])
	_keep_in()


## Standing: the feet moved along the floor by T's part along it (this file's top). Where the floor
## is flat (a flat universe, out of the curved zone's ball) a straight line of the chart, up to the
## zone's ball or LIMIT; where it bends, pieces of PIECE (_piece), back to the last place where the
## head had room if it has none (_fits).
func _walk(T: Vector4) -> void:
	var c := Vector2(T.dot(frame[0]), T.dot(frame[2]))      # the way in the room's x and z: kept as the axes turn
	var left := c.length()
	if left < 1e-7:
		return
	c /= left
	var first := true
	var ok := []                    # the last place on a bent floor where the head had room, and how
	var since := 0.0                # far the walk went since
	for _i in 100000:               # each pass uses up length: a bound against a hang
		if left <= 1e-9:
			break
		if absf(l) >= space.L:
			var side := signf(l)
			var x := space.chart_position(l, n)
			var d := WormholeSpace.vector_to_chart(side, n, T if first else (c.x * frame[0] + c.y * frame[2]) * left)
			var at := Vector2(x.x, x.y)
			var d2 := Vector2(d.x, d.y)
			var s_in := _to_zone(at, d2)
			var fx := WormholeSpace.vector_to_chart(side, n, frame[0])
			var fz := WormholeSpace.vector_to_chart(side, n, frame[2])
			if s_in >= 1.0:
				stand_at(side, (at + d2).limit_length(sqrt(maxf(LIMIT * LIMIT - space.lift * space.lift, 0.0))), fx, fz)
				return
			if s_in * left > 1e-6:
				stand_at(side, at + d2 * s_in, fx, fz)
				left -= s_in * left
		first = false
		if ok.is_empty():
			ok = [l, n, frame]
		var ds := minf(left, PIECE)
		_piece(c, ds)
		left -= ds
		since += ds
		if since >= FIT_EVERY or left <= 1e-9:
			if not _fits():
				l = ok[0]
				n = ok[1]
				frame = ok[2]
				return
			ok = [l, n, frame]
			since = 0.0


## The share of the chart step d2 from at (a flat floor's (x, y)) that reaches the circle inside
## which the floor is in the curved zone (WormholeSpace.floor_edge); 1 or more: the whole step keeps
## out of it.
func _to_zone(at: Vector2, d2: Vector2) -> float:
	var e := space.floor_edge()
	var dd := d2.length_squared()
	var b := at.dot(d2)
	if e <= 0.0 or b >= 0.0 or dd < 1e-18:
		return INF                  # no such circle, or going away from it
	var cc := at.length_squared() - e * e
	if cc <= 0.0:
		return 0.0                  # on it, going in
	var disc := b * b - dd * cc
	return (-b - sqrt(disc)) / dd if disc > 0.0 else INF


## A piece of a walk where the floor bends: ds along the space's geodesic the way c (in the room's x
## and z), back onto the floor, the axes carried and stood up on it.
func _piece(c: Vector2, ds: float) -> void:
	var res := space.geodesic(l, n, c.x * frame[0] + c.y * frame[2], ds, frame)
	res = space.to_floor(res[0], res[1], res[2])
	l = res[0]
	n = res[1]
	frame = _stood(res[2])


## Standing here, the head has room: where head puts it (the frame's next head asks for the same
## one), or for a head lower than FIT_HEIGHT somewhere up to that, it is HEAD_CLEAR over the floor.
func _fits() -> bool:
	if not space.floor_in_zone():
		return true
	var hp := head(_height)
	if space.height(hp[0], hp[1]) >= HEAD_CLEAR - 1e-6:
		return true
	return _height < FIT_HEIGHT and _up_height(_head_room(FIT_HEIGHT)) >= HEAD_CLEAR - 1e-6


## The axes f at the feet turned the least way that makes up the floor's normal there.
func _stood(f: Array) -> Array:
	var N := space.floor_normal(l, n)
	if N == Vector4.ZERO:
		return WormholeSpace.orthonormalize(f)
	var out := turn_up(f, N)
	out[1] = N
	return WormholeSpace.orthonormalize(out)


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
## along the height's gradient there (Newton's steps: one where the floor is flat), the velocity's
## part into the floor taken away. True if it was.
func keep_head_up(height: float) -> bool:
	if standing:
		return false
	var hp := head(height)
	var H := space.height(hp[0], hp[1])
	if H >= HEAD_CLEAR:
		return false
	for _it in 8:
		var g := space.height_grad(hp[0], hp[1])
		var gl := g.length()
		if gl < 1e-6:
			break
		# H grows by gl a metre along its gradient (1 where the space is flat)
		var k := (HEAD_CLEAR - H) / (gl * gl)
		if absf(hp[0]) < space.L:
			k = minf(k, 0.5 * space.bend(hp[0]) / gl)
		_move_head(hp, g * k, height)
		hp = head(height)
		H = space.height(hp[0], hp[1])
		if H >= HEAD_CLEAR - 1e-6:
			break
	var N := space.height_grad(hp[0], hp[1]).normalized()
	if V.dot(N) < 0.0:
		V -= V.dot(N) * N
	return true


## The head at height (m, the head's in the room) above the feet along up: [l, n, frame] (not to be
## changed: the same Array comes back while nothing moved). Standing where the floor comes round
## over the feet (this file's top), only as far up as it is HEAD_CLEAR over the floor (_head_room).
func head(height: float) -> Array:
	_height = height
	var key := [l, n, frame, height, standing]
	if key != _head_of:
		_head_of = [l, n, frame.duplicate(), height, standing]
		_head_up = maxf(height, HEAD_MIN)
		_head_was = space.geodesic(l, n, frame[1], _head_up, frame)
		if standing and space.floor_in_zone() and space.height(_head_was[0], _head_was[1]) < HEAD_CLEAR:
			_head_up = _head_room(_head_up)
			_head_was = space.geodesic(l, n, frame[1], _head_up, frame)
	return _head_was


## How far up from the feet, at most most, the head goes: to where the geodesic along up, probed
## every HEAD_PROBE, first comes back within HEAD_CLEAR of the floor; where it never gets that far
## off it, to where it is highest.
func _head_room(most: float) -> float:
	var parts := maxi(ceili(most / HEAD_PROBE), 1)
	var lo := 0.0                   # the last probe clear of the floor, and the first after it that is not
	var hi := -1.0
	var top := HEAD_MIN
	var top_h := -INF
	for k in range(1, parts + 1):
		var t := most * k / parts
		var H := _up_height(t)
		if H > top_h:
			top_h = H
			top = t
		if H >= HEAD_CLEAR:
			lo = t
		elif lo > 0.0:
			hi = t
			break
	if hi < 0.0:
		return maxf(top, HEAD_MIN)
	for _it in 12:
		var t := 0.5 * (lo + hi)
		if _up_height(t) >= HEAD_CLEAR:
			lo = t
		else:
			hi = t
	return lo


## The height over the floor t up from the feet.
func _up_height(t: float) -> float:
	var q := space.geodesic(l, n, frame[1], t, [])
	return space.height(q[0], q[1])


## The head put at (hl, hn) with the room's axes fh there: the feet height (in the room) down along
## up from it, the axes carried back; the head kept for head.
func _set_head(hl: float, hn: Vector3, fh: Array, height: float) -> void:
	var fo := WormholeSpace.orthonormalize(fh)
	_head_up = maxf(height, HEAD_MIN)
	var res := space.geodesic(hl, hn, -(fo[1] as Vector4), _head_up, fo)
	l = res[0]
	n = res[1]
	frame = WormholeSpace.orthonormalize(res[2])
	_head_of = [l, n, frame.duplicate(), height, standing]
	_head_was = [hl, hn, fo]
	_keep_in()


## The feet's height above the floor (WormholeSpace.height).
func height() -> float:
	return space.height(l, n)


## Flying with the feet below the floor: land (this file's top). True if it landed.
func touch_down() -> bool:
	if standing or space.height(l, n) > 0.0:
		return false
	if absf(l) >= space.L:
		var side := signf(l)
		var x := space.chart_position(l, n)
		if Vector2(x.x, x.y).length() >= space.floor_edge():
			# under a flat floor: straight up onto it
			var f := turn_up(frame, WormholeSpace.vector_from_chart(side, n, Vector3(0.0, 0.0, 1.0)))
			stand_at(side, Vector2(x.x, x.y), WormholeSpace.vector_to_chart(side, n, f[0]),
					WormholeSpace.vector_to_chart(side, n, f[2]))
			return true
	var was := [l, n, frame]
	var res := space.to_floor(l, n, frame)
	l = res[0]
	n = res[1]
	frame = _stood(res[2])
	standing = true
	if not _fits():
		# no room to stand there: it flies on, the head kept out of the floor (keep_head_up)
		l = was[0]
		n = was[1]
		frame = was[2]
		standing = false
		return false
	V = Vector4.ZERO
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


## Flying, the feet within LIMIT of the throat's centre: back on that sphere, the velocity's part
## outward taken away (standing: _walk keeps them in, on the floor's circle that far from it).
func _keep_in() -> void:
	if absf(l) <= space.L or space.r(l) <= LIMIT:
		return
	var side := signf(l)
	l = side * (LIMIT - space.Rout + space.L)
	if V.x * side > 0.0:
		V.x = 0.0
