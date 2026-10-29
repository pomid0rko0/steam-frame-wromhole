extends SceneTree
## WormholeSpace.geodesic (the head above the feet, each eye and hand from the head, walking, the
## toys' moves) against the full equations of docs/geometry.md («Движение наблюдателя и
## предметов»), exit status 1 on any failure:
##   godot --path . --headless -s res://tests/geodesic_test.gd
## The reference: RK4 in float64 of (l, n) and four transported vectors, no plane taken, in steps of
## REF_STEP, a step cut where l crosses 0 (where fillets meet with no cylinder, r' jumps) and the
## profile there taken from the side the step is on. On five throats (docs/geometry.md, «Точность»,
## in metres here), from points in and around the curved zone, in random directions (radial and
## tangential among them), 0 to 12 m: where the path ends and where three transported vectors
## point, within TOL (the vectors' own single precision is about 1e-6 at these distances).

const U := preload("res://tests/util.gd")
const PROFILES := [[3.0, 5.0, 1.0], [3.0, 1.0, 1.0], [3.0, 0.4, 1.0], [3.0, 0.1, 0.2], [3.0, 3.0, 2.5]]
const CASES := 60               # per profile
const REF_STEP := 0.002         # m
const TOL := 2e-5               # m, and for unit vectors

var sp: WormholeSpace


func _initialize() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for pr in PROFILES:
		sp = WormholeSpace.new(pr[0], pr[1], pr[2])
		var worst_p := 0.0
		var worst_f := 0.0
		for i in CASES:
			var l := rng.randf_range(-sp.L - 3.0, sp.L + 3.0)
			if i % 3 == 0:
				l = rng.randf_range(-sp.L - 0.3, sp.L + 0.3)
			var n := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
			var dir := _random_tangent(rng, n)
			if i % 10 == 1:
				dir = Vector4(signf(rng.randf() - 0.5), 0.0, 0.0, 0.0)
			elif i % 10 == 2:
				var t := _random_tangent(rng, n)
				dir = Vector4(0.0, t.y, t.z, t.w).normalized()
			var dist := rng.randf_range(0.0, 3.0) if i % 7 != 0 else rng.randf_range(3.0, 12.0)
			var fr := [_random_tangent(rng, n), _random_tangent(rng, n), dir]
			var a := sp.geodesic(l, n, dir, dist, fr)
			var b := _reference(l, n, dir, dist, fr)
			worst_p = maxf(worst_p, (sp.embed(a[0], a[1]) - sp.embed(b[0], b[1])).length())
			for k in 3:
				worst_f = maxf(worst_f, (sp.embed_vector(a[0], a[1], a[2][k]) - sp.embed_vector(b[0], b[1], b[2][k])).length())
		U.check("geodesic, throat %s" % [pr], worst_p < TOL and worst_f < TOL,
				"%d paths: end point off by %s m at most, transported vectors by %s" % [CASES,
				String.num_scientific(worst_p), String.num_scientific(worst_f)])
	U.finish(self)


func _random_tangent(rng: RandomNumberGenerator, n: Vector3) -> Vector4:
	return WormholeSpace.tangent(n, Vector4(rng.randfn(), rng.randfn(), rng.randfn(), rng.randfn())).normalized()


## The profile on side sg (r, r'): as WormholeSpace's r, dr, but at l = 0 that side's.
func _prof(l: float, sg: float) -> Vector2:
	var al := sg * l
	if al >= sp.L:
		return Vector2(al - sp.L + sp.Rout, sg)
	if sp.Lc > 0.0 and al <= sp.Lc:
		return Vector2(sp.rho0, 0.0)
	var th := sp.th0 + (al - sp.Lc) / sp.fillet
	return Vector2(sp.rho0 + sp.fillet * (1.0 - cos(th)), sg * sin(th))


## d/ds of [l, n, then (U_l, u) per vector, the first the velocity], on side sg.
func _deriv(y: PackedFloat64Array, sg: float) -> PackedFloat64Array:
	var p := _prof(y[0], sg)
	var rr: float = p.x
	var k: float = p.y / rr
	var d := PackedFloat64Array()
	d.resize(y.size())
	d[0] = y[4]
	for j in 3:
		d[1 + j] = y[5 + j] / rr
	for o in range(4, y.size(), 4):
		var uv := y[o + 1] * y[5] + y[o + 2] * y[6] + y[o + 3] * y[7]
		d[o] = k * uv
		for j in 3:
			d[o + 1 + j] = -k * y[o] * y[5 + j] - uv / rr * y[1 + j]
	return d


func _rk4(y: PackedFloat64Array, h: float, sg: float) -> PackedFloat64Array:
	var k1 := _deriv(y, sg)
	var k2 := _deriv(_plus(y, k1, 0.5 * h), sg)
	var k3 := _deriv(_plus(y, k2, 0.5 * h), sg)
	var k4 := _deriv(_plus(y, k3, h), sg)
	var out := y.duplicate()
	for i in out.size():
		out[i] += h / 6.0 * (k1[i] + 2.0 * k2[i] + 2.0 * k3[i] + k4[i])
	return out


static func _plus(y: PackedFloat64Array, d: PackedFloat64Array, h: float) -> PackedFloat64Array:
	var out := y.duplicate()
	for i in out.size():
		out[i] += h * d[i]
	return out


func _reference(l: float, n: Vector3, dir: Vector4, dist: float, frame: Array) -> Array:
	var y := PackedFloat64Array([l, n.x, n.y, n.z])
	for v: Vector4 in [dir] + frame:
		y.append_array([v.x, v.y, v.z, v.w])
	var left := dist
	while left > 0.0:
		var h := minf(REF_STEP, left)
		var sg := signf(y[0]) if y[0] != 0.0 else signf(y[4])
		var y1 := _rk4(y, h, sg)
		if sp.Lc == 0.0 and y1[0] * sg < 0.0:
			# across l = 0: the step up to it (linearly), then on the other side
			h *= y[0] / (y[0] - y1[0])
			y1 = _rk4(y, h, sg)
			y1[0] = 0.0
		y = y1
		left -= h
	var out := []
	for o in range(8, y.size(), 4):
		out.append(Vector4(y[o], y[o + 1], y[o + 2], y[o + 3]))
	return [y[0], Vector3(y[1], y[2], y[3]).normalized(), out]
