class_name Hands
extends RefCounted
## The hands: each a small ball at the controller's grip pose, placed in the curved space as the
## shader places each eye: by the geodesic from the head along the hand's offset in the room, with
## the room's axes carried along it. It pushes the toys; the grip takes the nearest one within reach
## and carries it at its offset and turn in the hand's axes; let go, it flies with the hand's
## velocity and spin. Buttons put a new ball or cube in the hand (README.md, «Управление»).
##
## Pulling, as Half-Life: Alyx's gloves do. An empty open hand points along its aim pose: the toy
## whose surface the geodesic from the hand that way passes nearest, seen from the hand, is aimed at
## (_aim; through the throat as the eye sees, the floor in the way) and drawn glowing (lit,
## Toys.glow); the grip, with no toy within reach, locks on it; a flick of the wrist up, or of the
## hand back or up (_flicked, in the room, since the lock), throws it to where the hand is then, to
## arrive PULL_TIME + PULL_TIME_PER_M per metre of the geodesic later. The throw is found by trying
## it (_solve): BallWorld.flight, the toys' own free motion in steps much longer than the physics',
## from the toy held at rest meanwhile, each try's miss at the hand turning into the next by Newton's
## step with a Jacobian (Broyden's, probed first where the throat bends the ways); then the toy flies
## as any toy does. A closed hand catches its toy within CATCH_REACH and draws it in. With beam on
## (the menu's «луч прицела») an empty hand's pointing geodesic is drawn (_beam, Renderer.set_beam).
## What it costs: tests/pull_test.gd prints the tries' count and time (also the headset's log, "pull:"
## lines), tests/cpu_time.gd a frame's with a hand pointing into the throat.

const RADIUS := 0.04             # m: the ball drawn at each hand's grip; it pushes the toys
const REACH := 0.12              # m from the hand's centre to a toy's surface: the grip takes it
const GRIP_ON := 0.7             # the grip's value that grabs, and the one below which it lets
const GRIP_OFF := 0.45           # go: apart, so a half-closed hand does not grab and drop by turns
const COLOR := Color(0.55, 0.62, 0.75)
const COLOR_READY := Color(0.35, 0.95, 0.5)   # a toy within reach, or held
const COLOR_AIM := Color(1.0, 0.6, 0.2)       # a toy aimed at, locked on or pulled
const VELOCITY_WINDOW := 0.06    # s of recent places a velocity is taken from (_velocity)
const STALE := 0.1               # s: with the newest place older than this, no velocity (tracking lost)
const MAX_THROW_SPEED := 25.0    # m/s: a tracking glitch at the release flings nothing farther
const MAX_THROW_SPIN := 40.0     # rad/s
const SET_DOWN_SPEED := 0.15     # m/s and rad/s: a hand slower than this, turning slower than
const SET_DOWN_SPIN := 1.0       # this, sets its toy down at rest
const NEW_BALL_RADIUS := 0.2     # m: a new ball in the right hand (its button: README.md)
const NEW_CUBE_HALF := 0.15      # m: a new cube in the left hand
# pulling (this file's top)
const PULL_RANGE := 24.0         # m along the pointing geodesic: from the start to universe B's floor
const AIM_ANGLE := deg_to_rad(8.0)   # a toy's surface this far off the geodesic at most, seen from the hand
const AIM_STICK := 0.6           # the toy aimed at counts as this much as far off (no flicker between two)
const AIM_EVERY := 4             # frames: how often a hand aims (the hands by turns)
const RAY_KEEP := 0.01           # m and rad: a hand that moved less than this, and turned less
const RAY_KEEP_TURN := 0.01      # than this, since its last pointing geodesic keeps it
const FLICK_TURN := 6.0          # rad/s: the wrist turning up this fast is a flick,
const FLICK_SPEED := 1.2         # m/s: and the hand moving back toward the toy, or up, this fast
const PULL_TIME := 0.35          # s: the flight's time, and per metre along the pointing geodesic,
const PULL_TIME_PER_M := 0.055   # at most PULL_TIME_MAX
const PULL_TIME_MAX := 1.2
const GUESS_POINTS := 6          # points of the pointing geodesic gravity is taken at for the first try
const PROBE_MISS := 0.3          # m: a first try that misses by more has the Jacobian probed,
const PROBE_SPEED := 0.2         # m/s: by changes of the throw this large
const PULL_STEP := 3.0           # m/s: a try changes the best throw by this much at most
const PULL_MAX_SPEED := 30.0     # m/s: the fastest throw tried
const PULL_MISS := 0.03          # m: a try that misses the hand's centre by less is taken,
const PULL_TRIES := 14           # else the best of this many
const PULL_BUDGET := 300         # us: a frame tries again while it has spent less on tries
const PULL_LATE := 0.4           # s past the planned arrival: a toy not caught by then is let be
const CATCH_REACH := 0.3         # m from the hand's centre to its pulled toy's surface: a closed hand catches it
const CATCH_GLIDE := 2.0         # m/s: a caught toy slides in until it touches the hand
const BEAM_STEP := 0.5           # m between a beam's points (_beam)
const BEAM_RADIUS := 0.003       # m: a beam's radius at the hand
const BEAM_GROW := 0.0015        # m more per metre along it
const BEAM_COLOR := Color(0.85, 0.9, 1.0)   # a beam at no toy

var space: WormholeSpace
var world: BallWorld
var list: Array[Hand] = []      # left, right; none on the desktop
var clock := 0.0                # s: the recent places' times
var frames := 0                 # update's: the hands aim by turns (_pull)
var beam := false               # the pointing geodesics drawn (_beam; the menu's «луч прицела»)


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
	var glide := false                 # a caught toy sliding in: off goes to snug
	var snug := Vector3.ZERO
	# pulling (this file's top)
	var aim: XRController3D            # the controller at its aim pose: where it points
	var room: Array = []               # the room's axes at the hand: x, y (up), z
	var moves: Array = []              # its recent grip poses in the room [t, origin, basis]: a flick
	var aimed: BallWorld.Body          # the toy it points at, or null
	var aim_room := Vector3.ZERO       # the room's direction it pointed in at it
	var aim_s := 0.0                   # m along the pointing geodesic to it,
	var aim_end := 0.0                 # and to where the geodesic passes nearest it (the beam's end)
	var aim_tan := Vector4.ZERO        # the geodesic's direction there, in R^4
	var locked := false                # the grip closed on the toy aimed at: a flick pulls it
	var locked_at := 0.0               # s (clock): when
	var pull: Pull                     # the toy it throws to itself, or null
	var beam_pts := PackedVector4Array()   # its beam (_beam): points of R^4, radii, colour
	var beam_r := PackedFloat32Array()
	var beam_col := Color.WHITE
	var ray: Array = []                # its last pointing geodesic (WormholeSpace.ray), from ray_at along ray_dir
	var ray_at := Vector4.ZERO
	var ray_dir := Vector4.ZERO


## A toy a hand pulls: the throw being tried while the toy waits (flying false), then its flight.
class Pull:
	var toy: BallWorld.Body
	var target := Vector4.ZERO         # the hand's centre at the flick, in R^4
	var T := 0.0                       # s: the flight's time
	var axes: Array = []               # at the toy (_axes): the throw's and miss's coordinates
	var U := Vector4.ZERO              # the throw tried next
	var J := Basis()                   # miss per throw, the Broyden estimate
	var best := Vector4.ZERO           # the throw that missed least so far, its miss and its length
	var best_m := Vector3.ZERO
	var miss := INF
	var last_s := Vector3.ZERO         # the change from best the last try made
	var reach := 1.0                   # how much of Newton's step from best the next try takes
	var probe := -1                    # the axis the try probes the Jacobian along, or -1 (_solve)
	var tries := 0
	var slowest := 0                   # us: the slowest try (the headset's log)
	var flying := false
	var t := 0.0                       # s since it was let fly


func _init(p_space: WormholeSpace, p_world: BallWorld) -> void:
	space = p_space
	world = p_world


## A hand at a controller's grip pose, pointing along its aim pose (aim; null: along the grip's
## -z). Main adds the left one first.
func add(grip: XRController3D, aim: XRController3D = null) -> void:
	var h := Hand.new()
	h.grip = grip
	h.aim = aim
	h.ball.radius = RADIUS
	h.ball.held = grip.tracker
	list.append(h)


## Each frame, after the free toys moved: each hand where the controller is, the toy it holds with
## it, the grip's take and release, its pull (_pull), a new ball (right) or cube (left) if asked.
## hp: the head's point (l, n) and the play space's axes [x, up, z] there; head: its pose in the
## room. Not active (the speed check, no tracking yet, no toys): the hands are not drawn and do
## nothing.
func update(delta: float, hp: Array, head: Transform3D, active: bool, new_ball: bool, new_cube: bool) -> void:
	clock += delta
	frames += 1
	for i in list.size():
		var h := list[i]
		var c := h.grip
		if c == null:
			continue                       # placed by its maker and only drawn (tests/emu_dump.gd)
		h.on = false
		if not active:
			_hold_still(h)
			h.tracked = false
			h.aimed = null
			h.locked = false
			h.beam_pts = PackedVector4Array()
			continue
		var tracked := c.get_has_tracking_data()
		if tracked and not h.tracked:
			# back from a gap in tracking: the places before it are no motion
			h.hist.clear()
			h.thist.clear()
			h.moves.clear()
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
			h.room = at[2]
			h.F = [WormholeSpace.combine(at[2], b.x), WormholeSpace.combine(at[2], b.y),
					WormholeSpace.combine(at[2], b.z)]
			_remember(h.hist, [clock, at[0], at[1]])
			_remember(h.moves, [clock, xf.origin, b])
			h.ball.U = _velocity(h.hist)[0]
			h.on = true
		# the held toy where the hand is now, also in the frame it lets go
		if h.on:
			_carry(h, delta)
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
			elif h.aimed and h.pull == null:
				h.locked = true
				h.locked_at = clock
				c.trigger_haptic_pulse(&"haptic", 0.0, 0.35, 0.04, 0.0)
				print("pull: %s hand locks on a %s %.2f m away" % [_name(i), _kind(h.aimed), h.aim_s])
		elif was and not h.closed:
			_release(i)
			h.locked = false
		_pull(i, delta)
		_beam(h)
		if h.on and h.pull == null and ((i == 1 and new_ball) or (i == 0 and new_cube)):
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
			var c := COLOR_READY if h.ready else (COLOR_AIM if h.aimed or h.pull else COLOR)
			out.append([space.embed(h.ball.l, h.ball.n), Vector4(c.r, c.g, c.b, RADIUS)])
	return out


## The toys the hands aim at, are locked on or pull, to draw lit: {toy: how much, 0 to 1}
## (Toys.glow); one aimed at only pulses.
func lit() -> Dictionary:
	var out := {}
	for h in list:
		if h.pull:
			out[h.pull.toy] = 0.8
		elif h.aimed:
			out[h.aimed] = 0.8 if h.locked else 0.5 + 0.25 * sin(TAU * 2.0 * clock)
	return out


## Both hands empty (the toys put back).
func empty() -> void:
	for h in list:
		h.held = null
		h.glide = false
		h.aimed = null
		h.locked = false
		h.pull = null


## The viewer was put somewhere else, or the room (a recentre): the hands' and held toys' places
## before are no motion.
func forget_motion() -> void:
	for h in list:
		h.hist.clear()
		h.thist.clear()
		h.moves.clear()


## The toy nearest to hand h's centre within REACH of its surface (not one it holds; the one it
## pulls within CATCH_REACH), or null.
func _nearest(h: Hand) -> BallWorld.Body:
	var P := space.embed(h.ball.l, h.ball.n)
	var best: BallWorld.Body = null
	var best_d := REACH
	for b: BallWorld.Body in world.balls + world.cubes:
		if b.held == h.ball.held:
			continue
		var d := world.distance_to(b, P)
		if h.pull and h.pull.toy == b:
			d -= CATCH_REACH - REACH
		if d < best_d:
			best_d = d
			best = b
	return best


## Hand i takes the toy where it is: from now on it keeps its place and its turn against the
## hand, as an offset in the hand's axes (the geodesic from the hand that reaches it) and, for a
## cube, its axes in the hand's axes carried there. Taken from the other hand, that one lets go;
## pulled, the pull ends, and the hand that pulled it draws it in until it touches.
func _take(i: int, toy: BallWorld.Body) -> void:
	var h := list[i]
	var other := list[1 - i]
	if other.held == toy:
		other.held = null
	var caught := h.pull != null and h.pull.toy == toy
	for hh in list:
		if hh.pull and hh.pull.toy == toy:
			hh.pull = null
		if hh.aimed == toy:
			hh.aimed = null
			hh.locked = false
	_release(i)
	toy.held = h.ball.held
	toy.ghost = &""
	var D := space.toward(h.ball.l, h.ball.n, toy.l, toy.n)
	h.held = toy
	h.off = BallWorld.to_body(h.F, D)
	h.thist = []
	var size: float = (toy as BallWorld.Cube).half if toy is BallWorld.Cube else (toy as BallWorld.Ball).radius
	h.snug = h.off.normalized() * (size + RADIUS)
	h.glide = caught and h.off.length() > h.snug.length()
	if toy is BallWorld.Cube:
		var at := _hold_point(h)
		h.rel = []
		for A: Vector4 in (toy as BallWorld.Cube).F:
			h.rel.append(BallWorld.to_body(at[2], A))
	h.grip.trigger_haptic_pulse(&"haptic", 0.0, 0.6, 0.06, 0.0)
	print("%s: %s hand takes a %s (%.2f m from the hand)" % ["catch" if caught else "grab", _name(i), _kind(toy), D.length()])


## Where hand h holds its toy: the end of the geodesic of its offset, with the hand's axes there.
func _hold_point(h: Hand) -> Array:
	var D := WormholeSpace.combine(h.F, h.off)
	if D.length() < 1e-7:
		return [h.ball.l, h.ball.n, h.F]
	return space.geodesic(h.ball.l, h.ball.n, D / D.length(), D.length(), h.F)


## The held toy follows hand h (a caught one sliding in); its velocity (and a cube's spin) from its
## recent places: what it pushes others with.
func _carry(h: Hand, delta: float) -> void:
	if h.held == null:
		return
	if h.glide:
		h.off = h.off.move_toward(h.snug, CATCH_GLIDE * delta)
		h.glide = not h.off.is_equal_approx(h.snug)
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
	h.glide = false
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


# ---------------------------------------------------------------- pulling (this file's top)

## Hand i's pull this frame: its toy's throw tried or its flight (_fly); else locked on, a flick
## throws it (_launch); else an empty open hand aims (_aim), every AIM_EVERY frames.
func _pull(i: int, delta: float) -> void:
	var h := list[i]
	if h.pull:
		_fly(i, delta)
	elif not h.on or h.held:
		h.aimed = null
		h.locked = false
	elif h.locked:
		if not _pullable(h.aimed):
			h.aimed = null
			h.locked = false
		elif _flicked(h):
			_launch(i)
	elif not h.closed:
		if (frames + 2 * i) % AIM_EVERY == 0:
			_aim(h)                         # by turns: one hand a frame at most
	else:
		h.aimed = null


## A toy a hand may aim at: in the world, held by none and pulled by none.
func _pullable(b: BallWorld.Body) -> bool:
	if b == null or not (world.cubes.has(b) if b is BallWorld.Cube else world.balls.has(b)):
		return false
	return b.held == &"" and not _pulled(b)


func _pulled(b: BallWorld.Body) -> bool:
	for h in list:
		if h.pull and h.pull.toy == b:
			return true
	return false


## What hand h points at: of the toys beyond its reach, the one whose surface the geodesic along
## its aim pose's -z passes nearest seen from the hand, within AIM_ANGLE (the one aimed at already
## counts AIM_STICK as far off; of those it goes through, the nearest along it): h.aimed, how far
## along the geodesic it is and the geodesic's direction there; a tick in the hand at a new one. A toy in the flat universe the hand is in,
## not behind the shell's sphere from it, it sees along the chord of R^4 (a straight line there);
## for the others, if any, the geodesic itself (_path).
func _aim(h: Hand) -> void:
	var way := _pointing(h)
	var d: Vector3 = way[0]
	var P: Vector4 = way[1]
	var Dp: Vector4 = way[2]
	var side := signf(h.ball.l) if absf(h.ball.l) > space.L else 0.0
	var best: BallWorld.Body = null
	var best_k := tan(AIM_ANGLE)
	var best_s := 0.0
	var best_end := 0.0
	var best_tan := Vector4.ZERO
	var others := []                       # candidates seen along no chord
	for c: Array in _candidates():
		var b: BallWorld.Body = c[0]
		var C: Vector4 = c[1]
		var V := C - P
		var dist := V.length()
		if dist - c[3] < REACH and world.distance_to(b, P) < REACH:
			continue                       # within reach: the grip takes it
		if side == 0.0 or c[4] != side or _behind_shell(P, C):
			others.append(c)
			continue
		var s := V.dot(Dp)
		if s <= 0.0:
			continue
		var k := (AIM_STICK if b == h.aimed else 1.0) * maxf((V - s * Dp).length() - c[2], 0.0) / maxf(s, 0.1)
		if k < best_k or (k == 0.0 and best_k == 0.0 and dist < best_s):
			best_k = k
			best = b
			best_s = dist
			best_end = s
			best_tan = V / dist
	if not others.is_empty():
		var path := _path(h, way)
		var pts: Array = path[0]
		var lens: Array = path[1]
		var last := pts.size() - 1
		for c: Array in others:
			var C: Vector4 = c[1]
			# the point of the path nearest the toy's centre: next to its nearest corner
			var jn := 0
			var dn := INF
			for j in pts.size():
				var dj: float = (C - pts[j]).length_squared()
				if dj < dn:
					dn = dj
					jn = j
			for j in [jn - 1, jn]:
				if j < 0 or j >= last:
					continue
				var A: Vector4 = pts[j]
				var AB: Vector4 = pts[j + 1] - A
				var len2 := AB.length_squared()
				if len2 < 1e-12:
					continue
				var t := clampf((C - A).dot(AB) / len2, 0.0, 1.0)
				var s: float = lens[j] + t * (lens[j + 1] - lens[j])
				var k := (AIM_STICK if c[0] == h.aimed else 1.0) * maxf((C - A - t * AB).length() - c[2], 0.0) / maxf(s, 0.1)
				if k < best_k or (k == 0.0 and best_k == 0.0 and s < best_s):
					best_k = k
					best = c[0]
					best_s = s
					best_end = s
					best_tan = AB / sqrt(len2)
	if best and best != h.aimed:
		h.grip.trigger_haptic_pulse(&"haptic", 0.0, 0.1, 0.015, 0.0)
	h.aimed = best
	h.aim_room = d
	h.aim_s = best_s
	h.aim_end = best_end
	h.aim_tan = best_tan


## Where hand h points: [the room's direction, the hand as a point of R^4, the direction there as a
## vector of R^4, and as a tangent vector]: its aim pose's -z (else its grip pose's).
func _pointing(h: Hand) -> Array:
	var a: XRController3D = h.aim if h.aim and h.aim.get_has_tracking_data() else h.grip
	var d := -a.transform.basis.z.normalized()
	var D := WormholeSpace.combine(h.room, d)
	return [d, space.embed(h.ball.l, h.ball.n), space.embed_vector(h.ball.l, h.ball.n, D), D]


## Hand h's pointing geodesic (way: _pointing's) up to PULL_RANGE, the floor in the way, as points
## of R^4 and their lengths along it: a straight line where it keeps out of the shell in the flat
## universe the hand is in (_straight), else WormholeSpace.ray, kept while the hand moves and turns
## less than RAY_KEEP and RAY_KEEP_TURN.
func _path(h: Hand, way: Array) -> Array:
	var P: Vector4 = way[1]
	var Dp: Vector4 = way[2]
	var end := _straight(P, Dp) if absf(h.ball.l) > space.L else -1.0
	if end >= 0.0:
		return [[P, P + end * Dp], [0.0, end]]
	if h.ray.is_empty() or (P - h.ray_at).length() > RAY_KEEP or Dp.dot(h.ray_dir) < cos(RAY_KEEP_TURN):
		h.ray = space.ray(h.ball.l, h.ball.n, way[3], PULL_RANGE)
		h.ray_at = P
		h.ray_dir = Dp
	return h.ray


## Hand h's beam this frame (beam on, the hand empty and pulling nothing): its pointing geodesic up
## to the toy it aims at (where it passes nearest), else to its end; points at most BEAM_STEP apart
## along it (more apart if Renderer.BEAM_POINTS would not do), BEAM_RADIUS thick at the hand and
## BEAM_GROW more per metre (it stays as thick in the view); in COLOR_AIM at a toy.
func _beam(h: Hand) -> void:
	h.beam_pts = PackedVector4Array()
	h.beam_r = PackedFloat32Array()
	if not beam or not h.on or h.held or h.pull:
		return
	var path := _path(h, _pointing(h))
	var pts: Array = path[0]
	var lens: Array = path[1]
	var total: float = lens[lens.size() - 1]
	if h.aimed:
		total = minf(total, h.aim_end)
	if total <= 0.0:
		return
	var parts := ceili(total / maxf(BEAM_STEP, total / (Renderer.BEAM_POINTS - 1)) - 1e-9)
	var j := 0
	for k in parts + 1:
		var s := total * k / parts
		while j < lens.size() - 2 and lens[j + 1] < s:
			j += 1
		var a: float = lens[j]
		var b: float = lens[j + 1]
		h.beam_pts.append((pts[j] as Vector4).lerp(pts[j + 1], clampf((s - a) / maxf(b - a, 1e-9), 0.0, 1.0)))
		h.beam_r.append(BEAM_RADIUS + BEAM_GROW * s)
	h.beam_col = COLOR_AIM if h.aimed else BEAM_COLOR


## The beams to draw, a hand each: [points of R^4, radii, colour] (Renderer.set_beam); no points
## when not drawn.
func beams() -> Array:
	var out := []
	for h in list:
		out.append([h.beam_pts, h.beam_r, h.beam_col])
	return out


## The toys a hand may aim at: [toy, centre in R^4, radius or half size, the radius of a ball round
## it, the flat universe it is in (the sign of l, 0 in the curved zone)].
func _candidates() -> Array:
	var out := []
	for b: BallWorld.Body in world.balls + world.cubes:
		if b.held != &"" or _pulled(b):
			continue
		var cube := b is BallWorld.Cube
		var size: float = (b as BallWorld.Cube).half if cube else (b as BallWorld.Ball).radius
		out.append([b, space.embed(b.l, b.n), size, 1.7321 * size if cube else size,
				signf(b.l) if absf(b.l) > space.L else 0.0])
	return out


## The length of the straight line from P along Dp (points and vectors of R^4 in one flat universe)
## to the floor or PULL_RANGE, if it keeps out of the shell's sphere that far; else -1.
func _straight(P: Vector4, Dp: Vector4) -> float:
	var end := PULL_RANGE
	if Dp.z < 0.0:
		end = minf(end, -P.z / Dp.z)
	var p := Vector3(P.x, P.y, P.z)
	var v := Vector3(Dp.x, Dp.y, Dp.z)
	var t := clampf(-p.dot(v) / maxf(v.length_squared(), 1e-12), 0.0, end)
	return end if (p + t * v).length() >= space.Rout else -1.0


## The chord between points P and C of one flat universe passes the shell's sphere (chart radius
## Rout): what is at C is seen from P along no straight line.
func _behind_shell(P: Vector4, C: Vector4) -> bool:
	var p := Vector3(P.x, P.y, P.z)
	var v := Vector3(C.x, C.y, C.z) - p
	var t := clampf(-p.dot(v) / maxf(v.length_squared(), 1e-12), 0.0, 1.0)
	return (p + t * v).length() < space.Rout


## A flick of hand h in the room over its last VELOCITY_WINDOW since it locked on: the grip pose
## turning up (about its own x) faster than FLICK_TURN, or moving back along where it pointed at its
## toy, or up, faster than FLICK_SPEED.
func _flicked(h: Hand) -> bool:
	var m := h.moves.size()
	if m < 2 or clock - h.moves[m - 1][0] > STALE:
		return false
	var i0 := 0
	while i0 < m - 1 and h.moves[i0][0] < h.locked_at - 1e-9:
		i0 += 1
	if i0 >= m - 1:
		return false
	var a: Array = h.moves[i0]
	var z: Array = h.moves[m - 1]
	var dt: float = z[0] - a[0]
	if dt < 1e-3:
		return false
	var v: Vector3 = (z[1] - a[1]) / dt
	var B: Basis = z[2]
	var B0: Basis = a[2]
	var turn := _rotation_vector((B * B0.transposed()).get_rotation_quaternion()).dot(B.x) / dt
	return turn > FLICK_TURN or maxf(-v.dot(h.aim_room), v.y) > FLICK_SPEED


## Hand i throws the toy it is locked on to where the hand is. The first try: back along the
## pointing geodesic, at the speed that covers its length in the flight's time against the air's
## drag (on a line: v' = -k v^2), and up against gravity as on a parabola, the gravity there the mean
## of GUESS_POINTS along that geodesic, each weighed by the time left after it and carried back to
## the toy (exact where gravity is uniform and the space flat, without the air). The toy waits at
## rest, held by none, while _fly tries the throw.
func _launch(i: int) -> void:
	var h := list[i]
	var toy := h.aimed
	h.locked = false
	h.aimed = null
	var p := Pull.new()
	p.toy = toy
	p.target = space.embed(h.ball.l, h.ball.n)
	p.T = minf(PULL_TIME + PULL_TIME_PER_M * h.aim_s, PULL_TIME_MAX)
	p.axes = _axes(toy.n)
	var back := -space.project(toy.l, toy.n, h.aim_tan)
	if back.length() < 1e-6:
		back = space.project(toy.l, toy.n, p.target - space.embed(toy.l, toy.n))
	back = back.normalized()
	var k := world.drag(toy)
	var len := h.aim_s
	var v0 := (exp(k * len) - 1.0) / (k * p.T) if k * len > 1e-6 else len / p.T
	var g := Vector3.ZERO
	var weights := 0.0
	var at := [toy.l, toy.n, p.axes + [back]]
	for j in GUESS_POINTS:
		var x := (j + 0.5) / GUESS_POINTS * len
		var step := x - (j - 0.5) / GUESS_POINTS * len if j > 0 else x
		at = space.geodesic(at[0], at[1], at[2][3], step, at[2], null, WormholeSpace.RAY_STEP)
		var t := (exp(k * x) - 1.0) / (k * v0) if k * len > 1e-6 else x / v0
		var w := maxf(p.T - t, 0.0)
		g += w * BallWorld.to_body(at[2], -BallWorld.GRAVITY * space.potential_grad(at[0], at[1]))
		weights += w
	if weights > 0.0:
		g /= weights
	p.U = v0 * back - 0.5 * p.T * BallWorld.from_body(p.axes, g)
	# miss per throw: the time, less as the air slows it
	var Te := p.T / (1.0 + k * v0 * p.T)
	p.J = Basis.from_scale(Vector3(Te, Te, Te))
	p.best = p.U
	toy.held = h.ball.held            # kinematic: it waits where it is
	toy.ghost = &""
	toy.U = Vector4.ZERO
	if toy is BallWorld.Cube:
		(toy as BallWorld.Cube).w = Vector3.ZERO
	h.pull = p
	h.grip.trigger_haptic_pulse(&"haptic", 0.0, 0.8, 0.05, 0.0)
	print("pull: %s hand flicks: a %s %.2f m away to arrive in %.2f s" % [_name(i), _kind(toy), h.aim_s, p.T])


## Hand i's pull this frame. While the toy waits: tries of the throw, one and more while they have
## taken less than PULL_BUDGET; the best one once it misses by less than PULL_MISS or after
## PULL_TRIES, and the toy flies. In flight: a closed hand catches it within CATCH_REACH (_nearest,
## _take); PULL_LATE after the planned arrival it is let be. Taken by the other hand, or gone (the
## toys put back), the pull ends.
func _fly(i: int, delta: float) -> void:
	var h := list[i]
	var p := h.pull
	var toy := p.toy
	var gone := not (world.cubes.has(toy) if toy is BallWorld.Cube else world.balls.has(toy))
	if gone or toy.held != (&"" if p.flying else h.ball.held):
		h.pull = null
		return
	if not p.flying:
		var t0 := Time.get_ticks_usec()
		var done := _solve(p)
		while not done and Time.get_ticks_usec() - t0 < PULL_BUDGET:
			done = _solve(p)
		if done:
			toy.held = &""
			toy.U = p.best
			toy.still = 0.0
			p.flying = true
			print("pull: the %s flies at %.2f m/s after %d tries (the slowest %.2f ms), to miss the hand by %.3f m"
					% [_kind(toy), p.best.length(), p.tries, p.slowest / 1000.0, p.miss])
		return
	p.t += delta
	if h.on and h.closed and _nearest(h) == toy:
		_take(i, toy)
	elif p.t > p.T + PULL_LATE:
		h.pull = null
		print("pull: the %s missed the %s hand" % [_kind(toy), _name(i)])


## One try of pull p's throw: its miss at the hand after the flight's time, in the toy's axes
## carried along the flight. A first try that misses by more than PROBE_MISS (through the throat,
## which bends the ways near it as a lens does) is followed by three that change it by PROBE_SPEED
## along each axis: the Jacobian (miss per change of throw) from their misses. Then each try a
## Newton step from the best one, half as long after each that missed more, and Broyden's update of
## the Jacobian from the change it made. True once done.
func _solve(p: Pull) -> bool:
	var toy := p.toy
	var t0 := Time.get_ticks_usec()
	var res := world.flight(toy, toy.l, toy.n, p.U, p.T, p.axes)
	p.slowest = maxi(p.slowest, Time.get_ticks_usec() - t0)
	var M := space.project(res[0], res[1], p.target - space.embed(res[0], res[1]))
	var m := BallWorld.to_body(res[3], M)
	p.tries += 1
	if p.probe >= 0:
		p.J[p.probe] = (p.best_m - m) / PROBE_SPEED
		p.probe += 1
		if p.probe < 3:
			p.U = p.best + PROBE_SPEED * p.axes[p.probe]
			return p.tries >= PULL_TRIES
		p.probe = -1
	else:
		if p.tries > 1:
			var s := p.last_s
			var y := (p.best_m - m - p.J * s) / s.length_squared()
			p.J = Basis(p.J.x + y * s.x, p.J.y + y * s.y, p.J.z + y * s.z)
		if m.length() < p.miss:
			p.best = p.U
			p.best_m = m
			p.miss = m.length()
			p.reach = 1.0
		else:
			p.reach *= 0.5
		if p.miss < PULL_MISS or p.tries >= PULL_TRIES:
			return true
		if p.tries == 1 and p.miss > PROBE_MISS:
			p.probe = 0
			p.U = p.best + PROBE_SPEED * p.axes[0]
			return false
	if absf(p.J.determinant()) < 1e-3 * pow(p.T, 3.0):
		p.J = Basis.from_scale(Vector3(p.T, p.T, p.T))
	var ds := p.reach * (p.J.inverse() * p.best_m)
	ds = ds.limit_length(PULL_STEP)
	p.U = p.best + BallWorld.from_body(p.axes, ds)
	if p.U.length() > PULL_MAX_SPEED:
		p.U *= PULL_MAX_SPEED / p.U.length()
	p.last_s = BallWorld.to_body(p.axes, p.U - p.best)
	return p.tries >= PULL_TRIES


## Three orthonormal tangent vectors at the point of direction n: along l, up the sphere of
## directions and across.
static func _axes(n: Vector3) -> Array:
	var u := Vector3(0.0, 0.0, 1.0) - n.z * n
	if u.length() < 0.1:
		u = Vector3(1.0, 0.0, 0.0) - n.x * n
	u = u.normalized()
	var w := n.cross(u)
	return [Vector4(1.0, 0.0, 0.0, 0.0), Vector4(0.0, u.x, u.y, u.z), Vector4(0.0, w.x, w.y, w.z)]


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
