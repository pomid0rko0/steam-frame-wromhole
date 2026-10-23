class_name BallWorld
extends RefCounted
## Balls moving through the wormhole space.
##
## A ball is a point (l, n) with velocity U = (U_l, u) and a radius. Free motion follows
## geodesics (zero redshift: no gravity from the metric itself) plus an explicit field
## pulling toward the floor, -g grad H with H = r(l) n_z, which is ordinary uniform gravity
## in both flat universes. Collisions use chord distances in R^4, the same definition of a
## ball the shader renders: the points within `radius` of the centre, measured in R^4.

const GRAVITY := 9.81
const DT := 1.0 / 180.0
const RESTITUTION_FLOOR := 0.55
const RESTITUTION_BALL := 0.85
const ROLLING_RESISTANCE := 0.02     # rolling friction coefficient: deceleration 0.02 g on the floor
const MAX_BALLS := 8
const WORLD_RADIUS := 40.0           # chart radius of an invisible wall that keeps balls nearby

var space: WormholeSpace
var scene: Dictionary
var balls: Array = []                # Dictionary: l, n, U, radius, color, held (StringName or &"")
var _acc := 0.0


func _init(p_space: WormholeSpace, p_scene: Dictionary) -> void:
	space = p_space
	scene = p_scene


func add(l: float, n: Vector3, U: Vector4, radius: float, color: Color) -> Dictionary:
	if balls.size() >= MAX_BALLS:
		balls.pop_front()
	var b := {"l": l, "n": n, "U": U, "radius": radius, "color": color, "held": &""}
	balls.append(b)
	return b


## Advance by delta seconds with fixed substeps. hands: Array of {l, n, U, radius} (kinematic).
func step(delta: float, hands: Array) -> void:
	_acc = minf(_acc + delta, 0.1)
	while _acc >= DT:
		_acc -= DT
		for b in balls:
			if b["held"] != &"":
				continue
			var s := space.dynamics_step(b["l"], b["n"], b["U"], DT, GRAVITY)
			b["l"] = s[0]
			b["n"] = s[1]
			b["U"] = s[2]
			_floor(b)
			_statics(b)
		for i in balls.size():
			for j in range(i + 1, balls.size()):
				_pair(balls[i], balls[j], RESTITUTION_BALL)
		for hand in hands:
			for b in balls:
				if b["held"] == &"":
					_push(b, hand)


## Signed chord distance between the surfaces of two balls (negative: overlap).
func gap(a: Dictionary, b: Dictionary) -> float:
	return (space.embed(a["l"], a["n"]) - space.embed(b["l"], b["n"])).length() - a["radius"] - b["radius"]


func _floor(b: Dictionary) -> void:
	var H := space.height(b["l"], b["n"])
	var rad: float = b["radius"]
	if H >= rad:
		return
	var g := space.height_grad(b["l"], b["n"])
	var gl := g.length()
	var N := g / gl
	var U: Vector4 = b["U"]
	var vn := U.dot(N)
	if vn < 0.0:
		U -= (1.0 + RESTITUTION_FLOOR) * vn * N
		if absf(vn) < 0.6:
			U -= U.dot(N) * N               # settle instead of micro-bouncing
	var Ut := U - U.dot(N) * N
	var speed := Ut.length()
	if speed > 0.0:
		U -= Ut * (minf(ROLLING_RESISTANCE * GRAVITY * DT, speed) / speed)
	b["U"] = U
	_move(b, N, (rad - H) / gl)


func _statics(b: Dictionary) -> void:
	var l: float = b["l"]
	if absf(l) < space.L:
		return                               # static objects live in the flat universes only
	var side := signf(l)
	var x := space.chart_position(l, b["n"])
	var rad: float = b["radius"]
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
	var N := WormholeSpace.vector_from_chart(side, b["n"], normal)
	var U: Vector4 = b["U"]
	var vn := U.dot(N)
	if vn < 0.0:
		U -= (1.0 + RESTITUTION_BALL) * vn * N
	b["U"] = U
	_move(b, N, depth)


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
	var ma: float = pow(a["radius"], 3.0) if a["held"] == &"" else 1e9
	var mb: float = pow(b["radius"], 3.0) if b["held"] == &"" else 1e9
	var Ua: Vector4 = a["U"]
	var Ub: Vector4 = b["U"]
	var approach := Ua.dot(Na) + Ub.dot(Nb)
	if approach > 0.0:
		var j := (1.0 + e) * approach / (1.0 / ma + 1.0 / mb)
		a["U"] = Ua - (j / ma) * Na
		b["U"] = Ub - (j / mb) * Nb
	var wa := mb / (ma + mb)
	if a["held"] == &"":
		_move(a, -Na, pen * wa)
	if b["held"] == &"":
		_move(b, -Nb, pen * (1.0 - wa))


## A hand (kinematic sphere) pushing a free ball.
func _push(b: Dictionary, hand: Dictionary) -> void:
	var Eb := space.embed(b["l"], b["n"])
	var Eh := space.embed(hand["l"], hand["n"])
	var D := Eb - Eh
	var dist := D.length()
	var pen: float = b["radius"] + hand["radius"] - dist
	if pen <= 0.0 or dist < 1e-6:
		return
	var Nb := space.project(b["l"], b["n"], D).normalized()      # at the ball, away from the hand
	var Nh := space.project(hand["l"], hand["n"], D).normalized()
	var Ub: Vector4 = b["U"]
	var rel: float = hand["U"].dot(Nh) - Ub.dot(Nb)
	if rel > 0.0:
		b["U"] = Ub + (1.0 + RESTITUTION_BALL) * rel * Nb
	_move(b, Nb, pen)


func _move(b: Dictionary, dir: Vector4, dist: float) -> void:
	if dist <= 0.0:
		return
	var res := space.geodesic(b["l"], b["n"], dir.normalized(), dist, [b["U"]])
	b["l"] = res[0]
	b["n"] = res[1]
	b["U"] = res[2][0]
