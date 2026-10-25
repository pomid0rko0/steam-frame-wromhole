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
const GRAV_NODES := 64   # nodes of the gravity table on the fillet
const GRAV_SUB := 8      # RK4 steps between nodes

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


## A short move by the tangent displacement D: one Euler step of the geodesic equation,
## transporting vecs (error of order |D|^2 / r^2). Returns [l, n, vecs].
func nudge(l: float, n: Vector3, D: Vector4, vecs: Array) -> Array:
	var rr := r(l)
	var k := dr(l) / rr
	var v := Vector3(D.y, D.z, D.w)
	var nn := (n + v / rr).normalized()
	var out := []
	for A: Vector4 in vecs:
		var au := Vector3(A.y, A.z, A.w)
		var da := -k * A.x * v - (au.dot(v) / rr) * n
		out.append(tangent(nn, A + Vector4(k * v.dot(au), da.x, da.y, da.z)))
	return [l + D.x, nn, out]


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


## dw/dl (even in l); together with dr/dl it is the unit tangent of the profile curve.
func dw(l: float) -> float:
	var al := absf(l)
	if al >= L:
		return 0.0
	if al <= Lc:
		return 1.0
	return cos(_theta(al))


## The point (l, n) as a point of R^4.
func embed(l: float, n: Vector3) -> Vector4:
	var p := r(l) * n
	return Vector4(p.x, p.y, p.z, w(l))


## A vector of R^4 projected onto the tangent space at (l, n), in the (U_l, u) representation.
func project(l: float, n: Vector3, D: Vector4) -> Vector4:
	var dx := Vector3(D.x, D.y, D.z)
	var rad := dx.dot(n)
	var u := dx - rad * n
	return Vector4(dr(l) * rad + dw(l) * D.w, u.x, u.y, u.z)


## Height above the floor, H = r(l) n_z: exactly the chart height z in both flat universes,
## extended smoothly through the throat. Its gradient (r' n_z, e_z - n_z n) has length 1 on the floor.
func height(l: float, n: Vector3) -> float:
	return r(l) * n.z


func height_grad(l: float, n: Vector3) -> Vector4:
	var u := Vector3(0.0, 0.0, 1.0) - n.z * n
	return Vector4(dr(l) * n.z, u.x, u.y, u.z)


# ---------------------------------------------------------------- gravity
# Gravity through the wormhole as in optozorax's video about gravity and portals: the potential
# obeys Poisson's equation on the curved space itself. There is no mass near the wormhole (the
# field comes from far below, like the Earth's), so the potential is harmonic, and far away it
# is ordinary uniform gravity, g z, in both universes. The space is SO(3)-symmetric, so with
# phi = g f(l) n_z the equation separates exactly into (r^2 f')' = 2 f, f even, f = r + beta / r^2
# in the flat universes (ref/gravity.py, checked there against a 2D solve of the full equation).
# On the throat's cylinder f = a cosh(sqrt(2) l / rho0): the field is screened, and in the
# middle of the long throat gravity on the floor is about 0.2 g.

## Solve the ODE for the current profile: closed form on the cylinder, RK4 over the fillet into
## a table, then scale so that f = r + beta / r^2 outside.
func _build_gravity() -> void:
	grav_k = sqrt(2.0) / rho0
	# f and the flux p = r^2 f' at l = Lc; plain floats, as Vector2 is single precision
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


## (f, df/dl) at l: the potential is g f(l) n_z. f is even, f' odd. On the fillet a cubic Hermite
## interpolant of the table, and f' is its derivative, so the force is exactly minus the
## gradient of the potential (energy is conserved).
func gravity_f(l: float) -> Vector2:
	var al := absf(l)
	var sg := -1.0 if l < 0.0 else 1.0
	if al >= L:
		var rr := al - L + Rout
		return Vector2(rr + grav_beta / (rr * rr), sg * (1.0 - 2.0 * grav_beta / (rr * rr * rr)))
	if al <= Lc:
		return Vector2(grav_a * cosh(grav_k * al), sg * grav_a * grav_k * sinh(grav_k * al))
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
	return Vector2(f, sg * fp)


## The potential divided by g, in metres: the chart height z far from the wormhole.
func potential(l: float, n: Vector3) -> float:
	return gravity_f(l).x * n.z


## Its gradient; gravity is -g times this. On the floor it is the floor normal times
## floor_gravity(l).
func potential_grad(l: float, n: Vector3) -> Vector4:
	var F := gravity_f(l)
	var u := (Vector3(0.0, 0.0, 1.0) - n.z * n) * (F.x / r(l))
	return Vector4(F.y * n.z, u.x, u.y, u.z)


## Strength of gravity on the floor at l, in g.
func floor_gravity(l: float) -> float:
	return gravity_f(l).x / r(l)


## Chart side and chart position of a point in a flat region.
func chart_position(l: float, n: Vector3) -> Vector3:
	var x := r(l) * n
	if l < 0.0:
		x.x = -x.x
	return x


## One RK4 step of free motion under gravity, -grav * potential_grad (geodesic + force).
## The vectors in frame (a body's axes) are parallel-transported along the step.
## Returns [l, n, U, frame].
func dynamics_step(l: float, n: Vector3, U: Vector4, dt: float, grav: float, frame: Array = []) -> Array:
	var f := func(ll: float, nn: Vector3, UU: Vector4, FF: Array) -> Array:
		var rr := r(ll)
		var k := dr(ll) / rr
		var v := Vector3(UU.y, UU.z, UU.w)
		var du := -k * UU.x * v - (v.dot(v) / rr) * nn
		var a := Vector4(k * v.dot(v), du.x, du.y, du.z) - grav * potential_grad(ll, nn)
		var dF := []
		for A: Vector4 in FF:
			var au := Vector3(A.y, A.z, A.w)
			var da := -k * A.x * v - (au.dot(v) / rr) * nn
			dF.append(Vector4(k * v.dot(au), da.x, da.y, da.z))
		return [UU.x, v / rr, a, dF]
	var shift := func(FF: Array, dF: Array, h: float) -> Array:
		var out := []
		for i in FF.size():
			out.append(FF[i] + h * dF[i])
		return out
	var k1: Array = f.call(l, n, U, frame)
	var k2: Array = f.call(l + 0.5 * dt * k1[0], n + 0.5 * dt * k1[1], U + 0.5 * dt * k1[2], shift.call(frame, k1[3], 0.5 * dt))
	var k3: Array = f.call(l + 0.5 * dt * k2[0], n + 0.5 * dt * k2[1], U + 0.5 * dt * k2[2], shift.call(frame, k2[3], 0.5 * dt))
	var k4: Array = f.call(l + dt * k3[0], n + dt * k3[1], U + dt * k3[2], shift.call(frame, k3[3], dt))
	var nl: float = l + dt / 6.0 * (k1[0] + 2.0 * k2[0] + 2.0 * k3[0] + k4[0])
	var nn: Vector3 = (n + dt / 6.0 * (k1[1] + 2.0 * k2[1] + 2.0 * k3[1] + k4[1])).normalized()
	var nU: Vector4 = U + dt / 6.0 * (k1[2] + 2.0 * k2[2] + 2.0 * k3[2] + k4[2])
	var nF := []
	for i in frame.size():
		nF.append(tangent(nn, frame[i] + dt / 6.0 * (k1[3][i] + 2.0 * k2[3][i] + 2.0 * k3[3][i] + k4[3][i])))
	return [nl, nn, tangent(nn, nU), nF]


## A tangent vector (U_l, u) at (l, n) as a vector of R^4 (the inverse of project).
func embed_vector(l: float, n: Vector3, U: Vector4) -> Vector4:
	var u := Vector3(U.y, U.z, U.w)
	var p := dr(l) * U.x * n + u
	return Vector4(p.x, p.y, p.z, dw(l) * U.x)


## Unit normal of the hypersurface in R^4 at (l, n): orthogonal to every embedded tangent vector.
func normal4(l: float, n: Vector3) -> Vector4:
	var p := -dw(l) * n
	return Vector4(p.x, p.y, p.z, dr(l))


## Chart direction of a tangent vector at (l, n) in a flat region (the inverse of vector_from_chart).
static func vector_to_chart(side: float, n: Vector3, U: Vector4) -> Vector3:
	var d := side * U.x * n + Vector3(U.y, U.z, U.w)
	if side < 0.0:
		d.x = -d.x
	return d
