class_name Viewer
extends RefCounted
## The viewer's body: the room (the play space) carried through the curved space. Its point is the
## feet, the point of the room's floor under the head (the head's room x and z, y = 0), with the
## room's axes there, frame = [x, up, z] (tangent vectors, orthonormal); the head is the head's room
## height along up from the feet (head). main.gd reads the buttons and moves it.
##
## Standing, the feet are on the floor (n.z = 0, up its normal) and every move goes along the
## floor, which keeps them on it (the floor is totally geodesic). Flying, the feet are anywhere above
## the floor and every move is a geodesic with the frame parallel-transported along it: a flight
## with the stick held and the head still is one geodesic, through the throat as light goes. What
## the sticks push moves at the speed they ask for, as a jetpack that holds the body up would;
## nothing pushed, the body hovers without gravity and with it falls freely from the velocity it
## had (WormholeSpace.dynamics_step: the geodesic and -g grad phi, the toys' gravity, docs/gravity.md;
## a fifth of g on the floor in the middle of the throat). No air: a fall keeps its energy, and one
## that never meets the floor goes on (above the throat's top, n = +z, gravity pulls along the throat
## toward its middle, where it is zero: a body let go there swings along the throat).
##
## Up is carried along like any other axis, so a flight off the floor through the curved zone comes
## out tilted against the floor: up turns with the path (a path at head height through the throat
## comes out about 25 degrees up, one over the throat's top turns over). Where the feet reach the
## floor, or the head comes within HEAD_CLEAR of it (the eyes must stay above it: the renderer
## draws from above it only), the body lands: the feet go onto the floor below them and the frame
## turns the least way that stands up along the floor's normal (upside down: a roll, the line of
## sight kept). Landing moves the view at once, as a snap turn does (main.gd: hands.forget_motion).
## The feet stay within LIMIT of the throat's centre in the flat universes.

const GRAVITY := BallWorld.GRAVITY
const HEAD_MIN := 0.05          # m: the head at least this far above the feet along up (the room's floor)
const HEAD_CLEAR := 0.04        # m: the head this close to the floor (height, WormholeSpace.height) lands
const FALL_DT := 1.0 / 120.0    # s: a free fall's longest RK4 step
const LIMIT := BallWorld.WORLD_RADIUS   # m: the feet's chart radius at most (the toys' wall)

var space: WormholeSpace
var l := 0.0                    # the feet (l, n)
var n := Vector3.RIGHT
var frame: Array = []           # the room's axes at the feet [x, up, z]
var V := Vector4.ZERO           # velocity at the feet, m/s (flying)
var standing := true
var gravity := true             # flying with nothing pushed: falls (else hovers)
var landed := false             # set by touch_down when it lands (main clears it each frame)


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


## Pushed at velocity S (a tangent vector at the feet, m/s) for dt s: standing, along the floor
## (S's part along up is dropped); flying, along S's geodesic, and S is the velocity a fall starts
## from (coast).
func push(S: Vector4, dt: float) -> void:
	if standing:
		S -= S.dot(frame[1]) * frame[1]
		V = Vector4.ZERO
	else:
		V = S
	move(S * dt)


## Nothing pushed for dt s: flying, a free fall with gravity, else at rest. True if it moved.
func coast(dt: float) -> bool:
	if standing:
		return false
	if not gravity:
		V = Vector4.ZERO
		return false
	var steps := ceili(dt / FALL_DT - 1e-9)
	var h := dt / steps
	for _i in steps:
		var s := space.dynamics_step(l, n, V, h, GRAVITY, frame)
		l = s[0]
		n = s[1]
		V = s[2]
		frame = WormholeSpace.orthonormalize(s[3])
	_keep_in()
	return true


## Move by the tangent displacement T at the feet along its geodesic, the frame (and the velocity)
## carried along; standing, it stays exactly on the floor (removes round-off only).
func move(T: Vector4) -> void:
	var dist := T.length()
	if dist < 1e-7:
		return
	var res := space.geodesic(l, n, T / dist, dist, frame + [V])
	l = res[0]
	if standing:
		n = Vector3(res[1].x, res[1].y, 0.0).normalized()
		var fx: Vector4 = WormholeSpace.tangent(n, Vector4(res[2][0].x, res[2][0].y, res[2][0].z, 0.0))
		var fz: Vector4 = WormholeSpace.tangent(n, Vector4(res[2][2].x, res[2][2].y, res[2][2].z, 0.0))
		frame = WormholeSpace.orthonormalize([fx, Vector4(0.0, 0.0, 0.0, 1.0), fz])
		return
	n = res[1]
	frame = WormholeSpace.orthonormalize(res[2].slice(0, 3))
	V = res[2][3]
	_keep_in()


## Turn the frame about up; a positive angle turns the view to the right.
func turn(angle: float) -> void:
	var c := cos(angle)
	var s := sin(angle)
	var fx: Vector4 = frame[0]
	var fz: Vector4 = frame[2]
	# a smooth turn rotates a little every frame: keep round-off from adding up
	frame = WormholeSpace.orthonormalize([c * fx + s * fz, frame[1], c * fz - s * fx])


## The head at height (m, the head's in the room) above the feet along up: [l, n, frame].
func head(height: float) -> Array:
	return space.geodesic(l, n, frame[1], maxf(height, HEAD_MIN), frame)


## The feet's height above the floor (WormholeSpace.height).
func height() -> float:
	return space.height(l, n)


## Flying with the feet below the floor or the head (at height in the room) within HEAD_CLEAR of
## it: land (this file's top). True if it landed.
func touch_down(height_in_room: float) -> bool:
	if standing:
		return false
	var hp := head(height_in_room)
	if space.height(l, n) > 0.0 and space.height(hp[0], hp[1]) > HEAD_CLEAR:
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
	var f := stand_up(frame, Vector4(0.0, 0.0, 0.0, 1.0))
	var fx: Vector4 = WormholeSpace.tangent(n, Vector4(f[0].x, f[0].y, f[0].z, 0.0))
	var fz: Vector4 = WormholeSpace.tangent(n, Vector4(f[2].x, f[2].y, f[2].z, 0.0))
	frame = WormholeSpace.orthonormalize([fx, Vector4(0.0, 0.0, 0.0, 1.0), fz])
	V = Vector4.ZERO
	standing = true
	landed = true
	return true


## The frame f turned the least way that takes its up to N (a unit tangent vector); up opposite N:
## half a turn about the line of sight (a roll).
static func stand_up(f: Array, N: Vector4) -> Array:
	var a: Vector4 = f[1]
	var c := clampf(a.dot(N), -1.0, 1.0)
	var p := N - c * a
	if p.length() < 1e-6:
		if c > 0.0:
			return f.duplicate()
		p = f[0]
	p = p.normalized()
	var s := sqrt(1.0 - c * c)
	var out := []
	for X: Vector4 in f:
		var xa := X.dot(a)
		var xp := X.dot(p)
		out.append(X + (xa * (c - 1.0) - xp * s) * a + (xa * s + xp * (c - 1.0)) * p)
	return out


## Where it is, to come back to (set).
func get_state() -> Array:
	return [l, n, frame.duplicate(), standing, V]


func set_state(p: Array) -> void:
	l = p[0]
	n = p[1]
	frame = p[2].duplicate()
	standing = p[3]
	V = p[4]


## The feet within LIMIT of the centre in a flat universe: back on its sphere, the velocity's part
## outward taken away.
func _keep_in() -> void:
	if absf(l) <= space.L or space.r(l) <= LIMIT:
		return
	var side := signf(l)
	l = side * (LIMIT - space.Rout + space.L)
	if V.x * side > 0.0:
		V.x = 0.0
