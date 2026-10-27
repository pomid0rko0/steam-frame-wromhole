class_name BallWorld
extends RefCounted
## Balls and cubes moving through the wormhole space.
##
## A ball is a point (l, n) with velocity U = (U_l, u) and a radius. Free motion follows
## geodesics (zero redshift: no gravity from the metric itself) plus gravity, -g grad phi.
## phi is the potential Poisson's equation gives on the curved space itself, as in optozorax's
## video about gravity and portals: ordinary uniform gravity far away in both universes, bent
## through the wormhole and weaker in the throat (WormholeSpace.potential, ref/gravity.py).
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
##
## A toy in a hand is a body like the others, not a copy of the hand: the hand pulls it toward the
## place and the turn it was taken with, as muscles do, with a limited force and torque (holds,
## _hold). Two hands can hold one toy, each at its own point.

const GRAVITY := 9.81
const DT := 1.0 / 180.0
const RESTITUTION_FLOOR := 0.55
const RESTITUTION_BALL := 0.85
# Rolling friction: a small part that follows the weight, and a part that follows the speed; air
# drag on top. A ball at rest stays where the floor pulls along itself less than ROLLING_RESISTANCE g;
# near the wormhole gravity pulls along the floor toward the throat, 0.01 g at the shell's edge
# (0.06-0.1 g where the fillet meets the throat), so a ball set down there rolls in by itself. 0.04 g
# alone held it still for the outer metre and a half of the fillet; 0.02 g alone let a thrown ball
# roll for 40 m. Air drag (as the square of the speed) slows fast balls, in flight too, but hardly a
# slow roll: that is the rolling drag's. A 50 cm ball rolling at 4 m/s stops in 19 m, at 2 m/s in
# 9.5 m, at 1 m/s in 4 m (0.04 g alone: 20, 5, 1.3 m).
const ROLLING_RESISTANCE := 0.005
const ROLLING_DRAG := 0.1            # 1/s: the deceleration per m/s of rolling speed
const AIR_DENSITY := 1.2             # kg/m^3
const TOY_DENSITY := 25.0            # kg/m^3: big rubber toys (a 50 cm ball 1.6 kg); masses go as size^3
const DRAG_BALL := 0.47              # drag coefficients of a sphere and of a cube
const DRAG_CUBE := 1.05
const MAX_BALLS := 8
const WORLD_RADIUS := 40.0           # chart radius of an invisible wall that keeps balls nearby
const MAX_CUBES := 6
const RESTITUTION_CUBE := 0.15       # cubes land with a small bounce
const FRICTION_CUBE := 0.5           # sliding friction: a sliding cube decelerates at 0.5 g
const FRICTION_BALL := 0.5           # the same for a held ball (a free one rolls)
const BOUNCE_SPEED := 0.4            # slower impacts do not bounce (no endless micro-bounces)
const ITERATIONS := 6                # velocity iterations of the contact solver
# a hand or a held toy against a ball: the hand moves on regardless (it is kinematic, and a held
# toy's hand keeps pulling), so with the balls' 0.85 a ball it met flew off at 1.85 times its
# speed, and one pressed against the floor or another ball gained speed from nothing; this is a
# soft hand's
const RESTITUTION_KINEMATIC := 0.3
# a hand's push: no bounce (a palm is soft), at most HAND_FORCE (a hand pushing a heavy toy moves it
# no faster than its strength: it goes into it), with the palm's friction (a ball pressed under the
# hand stays under it instead of squirting out). Balls: _push. A cube's overlap with a hand is
# undone no faster than HAND_SLOP a substep (the rest is the push's velocity).
const RESTITUTION_HAND := 0.0
const PALM_FRICTION := 0.8
const HAND_SLOP := 0.002
const HAND_GIVE := 0.35              # m: a hand pressed this far into a ball it pushes goes through it
const TOUCH_DEPTH := 0.03            # m: a hand deeper in a ball it did not touch went through it
const PROP_GAP := 0.002              # m: a ball this near the floor or a static object rests on it
const PUSH_ITERATIONS := 6
const PRESS_SPEED := 0.05            # m/s: a hand in a ball pushes it out no faster than it moves plus
									 # this (it is in only because it cannot feel the ball: pressed
									 # in deep beside its top, it threw a 22 cm ball at 4 m/s; and a
									 # ball a hand runs into leaves no faster than the hand)

var space: WormholeSpace
var scene: Dictionary
var air := true                      # air drag (tests of the motion itself turn it off)
# Dictionary: l, n, U, radius, color, holds (the hands that hold it: tracker -> hold, see take);
# held, also hF and hw: axes and their spin (body), which a free ball does not have
var balls: Array = []
var cubes: Array = []                # Dictionary: l, n, U, F (3 body axes), w (body), half, color, holds
var _acc := 0.0


func _init(p_space: WormholeSpace, p_scene: Dictionary) -> void:
	space = p_space
	scene = p_scene


func add(l: float, n: Vector3, U: Vector4, radius: float, color: Color) -> Dictionary:
	if balls.size() >= MAX_BALLS:
		_drop_oldest(balls)
	var b := {"l": l, "n": n, "U": U, "radius": radius, "color": color, "holds": {}}
	balls.append(b)
	return b


## A cube centred at (l, n): body axes F (tangent vectors, made orthonormal), angular velocity
## w in body coordinates (rad/s), half the edge length.
func add_cube(l: float, n: Vector3, U: Vector4, F: Array, w: Vector3, half: float, color: Color) -> Dictionary:
	if cubes.size() >= MAX_CUBES:
		_drop_oldest(cubes)
	var axes := []
	for A: Vector4 in F:
		axes.append(WormholeSpace.tangent(n, A))
	var c := {"l": l, "n": n, "U": U, "F": WormholeSpace.orthonormalize(axes), "w": w,
			"half": half, "color": color, "holds": {}, "still": 0.0}
	cubes.append(c)
	return c


## Makes room for a new ball or cube: the oldest one goes, unless a hand holds it.
static func _drop_oldest(list: Array) -> void:
	for i in list.size():
		if list[i]["holds"].is_empty():
			list.remove_at(i)
			return
	list.pop_front()


## How far the point P of R^4 is from the surface of a ball or a cube (chord distance; a ball's
## inside is negative, a cube's 0): what a hand reaches.
func distance_to(b: Dictionary, P: Vector4) -> float:
	if not b.has("F"):
		return (P - space.embed(b["l"], b["n"])).length() - b["radius"]
	var box := box4(b)
	var d: Vector4 = P - box[0]
	var a: float = b["half"]
	var q := Vector4(clampf(d.dot(box[1]), -a, a), clampf(d.dot(box[2]), -a, a),
			clampf(d.dot(box[3]), -a, a), clampf(d.dot(box[4]), -a, a))
	return (d - q.x * box[1] - q.y * box[2] - q.z * box[3] - q.w * box[4]).length()


## Advance by delta seconds with fixed substeps. hands: Array of {l, n, U, radius, tracker}
## (kinematic): they push the toys, but not the ones they hold. The holds' aims (aim) are where the
## hands are at the end of delta: each substep pulls toward where they were at its end.
func step(delta: float, hands: Array) -> void:
	_acc = minf(_acc + delta, 0.1)
	while _acc >= DT:
		_acc -= DT
		_hold(_acc)
		for b in balls:
			var held: bool = not b["holds"].is_empty()
			var before: Array = [b["l"], b["n"], b["U"]]
			var s := space.dynamics_step(b["l"], b["n"], b["U"], DT, GRAVITY, b["hF"] if held else [])
			b["l"] = s[0]
			b["n"] = s[1]
			b["U"] = _air(s[2], 3.0 * AIR_DENSITY * DRAG_BALL / (8.0 * TOY_DENSITY * b["radius"]))
			if held:
				b["hF"] = _turn(s[3], b["hw"])
			_floor(b, before)
			_statics(b)
		for c in cubes:
			if c["still"] <= SLEEP_TIME:
				_integrate_cube(c)
		for i in balls.size():
			for j in range(i + 1, balls.size()):
				_pair(balls[i], balls[j], RESTITUTION_BALL)
		for b in balls:
			_forget_touches(b, hands)
		for hand in hands:
			for b in balls:
				if not b["holds"].has(hand["tracker"]):
					_push(b, hand)
		if not cubes.is_empty():
			_solve_cubes(hands)


## A step of air drag, -k |U| U (k: drag / mass per metre), integrated implicitly: stable at any speed.
func _air(U: Vector4, k: float) -> Vector4:
	return U / (1.0 + k * U.length() * DT) if air else U


## Signed chord distance between the surfaces of two balls (negative: overlap).
func gap(a: Dictionary, b: Dictionary) -> float:
	return (space.embed(a["l"], a["n"]) - space.embed(b["l"], b["n"])).length() - a["radius"] - b["radius"]


## Bounce, rolling friction and the floor's push. before: [l, n, U] before this step's motion.
func _floor(b: Dictionary, before: Array) -> void:
	var H := space.height(b["l"], b["n"])
	var rad: float = b["radius"]
	if H >= rad:
		return
	var g := space.height_grad(b["l"], b["n"])
	var gl := g.length()
	var N := g / gl
	var U: Vector4 = b["U"]
	var vn := U.dot(N)
	# a held ball is pressed down by its hand: it does not bounce (it would every substep)
	var held: bool = not b["holds"].is_empty()
	if vn < 0.0:
		U -= (1.0 + (0.0 if held else RESTITUTION_FLOOR)) * vn * N
		if absf(vn) < 0.6:
			U -= U.dot(N) * N               # settle instead of micro-bouncing
		if held:
			U = _held_friction(b, U, N, -vn)
	var Ut := U - U.dot(N) * N
	var speed := Ut.length()
	if speed > 0.0:
		# rolling friction follows the weight on the floor, which is weaker in the throat
		var weight := GRAVITY * maxf(space.potential_grad(b["l"], b["n"]).dot(N), 0.0)
		var stop := (ROLLING_RESISTANCE * weight + ROLLING_DRAG * speed) * DT
		if speed <= stop and before[2].length() < 1e-6 and not held:
			# at rest and held by friction: gravity pulls slightly along the floor near the
			# wormhole, so undo this step's motion instead of letting the ball creep
			b["l"] = before[0]
			b["n"] = before[1]
			b["U"] = Vector4.ZERO
			return
		U -= Ut * (minf(stop, speed) / speed)
	b["U"] = U
	_move(b, N, (rad - H) / gl)


## A held ball on the floor does not roll as it likes (the hand holds its turn): its lowest point
## sliding over the floor is slowed by friction (FRICTION_BALL times the floor's push, which a hand
## pressing it down adds to: pressed hard, it stays where it is), its spin with it. pushed: the
## floor's push this substep (m/s: the velocity into the floor it took away). The velocity after it.
func _held_friction(b: Dictionary, U: Vector4, N: Vector4, pushed: float) -> Vector4:
	var F: Array = b["hF"]
	var rad: float = b["radius"]
	var n := to_body(F, N)
	var r := -rad * n                                    # the lowest point, from the centre
	var w: Vector3 = b["hw"]
	var slip := to_body(F, U) + w.cross(r)
	slip -= slip.dot(n) * n
	if slip.length() < 1e-9:
		return U
	# per unit mass: J changes the velocity by J and the slip by J (1 + m rad^2 / I) = 3.5 J
	var J := (-slip / 3.5).limit_length(FRICTION_BALL * pushed)
	b["hw"] = w + r.cross(J) * (mass_kg(b) / inertia_kg(b))
	return U + from_body(F, J)


func _statics(b: Dictionary) -> void:
	var touch := _static_contact(b)
	var depth: float = touch[0]
	if depth <= 0.0:
		return
	var N: Vector4 = touch[1]
	var U: Vector4 = b["U"]
	var vn := U.dot(N)
	if vn < 0.0:
		U -= (1.0 + (RESTITUTION_BALL if b["holds"].is_empty() else 0.0)) * vn * N
	b["U"] = U
	_move(b, N, depth)


## The static object (or the invisible wall) ball b overlaps most: [depth, its normal at b (away from
## it)]; depth 0 or less: none (-INF: nowhere near one).
func _static_contact(b: Dictionary) -> Array:
	var l: float = b["l"]
	if absf(l) < space.L:
		return [-INF, Vector4.ZERO]          # static objects live in the flat universes only
	var side := signf(l)
	var x := space.chart_position(l, b["n"])
	var rad: float = b["radius"]
	var normal := Vector3.ZERO
	var depth := -INF
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
	if normal == Vector3.ZERO:
		return [-INF, Vector4.ZERO]
	return [depth, WormholeSpace.vector_from_chart(side, b["n"], normal)]


func _pair(a: Dictionary, b: Dictionary, e: float) -> void:
	var Ea := space.embed(a["l"], a["n"])
	var Eb := space.embed(b["l"], b["n"])
	var D := Eb - Ea
	var dist := D.length()
	var pen: float = a["radius"] + b["radius"] - dist
	if pen <= 0.0 or dist < 1e-6:
		return
	var Na := space.project(a["l"], a["n"], D).normalized()      # at a, toward b
	var Nb := space.project(b["l"], b["n"], -D).normalized()     # at b, toward a
	var ma: float = pow(a["radius"], 3.0)
	var mb: float = pow(b["radius"], 3.0)
	if not a["holds"].is_empty() or not b["holds"].is_empty():
		e = RESTITUTION_KINEMATIC
	var Ua: Vector4 = a["U"]
	var Ub: Vector4 = b["U"]
	var approach := Ua.dot(Na) + Ub.dot(Nb)
	if approach > 0.0:
		var j := (1.0 + e) * approach / (1.0 / ma + 1.0 / mb)
		a["U"] = Ua - (j / ma) * Na
		b["U"] = Ub - (j / mb) * Nb
	var wa := mb / (ma + mb)
	_move(a, -Na, pen * wa)
	_move(b, -Nb, pen * (1.0 - wa))


## A hand (kinematic sphere) pushing a ball it does not hold. Where it touches the ball (touch: the
## direction from the ball's centre, kept per hand in b["touch"]) stays where it first touched
## while the hand is pressed in, and slides over the ball only as far as the palm's friction cone
## needs (_palm_slide): a hand cannot feel a toy, and goes on into it; from its centre the push
## would turn sideways the deeper it went, and a ball pressed under it squirted out. The push is
## along that place's normal: the ball's speed there what the hand's is, plus what takes the hand's
## depth in it out in HOLD_TIME, but no more than PRESS_SPEED (pressed in, the hand presses with all
## it has), at most HAND_FORCE; across it the palm's friction, at most PALM_FRICTION times the push;
## solved together with the floor and the static object the ball rests against (they take what
## pushes it into them: a ball pressed against the floor within the palm's friction angle from its
## top stays, beyond it rolls out). No overlap to undo: the place is on the ball. A hand pressed
## in deeper than HAND_GIVE or past the ball's centre goes through (it is a ghost until apart), and
## so does one that leaves it through the far side, one found deep in a ball it was not touching and
## one under the floor (it came back up through the floor, say: it would throw the ball up).
func _push(b: Dictionary, hand: Dictionary) -> void:
	var t: StringName = hand.get("tracker", &"")
	var touch: Dictionary = b.get("touch", {})
	if _ghosted(b, hand):
		touch.erase(t)
		return
	var Eb := space.embed(b["l"], b["n"])
	var D := space.embed(hand["l"], hand["n"]) - Eb
	var reach: float = b["radius"] + hand["radius"]
	var dist := D.length()
	if dist >= reach or dist < 1e-6:
		if touch.has(t) and D.dot(touch[t]["d"]) < 0.0:
			ghost(b, t)                      # it left through the far side: it went through
		touch.erase(t)
		return
	var Uh := space.project(b["l"], b["n"], space.embed_vector(hand["l"], hand["n"], hand["U"]))
	var Ub: Vector4 = b["U"]
	var d: Vector4
	if touch.has(t):
		d = _palm_slide(touch[t]["d"], D, reach)
	else:
		d = D / dist
		# a new touch is where the hand comes in: no deeper than it and the ball move in a frame,
		# and not from under the floor
		if reach - dist > TOUCH_DEPTH + Uh.length() / 60.0 + Ub.length() * DT \
				or space.height(hand["l"], hand["n"]) < 0.0:
			ghost(b, t)
			return
	var depth := reach - D.dot(d)
	if depth > minf(HAND_GIVE, reach):           # in deeper, or past the centre: it goes through
		touch.erase(t)
		ghost(b, t)
		return
	var last: Dictionary = touch.get(t, {})
	touch[t] = {"d": d, "depth": depth, "reach": reach}
	b["touch"] = touch
	var Nb := space.project(b["l"], b["n"], -d).normalized()      # at the ball, away from the hand
	var m := mass_kg(b)
	var want := Uh.dot(Nb) + minf(depth / HOLD_TIME, PRESS_SPEED)
	var props := _props(b)
	# the palm drags the ball along as it moves, but not into what the ball rests on
	var drag := Uh
	for pr: Array in props:
		drag -= minf(drag.dot(pr[1]), 0.0) * pr[1]
	# from the last substep's impulses (warm start): pressed against the floor, the push, the palm's
	# friction and the floor's push do not settle in PUSH_ITERATIONS passes from nothing (each pass
	# takes back some of the others'), and the ball crept out sideways at 0.14 m/s
	var jp := PackedFloat64Array()
	var was_p: Dictionary = last.get("jp", {})
	for k in props.size():
		jp.append(was_p.get(props[k][0], 0.0))
		Ub += (jp[k] / m) * props[k][1]
	var jn: float = minf(last.get("jn", 0.0), HAND_FORCE * DT)
	var jt: Vector4 = space.project(b["l"], b["n"], last.get("jt", Vector4.ZERO))
	jt -= jt.dot(Nb) * Nb
	if jt.length() > PALM_FRICTION * jn:
		jt *= PALM_FRICTION * jn / jt.length()
	Ub += (jn / m) * Nb + jt / m
	for _it in PUSH_ITERATIONS:
		var n_new := clampf(jn + m * (want - Ub.dot(Nb)), 0.0, HAND_FORCE * DT)
		Ub += ((n_new - jn) / m) * Nb
		jn = n_new
		var slide := Ub - drag
		slide -= slide.dot(Nb) * Nb
		var t_new: Vector4 = jt - m * slide
		var tl := t_new.length()
		if tl > PALM_FRICTION * jn:
			t_new *= PALM_FRICTION * jn / tl
		Ub += (t_new - jt) / m
		jt = t_new
		for k in props.size():
			var N: Vector4 = props[k][1]
			var p_new := maxf(jp[k] - m * Ub.dot(N), 0.0)
			Ub += ((p_new - jp[k]) / m) * N
			jp[k] = p_new
	b["U"] = Ub
	touch[t]["jn"] = jn
	touch[t]["jt"] = space.embed_vector(b["l"], b["n"], jt)
	var now_p := {}
	for k in props.size():
		now_p[props[k][0]] = jp[k]
	touch[t]["jp"] = now_p


## The floor and the static object ball b rests against, if it does: [name, normal (away from it)].
func _props(b: Dictionary) -> Array:
	var out := []
	var H := space.height(b["l"], b["n"])
	if H < b["radius"] + PROP_GAP:
		out.append(["floor", space.height_grad(b["l"], b["n"]).normalized()])
	var st := _static_contact(b)
	if st[0] > -PROP_GAP:
		out.append(["static", st[1]])
	return out


## Touches (_push) of hands that are gone (no tracking) or now hold the ball are over.
static func _forget_touches(b: Dictionary, hands: Array) -> void:
	var touch: Dictionary = b.get("touch", {})
	for t: StringName in touch.keys():
		var here := false
		for hand in hands:
			here = here or hand["tracker"] == t
		if not here or b["holds"].has(t):
			touch.erase(t)


## Where a hand that touches a ball is on it (d: the direction from its centre) after the hand moved
## to D (from the centre; reach: the centres' distance at a touch): it stays while the hand is within
## the palm's friction cone round the place's normal (tangential offset at most PALM_FRICTION times
## the depth), else it slides toward the hand to the cone's edge.
static func _palm_slide(d: Vector4, D: Vector4, reach: float) -> Vector4:
	var dist := D.length()
	var dc := D / dist
	var cosa := clampf(d.dot(dc), -1.0, 1.0)
	var alpha := acos(cosa)
	if dist * sin(alpha) <= PALM_FRICTION * (reach - dist * cosa):
		return d
	# the angle between the place and the hand at the cone's edge (the nearer one):
	# sin(beta) + mu cos(beta) = mu reach / dist
	var k := PALM_FRICTION * reach / (dist * sqrt(1.0 + PALM_FRICTION * PALM_FRICTION))
	var beta := asin(minf(k, 1.0)) - atan(PALM_FRICTION)
	var across := (dc - cosa * d).normalized()
	var turn := alpha - beta
	return (cos(turn) * d + sin(turn) * across).normalized()


## Where hand `tracker` is drawn when it pushes a ball: on the ball, where it touches it (the one it
## is deepest in), or [] when it touches none.
func touch_place(tracker: StringName) -> Array:
	var best := {}
	var deepest := 0.0
	for b in balls:
		var touch: Dictionary = b.get("touch", {})
		if touch.has(tracker) and touch[tracker]["depth"] > deepest:
			deepest = touch[tracker]["depth"]
			best = b
	if best.is_empty():
		return []
	var tc: Dictionary = best["touch"][tracker]
	var dir := space.project(best["l"], best["n"], tc["d"])
	var at := space.geodesic(best["l"], best["n"], dir.normalized(), tc["reach"], [])
	return [at[0], at[1]]


## A toy just let go is not pushed by the hands that let it go (ghost: their trackers) until each
## is 1 cm apart from it: they held it touching or inside, and set down gently, or thrown with both
## hands, it would be pushed away at once.
func _ghosted(b: Dictionary, hand: Dictionary) -> bool:
	var ghosts: Array = b.get("ghost", [])
	var t: StringName = hand.get("tracker", &"")
	if not ghosts.has(t):
		return false
	if distance_to(b, space.embed(hand["l"], hand["n"])) < hand["radius"] + 0.01:
		return true
	ghosts.erase(t)
	return false


## Hand `tracker` let go of b: it does not push it until they are apart (_ghosted).
static func ghost(b: Dictionary, tracker: StringName) -> void:
	var ghosts: Array = b.get("ghost", [])
	if not ghosts.has(tracker):
		ghosts.append(tracker)
	b["ghost"] = ghosts


func _move(b: Dictionary, dir: Vector4, dist: float) -> void:
	if dist <= 0.0 or dir.length() < 1e-9:
		return
	var carried: Array = [b["U"]]
	var axes: String = "F" if b.has("F") else ("hF" if b.has("hF") else "")
	if axes != "":
		carried.append_array(b[axes])
	var res: Array
	if dist < 0.005:
		res = space.nudge(b["l"], b["n"], dir.normalized() * dist, carried)
	else:
		res = space.geodesic(b["l"], b["n"], dir.normalized(), dist, carried)
	b["l"] = res[0]
	b["n"] = res[1]
	b["U"] = res[2][0]
	if axes != "":
		b[axes] = WormholeSpace.orthonormalize(res[2].slice(1))


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
static func cube_mass(c: Dictionary) -> float:
	return 6.0 / PI * pow(c["half"], 3.0)


static func cube_inertia(c: Dictionary) -> float:
	return 2.0 / 3.0 * cube_mass(c) * c["half"] * c["half"]


## Body coordinates of a tangent vector at the cube's centre, and back.
static func to_body(F: Array, V: Vector4) -> Vector3:
	return Vector3(V.dot(F[0]), V.dot(F[1]), V.dot(F[2]))


static func from_body(F: Array, v: Vector3) -> Vector4:
	return v.x * F[0] + v.y * F[1] + v.z * F[2]


## The cube's box in R^4: [centre, E1, E2, E3, E4].
func box4(c: Dictionary) -> Array:
	var l: float = c["l"]
	var n: Vector3 = c["n"]
	var F: Array = c["F"]
	return [space.embed(l, n), space.embed_vector(l, n, F[0]), space.embed_vector(l, n, F[1]),
			space.embed_vector(l, n, F[2]), space.normal4(l, n)]


## Free motion: the centre moves as a ball does, the axes are transported along and turn by w.
func _integrate_cube(c: Dictionary) -> void:
	var s := space.dynamics_step(c["l"], c["n"], c["U"], DT, GRAVITY, c["F"])
	c["l"] = s[0]
	c["n"] = s[1]
	c["U"] = _air(s[2], AIR_DENSITY * DRAG_CUBE / (4.0 * TOY_DENSITY * c["half"]))
	c["F"] = _turn(s[3], c["w"])


## Axes F turned by the spin w (body coordinates) for a substep.
static func _turn(F: Array, w: Vector3) -> Array:
	var rate := w.length()
	if rate > 1e-9:
		var R := Basis(w / rate, rate * DT)
		F = [from_body(F, R.x), from_body(F, R.y), from_body(F, R.z)]
	return WormholeSpace.orthonormalize(F)


## A contact pushes cube a along na at its point ra, and b (a ball, cube or hand; null for the
## floor and static objects) along nb at rb. Three directions: the normal, then two tangents
## for friction, carried over from a to b through R^4. Per direction the arms r x d in body
## coordinates and the effective inverse mass are kept, so the solver only takes dot products.
class Contact:
	var a: Dictionary
	var b: Dictionary                    # empty: the floor or a static object
	var spin_b := false                  # b is a cube
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
	var cap := INF                       # the most normal impulse (a hand's: HAND_FORCE over a substep)
	var group := ""

	func speed(i: int) -> float:
		var v: float = a["U"].dot(da[i]) + a["w"].dot(arm_a[i])
		if not b.is_empty():
			v += b["U"].dot(db[i])
			if spin_b:
				v += b["w"].dot(arm_b[i])
		return v

	func push(i: int, j: float) -> void:
		if ima > 0.0:
			a["U"] += (j * ima) * da[i]
			a["w"] += (j * iia) * arm_a[i]
		if imb > 0.0:
			b["U"] += (j * imb) * db[i]
			if spin_b:
				b["w"] += (j * iib) * arm_b[i]


## Inverse mass and inverse moment of inertia; 0 for the floor, statics, hands and sleeping things.
func _inverse_mass(b: Variant) -> Vector2:
	if b == null or b.has("tracker"):
		return Vector2.ZERO
	if b.has("F"):
		if b["still"] > SLEEP_TIME:
			return Vector2.ZERO
		return Vector2(1.0 / cube_mass(b), 1.0 / cube_inertia(b))
	return Vector2(1.0 / pow(b["radius"], 3.0), 0.0)


## The unit normal na at a's centre and two unit tangents orthogonal to it:
## [as tangent vectors, in a's body coordinates].
static func _directions(a: Dictionary, na: Vector4) -> Array:
	var F: Array = a["F"]
	var nbody := to_body(F, na)
	var ax := Vector3.RIGHT if absf(nbody.x) < 0.6 else Vector3.UP
	var t1 := (ax - ax.dot(nbody) * nbody).normalized()
	var t2 := nbody.cross(t1)
	return [[na, from_body(F, t1), from_body(F, t2)], [nbody, t1, t2]]


func _contact(a: Dictionary, ra: Vector3, na: Vector4, b: Variant, rb: Vector3, nb: Vector4,
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
		ct.spin_b = b.has("F")
		var mb := _inverse_mass(b)
		ct.imb = mb.x
		ct.iib = mb.y
		ct.db = [nb, Vector4.ZERO, Vector4.ZERO]
		if mu > 0.0:
			for i in [1, 2]:
				var T := space.embed_vector(a["l"], a["n"], ct.da[i])
				ct.db[i] = -space.project(b["l"], b["n"], T).normalized()
		for d in ct.db:
			ct.arm_b.append(rb.cross(to_body(b["F"], d)) if ct.spin_b else Vector3.ZERO)
	for i in 3:
		var kk := ct.ima + ct.iia * ct.arm_a[i].length_squared()
		if b != null:
			kk += ct.imb + ct.iib * ct.arm_b[i].length_squared()
		ct.k.append(kk)
	var vs := ct.speed(0)
	ct.target = -e * vs if vs < -BOUNCE_SPEED else 0.0
	return ct


## Contacts of every cube, then sequential impulses on them, then the overlaps are pushed apart.
func _solve_cubes(hands: Array) -> void:
	var contacts: Array[Contact] = []
	var boxes := []
	for c in cubes:
		boxes.append(box4(c))
	for i in cubes.size():
		var c: Dictionary = cubes[i]
		if c["still"] <= SLEEP_TIME:
			# a held cube is pressed down by its hand: it does not bounce
			var e := RESTITUTION_CUBE if c["holds"].is_empty() else 0.0
			_floor_contacts(c, "f%d" % i, contacts, e)
			_static_contacts(c, "s%d" % i, contacts, e)
		for j in balls.size():
			_ball_contacts(c, boxes[i], balls[j], RESTITUTION_CUBE, "b%d_%d" % [i, j], contacts)
		for j in hands.size():
			if not c["holds"].has(hands[j]["tracker"]) and not _ghosted(c, hands[j]):
				_ball_contacts(c, boxes[i], hands[j], RESTITUTION_HAND, "h%d_%d" % [i, j], contacts, PALM_FRICTION)
		for j in range(i + 1, cubes.size()):
			if (boxes[i][0] - boxes[j][0]).length() < 2.0 * (c["half"] + cubes[j]["half"]):
				_points_in_box(c, boxes[i], cubes[j], boxes[j], "c%d_%d" % [i, j], contacts)
				_points_in_box(cubes[j], boxes[j], c, boxes[i], "c%d_%d" % [i, j], contacts)
	for _it in ITERATIONS:
		for ct in contacts:
			if ct.k[0] <= 0.0:
				continue                     # asleep against the floor or a hand: nothing to push
			var jn := maxf(ct.jn + (ct.target - ct.speed(0)) / ct.k[0], 0.0)
			jn = minf(jn, ct.cap)              # a hand pushes with HAND_FORCE at most
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
		if ct.cap < INF:
			depth = minf(depth, HAND_SLOP)   # a hand's overlap: its push moves the cube, not this
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
		if not c["holds"].is_empty():
			c["still"] = 0.0                 # held, it never sleeps
			continue
		var U: Vector4 = c["U"]
		var w: Vector3 = c["w"]
		if U.length() < SLEEP_SPEED and w.length() < SLEEP_SPIN:
			c["still"] += DT
		else:
			c["still"] = 0.0
		if c["still"] > SLEEP_TIME:
			c["U"] = Vector4.ZERO
			c["w"] = Vector3.ZERO


## Wakes a sleeping cube when b, which touches it, moves.
func _wake(c: Dictionary, b: Dictionary) -> void:
	if c["still"] <= SLEEP_TIME:
		return
	var moving: bool = b["U"].length() > SLEEP_SPEED
	if b.has("F"):
		moving = moving or b["w"].length() > SLEEP_SPIN
	if moving:
		c["still"] = 0.0


## Corners below the floor. Heights to first order at the centre: H + grad H . r, which is the
## z of the box corner in R^4 (exact in the flat universes).
func _floor_contacts(c: Dictionary, group: String, contacts: Array[Contact], e: float) -> void:
	var H := space.height(c["l"], c["n"])
	var a: float = c["half"]
	if H > 1.8 * a:
		return
	var g4 := space.height_grad(c["l"], c["n"])
	var gl := g4.length()
	var gb := to_body(c["F"], g4)
	var dirs := []
	for s: Vector3 in CORNERS:
		var pen := -(H + gb.dot(a * s)) / gl
		if pen > 0.0:
			if dirs.is_empty():
				dirs = _directions(c, g4 / gl)      # shared by all corners
			contacts.append(_contact(c, a * s, g4 / gl, null, Vector3.ZERO, Vector4.ZERO, pen,
					FRICTION_CUBE, e, group, dirs))


## The static objects of the flat universes and the world's wall, in chart coordinates.
func _static_contacts(c: Dictionary, group: String, contacts: Array[Contact], e: float) -> void:
	var l: float = c["l"]
	if absf(l) < space.L:
		return
	var side := signf(l)
	var n: Vector3 = c["n"]
	var x := space.chart_position(l, n)
	var a: float = c["half"]
	var F: Array = c["F"]
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
				Vector3.ZERO, Vector4.ZERO, h[2], FRICTION_CUBE, e, group))


## A ball (or a hand) against the cube: the point of the box closest to the ball's centre, in R^4.
func _ball_contacts(c: Dictionary, box: Array, b: Dictionary, e: float, group: String, contacts: Array[Contact], mu := 0.0) -> void:
	var B := space.embed(b["l"], b["n"])
	var C: Vector4 = box[0]
	var d := B - C
	var rad: float = b["radius"]
	var a: float = c["half"]
	if d.length() > rad + 2.0 * a:
		return
	var q := Vector4(clampf(d.dot(box[1]), -a, a), clampf(d.dot(box[2]), -a, a),
			clampf(d.dot(box[3]), -a, a), clampf(d.dot(box[4]), -a, a))
	var D: Vector4 = B - (C + q.x * box[1] + q.y * box[2] + q.z * box[3] + q.w * box[4])
	var dist := D.length()
	if dist >= rad or dist < 1e-6:
		return
	_wake(c, b)
	var ct := _contact(c, Vector3(q.x, q.y, q.z), space.project(c["l"], c["n"], -D).normalized(),
			b, Vector3.ZERO, space.project(b["l"], b["n"], D).normalized(), rad - dist, mu, e, group)
	if b.has("tracker") and ct.ima > 0.0:
		# the solver's impulses are in its mass units (cube_mass): HAND_FORCE over a substep in them
		ct.cap = HAND_FORCE * DT / (mass_kg(c) * ct.ima)
	contacts.append(ct)


## Corners and edge midpoints of cube P inside cube Q's box push P out through Q's nearest face.
func _points_in_box(P: Dictionary, bp: Array, Q: Dictionary, bq: Array, group: String, contacts: Array[Contact]) -> void:
	var ap: float = P["half"]
	var aq: float = Q["half"]
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
		contacts.append(_contact(P, ap * s, space.project(P["l"], P["n"], out).normalized(),
				Q, q, -signf(q[k]) * Q["F"][k], o[k], FRICTION_CUBE, RESTITUTION_CUBE, group))


# ---------------------------------------------------------------- holding
# A hand holds a toy at a point (its grip, where the hand's centre was when it took it) and pulls it
# toward the place and the turn it had against the hand then, as an arm and a wrist do: a force at
# that point, at most HAND_FORCE, and a twist about it, at most HAND_TORQUE. Within them the toy
# follows the hand exactly (each substep's impulses give it the hand's motion, and take out what is
# left of its place and turn in HOLD_TIME); beyond them it lags. A toy held off its centre needs
# the twist to keep it from swinging about the hand: its weight and its inertia times the lever
# work against the wrist. A flick of the wrist spins a toy only up to WRIST_SPEED. Two hands at
# two points turn it with their forces apart instead. Let go, a toy flies with the motion it has.

const HAND_FORCE := 150.0        # N, per hand: an arm lifts about 15 kg
const HAND_TORQUE := 30.0        # N m, per hand, about its grip: the wrist with the fingers
const WRIST_SPEED := 20.0        # rad/s: the hand turns what it holds no faster (a hand turns a toy as
								 # it turns, a flick spins it no faster; a twist falling off from 0
								 # with the toy's spin, as a muscle's force with its speed, made every
								 # turn sluggish in the headset, and a light toy outran it within a
								 # substep; a cap of 10 left the hand no room to catch up a toy
								 # turning with it: still sluggish)
const BRAKING := 1.5             # a wrist that is stretched holds this much more: what slows a
const BRAKING_SPIN := 0.5        # toy's spin, from this spin (rad/s) on (less below: in proportion);
								 # without it a toy too heavy to hold up swings in the hand for good
								 # (the arm has none: it would hold a crate up that it cannot lift)
const HOLD_TIME := 0.02          # s: what is left of a held toy's place and turn goes in this time
const HOLD_ITERATIONS := 4       # passes over the hands that hold a toy (two share it)


## A toy's mass in kg (TOY_DENSITY) and its moment of inertia about its centre (solid).
static func mass_kg(b: Dictionary) -> float:
	if b.has("F"):
		return 8.0 * TOY_DENSITY * pow(b["half"], 3.0)
	return 4.0 / 3.0 * PI * TOY_DENSITY * pow(b["radius"], 3.0)


static func inertia_kg(b: Dictionary) -> float:
	if b.has("F"):
		return 2.0 / 3.0 * mass_kg(b) * b["half"] * b["half"]
	return 0.4 * mass_kg(b) * b["radius"] * b["radius"]


## Hand `tracker` takes toy b at its point g (body coordinates, from the centre). A ball gets axes
## while it is held, ball_axes (tangent at its centre), since a hand turns what it holds. The hold's
## aim is where the toy is now, at rest, until aim says otherwise; its strength HAND_FORCE and
## HAND_TORQUE until strength says otherwise.
func take(b: Dictionary, tracker: StringName, g: Vector3, ball_axes: Array) -> void:
	if not b.has("F") and not b.has("hF"):
		b["hF"] = WormholeSpace.orthonormalize(ball_axes)
		b["hw"] = Vector3.ZERO
	var was: Dictionary = b["holds"].get(tracker, {})
	b["holds"][tracker] = {"g": g, "l": b["l"], "n": b["n"],
			"A": (b["F"] if b.has("F") else b["hF"]).duplicate(), "V": Vector4.ZERO, "W": Vector4.ZERO,
			"acc": Vector4.ZERO, "force": was.get("force", HAND_FORCE), "torque": was.get("torque", HAND_TORQUE)}
	if b.has("ghost"):
		b["ghost"].erase(tracker)
	if b.has("F"):
		b["still"] = 0.0


## How strong hand `tracker`'s hold on b is: the most force (N) and twist (N m) it gives.
func strength(b: Dictionary, tracker: StringName, force: float, torque: float) -> void:
	b["holds"][tracker]["force"] = force
	b["holds"][tracker]["torque"] = torque


func let_go(b: Dictionary, tracker: StringName) -> void:
	b["holds"].erase(tracker)
	if b["holds"].is_empty():
		b.erase("hF")
		b.erase("hw")


## Where hand `tracker` wants its toy: its centre at (l, n) with axes A there, moving with velocity V
## and spin W (a tangent vector there: the axis times rad/s), as it would if it moved with the hand,
## and the hand's acceleration Acc (where the hand was a substep before: on an arc, not a line).
func aim(b: Dictionary, tracker: StringName, l: float, n: Vector3, A: Array, V: Vector4, W: Vector4, Acc: Vector4) -> void:
	var h: Dictionary = b["holds"][tracker]
	h["l"] = l
	h["n"] = n
	h["A"] = A
	h["V"] = V
	h["W"] = W
	h["acc"] = Acc


## The toy put where hand `tracker` wants it, moving as it wants (the viewer was moved: the hand
## jumped, and so does what it holds).
func snap(b: Dictionary, tracker: StringName) -> void:
	var h: Dictionary = b["holds"][tracker]
	var A: Array = WormholeSpace.orthonormalize(h["A"])
	b["l"] = h["l"]
	b["n"] = h["n"]
	b["U"] = h["V"]
	b["F" if b.has("F") else "hF"] = A
	b["w" if b.has("F") else "hw"] = to_body(A, h["W"])


## Where the toy's grip point of hand `tracker` is: the geodesic from its centre along g in its axes.
func grip_place(b: Dictionary, tracker: StringName) -> Array:
	var G := from_body(b["F"] if b.has("F") else b["hF"], b["holds"][tracker]["g"])
	if G.length() < 1e-6:
		return [b["l"], b["n"]]
	var at := space.geodesic(b["l"], b["n"], G / G.length(), G.length(), [])
	return [at[0], at[1]]


## The hands' pull on the held toys for one substep: impulses on their velocity and spin, toward
## where the hands wanted them `lag` s before the aims (the end of this substep).
func _hold(lag: float) -> void:
	for list in [balls, cubes]:
		for b: Dictionary in list:
			if not b["holds"].is_empty():
				_hold_toy(b, lag)


## Each hand's grip is a point g of the toy (body coordinates) that the hand moves as its own centre
## moves, and a turn it gives the toy: per hand an impulse P at g (the arm) and a twist L (the
## wrist), found so that after them the grip point and the spin are as the hand wants (its motion,
## plus what takes the place and turn left over out in HOLD_TIME; the spin no more than
## WRIST_SPEED), then limited: P to HAND_FORCE first, L for that P to HAND_TORQUE, and if L is at its
## limit, P found again for the turn the toy then has, and limited. The impulses also hold the
## toy's weight (this substep's fall is counted in). Body coordinates, the inertia a ball's or a
## cube's (the same about any axis): an impulse P at g changes the velocity by P / m and the spin
## by g x P / I, so the grip point moves by P / m along g and by P (1 / m + |g|^2 / I) across it.
func _hold_toy(b: Dictionary, lag: float) -> void:
	var l: float = b["l"]
	var n: Vector3 = b["n"]
	var cube: bool = b.has("F")
	var F: Array = b["F"] if cube else b["hF"]
	var m := mass_kg(b)
	var I := inertia_kg(b)
	var E := space.embed(l, n)
	var weight := to_body(F, space.potential_grad(l, n)) * (-GRAVITY * m)
	# half the substep's fall: the impulses give the toy the velocity it should have on average
	# over the substep, which is what moves it
	var fall := weight * (0.5 * DT / m)
	var v0 := to_body(F, b["U"])
	var w: Vector3 = b["w"] if cube else b["hw"]
	var w0 := w
	var v := v0 + fall
	# how it moves, for the muscles: on average over the last substep (a toy held still is at rest,
	# not falling at half a substep's fall)
	var moving := v0 - fall
	var hands: int = b["holds"].size()
	var grips := []
	for h: Dictionary in b["holds"].values():
		var g: Vector3 = h["g"]
		var hl: float = h["l"]
		var hn: Vector3 = h["n"]
		var A: Array = h["A"]
		# the aim's grip point (its centre plus g in its axes, to first order, as the toy's own below)
		# and how it moves (with the hand: the aim's velocity plus its spin times g), back by lag
		var Wa := to_body(A, h["W"])
		var acc: Vector4 = h["acc"]
		var Va: Vector4 = h["V"] + from_body(A, Wa.cross(g))
		var aim := space.embed(hl, hn) + space.embed_vector(hl, hn,
				from_body(A, g) - Va * lag + acc * (0.5 * lag * lag))
		Va -= acc * lag
		var grip := E + space.embed_vector(l, n, from_body(F, g))
		# seen from the toy (chords of R^4: the toy is near its aim)
		var vp := to_body(F, space.project(l, n, space.embed_vector(hl, hn, Va)))
		var W := to_body(F, space.project(l, n, space.embed_vector(hl, hn, h["W"])))
		var M := Basis(to_body(F, space.project(l, n, space.embed_vector(hl, hn, A[0]))),
				to_body(F, space.project(l, n, space.embed_vector(hl, hn, A[1]))),
				to_body(F, space.project(l, n, space.embed_vector(hl, hn, A[2])))).orthonormalized()
		var turn := _rotation_vector(M.get_rotation_quaternion()) - W * lag
		var place := to_body(F, space.project(l, n, aim - grip))
		# what is left of the hand's strength once it holds the weight (shared by the hands; the
		# weight's torque about the grip only for one hand: two turn it with their forces apart) is
		# how fast it closes the gap: a toy too heavy to hold up sags to where the wrist holds it and
		# stops there (with the hand's whole strength the hand would swing it about there for good)
		var Ig := I + m * g.length_squared()
		var force: float = h["force"]
		var torque: float = h["torque"]
		var lift := maxf(force - weight.length() / hands, 0.1 * force) / m
		var twist := torque - (g.cross(weight).length() if hands == 1 else 0.0)
		grips.append({"g": g, "vp": vp + _closing(place, lift),
				"w": (W + _closing(turn, maxf(twist, 0.1 * torque) / Ig)).limit_length(WRIST_SPEED),
				"P": Vector3.ZERO, "L": Vector3.ZERO, "force": force, "torque": torque})
	for _it in HOLD_ITERATIONS:
		for gr: Dictionary in grips:
			var g: Vector3 = gr["g"]
			var dw: Vector3 = gr["w"] - w
			var dv: Vector3 = gr["vp"] - (v + w.cross(g))
			# the muscles' speeds: the toy's motion as the substep starts (not as the impulses change it)
			var arm := moving + w0.cross(g)
			# the twist for the force the arm can give (for the force it would want, it would turn a toy
			# pressed against the floor the other way)
			var P0: Vector3 = _muscle(gr["P"] + m * (dv - dw.cross(g)), arm, gr["force"], INF) - gr["P"]
			var Lw: Vector3 = gr["L"] + I * dw - g.cross(P0)
			var L: Vector3 = _muscle(Lw, w0, gr["torque"], BRAKING_SPIN)
			var dL: Vector3 = L - gr["L"]
			var dP := P0
			if not L.is_equal_approx(Lw):
				# the wrist at its limit: the toy turns otherwise than the hand, and the arm moves the
				# grip point as the toy turns. (A wrist that holds the turn keeps it: an arm at its
				# limit, the grip point short of where the hand wants it, does not turn the toy to
				# get it there: pressed into the floor, a ball was turned and slid away.)
				var rhs: Vector3 = dv - (dL / I).cross(g)
				var g2 := g.length_squared()
				dP = m * rhs
				if g2 > 1e-12:
					var along := (rhs.dot(g) / g2) * g
					dP = m * along + (rhs - along) / (1.0 / m + g2 / I)
				dP = _muscle(gr["P"] + dP, arm, gr["force"], INF) - gr["P"]
			var P: Vector3 = gr["P"] + dP
			v += dP / m
			w += (dL + g.cross(dP)) / I
			gr["P"] = P
			gr["L"] = L
	b["U"] = from_body(F, v - fall)
	b["w" if cube else "hw"] = w


## The velocity that takes error e out in HOLD_TIME, but no faster than one that a deceleration of
## half of a (what the hand has to spare) can still stop at the place: a toy that lags because the
## hand's strength is all used does not overshoot when it catches up.
static func _closing(e: Vector3, a: float) -> Vector3:
	var d := e.length()
	if d < 1e-9:
		return Vector3.ZERO
	return e * minf(1.0 / HOLD_TIME, sqrt(a / d))


## An impulse J of a muscle (the arm's force at the grip, the wrist's twist) limited by its
## strength `most` (N or N m, over a substep): what slows the motion vel (the grip point's velocity,
## the toy's spin) may be BRAKING times as much, from the speed `brake` on (less below, in
## proportion; INF: never more).
static func _muscle(J: Vector3, vel: Vector3, most: float, brake: float) -> Vector3:
	most *= DT
	var s := vel.length()
	if s < 1e-6 or J.dot(vel) >= 0.0:
		return J.limit_length(most)
	return J.limit_length(most * (1.0 + (BRAKING - 1.0) * minf(s / brake, 1.0)))


## The rotation vector (axis times angle) of a unit quaternion.
static func _rotation_vector(q: Quaternion) -> Vector3:
	if q.w < 0.0:
		q = -q
	var u := Vector3(q.x, q.y, q.z)
	var s := u.length()
	if s < 1e-9:
		return 2.0 * u
	return u * (2.0 * atan2(s, q.w) / s)
