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


## Linear combination c.x * f[0] + c.y * f[1] + c.z * f[2].
static func combine(f: Array, c: Vector3) -> Vector4:
	return c.x * f[0] + c.y * f[1] + c.z * f[2]


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


## Chart side and chart position of a point in a flat region.
func chart_position(l: float, n: Vector3) -> Vector3:
	var x := r(l) * n
	if l < 0.0:
		x.x = -x.x
	return x


## One RK4 step of free motion under the field g = -grav * grad H (geodesic + force).
func dynamics_step(l: float, n: Vector3, U: Vector4, dt: float, grav: float) -> Array:
	var f := func(ll: float, nn: Vector3, UU: Vector4) -> Array:
		var rr := r(ll)
		var k := dr(ll) / rr
		var v := Vector3(UU.y, UU.z, UU.w)
		var du := -k * UU.x * v - (v.dot(v) / rr) * nn
		var a := Vector4(k * v.dot(v), du.x, du.y, du.z) - grav * height_grad(ll, nn)
		return [UU.x, v / rr, a]
	var k1: Array = f.call(l, n, U)
	var k2: Array = f.call(l + 0.5 * dt * k1[0], n + 0.5 * dt * k1[1], U + 0.5 * dt * k1[2])
	var k3: Array = f.call(l + 0.5 * dt * k2[0], n + 0.5 * dt * k2[1], U + 0.5 * dt * k2[2])
	var k4: Array = f.call(l + dt * k3[0], n + dt * k3[1], U + dt * k3[2])
	var nl: float = l + dt / 6.0 * (k1[0] + 2.0 * k2[0] + 2.0 * k3[0] + k4[0])
	var nn: Vector3 = (n + dt / 6.0 * (k1[1] + 2.0 * k2[1] + 2.0 * k3[1] + k4[1])).normalized()
	var nU: Vector4 = U + dt / 6.0 * (k1[2] + 2.0 * k2[2] + 2.0 * k3[2] + k4[2])
	return [nl, nn, tangent(nn, nU)]
