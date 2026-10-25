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
const GRAV_NODES := 256  # nodes of the gravity table on the fillet: 6 mm apart here
const GRAV_SUB := 2      # RK4 steps between nodes
const GRAV_DEG := 7      # the shader's polynomials on the fillet (gravity_shader)

var rho0: float
var h: float
var fillet: float
var Lc: float
var th0: float
var L: float
var Rout: float
# gravity (see gravity_f): f = grav_a cosh(grav_k l) on the cylinder, a table on the fillet,
# r + grav_beta / r^2 in the flat universes
var grav_a := 1.0
var grav_k := 1.0
var grav_beta := 0.0
var _grav_tab := PackedFloat64Array()   # f, f' at |l| = Lc + i (L - Lc) / GRAV_NODES, interleaved


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
	_build_gravity()


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


# ---------------------------------------------------------------- gravity
# Gravity through the wormhole as in optozorax's video about gravity and portals: the potential
# obeys Poisson's equation on the curved space itself. There is no mass near the wormhole (the
# field comes from far below, like the Earth's), so the potential is harmonic, and far away it
# is ordinary uniform gravity, g z, in both universes. The space is SO(3)-symmetric, so with
# phi = g f(l) n_z the equation separates exactly into (r^2 f')' = 2 f, f even, f = r + beta / r^2
# in the flat universes (ref/gravity.py, checked there against a 2D solve of the full equation).
# On the throat's cylinder f = a cosh(sqrt(2) l / rho0): the field is screened, and in the
# middle of the long throat gravity on the floor is about 0.2 g.
# Everything here is in plain floats (double precision): GDScript's Vector2/3/4 are single
# precision, and an ODE or a table kept in them made the field's second derivative noisy.

## Solve the ODE for the current profile: closed form on the cylinder, RK4 over the fillet into
## a table, then scale so that f = r + beta / r^2 outside.
func _build_gravity() -> void:
	grav_k = sqrt(2.0) / rho0
	# f and the flux p = r^2 f' at l = Lc (p is continuous even across the crease of h < R)
	var f := 1.0
	var p := 0.0
	if Lc > 0.0:
		f = cosh(grav_k * Lc)
		p = rho0 * rho0 * grav_k * sinh(grav_k * Lc)
	var d := (L - Lc) / GRAV_NODES
	var hs := d / GRAV_SUB
	var raw := PackedFloat64Array()
	for i in GRAV_NODES + 1:
		var l := Lc + i * d
		raw.append(f)
		raw.append(p / (r(l) * r(l)))
		if i == GRAV_NODES:
			break
		for _s in GRAV_SUB:               # RK4 for f' = p / r^2, p' = 2 f
			var rm := r(l + 0.5 * hs)
			var r1 := r(l + hs)
			var f1 := p / (r(l) * r(l))
			var p1 := 2.0 * f
			var f2 := (p + 0.5 * hs * p1) / (rm * rm)
			var p2 := 2.0 * (f + 0.5 * hs * f1)
			var f3 := (p + 0.5 * hs * p2) / (rm * rm)
			var p3 := 2.0 * (f + 0.5 * hs * f2)
			var f4 := (p + hs * p3) / (r1 * r1)
			var p4 := 2.0 * (f + hs * f3)
			f += hs / 6.0 * (f1 + 2.0 * f2 + 2.0 * f3 + f4)
			p += hs / 6.0 * (p1 + 2.0 * p2 + 2.0 * p3 + p4)
			l += hs
	var fe: float = raw[2 * GRAV_NODES]                 # at l = L, where r = Rout
	var fpe: float = raw[2 * GRAV_NODES + 1]
	var a := (2.0 * fe + Rout * fpe) / (3.0 * Rout)
	grav_beta = Rout * Rout * (fe - Rout * fpe) / (3.0 * a)
	grav_a = 1.0 / a
	_grav_tab = PackedFloat64Array()
	for v in raw:
		_grav_tab.append(v / a)


## [f, df/dl] at l: the potential is g f(l) n_z. f is even, f' odd. On the fillet a cubic Hermite
## interpolant of the table, and f' is its derivative, so the force is exactly minus the
## gradient of the potential (energy is conserved). Plain floats, not a Vector2 (single precision).
func gravity_f(l: float) -> PackedFloat64Array:
	var al := absf(l)
	var sg := -1.0 if l < 0.0 else 1.0
	if al >= L:
		var rr := al - L + Rout
		return PackedFloat64Array([rr + grav_beta / (rr * rr), sg * (1.0 - 2.0 * grav_beta / (rr * rr * rr))])
	if al <= Lc:
		return PackedFloat64Array([grav_a * cosh(grav_k * al), sg * grav_a * grav_k * sinh(grav_k * al)])
	var d := (L - Lc) / GRAV_NODES
	var x := (al - Lc) / d
	var i := mini(int(x), GRAV_NODES - 1)
	var t := x - i
	var f0 := _grav_tab[2 * i]
	var m0 := _grav_tab[2 * i + 1]
	var f1 := _grav_tab[2 * i + 2]
	var m1 := _grav_tab[2 * i + 3]
	var t2 := t * t
	var t3 := t2 * t
	var f := (2.0 * t3 - 3.0 * t2 + 1.0) * f0 + (t3 - 2.0 * t2 + t) * d * m0 \
			+ (3.0 * t2 - 2.0 * t3) * f1 + (t3 - t2) * d * m1
	var fp := ((6.0 * t2 - 6.0 * t) * (f0 - f1)) / d + (3.0 * t2 - 4.0 * t + 1.0) * m0 \
			+ (3.0 * t2 - 2.0 * t) * m1
	return PackedFloat64Array([f, sg * fp])


## The potential divided by g, in metres: the chart height z far from the wormhole.
func potential(l: float, n: Vector3) -> float:
	return gravity_f(l)[0] * n.z


## Its gradient; gravity is -g times this. On the floor it is the floor normal times
## floor_gravity(l).
func potential_grad(l: float, n: Vector3) -> Vector4:
	var F := gravity_f(l)
	var u := (Vector3(0.0, 0.0, 1.0) - n.z * n) * (F[0] / r(l))
	return Vector4(F[1] * n.z, u.x, u.y, u.z)


## Strength of gravity on the floor at l, in g.
func floor_gravity(l: float) -> float:
	return gravity_f(l)[0] / r(l)


## The ray tracer's gravity view (wormhole_gravity.gdshader) without a table: on the cylinder
## f / r = (a / rho0) cosh(k l) and f' = a k sinh(k l); outside f / r = 1 + beta / r^3 and
## f' = 1 - 2 beta / r^3; on the fillet f / r and f' as polynomials of degree GRAV_DEG in
## x = (|l| - Lc) / (L - Lc), interpolating gravity_f at Chebyshev points (near the best fit:
## within 1e-6 g here, 4e-5 on a fillet as long as the throat's radius; the gravity test checks
## them). {cyl: (a / rho0, k, a k, beta), g: [2 Vector4], d: [2 Vector4]}: the shader's grav_cyl,
## grav_g, grav_d, coefficients from x^0 up.
func gravity_shader() -> Dictionary:
	var n := GRAV_DEG + 1
	var V: Array = []
	var yg := PackedFloat64Array()
	var yd := PackedFloat64Array()
	for i in n:
		var x := 0.5 - 0.5 * cos(PI * (i + 0.5) / n)
		var l := Lc + x * (L - Lc)
		var F := gravity_f(l)
		var row := PackedFloat64Array()
		for k in n:
			row.append(pow(x, k))
		V.append(row)
		yg.append(F[0] / r(l))
		yd.append(F[1])
	var cg := _solve(V, yg)
	var cd := _solve(V, yd)
	return {"cyl": Vector4(grav_a / rho0, grav_k, grav_a * grav_k, grav_beta),
			"g": [Vector4(cg[0], cg[1], cg[2], cg[3]), Vector4(cg[4], cg[5], cg[6], cg[7])],
			"d": [Vector4(cd[0], cd[1], cd[2], cd[3]), Vector4(cd[4], cd[5], cd[6], cd[7])]}


## A x = y by Gaussian elimination with partial pivoting, in doubles (rows: PackedFloat64Array).
static func _solve(rows: Array, y: PackedFloat64Array) -> PackedFloat64Array:
	var n := y.size()
	var A: Array = []
	for i in n:
		var line: PackedFloat64Array = rows[i].duplicate()
		line.append(y[i])
		A.append(line)
	for c in n:
		var piv := c
		for k in range(c + 1, n):
			if absf(A[k][c]) > absf(A[piv][c]):
				piv = k
		var tmp: PackedFloat64Array = A[c]
		A[c] = A[piv]
		A[piv] = tmp
		for k in range(c + 1, n):
			var q: float = A[k][c] / A[c][c]
			var rk: PackedFloat64Array = A[k]
			for j in range(c, n + 1):
				rk[j] -= q * A[c][j]
			A[k] = rk
	var out := PackedFloat64Array()
	out.resize(n)
	for c in range(n - 1, -1, -1):
		var s: float = A[c][n]
		for j in range(c + 1, n):
			s -= A[c][j] * out[j]
		out[c] = s / A[c][c]
	return out


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
