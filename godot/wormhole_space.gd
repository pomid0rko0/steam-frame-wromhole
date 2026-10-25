class_name WormholeSpace
extends RefCounted
## Geometry of the wormhole space on the CPU side: moving the viewer along
## geodesics and parallel-transporting their frame. Same metric as the shader
## (optozorax's SDF world: planes w = +-h, extruded sphere rho0, union_round fillet R):
##   ds^2 = dl^2 + r(l)^2 dOmega^2
##   cylinder |l| <= Lc:      r = rho0
##   fillet   Lc <= |l| <= L: r = rho0 + R (1 - cos th),  th = th0 + (|l| - Lc) / R
##   flat     |l| >= L:       r = |l| - L + Rout
##   Lc = max(h - R, 0), th0 = asin(max(1 - h/R, 0)), L = Lc + R (pi/2 - th0), Rout = rho0 + R
## A point is (l, n): n is a unit Vector3 on the shared angular sphere.
## A tangent vector is Vector4(U_l, u.x, u.y, u.z): U_l along d/dl, u the physical
## tangential part (u . n = 0). In this representation the metric is Vector4.dot.

const STEP := 0.02  # metres per RK4 step

var rho0: float
var h: float
var fillet: float
var Lc: float
var th0: float
var L: float
var Rout: float


func _init(throat_radius: float, half_length: float, fillet_radius: float) -> void:
	set_profile(throat_radius, half_length, fillet_radius)


func set_profile(throat_radius: float, half_length: float, fillet_radius: float) -> void:
	rho0 = throat_radius
	h = half_length
	fillet = fillet_radius
	Lc = maxf(h - fillet, 0.0)
	th0 = asin(maxf(1.0 - h / fillet, 0.0))
	L = Lc + fillet * (PI / 2.0 - th0)
	Rout = rho0 + fillet


func _theta(al: float) -> float:
	return th0 + (clampf(al, Lc, L) - Lc) / fillet


func r(l: float) -> float:
	var al := absf(l)
	if al >= L:
		return al - L + Rout
	return rho0 + fillet * (1.0 - cos(_theta(al)))


func dr(l: float) -> float:
	var al := absf(l)
	if al >= L:
		return signf(l)
	return signf(l) * sin(_theta(al))


## d/ds of (l, n, vectors) for a geodesic whose velocity is vectors[0];
## every vector in the list is parallel-transported.
func _deriv(l: float, n: Vector3, vecs: Array) -> Array:
	var rr := r(l)
	var k := dr(l) / rr
	var vel: Vector4 = vecs[0]
	var w := Vector3(vel.y, vel.z, vel.w)
	var dvecs := []
	for U: Vector4 in vecs:
		var u := Vector3(U.y, U.z, U.w)
		var du := -k * U.x * w - (u.dot(w) / rr) * n
		dvecs.append(Vector4(k * w.dot(u), du.x, du.y, du.z))
	return [vel.x, w / rr, dvecs]


func _shift(l: float, n: Vector3, vecs: Array, d: Array, h: float) -> Array:
	var out := []
	for i in vecs.size():
		out.append(vecs[i] + h * d[2][i])
	return [l + h * d[0], n + h * d[1], out]


## Follow the geodesic from (l, n) with unit initial direction dir for length dist,
## transporting frame (Array of Vector4). Returns [l, n, frame].
func geodesic(l: float, n: Vector3, dir: Vector4, dist: float, frame: Array) -> Array:
	if dist <= 0.0:
		return [l, n, frame.duplicate()]
	var vecs := [dir]
	vecs.append_array(frame)
	var steps := maxi(1, ceili(dist / STEP))
	var h := dist / steps
	for _s in steps:
		var k1 := _deriv(l, n, vecs)
		var y2 := _shift(l, n, vecs, k1, 0.5 * h)
		var k2 := _deriv(y2[0], y2[1], y2[2])
		var y3 := _shift(l, n, vecs, k2, 0.5 * h)
		var k3 := _deriv(y3[0], y3[1], y3[2])
		var y4 := _shift(l, n, vecs, k3, h)
		var k4 := _deriv(y4[0], y4[1], y4[2])
		l += h / 6.0 * (k1[0] + 2.0 * k2[0] + 2.0 * k3[0] + k4[0])
		n += h / 6.0 * (k1[1] + 2.0 * k2[1] + 2.0 * k3[1] + k4[1])
		n = n.normalized()
		for i in vecs.size():
			var U: Vector4 = vecs[i] + h / 6.0 * (k1[2][i] + 2.0 * k2[2][i] + 2.0 * k3[2][i] + k4[2][i])
			vecs[i] = tangent(n, U)
	return [l, n, vecs.slice(1)]


## Drop the component along n (keeps a vector tangent after a numerical step).
static func tangent(n: Vector3, U: Vector4) -> Vector4:
	var u := Vector3(U.y, U.z, U.w)
	u -= u.dot(n) * n
	return Vector4(U.x, u.x, u.y, u.z)


## Gram-Schmidt on a right-handed frame [ex, ey, ez].
static func orthonormalize(f: Array) -> Array:
	var ey: Vector4 = f[1].normalized()
	var ez: Vector4 = f[2] - f[2].dot(ey) * ey
	ez = ez.normalized()
	var ex: Vector4 = f[0] - f[0].dot(ey) * ey - f[0].dot(ez) * ez
	return [ex.normalized(), ey, ez]


## Chart of the flat region on one side: side A (l >= L) x = r n, side B x = P r n,
## P = diag(-1, 1, 1). Converts a chart position to a manifold point.
func point_from_chart(side: float, x: Vector3) -> Array:
	var rr := x.length()
	var n := x / rr
	if side < 0.0:
		n.x = -n.x
	return [side * (rr - Rout + L), n]


## Chart direction d at manifold point (l, n), l on that side's flat region.
static func vector_from_chart(side: float, n: Vector3, d: Vector3) -> Vector4:
	var md := d
	if side < 0.0:
		md.x = -md.x
	var rad := md.dot(n)
	var u := md - rad * n
	return Vector4(side * rad, u.x, u.y, u.z)


## 4th coordinate of the embedding in R^4 (odd in l): the world is the hypersurface (r n, w(l)).
func w(l: float) -> float:
	var al := absf(l)
	if al >= L:
		return signf(l) * h
	if al <= Lc:
		return l
	return signf(l) * (h - fillet + fillet * sin(_theta(al)))


## The point (l, n) as a point of R^4.
func embed(l: float, n: Vector3) -> Vector4:
	var p := r(l) * n
	return Vector4(p.x, p.y, p.z, w(l))


## Chart side and chart position of a point in a flat region.
func chart_position(l: float, n: Vector3) -> Vector3:
	var x := r(l) * n
	if l < 0.0:
		x.x = -x.x
	return x


# ---------------------------------------------------------------- the fillet table
## The ray tracer's fillet polynomials (wormhole_core.gdshaderinc, "curved part") depend on the
## ray's impact parameter b alone: the shader samples them from this table instead of working them
## out per ray. Four rows of TABLE_N knots, one per span of b with one regime of the moments
## (rows 0, 1: rays that pass the throat, b < rmin; 2, 3: rays that turn in the fillet), knots
## evenly spaced over the row. A factor 1 / sqrt(mx) (times 1 / sqrt(mn) in regime 2), which goes to
## zero like a square root at the shell's edge, is taken out (the shader puts it back): what is
## left is smooth enough for linear interpolation (psi within 1e-5 rad).
const TABLE_N := 256
const _TAU := [0.004820780989426014, 0.10890625570683385, 0.44888729929169013, 0.8659570925834785]
const _A := [
	[1.0635954209629264, -0.06994895315294707, 0.0072202981818859785, -0.0008667659918653305],
	[-13.363790651033874, 14.746483787306632, -1.5723807203730116, 0.1896875841002548],
	[35.770406476784, -49.259940350673936, 15.558746458518186, -2.0692125846282434],
	[-25.12406687051129, 37.32760503465092, -15.881390739642725, 3.6778525755030924]]


## {image: the table (TABLE_N x 4, RGBA float), lo: each row's first b, inv: (TABLE_N - 1) / its
## span of b, reg: its regime}: the shader's wh_tab, wh_tabLo, wh_tabInv, wh_tabReg.
func fillet_table() -> Dictionary:
	var s0 := sin(0.5 * th0)
	var rmin := rho0 + 2.0 * fillet * s0 * s0
	var sp := maxf(Rout - rmin, 1e-6 * fillet)       # the span of passing rays
	var al_pass := (rmin - rho0) / sp
	var b1 := clampf(rmin - sp, 0.0, rmin)           # passing: ga = (rmin - b) / sp >= 1 below
	var b3 := clampf(0.5 * (Rout + rho0), rmin, Rout)   # turning: al = (b - rho0) / (Rout - b) >= 1 above
	var lo := [0.0, b1, rmin, b3]
	var hi := [b1, rmin, b3, Rout]
	var reg := [2 if al_pass >= 1.0 else 1, 1 if al_pass >= 1.0 else 0, 0, 1]
	var data := PackedFloat32Array()
	data.resize(TABLE_N * 4 * 4)
	var inv := Vector4.ZERO
	for row in 4:
		var span_b: float = hi[row] - lo[row]
		inv[row] = (TABLE_N - 1) / span_b if span_b > 0.0 else 0.0
		for i in TABLE_N:
			var b: float = lo[row] + span_b * i / (TABLE_N - 1)
			var e := _fillet_coef(b, row >= 2, reg[row], rmin)
			for c in 4:
				data[(row * TABLE_N + i) * 4 + c] = e[c]
	var img := Image.create_from_data(TABLE_N, 4, false, Image.FORMAT_RGBAF, data.to_byte_array())
	return {"image": img, "lo": Vector4(lo[0], lo[1], lo[2], lo[3]), "inv": inv,
			"reg": Vector4(reg[0], reg[1], reg[2], reg[3])}


## The shader's f.e for impact parameter b in the given regime, times sqrt(mx) (and sqrt(mn) in
## regime 2): wh_fil, in float64.
func _fillet_coef(b: float, turn: bool, reg: int, rmin: float) -> Vector4:
	var ra := b if turn else rmin
	var span := maxf(Rout - ra, 1e-6 * fillet)
	var al := (ra - rho0) / span
	var ga := 0.0 if turn else (rmin - b) / span
	var mn := minf(al, ga)
	var mx := maxf(al, ga)
	var F := []
	for k in 4:
		var r: float = ra + span * _TAU[k]
		var u := (r - rho0) / (2.0 * fillet)
		var q := (1.0 - u) * (r + b)
		if reg >= 1:
			q *= _TAU[k] + mx
		if reg == 2:
			q *= _TAU[k] + mn
		F.append(b * sqrt(2.0 * fillet) / sqrt(q * r * r))
	var scale := 1.0
	if reg >= 1:
		scale *= sqrt(mx)
	if reg == 2:
		scale *= sqrt(mn)
	var e := Vector4.ZERO
	for j in 4:
		e[j] = scale * (_A[j][0] * F[0] + _A[j][1] * F[1] + _A[j][2] * F[2] + _A[j][3] * F[3])
	return e
