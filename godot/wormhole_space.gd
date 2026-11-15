class_name WormholeSpace
extends RefCounted
## Geometry of the wormhole space on the CPU side: moving the viewer along
## geodesics and parallel-transporting their frame. The space and its profile r(l) (Lc, L, th0,
## Rout): docs/geometry.md; gravity: docs/gravity.md. GDScript's Vector2/3/4 are single precision
## (float is double): the gravity ODE and its table are plain floats and PackedFloat64Array.
## A point is (l, n): n is a unit Vector3 on the shared angular sphere.
## A tangent vector is Vector4(U_l, u.x, u.y, u.z): U_l along d/dl, u the physical
## tangential part (u . n = 0). In this representation the metric is Vector4.dot.
##
## The floor is the space cut by R^4's hyperplane z = -lift: the points (l, n) of height
## H = r(l) n_z + lift = 0 (height); above it is H > 0. lift is any number (docs/geometry.md,
## «Пространство»): above Rout the floor is two planes, one in each flat universe, out of the curved
## zone; below it the floor runs through the zone (floor_in_zone), bent there, and with
## |lift| < r_min through the throat itself (floor_through): one surface, a way on foot from one
## universe to the other; at lift <= -Rout the whole zone is under two flat floors. The charts
## (chart_position, point_from_chart) are R^4's xyz raised by lift, chart A of the half l > 0, chart
## B of the half l < 0, mirrored in x: coordinates of a universe and its fillet (the throat's cylinder
## is the one sphere r = rho0 in both), in which the floor is the plane z = 0 everywhere and the
## height is z. What a floor needs: floor_point (the floor's point at a chart's (x, y)), floor_normal
## (up there), to_floor (the foot of a point near it), floor_distance (how far a body's centre is from
## it) and height_hess (how the height bends); tests/floor_test.gd checks them at every kind of lift.

const STEP := 0.1  # the longest RK4 step geodesic takes on a fillet, in fillet radii (it takes none elsewhere)
const GRAV_NODES := 256  # spans of the gravity table on the fillet (GRAV_NODES + 1 nodes, (L - Lc) / GRAV_NODES apart)
const GRAV_SUB := 2      # RK4 steps between nodes

var rho0: float
var h: float
var fillet: float
var lift: float                 # m: the throat's centre above the floor
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


func _init(throat_radius: float, half_length: float, fillet_radius: float, p_lift: float) -> void:
	set_profile(throat_radius, half_length, fillet_radius)
	lift = p_lift


## The throat's shape as _init takes it, a crease (h < fillet) too. At run time the shape changes by
## set_shape.
func set_profile(throat_radius: float, half_length: float, fillet_radius: float) -> void:
	rho0 = throat_radius
	h = half_length
	fillet = fillet_radius
	Lc = maxf(h - fillet, 0.0)
	th0 = asin(maxf(1.0 - h / fillet, 0.0))
	L = Lc + fillet * (PI / 2.0 - th0)
	Rout = rho0 + fillet
	_build_gravity()


# The shapes set_shape takes (fit: the menu's rows offer these), m: the throat's radius, its
# fillet's (the throat at least WIDE of them across its radius: no softer against the throat than
# the video's, but for the throats narrower than the video's with the sharpest fillet; so the
# softest fillet, FILLET_MAX, is the widest throat's), its cylinder's length and its centre over the
# floor. ref/test_gpu.py checks the method on the far corners of the radius and the fillet, without
# a cylinder and with the longest (its MENU). No wider: a fillet softer against the throat puts rays
# off (issue #135: at half the throat's radius, 1.5 m and more, the sweep table misses its limit on
# some rays, and so does the search for a point's image), a sharper one breaks the bodies in the
# curved zone (#136). RADIUS_MAX and LIFT_MAX only keep the throat within the scene and in sight.
const RADIUS_MIN := 2.0
const RADIUS_MAX := 6.0
const FILLET_MIN := 1.0
const FILLET_MAX := 2.0
const WIDE := 3.0
const LENGTH_MAX := 80.0
const LIFT_MAX := 15.0


## The lowest the centre of a throat of this radius and fillet goes against the floor: under it by
## the curved zone's radius Rout, where the zone's ball is wholly under the floor and both universes
## are flat. Above that the floor cuts the zone (through the fillets over the throat, lower through
## the throat itself, then through the fillets under it: docs/geometry.md, «Пол»), and from Rout up it
## is out of the zone again.
static func lift_min(throat_radius: float, fillet_radius: float) -> float:
	return -(throat_radius + fillet_radius)


## The shape nearest to (radius, cylinder, fillet, lift) that set_shape takes, as shape() gives one:
## each part within its limits; the radius and the fillet together (WIDE): the radius as asked and
## the fillet as sharp as that throat needs (a throat made narrow gets a sharper fillet), or with
## fillet_leads the fillet as asked and the throat as wide as it needs (a fillet made soft widens
## the throat); then the lift no lower than lift_min of both.
static func fit(throat_radius: float, cylinder: float, fillet_radius: float, p_lift: float, fillet_leads := false) -> PackedFloat64Array:
	var rad := clampf(throat_radius, RADIUS_MIN, RADIUS_MAX)
	var fil := clampf(fillet_radius, FILLET_MIN, FILLET_MAX)
	if fillet_leads:
		if fil > FILLET_MIN:
			rad = clampf(maxf(rad, WIDE * fil), RADIUS_MIN, RADIUS_MAX)
	fil = clampf(fil, FILLET_MIN, maxf(FILLET_MIN, rad / WIDE))
	return PackedFloat64Array([rad, clampf(cylinder, 0.0, LENGTH_MAX), fil,
			clampf(p_lift, lift_min(rad, fil), maxf(LIFT_MAX, lift_min(rad, fil)))])


## The shape: [the throat's radius, its cylinder's length 2 Lc, its fillet's radius, the lift], m.
func shape() -> PackedFloat64Array:
	return PackedFloat64Array([rho0, 2.0 * Lc, fillet, lift])


## A space of the shape s (shape()'s).
static func of(s: PackedFloat64Array) -> WormholeSpace:
	var sp := WormholeSpace.new(s[0], 0.5 * s[1] + s[2], s[2], s[3])
	sp.set_shape(s[0], s[1], s[2], s[3])        # Lc to the last digit
	return sp


## The shape changed at run time, to one fit gives: a throat without a crease (h = Lc + fillet, the
## fillets meet the cylinder, or each other at cylinder 0, smoothly). What is built for the shape
## must follow: the renderer (Renderer.set_space: the profile and gravity's numbers to every shader,
## the sweep table, which hangs on the radius and the fillet alone, the field lines) and what stands
## in the space (carried); main.set_shape does it all. Gravity: with the radius and the fillet as
## they were the fillet's two solutions are summed afresh (_grav_sum, cheap: a frame can take it),
## else taken from solved, a space of that radius and fillet (made off the main thread), or without
## one solved here (milliseconds: too long for a frame in the headset); the lift is not in it.
func set_shape(throat_radius: float, cylinder: float, fillet_radius: float, p_lift: float, solved: WormholeSpace = null) -> void:
	var same := throat_radius == rho0 and fillet_radius == fillet and not _grav_one.is_empty() and th0 == 0.0
	var Lc0 := Lc
	rho0 = throat_radius
	fillet = fillet_radius
	Lc = 0.5 * cylinder
	h = Lc + fillet
	th0 = 0.0
	L = Lc + fillet * PI / 2.0
	Rout = rho0 + fillet
	lift = p_lift
	if same:
		if Lc != Lc0:
			_grav_sum()
	elif solved != null and solved.rho0 == rho0 and solved.fillet == fillet and solved.th0 == 0.0:
		grav_k = solved.grav_k
		_grav_one = solved._grav_one
		_grav_sum()
	else:
		_build_gravity()


## Where the point (l, n) of the space before a change of its shape (from: shape() then; no crease
## then or now), with the tangent vectors vecs there, is in it now: [l, n, vecs].
## - In the cylinder: at the same share of its length; on a fillet: at the same angle along it; n
##   and the vectors' parts (U_l, u) as they were. It goes with the throat.
## - In a flat universe: at the same place of its chart, the vectors as the chart has them: what
##   stands on the floor stays there, what hangs over it keeps its height. A place the curved zone's
##   ball now covers goes straight out from the throat's centre to the ball's edge. With the lift
##   as it was n stays exactly.
func carried(l: float, n: Vector3, vecs: Array, from: PackedFloat64Array) -> Array:
	var Lc0 := 0.5 * from[1]
	var L0 := Lc0 + from[2] * PI / 2.0
	var al := absf(l)
	if al < Lc0:
		return [l * Lc / Lc0, n, vecs.duplicate()]
	if al < L0:
		return [signf(l) * (Lc + (al - Lc0) * fillet / from[2]), n, vecs.duplicate()]
	var sg := -1.0 if l < 0.0 else 1.0
	var rr := al - L0 + from[0] + from[2]
	if lift == from[3]:
		return [sg * (maxf(rr, Rout) - Rout + L), n, vecs.duplicate()]
	# from the centre where it is now, in float64 (n's own digits are single)
	var cx := rr * n.x
	var cy := rr * n.y
	var cz := rr * n.z + from[3] - lift
	var rn := sqrt(cx * cx + cy * cy + cz * cz)
	var nn := Vector3(cx / rn, cy / rn, cz / rn)
	var out := []
	for U: Vector4 in vecs:
		# as R^4's xyz has it in that sheet (a chart's mirror in x undone both ways)
		var d := sg * U.x * n + Vector3(U.y, U.z, U.w)
		var rad := d.dot(nn)
		var u := d - rad * nn
		out.append(Vector4(sg * rad, u.x, u.y, u.z))
	return [sg * (maxf(rn, Rout) - Rout + L), nn, out]


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


## r''(l): cos(theta) / fillet on a fillet, 0 on the cylinder and in the flat universes.
func ddr(l: float) -> float:
	var al := absf(l)
	if al >= L or al < Lc:
		return 0.0
	return cos(_theta(al)) / fillet


## |l| where the sphere's radius is rr, in a universe or on its fillet: r's inverse there (rr below
## r_min: the cylinder's end, Lc).
func l_of_r(rr: float) -> float:
	if rr >= Rout:
		return rr - Rout + L
	return Lc + fillet * (acos(clampf(1.0 - (rr - rho0) / fillet, 0.0, cos(th0))) - th0)


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
## With trace ([points of R^4, their lengths along], Arrays: ray's), it also notes points of the path
## (_trace), stops where it goes through the floor and finds a fillet's end coarser (_cross); step: a
## fillet's RK4 steps, in fillet radii.
func geodesic(l: float, n: Vector3, dir: Vector4, dist: float, frame: Array, trace = null, step := STEP) -> Array:
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
			if trace != null and _trace(trace, l, psi, n, e, dist - left):
				break
		elif Lc > 0.0 and (al < Lc or (al == Lc and sg * vl <= 0.0)):
			# the cylinder: l and psi at constant rates until an end
			var s_out := INF
			if vl > 0.0:
				s_out = (Lc - l) / vl
			elif vl < 0.0:
				s_out = (Lc + l) / -vl
			var s := minf(left, s_out)
			if trace != null:
				# a helix in R^4, of curvature b^2 / rho0^3: points RAY_TOL off its chords at most
				var parts := ceili(s * b / sqrt(8.0 * RAY_TOL * rho0 * rho0 * rho0) - 1e-9)
				var hit := false
				for k in range(1, parts):
					var f := float(k) / parts
					if _trace(trace, l + vl * s * f, psi + b / (rho0 * rho0) * s * f, n, e, dist - left + s * f):
						hit = true
						break
				if hit:
					break
			l = (Lc if vl > 0.0 else -Lc) if s == s_out else l + vl * s
			psi += b / (rho0 * rho0) * s
			left -= s
			if trace != null and _trace(trace, l, psi, n, e, dist - left):
				break
		else:
			# a fillet, on side sg (at l = 0, where fillets meet with no cylinder: the side it goes to)
			if sg == 0.0:
				sg = signf(vl)
			var hs := minf(left, step * fillet)
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
				hs *= _cross(l, vl * hs, y1[0], y1[1] * hs, target, (sg > 0.0) == out, 32 if trace == null else 8,
						30 if trace == null else 10)
				y1 = _fillet_step(l, vl, psi, b, hs, sg)
				var bt := b / r(target)
				y1[0] = target
				y1[1] = (sg if out else -sg) * sqrt(maxf(1.0 - bt * bt, 0.0))
			if trace != null and _plane_height(y1[0], y1[2], n, e) < 0.0:
				# a traced step through the floor: only as far as the path's own point a hair
				# under it (halving the step's length), where _trace ends the ray
				var a := 0.0
				var z := hs
				for _it in 14:
					var m := 0.5 * (a + z)
					var ym := _fillet_step(l, vl, psi, b, m, sg)
					if _plane_height(ym[0], ym[2], n, e) < 0.0:
						z = m
						y1 = ym
					else:
						a = m
				hs = z
			l = y1[0]
			vl = y1[1]
			psi = y1[2]
			left -= hs
			if trace != null and _trace(trace, l, psi, n, e, dist - left):
				break
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


## The height over the floor at (l, psi) of the plane of n and e.
func _plane_height(l: float, psi: float, n: Vector3, e: Vector3) -> float:
	return r(l) * (cos(psi) * n.z + sin(psi) * e.z) + lift


## A point of a traced geodesic (ray): at (l, psi) of the plane of n and e, s along, appended to
## trace; true if the path went through the floor on its way there, where it is cut instead (on a
## straight piece exactly; a fillet's step ends a hair under the floor: geodesic; on the cylinder
## where the chord between two points of the helix does).
func _trace(trace: Array, l: float, psi: float, n: Vector3, e: Vector3, s: float) -> bool:
	var pts: Array = trace[0]
	var lens: Array = trace[1]
	var Q := embed(l, (cos(psi) * n + sin(psi) * e).normalized())
	if Q.z < -lift:
		var P: Vector4 = pts[pts.size() - 1]
		var s0: float = lens[lens.size() - 1]
		var f := (P.z + lift) / (P.z - Q.z)
		pts.append(P.lerp(Q, f))
		lens.append(s0 + f * (s - s0))
		return true
	pts.append(Q)
	lens.append(s)
	return false


## Where on a step the cubic with values y0, y1 and slopes d0, d1 (per step) at its ends first
## crosses target, going up (up) or down: the step's fraction (y0 may lie on target: a path that
## has just come in there). Its first sample past target of samples, then iters bisections; where
## none is, the sample nearest to target (a dip the samples miss).
static func _cross(y0: float, d0: float, y1: float, d1: float, target: float, up: bool, samples := 32,
		iters := 30) -> float:
	var a := 0.0
	var z := 1.0
	var nearest := 1.0
	var gap := INF
	for k in range(1, samples + 1):
		var t := float(k) / samples
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
	for _it in iters:
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


## The geodesic from (l, n) along the unit vector dir, for up to dist, cut where it reaches the
## floor (height 0): as points of R^4 and their lengths along it, [Array of Vector4, Array
## of float], the first at (l, n). In a flat universe a geodesic is a straight line of R^4, given by
## its ends; on the cylinder a helix, by points RAY_TOL off its chords at most; on a fillet by the
## ends of RK4 steps of RAY_STEP fillet radii. The floor is wherever the throat's height puts it
## (this file's top), in the curved zone too. What a hand points at (hands.gd).
func ray(l: float, n: Vector3, dir: Vector4, dist: float) -> Array:
	var trace := [[embed(l, n)], [0.0]]
	if trace[0][0].z > -lift:
		geodesic(l, n, dir, dist, [], trace, RAY_STEP)
	return trace


const RAY_STEP := 0.5           # fillet radii: ray's RK4 steps on a fillet
const RAY_TOL := 0.01           # m: how far a ray's helix on the cylinder strays from its points' chords


## The length the space bends over at l: r(l) in a flat universe, the throat's radius on its
## cylinder, the fillet's radius on a fillet (BallWorld.flight's steps).
func bend(l: float) -> float:
	var al := absf(l)
	if al >= L:
		return r(l)
	return rho0 if al <= Lc else fillet


## A chart position on one side (+1: chart A, -1: chart B) to the point of the space there. A chart
## is R^4's xyz in that side's half of the space (l > 0 or l < 0) raised by lift (the floor at
## z = 0), chart B's mirrored in x (a frame right-handed in either chart has the same orientation in
## the space): the point at x is the one on that side whose sphere has the radius of x from the
## throat's centre (0, 0, lift), in x's direction from it: in the flat universe from Rout on, on the
## fillet below it. Nearer the centre than r_min no point is: there it gives the cylinder's end in
## that direction.
func point_from_chart(side: float, x: Vector3) -> Array:
	var c := Vector3(x.x, x.y, x.z - lift)
	var rr := c.length()
	var n := c / rr if rr > 1e-9 else Vector3(0.0, 0.0, -1.0)
	if side < 0.0:
		n.x = -n.x
	if rr >= Rout:
		return [side * (rr - Rout + L), n]
	return [side * l_of_r(rr), n]


## Chart direction d at the point (l, n) of that side as a tangent vector: the chart's radial
## direction is the space's l, away from the throat. In a flat universe that is the vector itself;
## on a fillet and the cylinder it is the one of the same length and angles to n's sphere and to l (not
## R^4's xyz of it, which is shorter along l there).
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


## How far the point P of R^4 is from the space, along the space's normal there (normal4; 0 on it):
## in the plane of (distance from the w axis, |w|) the profile is the line w = h from Rout on, the
## line of radius rho0 up to the fillet's start, and the fillet's circle between them.
func off_surface(P: Vector4) -> float:
	var rho := sqrt(P.x * P.x + P.y * P.y + P.z * P.z)
	var a := absf(P.w)
	var ka := Lc - fillet * sin(th0)
	if rho >= Rout:
		return a - h
	if a <= ka:
		return rho0 - rho
	return sqrt((Rout - rho) * (Rout - rho) + (a - ka) * (a - ka)) - fillet


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


## Height above the floor, H = r(l) n_z + lift: R^4's z from the floor's hyperplane, the chart
## height z in either chart. Its gradient (r' n_z, e_z - n_z n) is no longer than 1 (the floor is no
## nearer than H), 1 in the flat universes and shorter in the curved zone; it is zero on the
## cylinder's top and bottom lines (n = +-z).
func height(l: float, n: Vector3) -> float:
	return r(l) * n.z + lift


func height_grad(l: float, n: Vector3) -> Vector4:
	var u := Vector3(0.0, 0.0, 1.0) - n.z * n
	return Vector4(dr(l) * n.z, u.x, u.y, u.z)


## The height's second derivative (its Hessian) at (l, n) applied to the tangent vector X: the
## gradient changes by this along X, per metre. Hess(X, Y) = n_z (r'' X_l Y_l - (1 - r'^2) / r x . y):
## zero in the flat universes.
func height_hess(l: float, n: Vector3, X: Vector4) -> Vector4:
	if absf(l) >= L:
		return Vector4.ZERO
	var rp := dr(l)
	var k := -n.z * (1.0 - rp * rp) / r(l)
	return Vector4(n.z * ddr(l) * X.x, k * X.y, k * X.z, k * X.w)


# ---------------------------------------------------------------- the floor

## The floor runs through the curved zone (bent there); else it is the charts' planes alone.
func floor_in_zone() -> bool:
	return absf(lift) < Rout


## The floor runs through the throat: one surface from universe A to B.
func floor_through() -> bool:
	return absf(lift) < r(0.0)


## The chart radius (from the point under or over the throat's centre) from which the floor is the
## chart's flat plane: inside it the floor is in the curved zone. 0: flat everywhere.
func floor_edge() -> float:
	return sqrt(maxf(Rout * Rout - lift * lift, 0.0))


## The chart radius of the floor's hole, the circle where it meets the throat's cylinder
## (floor_through); 0: no hole.
func floor_hole() -> float:
	var rm := r(0.0)
	return sqrt(maxf(rm * rm - lift * lift, 0.0))


## The floor's point at chart (x, y) of universe side: [l, n]. In the charts the floor is the plane
## z = 0 down to its hole (point_from_chart); a place inside the hole, where no floor is, gives the
## hole's rim in the same direction from the axis (toward +x from the axis itself): the floor's
## circle on the cylinder's end of that side.
func floor_point(side: float, xy: Vector2) -> Array:
	var rho := xy.length()
	if rho >= floor_hole():
		return point_from_chart(side, Vector3(xy.x, xy.y, 0.0))
	var nz := clampf(-lift / r(0.0), -1.0, 1.0)
	var d := xy / rho if rho > 1e-9 else Vector2(1.0, 0.0)
	var s := sqrt(1.0 - nz * nz)
	return [side * Lc, Vector3(side * s * d.x, s * d.y, nz)]


## Up on the floor at (l, n): the height's unit gradient (a tangent vector); zero where the height
## has none (height's comment), which the floor reaches only at lift = +-r_min.
func floor_normal(l: float, n: Vector3) -> Vector4:
	var g := height_grad(l, n)
	var gl := g.length()
	return g / gl if gl > 1e-6 else Vector4.ZERO


## The foot of (l, n) on the floor, or on the surface of height level: Newton's steps along the
## height's gradient, each a geodesic no longer than half the length the space bends over there (in a
## flat universe: than that past the way to the curved zone's ball), vecs carried along; where the
## height has no gradient, a step round the sphere. [l, n, vecs]. From a point near the floor it
## is near the floor's nearest point: off it by about the square of the way over the length the
## space bends over (the gradient's lines are not the floor's normals in the curved zone).
func to_floor(l: float, n: Vector3, vecs: Array = [], level := 0.0) -> Array:
	var out := vecs.duplicate()
	for _it in 40:
		var H := height(l, n) - level
		if absf(H) < FLOOR_TOL:
			break
		var g := height_grad(l, n)
		var gl := g.length()
		var most := 0.5 * bend(l) if absf(l) < L else r(l) - Rout + 0.5 * minf(fillet, rho0)
		var dir: Vector4
		var d: float
		if gl < 1e-6:
			var t := _normal_to(n)
			dir = Vector4(0.0, t.x, t.y, t.z)
			d = minf(sqrt(2.0 * rho0 * absf(H)), most)
		else:
			dir = g * (-signf(H) / gl)
			d = minf(absf(H) / gl, most)
		var res := nudge(l, n, dir * d, out) if d < 0.002 else geodesic(l, n, dir, d, out)
		l = res[0]
		n = res[1]
		out = res[2]
	return [l, n, out]


const FLOOR_TOL := 1e-7         # m: to_floor's foot is this near the floor (a point's n is single precision)


## How far (l, n) is from the floor, m, positive above it: the way along the height's unit gradient
## N to where the height's second-order expansion there, H - t |grad H| + t^2 Hess(N, N) / 2, is zero
## (in a flat universe the height itself: exact where the floor under the point is flat). INF where
## that never is: above a floor that bends away. What a ball's centre is from the floor: for the
## toys' sizes the third order is millimetres (tests/floor_test.gd, 1).
func floor_distance(l: float, n: Vector3) -> float:
	var H := height(l, n)
	if absf(l) >= L:
		return H
	var g := height_grad(l, n)
	var gl := g.length()
	if gl < 1e-6:
		return INF if H >= 0.0 else H
	var q := height_hess(l, n, g).dot(g) / (gl * gl)
	var disc := gl * gl - 2.0 * H * q
	if disc < 0.0:
		return INF if H >= 0.0 else 2.0 * H / gl
	return 2.0 * H / (gl + sqrt(disc))


# ---------------------------------------------------------------- gravity
# Gravity through the wormhole: docs/gravity.md.

## Solve the ODE for the current profile: closed form on the cylinder, RK4 over the fillet into
## a table, then scale so that f = r + beta / r^2 outside. The ODE is linear: over the fillet its
## solutions from (f, p) = (1, 0) and (0, 1) at its start (p = r^2 f' the flux, continuous even across
## the crease of h < fillet), kept (_grav_one), are summed with the cylinder's f and p there (_grav_sum).
func _build_gravity() -> void:
	grav_k = sqrt(2.0) / rho0
	var d := (L - Lc) / GRAV_NODES
	var hs := d / GRAV_SUB
	_grav_one = []
	for k in 2:
		var f := 1.0 if k == 0 else 0.0
		var p := 1.0 - f
		var raw := PackedFloat64Array()
		for i in GRAV_NODES + 1:
			var x := i * d                  # from the fillet's start: its shape there is the same at any Lc
			var ri := r(Lc + x)
			raw.append(f)
			raw.append(p / (ri * ri))
			if i == GRAV_NODES:
				break
			for _s in GRAV_SUB:               # RK4 for f' = p / r^2, p' = 2 f
				var r0 := r(Lc + x)
				var rm := r(Lc + x + 0.5 * hs)
				var r1 := r(Lc + x + hs)
				var f1 := p / (r0 * r0)
				var p1 := 2.0 * f
				var f2 := (p + 0.5 * hs * p1) / (rm * rm)
				var p2 := 2.0 * (f + 0.5 * hs * f1)
				var f3 := (p + 0.5 * hs * p2) / (rm * rm)
				var p3 := 2.0 * (f + 0.5 * hs * f2)
				var f4 := (p + hs * p3) / (r1 * r1)
				var p4 := 2.0 * (f + hs * f3)
				f += hs / 6.0 * (f1 + 2.0 * f2 + 2.0 * f3 + f4)
				p += hs / 6.0 * (p1 + 2.0 * p2 + 2.0 * p3 + p4)
				x += hs
		_grav_one.append(raw)
	_grav_sum()


var _grav_one: Array = []       # the fillet's two solutions, as _grav_tab (_build_gravity)


## The fillet's table for the cylinder's f and p at its end (cosh and its flux: 1, 0 without one), and
## the numbers outside.
func _grav_sum() -> void:
	var f := 1.0
	var p := 0.0
	if Lc > 0.0:
		f = cosh(grav_k * Lc)
		p = rho0 * rho0 * grav_k * sinh(grav_k * Lc)
	var s0: PackedFloat64Array = _grav_one[0]
	var s1: PackedFloat64Array = _grav_one[1]
	var fe := f * s0[2 * GRAV_NODES] + p * s1[2 * GRAV_NODES]           # at l = L, where r = Rout
	var fpe := f * s0[2 * GRAV_NODES + 1] + p * s1[2 * GRAV_NODES + 1]
	var a := (2.0 * fe + Rout * fpe) / (3.0 * Rout)
	grav_beta = Rout * Rout * (fe - Rout * fpe) / (3.0 * a)
	grav_a = 1.0 / a
	_grav_tab.resize(s0.size())
	for i in s0.size():
		_grav_tab[i] = (f * s0[i] + p * s1[i]) / a


## The fillet's table as the renderer takes it (look.gdshaderinc, look_grav_at): f, f' at its
## GRAV_NODES + 1 nodes from the fillet's start to its end, interleaved, single precision.
func gravity_table() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(_grav_tab.size())
	for i in _grav_tab.size():
		out[i] = _grav_tab[i]
	return out


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


## The potential divided by g, in metres: the chart height z far from the wormhole (lift added:
## the harmonic f n_z is measured from the throat's centre).
func potential(l: float, n: Vector3) -> float:
	return gravity_f(l)[0] * n.z + lift


## Its gradient; gravity is -g times this.
func potential_grad(l: float, n: Vector3) -> Vector4:
	var F := gravity_f(l)
	var u := (Vector3(0.0, 0.0, 1.0) - n.z * n) * (F[0] / r(l))
	return Vector4(F[1] * n.z, u.x, u.y, u.z)


## Strength of gravity on the floor, in g, at chart radius rho, m (along the chart's plane from the
## point under or over the throat's centre). Where the floor is flat (rho >= floor_edge()) the
## potential is z' (1 + beta / r^3) + lift (z' = -lift the floor's height against the centre,
## r^2 = rho^2 + lift^2), whose gradient has the parts 3 beta lift rho / r^5 along the floor and
## 1 + beta / r^3 - 3 beta lift^2 / r^5 up: look.gdshaderinc's look_grav_floor is the same. Where the
## floor is in the curved zone, the field at its point there (floor_point; inside the floor's hole:
## on its rim). Anywhere on the floor it is potential_grad's length at the point.
func floor_gravity(rho: float) -> float:
	var r2 := rho * rho + lift * lift
	if r2 < Rout * Rout:
		var p := floor_point(1.0, Vector2(rho, 0.0))
		return potential_grad(p[0], p[1]).length()
	var r1 := sqrt(r2)
	var r5 := r2 * r2 * r1
	var along := 3.0 * grav_beta * lift * rho / r5
	var up := 1.0 + grav_beta / (r2 * r1) - 3.0 * grav_beta * lift * lift / r5
	return sqrt(along * along + up * up)


## One RK4 step of free motion under gravity, -grav * potential_grad (geodesic + force).
## The vectors in frame (a body's axes) are parallel-transported along the step.
## Returns [l, n, U, frame]. The stages written out (no lambdas: GDScript calls them slowly).
func dynamics_step(l: float, n: Vector3, U: Vector4, dt: float, grav: float, frame: Array = []) -> Array:
	var h2 := 0.5 * dt
	var r1 := r(l)
	var k1 := dr(l) / r1
	var a1 := _accel(n, U, r1, k1, l, grav)
	var m1 := Vector3(U.y, U.z, U.w) / r1
	var l2 := l + h2 * U.x
	var n2 := n + h2 * m1
	var U2 := U + h2 * a1
	var r2 := r(l2)
	var k2 := dr(l2) / r2
	var a2 := _accel(n2, U2, r2, k2, l2, grav)
	var m2 := Vector3(U2.y, U2.z, U2.w) / r2
	var l3 := l + h2 * U2.x
	var n3 := n + h2 * m2
	var U3 := U + h2 * a2
	var r3 := r(l3)
	var k3 := dr(l3) / r3
	var a3 := _accel(n3, U3, r3, k3, l3, grav)
	var m3 := Vector3(U3.y, U3.z, U3.w) / r3
	var l4 := l + dt * U3.x
	var n4 := n + dt * m3
	var U4 := U + dt * a3
	var r4 := r(l4)
	var k4 := dr(l4) / r4
	var a4 := _accel(n4, U4, r4, k4, l4, grav)
	var m4 := Vector3(U4.y, U4.z, U4.w) / r4
	var nl := l + dt / 6.0 * (U.x + 2.0 * U2.x + 2.0 * U3.x + U4.x)
	var nn := (n + dt / 6.0 * (m1 + 2.0 * m2 + 2.0 * m3 + m4)).normalized()
	var nU := U + dt / 6.0 * (a1 + 2.0 * a2 + 2.0 * a3 + a4)
	var nF := []
	for A: Vector4 in frame:
		var b1 := _transport_rate(A, n, U, r1, k1)
		var b2 := _transport_rate(A + h2 * b1, n2, U2, r2, k2)
		var b3 := _transport_rate(A + h2 * b2, n3, U3, r3, k3)
		var b4 := _transport_rate(A + dt * b3, n4, U4, r4, k4)
		nF.append(tangent(nn, A + dt / 6.0 * (b1 + 2.0 * b2 + 2.0 * b3 + b4)))
	return [nl, nn, tangent(nn, nU), nF]


## dynamics_step's U' at a stage (nn, UU; rr = r(l), k = r'(l) / rr there): the geodesic's terms
## and gravity.
func _accel(nn: Vector3, UU: Vector4, rr: float, k: float, ll: float, grav: float) -> Vector4:
	var v := Vector3(UU.y, UU.z, UU.w)
	var vv := v.dot(v)
	var du := -k * UU.x * v - (vv / rr) * nn
	return Vector4(k * vv, du.x, du.y, du.z) - grav * potential_grad(ll, nn)


## The rate of a vector A parallel-transported at a stage of dynamics_step.
static func _transport_rate(A: Vector4, nn: Vector3, UU: Vector4, rr: float, k: float) -> Vector4:
	var v := Vector3(UU.y, UU.z, UU.w)
	var au := Vector3(A.y, A.z, A.w)
	var da := -k * A.x * v - (au.dot(v) / rr) * nn
	return Vector4(k * v.dot(au), da.x, da.y, da.z)


## Chart direction of a tangent vector at (l, n) of that side (the inverse of vector_from_chart).
static func vector_to_chart(side: float, n: Vector3, U: Vector4) -> Vector3:
	var d := side * U.x * n + Vector3(U.y, U.z, U.w)
	if side < 0.0:
		d.x = -d.x
	return d


## The chart position of a point (its side: the sign of l; point_from_chart's inverse off the
## cylinder, whose every point is r = rho0 from the centre in both charts).
func chart_position(l: float, n: Vector3) -> Vector3:
	var x := r(l) * n
	if l < 0.0:
		x.x = -x.x
	return Vector3(x.x, x.y, x.z + lift)


# ---------------------------------------------------------------- the sweep table
## The renderer's table (shaders/geo.gdshaderinc, ref/geo.py's top): G(b, v), the part of a ray's
## sweep (r) and length (g) over the fillet that the closed forms leave, on SWEEP_NB x SWEEP_NV
## nodes, both ends included: b by t = sign(s) sqrt(|s|), s = sigma - u0, evenly from b = 0 to
## b = Rout (fine where the weight is singular, at b = r_min); v = sqrt((u - u_lo) / (1/2 - u_lo))
## evenly from the fillet's start (or the turning point) to its end. Cumulative Gauss-Legendre,
## four points (_GAUSS_X) per span; the last row (v = 1) is the whole fillet's. ref/geo.py builds
## it the same way. {image (RGF), axes: the shader's g_tabx}.
const SWEEP_NB := 256
const SWEEP_NV := 64
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
	return {"image": img, "axes": Vector4(t0, 1.0 / (t1 - t0), SWEEP_NB, SWEEP_NV)}


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
