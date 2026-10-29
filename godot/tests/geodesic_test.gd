extends SceneTree
## WormholeSpace.geodesic (the head above the feet, the hands from the head, walking, the toys'
## moves) against the full equations of docs/geometry.md («Движение наблюдателя и предметов»), exit
## status 1 on any failure:
##   godot --path . --headless -s res://tests/geodesic_test.gd
## The reference: RK4 in float64 of (l, n) and four transported vectors, no plane taken, in steps of
## REF_STEP; with no cylinder a step is cut where l crosses 0 (with h < R, r' jumps there; the
## crossing on the step's cubic in l) and the profile there is taken from the side the step is on. On five throats (docs/geometry.md,
## «Точность», in metres here):
## 1. from points in and around the curved zone, in random directions (radial and tangential among
##    them), 0 to 12 m;
## 2. paths that come close to the throat's narrowest circle, r_min: from a fillet toward the
##    throat with impact parameter b within 1% of r_min, just below (they pass the throat) and just
##    above (they turn back just before it), up to 6 m.
## Each: where the path ends and where three transported vectors point, within TOL (the vectors' own
## single precision is about 1e-6 at these distances). Near r_min a path is so sensitive to its
## direction that a change of it in its last stored digit can move its end by more than TOL: there
## within TOL beyond the spread of the reference itself, whose direction a second run takes about
## two single-precision steps longer across.

const U := preload("res://tests/util.gd")
const PROFILES := [[3.0, 5.0, 1.0], [3.0, 1.0, 1.0], [3.0, 0.4, 1.0], [3.0, 0.1, 0.2], [3.0, 3.0, 2.5]]
const CASES := 60               # per profile: 1
const GRAZING := 20             # per profile: 2
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
		# 2
		var rmin: float = sp.r(0.0)
		worst_p = 0.0
		worst_f = 0.0
		var wrong := 0
		var spread := 0.0
		for i in GRAZING:
			var sg := 1.0 if i % 4 < 2 else -1.0
			var l := sg * rng.randf_range(sp.Lc + 0.5 * (sp.L - sp.Lc), sp.L)
			var b := rmin * (1.0 + (1.0 if i % 2 == 0 else -1.0) * pow(10.0, rng.randf_range(-6.0, -2.0)))
			var n := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
			var t := _random_tangent(rng, n)
			var e := Vector3(t.y, t.z, t.w).normalized()
			var ut := b / sp.r(l)
			var dir := Vector4(-sg * sqrt(1.0 - ut * ut), ut * e.x, ut * e.y, ut * e.z)
			var dist := rng.randf_range(1.0, 6.0)
			var fr := [_random_tangent(rng, n), _random_tangent(rng, n), dir]
			var a := sp.geodesic(l, n, dir, dist, fr)
			var r := _reference(l, n, dir, dist, fr)
			var wider := Vector4(dir.x, (1.0 + 2.4e-7) * dir.y, (1.0 + 2.4e-7) * dir.z, (1.0 + 2.4e-7) * dir.w)
			var r2 := _reference(l, n, wider, dist, fr)
			if signf(a[0]) != signf(r[0]):
				wrong += 1
			var sp_p := (sp.embed(r2[0], r2[1]) - sp.embed(r[0], r[1])).length()
			var sp_f := 0.0
			var off_f := 0.0
			for k in 3:
				sp_f = maxf(sp_f, (sp.embed_vector(r2[0], r2[1], r2[2][k]) - sp.embed_vector(r[0], r[1], r[2][k])).length())
				off_f = maxf(off_f, (sp.embed_vector(a[0], a[1], a[2][k]) - sp.embed_vector(r[0], r[1], r[2][k])).length())
			spread = maxf(spread, sp_p)
			worst_p = maxf(worst_p, (sp.embed(a[0], a[1]) - sp.embed(r[0], r[1])).length() - sp_p)
			worst_f = maxf(worst_f, off_f - sp_f)
		U.check("geodesic near r_min, throat %s" % [pr], wrong == 0 and worst_p < TOL and worst_f < TOL,
				"%d paths, %d in the other universe than the reference's; beyond the reference's spread (up to %s m), end point off by %s m at most, transported vectors by %s"
				% [GRAZING, wrong, String.num_scientific(spread), String.num_scientific(worst_p), String.num_scientific(worst_f)])
	U.finish(self)


func _random_tangent(rng: RandomNumberGenerator, n: Vector3) -> Vector4:
	return WormholeSpace.tangent(n, Vector4(rng.randfn(), rng.randfn(), rng.randfn(), rng.randfn())).normalized()


## The profile on side sg, [r, r'] (float64): as WormholeSpace's r, dr, but at l = 0 that side's.
func _prof(l: float, sg: float) -> PackedFloat64Array:
	var al := sg * l
	if al >= sp.L:
		return PackedFloat64Array([al - sp.L + sp.Rout, sg])
	if sp.Lc > 0.0 and al <= sp.Lc:
		return PackedFloat64Array([sp.rho0, 0.0])
	var th := sp.th0 + (al - sp.Lc) / sp.fillet
	return PackedFloat64Array([sp.rho0 + sp.fillet * (1.0 - cos(th)), sg * sin(th)])


## d/ds of [l, n, then (U_l, u) per vector, the first the velocity], on side sg.
func _deriv(y: PackedFloat64Array, sg: float) -> PackedFloat64Array:
	var p := _prof(y[0], sg)
	var rr := p[0]
	var k := p[1] / rr
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
			# across l = 0: the step up to it (where the cubic of l, its values and slopes at the
			# step's ends, crosses 0), then on the other side
			h *= _zero(y[0], y[4] * h, y1[0], y1[4] * h)
			y1 = _rk4(y, h, sg)
			y1[0] = 0.0
		y = y1
		left -= h
	var out := []
	for o in range(8, y.size(), 4):
		out.append(Vector4(y[o], y[o + 1], y[o + 2], y[o + 3]))
	return [y[0], Vector3(y[1], y[2], y[3]).normalized(), out]


## Where the cubic with values y0, y1 (of opposite signs) and slopes d0, d1 (per step) at a step's
## ends is 0: the step's fraction, by bisection.
static func _zero(y0: float, d0: float, y1: float, d1: float) -> float:
	var a := 0.0
	var z := 1.0
	for _it in 50:
		var t := 0.5 * (a + z)
		var t2 := t * t
		var t3 := t2 * t
		var y := (2.0 * t3 - 3.0 * t2 + 1.0) * y0 + (t3 - 2.0 * t2 + t) * d0 + (-2.0 * t3 + 3.0 * t2) * y1 + (t3 - t2) * d1
		if (y > 0.0) == (y0 > 0.0):
			a = t
		else:
			z = t
	return z
