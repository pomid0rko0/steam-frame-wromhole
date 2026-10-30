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
## the shape: the renderer's profile, sweep table and gravity table (Renderer.upload_space), the
## stereo check scene
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
	# the direction's tangential part and its length in float64 (Vector3 math is single precision):
	# b, worked out from it, decides paths that pass close to r_min
	var nn := n.x * n.x + n.y * n.y + n.z * n.z
	var un_ := (dir.y * n.x + dir.z * n.y + dir.w * n.z) / nn
	var ux := dir.y - un_ * n.x
	var uy := dir.z - un_ * n.y
	var uz := dir.w - un_ * n.z
	var ul := sqrt(ux * ux + uy * uy + uz * uz)
	var size := sqrt(dir.x * dir.x + ul * ul)
	var un := ul / size
	# a radial direction has no plane of its own: any one through it
	var e := Vector3(ux, uy, uz) / ul if un > 1e-9 else _normal_to(n)
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
			# continuation narrows below r_min, down to rho0: a path with rho0 < b < r_min, which
			# passes the throat, can turn back there within the step. On this fillet r only grows
			# away from the throat, so a path coming in with b < r_min does not turn on it: a step
			# that turns it has crossed l = 0.
			var bounced := th0 > 0.0 and sg * vl < 0.0 and sg * y1[1] > 0.0 and b < r(0.0)
			if bounced or sg * y1[0] > L or sg * y1[0] < Lc:
				# where l first crosses the fillet's end: on the step's cubic in l (its values and
				# slopes at both ends), then the step again up to there, its end put there with the
				# rate that keeps the direction a unit vector, vl^2 + (b / r)^2 = 1 (a path that
				# crosses at a grazing angle is sensitive to the rate)
				var out := sg * y1[0] > L and not bounced
				var target := sg * L if out else sg * Lc
				hs *= _cross(l, vl * hs, y1[0], y1[1] * hs, target, (sg > 0.0) == out)
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
## crosses target, going up (up) or down: the step's fraction (y0 may lie on target: a path that
## has just come in there). Its first sample past target of 32, then bisection; where none is, the
## sample nearest to target (a dip the samples miss).
static func _cross(y0: float, d0: float, y1: float, d1: float, target: float, up: bool) -> float:
	var a := 0.0
	var z := 1.0
	var nearest := 1.0
	var gap := INF
	for k in range(1, 33):
		var t := k / 32.0
		var y := _cubic(y0, d0, y1, d1, t)
		if (y > target) == up and y != target:
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
		var y := _cubic(y0, d0, y1, d1, t)
		if (y > target) == up and y != target:
			z = t
		else:
			a = t
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


## A chart position of the flat region on one side to a manifold point. Chart A is R^4's xyz in
## sheet A; chart B is sheet B's, mirrored in x (a frame right-handed in either chart has the same
## orientation in the space).
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


## The point (l, n) of the space at its point P of R^4 (the inverse of embed): [l, n].
func point_of(P: Vector4) -> Array:
	var x := Vector3(P.x, P.y, P.z)
	var rho := x.length()
	var n := x / rho
	var a := absf(P.w)
	var sg := -1.0 if P.w < 0.0 else 1.0
	var ka := Lc - fillet * sin(th0)
	if rho >= Rout:
		return [sg * (L + rho - Rout), n]
	if a <= ka:
		return [P.w, n]
	return [sg * (Lc + fillet * (atan2(a - ka, Rout - rho) - th0)), n]


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


## Gravity on the floor for the renderer's gravity view (floor_gravity.gdshader): its strength in g
## at |l| = i GRAV_FLOOR_END / (GRAV_FLOOR_N - 1), and beyond that end the closed form 1 + beta / r^3.
## {image (RF, GRAV_FLOOR_N x 1), axes: (the end, beta)}.
const GRAV_FLOOR_N := 512


func gravity_table() -> Dictionary:
	var end := L + 8.0
	var data := PackedFloat32Array()
	data.resize(GRAV_FLOOR_N)
	for i in GRAV_FLOOR_N:
		data[i] = floor_gravity(end * i / (GRAV_FLOOR_N - 1))
	var img := Image.create_from_data(GRAV_FLOOR_N, 1, false, Image.FORMAT_RF, data.to_byte_array())
	return {"image": img, "axes": Vector2(end, grav_beta)}


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


# ---------------------------------------------------------------- the sweep table
## The renderer's table (shaders/geo.gdshaderinc, ref/geo.py's top): G(b, v), the part of a ray's
## sweep (r) and length (g) over the fillet that the closed forms leave, on SWEEP_NB x SWEEP_NV
## nodes, both ends included: b by t = sign(s) sqrt(|s|), s = sigma - u0, evenly from b = 0 to
## b = Rout (fine where the weight is singular, at b = r_min); v = sqrt((u - u_lo) / (1/2 - u_lo))
## evenly from the fillet's start (or the turning point) to its end. Cumulative Gauss-Legendre,
## SWEEP_GAUSS points per span. Over the whole fillet, G(b, 1/2) as Chebyshev series of degree
## SWEEP_DEG in t on each side of t = 0, from SWEEP_NODES Chebyshev nodes. ref/geo.py builds both
## the same way. {image (RGF), axes: the shader's g_tabx, poly: its g_poly}.
const SWEEP_NB := 256
const SWEEP_NV := 64
const SWEEP_DEG := 8
const SWEEP_NODES := 24
const _GAUSS_X := [-0.8611363115940526, -0.33998104358485626, 0.33998104358485626, 0.8611363115940526]
const _GAUSS_W := [0.34785484513745385, 0.6521451548625461, 0.6521451548625461, 0.34785484513745385]


func sweep_table() -> Dictionary:
	var u0 := sin(0.5 * th0) * sin(0.5 * th0)
	var t0 := _t_of_b(0.0, u0)
	var t1 := _t_of_b(Rout, u0)
	var data := PackedFloat32Array()
	data.resize(SWEEP_NB * SWEEP_NV * 2)
	for i in SWEEP_NB:
		var col := _sweep_rest(_b_of_t(t0 + (t1 - t0) * i / (SWEEP_NB - 1), u0), u0)
		for j in SWEEP_NV:
			data[(j * SWEEP_NB + i) * 2] = col[j].x
			data[(j * SWEEP_NB + i) * 2 + 1] = col[j].y
	var img := Image.create_from_data(SWEEP_NB, SWEEP_NV, false, Image.FORMAT_RGF, data.to_byte_array())
	# the series: (psi, len) below t = 0 in .xy, above in .zw
	var poly := PackedVector4Array()
	poly.resize(SWEEP_DEG + 1)
	for hi in 2:
		var f: Array[Vector2] = []
		for j in SWEEP_NODES:
			var x := cos(PI * (j + 0.5) / SWEEP_NODES)
			var t := (0.5 * (x + 1.0) * t1) if hi == 1 else (0.5 * (1.0 - x) * t0)
			var col := _sweep_rest(_b_of_t(t, u0), u0)
			f.append(col[SWEEP_NV - 1])
		for k in SWEEP_DEG + 1:
			var c := Vector2.ZERO
			for j in SWEEP_NODES:
				c += f[j] * cos(PI * k * (j + 0.5) / SWEEP_NODES)
			c *= (1.0 if k == 0 else 2.0) / SWEEP_NODES
			if hi == 1:
				poly[k] = Vector4(poly[k].x, poly[k].y, c.x, c.y)
			else:
				poly[k] = Vector4(c.x, c.y, poly[k].z, poly[k].w)
	return {"image": img, "axes": Vector4(t0, 1.0 / (t1 - t0), SWEEP_NB, SWEEP_NV), "poly": poly}


func _t_of_b(b: float, u0: float) -> float:
	var s := (b - rho0) / (2.0 * fillet) - u0
	return signf(s) * sqrt(absf(s))


func _b_of_t(t: float, u0: float) -> float:
	return clampf(rho0 + 2.0 * fillet * (signf(t) * t * t + u0), 0.0, Rout)


## The table's column at impact b: G at v = j / (SWEEP_NV - 1), cumulative over the spans.
func _sweep_rest(b: float, u0: float) -> Array[Vector2]:
	var col: Array[Vector2] = []
	col.resize(SWEEP_NV)
	col[0] = Vector2.ZERO
	var sig := (b - rho0) / (2.0 * fillet)
	var ul := maxf(sig, u0)
	var span := 0.5 - ul
	var acc := Vector2.ZERO
	var f0 := _sweep_F(b, ul)
	var f1 := _sweep_Fu(b, ul, f0)
	for j in range(1, SWEEP_NV):
		if span > 1e-12:
			var va := (j - 1.0) / (SWEEP_NV - 1)
			var vb := float(j) / (SWEEP_NV - 1)
			for k in 4:
				var v: float = 0.5 * (va + vb) + 0.5 * (vb - va) * _GAUSS_X[k]
				var u := ul + span * v * v
				var jac := 2.0 * span * v / sqrt(u * (u - sig))
				acc += 0.5 * (vb - va) * _GAUSS_W[k] * jac * (_sweep_F(b, u) - f0 - f1 * (u - ul))
		col[j] = acc
	return col


## The fillet's integrands of psi and length without the weight 1 / sqrt(u (u - sigma)), and their
## derivatives in u (the shader's geo_F, geo_Fu).
func _sweep_F(b: float, u: float) -> Vector2:
	var rr := rho0 + 2.0 * fillet * u
	var c := sqrt(0.5 * fillet) / (sqrt(1.0 - u) * sqrt(rr + b))
	return Vector2(b / rr, rr) * c


func _sweep_Fu(b: float, u: float, f: Vector2) -> Vector2:
	var rr := rho0 + 2.0 * fillet * u
	var a := 0.5 / (1.0 - u) - fillet / (rr + b)
	var k := 2.0 * fillet / rr
	return f * Vector2(a - k, a + k)
