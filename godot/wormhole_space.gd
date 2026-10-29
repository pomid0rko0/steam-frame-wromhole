class_name WormholeSpace
extends RefCounted
## Geometry of the wormhole space on the CPU side: moving the viewer along
## geodesics and parallel-transporting their frame. The space and its profile r(l) (Lc, L, th0,
## Rout): docs/geometry.md; gravity: docs/gravity.md. GDScript's Vector2/3/4 are single precision
## (float is double): the gravity ODE and its table are plain floats and PackedFloat64Array.
## A point is (l, n): n is a unit Vector3 on the shared angular sphere.
## A tangent vector is Vector4(U_l, u.x, u.y, u.z): U_l along d/dl, u the physical
## tangential part (u . n = 0). In this representation the metric is Vector4.dot.

const STEP := 0.1  # the longest RK4 step geodesic takes on a fillet, in fillet radii (it takes none elsewhere)
const GRAV_NODES := 256  # spans of the gravity table on the fillet (GRAV_NODES + 1 nodes, (L - Lc) / GRAV_NODES apart)
const GRAV_SUB := 2      # RK4 steps between nodes
# the degree of the shader's polynomials on the fillet (gravity_shader): their GRAV_DEG + 1
# coefficients go four to a vec4 of its grav_g[] and grav_d[] (Tracer._fits_shader checks they fit)
const GRAV_DEG := 7

var rho0: float
var h: float
var fillet: float
var Lc: float
var th0: float
var L: float
var Rout: float
# gravity (see gravity_f): the coefficients of docs/gravity.md's f on the cylinder (grav_a,
# grav_k) and in the flat universes (grav_beta); on the fillet a table
var grav_a := 1.0
var grav_k := 1.0
var grav_beta := 0.0
var _grav_tab := PackedFloat64Array()   # f, f' at |l| = Lc + i (L - Lc) / GRAV_NODES, interleaved


func _init(throat_radius: float, half_length: float, fillet_radius: float) -> void:
	set_profile(throat_radius, half_length, fillet_radius)


## The throat's shape. Only _init calls it: a change at run time must also rebuild what is built for
## the shape: the shader's wh_rho0, wh_h, wh_fillet (Tracer.param, set once in Tracer._ready),
## Tracer.upload_fillet_table (slow in GDScript: not per frame), Tracer.upload_gravity,
## Tracer.set_objects (its sorting and proxies use h and Rout), the stereo check scene
## (check_scene.gd: its grid's rout and lsh, its balls' and cube's R^4 centres from h), and what
## stands in chart coordinates outside Rout: godot/scene.json's objects, the toys' places (toys.gd),
## CheckScene.BALLS and CUBE, main.START_POS, and bench.gd's PLACES and TOUR_L (metres of l chosen
## against the edge). Nothing keeps the feet's and the balls' distance to the curved zone's edge.
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


## Follow the geodesic from (l, n) with initial direction dir (a unit vector) for length dist,
## transporting frame (Array of Vector4). Returns [l, n, frame].
## The geodesic lies in the plane through the centre spanned by n and dir's tangential part e
## (docs/geometry.md, «Почему луч считается быстро», 1): n = cos psi n0 + sin psi e, with
## b = r |u| kept. Only l, its rate vl and psi change: along a straight line in a flat chart and on
## the cylinder (closed forms, exact), in RK4 steps of l'' = r' b^2 / r^3, psi' = b / r^2 on a
## fillet (a step that leaves it is cut where it first does). The surface the plane cuts out is totally
## geodesic (the space's mirror image in the plane leaves it in place), so a transported vector keeps
## its part along the plane's normal, and its part in the plane, (U_l, the part toward growing psi),
## keeps its angle to the geodesic's direction, which is (vl, b / r) there.
func geodesic(l: float, n: Vector3, dir: Vector4, dist: float, frame: Array) -> Array:
	if dist <= 0.0:
		return [l, n, frame.duplicate()]
	var size := dir.length()
	var u := Vector3(dir.y, dir.z, dir.w)
	u -= u.dot(n) * n
	var un := u.length() / size
	# a radial direction has no plane of its own: any one through it
	var e := u.normalized() if un > 1e-9 else _normal_to(n)
	var vl := dir.x / size
	var r0 := r(l)
	var b := r0 * un
	var chi0 := atan2(un, vl)
	var psi := 0.0
	var left := dist
	for _pass in 100000:           # each pass uses up length or moves to the next piece: a bound against a hang
		if left <= 0.0:
			break
		var al := absf(l)
		var sg := signf(l)
		if al > L or (al == L and sg * vl >= 0.0):
			# a flat chart: in the plane the straight line from (rr, 0) along (rd, b / rr), until it
			# meets the shell (r = Rout, only coming in with b < Rout)
			var rr := al - L + Rout
			var rd := sg * vl              # dr/ds
			var bt := b / rr
			var s_in := INF
			if rd < 0.0 and b < Rout:
				s_in = maxf(-rr * rd - sqrt(Rout * Rout - b * b), 0.0)
			var s := minf(left, s_in)
			var x := rr + rd * s
			var y := bt * s
			var r1 := sqrt(x * x + y * y)
			psi += atan2(y, x)
			vl = sg * (x * rd + y * bt) / r1
			l = sg * L if s == s_in else sg * (r1 - Rout + L)
			left -= s
		elif Lc > 0.0 and (al < Lc or (al == Lc and sg * vl <= 0.0)):
			# the cylinder: l and psi at constant rates until an end
			var s_out := INF
			if vl > 0.0:
				s_out = (Lc - l) / vl
			elif vl < 0.0:
				s_out = (Lc + l) / -vl
			var s := minf(left, s_out)
			l = (Lc if vl > 0.0 else -Lc) if s == s_out else l + vl * s
			psi += b / (rho0 * rho0) * s
			left -= s
		else:
			# a fillet, on side sg (at l = 0, where fillets meet with no cylinder: the side it goes to)
			if sg == 0.0:
				sg = signf(vl)
			var hs := minf(left, STEP * fillet)
			var y1 := _fillet_step(l, vl, psi, b, hs, sg)
			# Past a crease (h < fillet: the fillets meet at l = 0 at an angle) the circle's
			# continuation narrows below r_min: a path that passes the throat (b < r_min) would turn
			# back there, within the step. Coming in, it turns back on this fillet only if it does not
			# pass; so if it does, a step that turns it has crossed l = 0.
			var bounced := th0 > 0.0 and sg * vl < 0.0 and sg * y1[1] > 0.0 and b < r(0.0)
			if bounced or sg * y1[0] > L or sg * y1[0] < Lc:
				# where l first crosses the fillet's end: on the step's cubic in l (its values and
				# slopes at both ends), then the step again up to there, its end put there with the
				# rate that keeps the direction a unit vector, vl^2 + (b / r)^2 = 1 (a path that
				# crosses at a grazing angle is sensitive to the rate)
				var out := sg * y1[0] > L and not bounced
				var target := sg * L if out else sg * Lc
				hs *= _cross(l, vl * hs, y1[0], y1[1] * hs, target)
				y1 = _fillet_step(l, vl, psi, b, hs, sg)
				var bt := b / r(target)
				y1[0] = target
				y1[1] = (sg if out else -sg) * sqrt(maxf(1.0 - bt * bt, 0.0))
			l = y1[0]
			vl = y1[1]
			psi = y1[2]
			left -= hs
	var d := atan2(b / r(l), vl) - chi0       # the in-plane turn of the direction
	var c := cos(d)
	var s := sin(d)
	var cp := cos(psi)
	var sp := sin(psi)
	var t1 := -sp * n + cp * e
	var m := n.cross(e)
	var out_frame := []
	for U: Vector4 in frame:
		var uu := Vector3(U.y, U.z, U.w)
		var ct := uu.dot(e)
		var tu := (U.x * s + ct * c) * t1 + uu.dot(m) * m
		out_frame.append(Vector4(U.x * c - ct * s, tu.x, tu.y, tu.z))
	return [l, (cp * n + sp * e).normalized(), out_frame]


## One RK4 step of (l, vl, psi) on the fillet of side sg: l'' = r' b^2 / r^3, psi' = b / r^2, with
## that fillet's circle, continued smoothly past its ends (where a step that is cut there looks).
func _fillet_step(l: float, vl: float, psi: float, b: float, hs: float, sg: float) -> PackedFloat64Array:
	var a1 := _fillet_rate(l, b, sg)
	var l2 := l + 0.5 * hs * vl
	var v2 := vl + 0.5 * hs * a1[0]
	var a2 := _fillet_rate(l2, b, sg)
	var l3 := l + 0.5 * hs * v2
	var v3 := vl + 0.5 * hs * a2[0]
	var a3 := _fillet_rate(l3, b, sg)
	var l4 := l + hs * v3
	var v4 := vl + hs * a3[0]
	var a4 := _fillet_rate(l4, b, sg)
	return PackedFloat64Array([l + hs / 6.0 * (vl + 2.0 * v2 + 2.0 * v3 + v4),
			vl + hs / 6.0 * (a1[0] + 2.0 * a2[0] + 2.0 * a3[0] + a4[0]),
			psi + hs / 6.0 * (a1[1] + 2.0 * a2[1] + 2.0 * a3[1] + a4[1])])


## [l'', psi'] at l on the fillet of side sg (its circle, continued smoothly), for impact parameter b.
func _fillet_rate(l: float, b: float, sg: float) -> PackedFloat64Array:
	var th := th0 + (sg * l - Lc) / fillet
	var p := rho0 + fillet * (1.0 - cos(th))
	var ip2 := 1.0 / (p * p)
	return PackedFloat64Array([sg * sin(th) * b * b * ip2 / p, b * ip2])


## Where on a step the cubic with values y0, y1 and slopes d0, d1 (per step) at its ends first
## reaches target (y0 is on one side of it): the step's fraction. Its first sample on the other side
## of 32, then bisection; where none is, the sample nearest to target (a dip the samples miss).
static func _cross(y0: float, d0: float, y1: float, d1: float, target: float) -> float:
	var side := y0 > target
	var a := 0.0
	var z := 1.0
	var nearest := 1.0
	var gap := INF
	for k in range(1, 33):
		var t := k / 32.0
		var y := _cubic(y0, d0, y1, d1, t)
		if (y > target) != side:
			z = t
			break
		a = t
		if absf(y - target) < gap:
			gap = absf(y - target)
			nearest = t
	if a == 1.0:
		return nearest
	for _it in 30:
		var t := 0.5 * (a + z)
		if (_cubic(y0, d0, y1, d1, t) > target) == side:
			a = t
		else:
			z = t
	return z


static func _cubic(y0: float, d0: float, y1: float, d1: float, t: float) -> float:
	var t2 := t * t
	var t3 := t2 * t
	return (2.0 * t3 - 3.0 * t2 + 1.0) * y0 + (t3 - 2.0 * t2 + t) * d0 + (-2.0 * t3 + 3.0 * t2) * y1 + (t3 - t2) * d1


## A unit vector orthogonal to n.
static func _normal_to(n: Vector3) -> Vector3:
	return (Vector3(0.0, 0.0, 1.0) if absf(n.z) < 0.9 else Vector3(1.0, 0.0, 0.0)).cross(n).normalized()


## A short move by the tangent displacement D: one Euler step of the geodesic equation,
## transporting vecs (an error of second order in |D|: BallWorld._move takes it for short moves
## only). Returns [l, n, vecs].
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


static func combine(f: Array, c: Vector3) -> Vector4:
	return c.x * f[0] + c.y * f[1] + c.z * f[2]


## The tangent vector at (l, n) whose geodesic, followed for its length, reaches (tl, tn): the
## inverse of geodesic, for points within a hand's reach. The chord of R^4 seen from (l, n) is a
## first guess (on the fillet it misses, the more the farther); two corrections by where its
## geodesic lands (tests/grab_test.gd checks the hands with it).
func toward(l: float, n: Vector3, tl: float, tn: Vector3) -> Vector4:
	var E := embed(l, n)
	var T := embed(tl, tn)
	var D := project(l, n, T - E)
	if D.length() < 1e-7:
		return Vector4.ZERO
	D = D.normalized() * (T - E).length()
	for _it in 2:
		var res := geodesic(l, n, D.normalized(), D.length(), [])
		D += project(l, n, T - embed(res[0], res[1]))
	return D


## A chart position of the flat region on one side (the charts: wormhole_core.gdshaderinc's top) to
## a manifold point.
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


func embed(l: float, n: Vector3) -> Vector4:
	var p := r(l) * n
	return Vector4(p.x, p.y, p.z, w(l))


## A vector of R^4 projected onto the tangent space at (l, n), in the (U_l, u) representation.
func project(l: float, n: Vector3, D: Vector4) -> Vector4:
	var dx := Vector3(D.x, D.y, D.z)
	var rad := dx.dot(n)
	var u := dx - rad * n
	return Vector4(dr(l) * rad + dw(l) * D.w, u.x, u.y, u.z)


## A tangent vector (U_l, u) at (l, n) as a vector of R^4 (the inverse of project).
func embed_vector(l: float, n: Vector3, U: Vector4) -> Vector4:
	var u := Vector3(U.y, U.z, U.w)
	var p := dr(l) * U.x * n + u
	return Vector4(p.x, p.y, p.z, dw(l) * U.x)


## Unit normal of the hypersurface in R^4 at (l, n): orthogonal to every embedded tangent vector.
func normal4(l: float, n: Vector3) -> Vector4:
	var p := -dw(l) * n
	return Vector4(p.x, p.y, p.z, dr(l))


## Height above the floor, H = r(l) n_z: exactly the chart height z in both flat universes,
## extended smoothly through the throat. Its gradient (r' n_z, e_z - n_z n) has length 1 on the
## floor: where a body touches the floor and which way the floor pushes it.
func height(l: float, n: Vector3) -> float:
	return r(l) * n.z


func height_grad(l: float, n: Vector3) -> Vector4:
	var u := Vector3(0.0, 0.0, 1.0) - n.z * n
	return Vector4(dr(l) * n.z, u.x, u.y, u.z)


# ---------------------------------------------------------------- gravity
# Gravity through the wormhole: docs/gravity.md.

## Solve the ODE for the current profile: closed form on the cylinder, RK4 over the fillet into
## a table, then scale so that f = r + beta / r^2 outside.
func _build_gravity() -> void:
	grav_k = sqrt(2.0) / rho0
	# f and the flux p = r^2 f' at l = Lc (p is continuous even across the crease of h < fillet)
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


## [f, df/dl] at l (docs/gravity.md's f). f is even, f' odd. On the fillet a cubic Hermite
## interpolant of the table, and f' is its derivative, so the force is exactly minus the
## gradient of the potential (energy is conserved). Plain floats, not a Vector2.
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


## The ray tracer's gravity views (WH_GRAVITY in wormhole_core.gdshaderinc) without a table: the
## closed forms' constants, and on the fillet f / r and f' as polynomials of degree GRAV_DEG in
## x = (|l| - Lc) / (L - Lc), interpolating gravity_f at Chebyshev points (tests/gravity_test.gd
## checks them). {cyl: (a / rho0, k, a k, beta), g, d: [Vector4...]}: the shader's grav_cyl,
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
	var g := []
	var dd := []
	for j in range(0, n, 4):
		g.append(Vector4(cg[j], cg[j + 1], cg[j + 2], cg[j + 3]))
		dd.append(Vector4(cd[j], cd[j + 1], cd[j + 2], cd[j + 3]))
	return {"cyl": Vector4(grav_a / rho0, grav_k, grav_a * grav_k, grav_beta), "g": g, "d": dd}


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
	var shift := func(FF: Array, dF: Array, hh: float) -> Array:
		var out := []
		for i in FF.size():
			out.append(FF[i] + hh * dF[i])
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


## Chart direction of a tangent vector at (l, n) in a flat region (the inverse of vector_from_chart).
static func vector_to_chart(side: float, n: Vector3, U: Vector4) -> Vector3:
	var d := side * U.x * n + Vector3(U.y, U.z, U.w)
	if side < 0.0:
		d.x = -d.x
	return d


## The chart position of a point in a flat region (its side: the sign of l).
func chart_position(l: float, n: Vector3) -> Vector3:
	var x := r(l) * n
	if l < 0.0:
		x.x = -x.x
	return x


# ---------------------------------------------------------------- the fillet table
## The ray tracer's fillet polynomials (wormhole_core.gdshaderinc, "curved part") by the ray's
## impact parameter b: the shader samples them from this table instead of working them out per ray.
## Four rows of TABLE_N knots, one per span of b with one regime of the moments (rows 0, 1: rays
## that pass the throat, b < rmin; 2, 3: rays that turn in the fillet), knots evenly spaced over the
## row. In rows of regimes 1 and 2 a factor 1 / sqrt(mx) (times 1 / sqrt(mn) in regime 2), which
## goes to zero like a square root at the shell's edge, is taken out (the shader puts it back): what
## is left is smooth enough for linear interpolation.
const TABLE_N := 256           # the shader's WH_TABN (Tracer._fits_shader checks it)
# the polynomial's nodes in tau: the squares of the 4-point Gauss-Legendre nodes on [0, 1], and the
# inverse of their Vandermonde matrix, which takes F at them to the coefficients (numpy:
# x = leggauss(4)[0]; _TAU = ((x + 1) / 2)^2; _A = inv(vander(_TAU, 4, increasing=True)))
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
		var rk: float = ra + span * _TAU[k]
		var u := (rk - rho0) / (2.0 * fillet)
		var q := (1.0 - u) * (rk + b)
		if reg >= 1:
			q *= _TAU[k] + mx
		if reg == 2:
			q *= _TAU[k] + mn
		F.append(b * sqrt(2.0 * fillet) / sqrt(q * rk * rk))
	var scale := 1.0
	if reg >= 1:
		scale *= sqrt(mx)
	if reg == 2:
		scale *= sqrt(mn)
	var e := Vector4.ZERO
	for j in 4:
		e[j] = scale * (_A[j][0] * F[0] + _A[j][1] * F[1] + _A[j][2] * F[2] + _A[j][3] * F[3])
	return e
