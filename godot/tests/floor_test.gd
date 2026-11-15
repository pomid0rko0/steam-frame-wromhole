extends SceneTree
## The floor at any height of the throat over it (WormholeSpace's top, viewer.gd, ball_world.gd,
## toys.gd, Renderer's field lines): no picture, exit status 1 on any failure:
##   godot --path . --headless --xr-mode off -s res://tests/floor_test.gd
## On the video's throat with its cylinder 8, 0 and 80 m long, at each of LIFTS' heights: over the
## curved zone (today's), through the fillets only, through the throat (twice), with the throat's
## centre under the floor (the floor still through the throat; only a cap of the zone over the
## floor), and the zone wholly under the floor.
## 1. the floor's geometry: floor_point is on the floor and at its chart place (inside the floor's
##    hole: on the rim, the same way from the axis); the charts' points come back from
##    chart_position; to_floor brings a point off the floor back to its foot; height_hess is the
##    height's second difference along geodesics; floor_distance is the way up the normal
## 2. standing anywhere: the feet on the floor, up the floor's normal, the axes orthonormal, the
##    head over the floor
## 3. walking: on the floor all the way, upright; the path is the floor's geodesic: it keeps the
##    angular momentum about the vertical axis through the throat's centre (the floor is a surface of
##    revolution about it: Clairaut), a walk in one move ends where the same in centimetre steps
##    does, and one straight at the axis goes as far as the floor's meridian is long, by an
##    independent quadrature: through the throat into universe B (lift below r_min), over the pit or
##    the bump and on in A (else); at lift 0 the floor is the space's own mirror plane, and the walk
##    is the space's geodesic (WormholeSpace.geodesic); the head stays over the floor and moves
##    little for a step; the world's limit holds
## 4. flying: with the feet under a bent floor the body lands on it, upright; a head at the floor
##    is pushed out of it; off the floor, up and let go, the fall with gravity lands on the floor
##    (in the throat too, under its roof; deep in the 80 m throat, where the field has faded, it
##    hangs), the head never in it
## 5. a ball and a cube dropped onto the floor where it bends (on a flat one too, to compare):
##    neither goes into it, the ball is held its radius from it by the chord of R^4 to the floor's
##    nearest point, the cube rests with its lowest corner (where the space cuts the box's edges) on it
## 6. the toys: nothing starts under the floor, in another toy or in one of the scene's objects;
##    with the throw and the drop, 12 s on, nothing is under the floor or gone
## 7. a pointing ray stops at the floor where it bends
## 8. floor_gravity is the field on the floor; the field lines start over the floor and end on it
## And where the floor leaves less room over the feet than the body is tall (the throat's top 9 cm
## over the floor), the head stays under the floor's other side and there is no taking off; at the
## lifts where the floor changes its kind (+-r_min, +-Rout, 0) and a millimetre to each side, walks
## from anywhere keep to the floor with the head HEAD_CLEAR over it (where it has no room, nobody
## stands: viewer.gd's top), and the toys stay over it.

const U := preload("res://tests/util.gd")
const THROAT := [3.0, 5.0, 1.0]         # main.gd's
const LENGTHS := [8.0, 0.0, 80.0]
const HEAD := 1.6

var sp: WormholeSpace
var tag := ""
var scene: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://scene.json"))


## The lifts of this file's top for the throat sp.
static func lifts(s: WormholeSpace) -> Array:
	return [s.Rout + 1.0, s.rho0 + 0.5 * s.fillet, 0.6 * s.rho0, 0.0, -0.5 * s.rho0,
			-(s.rho0 + 0.4 * s.fillet), -(s.Rout + 1.0)]


func _initialize() -> void:
	for cyl: float in LENGTHS:
		var probe := WormholeSpace.new(THROAT[0], THROAT[1], THROAT[2], 0.0)
		for lift: float in lifts(probe):
			sp = WormholeSpace.new(THROAT[0], THROAT[1], THROAT[2], lift)
			sp.set_shape(THROAT[0], cyl, THROAT[2], lift)
			tag = "lift %+.1f, cylinder %d m: " % [lift, roundi(cyl)]
			_geometry()
			_standing()
			_walking()
			_flying()
			_bodies()
			_toys()
			_rays()
			_gravity()
	_low_room()
	_odd_lifts()
	U.finish(self)


func _random_tangent(rng: RandomNumberGenerator, n: Vector3) -> Vector4:
	return WormholeSpace.tangent(n, Vector4(rng.randfn(), rng.randfn(), rng.randfn(), rng.randfn())).normalized()


## A random place of the floor's chart of side: half of them where the floor bends, if it does.
func _random_xy(rng: RandomNumberGenerator, i: int) -> Vector2:
	var e := sp.floor_edge()
	var rho := rng.randf_range(0.0, e + 0.5) if (i % 2 == 0 and e > 0.0) else rng.randf_range(0.0, 15.0)
	var a := rng.randf_range(0.0, TAU)
	return rho * Vector2(cos(a), sin(a))


func _geometry() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var hole := sp.floor_hole()
	var off := 0.0
	var place := 0.0
	for i in 300:
		var side := 1.0 if i % 3 > 0 else -1.0
		var xy := _random_xy(rng, i)
		var p := sp.floor_point(side, xy)
		off = maxf(off, absf(sp.height(p[0], p[1])))
		var x := sp.chart_position(p[0], p[1])
		if p[0] == 0.0 and side < 0.0:
			x.x = -x.x                      # the middle of a throat without a cylinder: side B's chart
		if xy.length() >= hole:
			place = maxf(place, (Vector2(x.x, x.y) - xy).length())
		else:
			# the rim, the same way from the axis
			place = maxf(place, absf(absf(p[0]) - sp.Lc) + absf(Vector2(x.x, x.y).length() - hole))
			if xy.length() > 1e-3:
				place = maxf(place, hole * absf(Vector2(x.x, x.y).angle_to(xy)))
	U.check(tag + "floor_point is on the floor, at its chart place", off < 2e-6 and place < 2e-5,
			"height within %s m, place within %s m" % [_e(off), _e(place)])
	var back := 0.0
	for i in 200:
		var side := 1.0 if i % 2 == 0 else -1.0
		var d := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized() * rng.randf_range(sp.r(0.0) + 1e-3, 12.0)
		var x := d + Vector3(0.0, 0.0, sp.lift)
		var p := sp.point_from_chart(side, x)
		back = maxf(back, (sp.chart_position(p[0], p[1]) - x).length() if p[0] != 0.0 else 0.0)
		back = maxf(back, absf(sp.height(p[0], p[1]) - x.z))
	U.check(tag + "a chart's point comes back from chart_position, its height the chart's z", back < 2e-5, "within %s m" % _e(back))
	# off the floor along its normal and back
	var foot := 0.0
	var landed := 0.0
	var dist3 := 0.0
	var dist5 := 0.0
	for i in 200:
		var side := 1.0 if i % 2 == 0 else -1.0
		var p := sp.floor_point(side, _random_xy(rng, i))
		var N := sp.floor_normal(p[0], p[1])
		if N == Vector4.ZERO:
			continue
		var t := rng.randf_range(0.03, 0.5) * (1.0 if i % 4 < 3 else -1.0)
		var q := sp.geodesic(p[0], p[1], N * signf(t), absf(t), [])
		var f := sp.to_floor(q[0], q[1])
		landed = maxf(landed, absf(sp.height(f[0], f[1])))
		foot = maxf(foot, (sp.embed(f[0], f[1]) - sp.embed(p[0], p[1])).length() / absf(t))
		var d := sp.floor_distance(q[0], q[1])
		if absf(t) <= 0.3:
			dist3 = maxf(dist3, absf(d - t))
		dist5 = maxf(dist5, absf(d - t))
	U.check(tag + "to_floor lands on the floor, at the foot", landed < 2e-6 and foot < 0.2,
			"height within %s m, off the foot by %.3f of the way at most" % [_e(landed), foot])
	U.check(tag + "floor_distance is the way up the floor's normal", dist3 < 0.005 and dist5 < 0.025,
			"within %.4f m up to 0.3 m, %.4f m up to 0.5 m" % [dist3, dist5])
	# the Hessian: the height's second difference along a geodesic
	var hess := 0.0
	var t := 0.05
	for i in 200:
		var l := rng.randf_range(-sp.L, sp.L)
		if absf(absf(l) - sp.Lc) < 1.5 * t or absf(absf(l) - sp.L) < 1.5 * t:
			continue
		var n := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		var X := _random_tangent(rng, n)
		var a := sp.geodesic(l, n, X, t, [])
		var b := sp.geodesic(l, n, -X, t, [])
		var second := (sp.height(a[0], a[1]) - 2.0 * sp.height(l, n) + sp.height(b[0], b[1])) / (t * t)
		hess = maxf(hess, absf(second - sp.height_hess(l, n, X).dot(X)))
	U.check(tag + "height_hess is the height's second difference", hess < 5e-3, "within %s per m" % _e(hess))


## How far the viewer's axes are from orthonormal with up the floor's normal, and the feet from the floor.
func _upright(v: Viewer) -> float:
	var N := sp.floor_normal(v.l, v.n)
	var e := absf(sp.height(v.l, v.n))
	if N != Vector4.ZERO:
		e = maxf(e, ((v.frame[1] as Vector4) - N).length())
	for i in 3:
		for j in 3:
			e = maxf(e, absf((v.frame[i] as Vector4).dot(v.frame[j]) - (1.0 if i == j else 0.0)))
		var F: Vector4 = v.frame[i]
		e = maxf(e, absf(Vector3(F.y, F.z, F.w).dot(v.n)))
	return e


func _head_height(v: Viewer) -> float:
	var hp := v.head(HEAD)
	return sp.height(hp[0], hp[1])


func _standing() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12
	var v := Viewer.new(sp)
	var worst := 0.0
	var low := INF
	for i in 300:
		var side := 1.0 if i % 3 > 0 else -1.0
		var a := rng.randf_range(0.0, TAU)
		v.stand_at(side, _random_xy(rng, i), Vector3(cos(a), sin(a), 0.0), Vector3(-sin(a), cos(a), 0.0))
		worst = maxf(worst, _upright(v))
		low = minf(low, _head_height(v))
	U.check(tag + "standing anywhere: on the floor, up its normal", worst < 5e-6, "within %s" % _e(worst))
	U.check(tag + "... the head over the floor", low >= Viewer.HEAD_CLEAR - 1e-5, "%.3f m over it at the least" % low)


## The floor's angular momentum about the vertical axis through the throat's centre of a walk the
## way c (in the room's x, z) from where v stands.
func _clairaut(v: Viewer, c: Vector2) -> float:
	var P := sp.embed(v.l, v.n)
	var D := sp.embed_vector(v.l, v.n, c.x * v.frame[0] + c.y * v.frame[2])
	return P.x * D.y - P.y * D.x


## The length of the floor's meridian from the chart radius e (the bend's edge) in to the floor's
## hole (the cylinder's end) or, with none, to the axis: Simpson's rule, by l (ds^2 = (1 + lift^2
## r'^2 / (r^2 - lift^2)) dl^2) or by the chart radius (ds^2 = (1 + (1 / r'^2 - 1) rho^2 / r^2)
## drho^2), whichever is regular there.
func _meridian() -> float:
	var m := 2000
	var sum := 0.0
	var e := sp.floor_edge()
	if sp.floor_through():
		for k in m + 1:
			var l := sp.Lc + (sp.L - sp.Lc) * k / m
			var rr := sp.r(l)
			var f := sqrt(1.0 + sp.lift * sp.lift * sp.dr(l) * sp.dr(l) / (rr * rr - sp.lift * sp.lift))
			sum += f * (1.0 if k == 0 or k == m else (4.0 if k % 2 == 1 else 2.0))
		return sum * (sp.L - sp.Lc) / m / 3.0
	for k in m + 1:
		var rho := e * k / m
		var rr := sqrt(rho * rho + sp.lift * sp.lift)
		var rp := sp.dr(sp.l_of_r(rr))
		var f := sqrt(1.0 + (1.0 / (rp * rp) - 1.0) * rho * rho / (rr * rr))
		sum += f * (1.0 if k == 0 or k == m else (4.0 if k % 2 == 1 else 2.0))
	return sum * e / m / 3.0


func _walking() -> void:
	var v := Viewer.new(sp)
	var fwd := Vector2(0.0, -1.0)       # the room's -z: forward
	var e := sp.floor_edge()
	# straight at the axis from chart A (10, 0), 16 m and the cylinder's length, in steps of a frame's run
	var far := 16.0 + (2.0 * sp.Lc if sp.floor_through() else 0.0)
	v.stand_at(1.0, Vector2(10.0, 0.0), Vector3(0.0, -1.0, 0.0), Vector3(1.0, 0.0, 0.0))
	var worst := 0.0
	var low := INF
	var jump := 0.0
	var was := sp.embed(v.head(HEAD)[0], v.head(HEAD)[1])
	for i in roundi(far / 0.05):
		v.move(0.05 * -(v.frame[2] as Vector4))
		worst = maxf(worst, _upright(v))
		low = minf(low, _head_height(v))
		var now := sp.embed(v.head(HEAD)[0], v.head(HEAD)[1])
		jump = maxf(jump, (now - was).length())
		was = now
	var x := sp.chart_position(v.l, v.n)
	var across := 2.0 * _meridian() + (2.0 * sp.Lc if sp.floor_through() else 0.0)
	var want := -(e + far - (10.0 - e) - across) if e > 0.0 else 10.0 - far
	var side := -1.0 if sp.floor_through() else 1.0
	U.check(tag + "%d m straight at the axis: " % roundi(far) + ("through the throat into universe B" if side < 0.0 else "on in universe A"),
			signf(v.l) == side and absf(x.x - want) < 3e-3 and absf(x.y) < 1e-3 and absf(x.z) < 1e-5,
			"side %+d, chart (%.4f, %.4f), expected (%.4f, 0): the floor's meridian by quadrature" % [signf(v.l), x.x, x.y, want])
	U.check(tag + "... on the floor and upright all the way", worst < 1e-5, "within %s" % _e(worst))
	U.check(tag + "... the head over the floor, and never far from where it was", low >= Viewer.HEAD_CLEAR - 1e-5 and jump < 0.15,
			"%.3f m over it at the least, %.3f m a 5 cm step at the most" % [low, jump])
	# past the axis, 1.2 m off it: the floor's geodesic keeps its angular momentum
	var ends := []
	for step: float in [0.011, 0.05, 30.0]:
		v.stand_at(1.0, Vector2(9.0, 1.2), Vector3(0.0, -1.0, 0.0), Vector3(1.0, 0.0, 0.0))
		var j0 := _clairaut(v, fwd)
		var drift := 0.0
		worst = 0.0
		var gone := 0.0
		while gone < 30.0 - 1e-9:
			var s := minf(step, 30.0 - gone)
			v.move(s * -(v.frame[2] as Vector4))
			gone += s
			drift = maxf(drift, absf(_clairaut(v, fwd) - j0))
			worst = maxf(worst, _upright(v))
		ends.append([v.l, v.n, v.frame.duplicate()])
		if step == 0.05:
			U.check(tag + "30 m past the axis, 1.2 m off it: the floor's geodesic (Clairaut)", drift < 2e-3 and worst < 1e-5,
					"its angular momentum about the axis within %s m of %.2f, on the floor within %s" % [_e(drift), j0, _e(worst)])
	var apart := 0.0
	var turned := 0.0
	for k in [0, 2]:
		apart = maxf(apart, (sp.embed(ends[k][0], ends[k][1]) - sp.embed(ends[1][0], ends[1][1])).length())
		for i in 3:
			turned = maxf(turned, (sp.embed_vector(ends[k][0], ends[k][1], ends[k][2][i])
					- sp.embed_vector(ends[1][0], ends[1][1], ends[1][2][i])).length())
	U.check(tag + "... in steps of 1.1 cm, of 5 cm and in one move: the same end", apart < 3e-3 and turned < 3e-3,
			"within %s m, the axes within %s" % [_e(apart), _e(turned)])
	if sp.lift == 0.0:
		# the floor is the space's mirror plane n_z = 0: its geodesics are the space's
		v.stand_at(1.0, Vector2(9.0, 1.2), Vector3(0.0, -1.0, 0.0), Vector3(1.0, 0.0, 0.0))
		var g := sp.geodesic(v.l, v.n, -(v.frame[2] as Vector4), 30.0, v.frame)
		var d: float = (sp.embed(g[0], g[1]) - sp.embed(ends[1][0], ends[1][1])).length()
		var f := 0.0
		for i in 3:
			f = maxf(f, (sp.embed_vector(g[0], g[1], g[2][i]) - sp.embed_vector(ends[1][0], ends[1][1], ends[1][2][i])).length())
		U.check(tag + "... and where the space's geodesic ends, the axes as it carries them", d < 1e-3 and f < 1e-3,
				"within %s m, the axes within %s; in universe %s" % [_e(d), _e(f), "B" if g[0] < 0.0 else "A"])
	# the world's limit
	v.stand_at(1.0, Vector2(38.0, 3.0), Vector3(0.0, -1.0, 0.0), Vector3(1.0, 0.0, 0.0))
	v.move(6.0 * (v.frame[2] as Vector4))
	var out := sp.chart_position(v.l, v.n)
	var lim := sqrt(Viewer.LIMIT * Viewer.LIMIT - sp.lift * sp.lift)
	U.check(tag + "the feet stay within the world", absf(Vector2(out.x, out.y).length() - lim) < 1e-4 and absf(out.z) < 1e-5,
			"%.4f m from the axis, the limit %.4f" % [Vector2(out.x, out.y).length(), lim])


func _flying() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 14
	var v := Viewer.new(sp)
	var worst := 0.0
	var away := 0.0
	var pushed := INF
	var count := 0
	for i in 60:
		var side := 1.0 if i % 3 > 0 else -1.0
		var a := rng.randf_range(0.0, TAU)
		var xy := _random_xy(rng, 0)
		v.stand_at(side, xy, Vector3(cos(a), sin(a), 0.0), Vector3(-sin(a), cos(a), 0.0))
		if _head_height(v) < 1.0:
			continue                        # no room to fly here
		count += 1
		var feet := sp.embed(v.l, v.n)
		# the head 1 m over the floor, the body tilted: the feet under the floor
		var hp := sp.geodesic(v.l, v.n, v.frame[1], 1.0, v.frame)
		v.fly_at(hp[0], hp[1], Viewer.tilt(hp[2], 0.2, 0.1, Vector2(0.0, -1.0)), HEAD)
		var landed := v.touch_down()
		worst = maxf(worst, _upright(v) if landed and v.standing else 1.0)
		away = maxf(away, (sp.embed(v.l, v.n) - feet).length())
		# upside down, the head 1 cm over the floor: pushed out, the feet over it
		v.stand_at(side, xy, Vector3(cos(a), sin(a), 0.0), Vector3(-sin(a), cos(a), 0.0))
		hp = sp.geodesic(v.l, v.n, v.frame[1], 0.01, v.frame)
		v.fly_at(hp[0], hp[1], [hp[2][0], -hp[2][1], -hp[2][2]], HEAD)
		v.V = -3.0 * (hp[2][1] as Vector4)
		var was := v.keep_head_up(HEAD)
		var h2 := v.head(HEAD)
		pushed = minf(pushed, sp.height(h2[0], h2[1]) if was else -1.0)
		worst = maxf(worst, maxf(-v.V.dot(sp.floor_normal(h2[0], h2[1])), 0.0))
	U.check(tag + "flying with the feet under the floor: lands on it, upright", worst < 1e-5 and away < 0.7,
			"within %s, %.2f m from under the head at most (%d places)" % [_e(worst), away, count])
	U.check(tag + "a head at the floor is pushed out of it", pushed >= Viewer.HEAD_CLEAR - 1e-4, "%.4f m over it" % pushed)
	# as main._locomotion does it: off the floor 6, 8 m and (to the throat's middle, with the floor
	# through it) 6 m + L on from chart A (10, 0.3), half a second up and aside, then let go
	var landed := 0
	var adrift := 0
	var slow := 0.0
	var low := INF
	worst = 0.0
	for far: float in [6.0, 8.0, 10.0 - sp.Rout + sp.L]:
		v.stand_at(1.0, Vector2(10.0, 0.3), Vector3(0.0, -1.0, 0.0), Vector3(1.0, 0.0, 0.0))
		v.move(far * -(v.frame[2] as Vector4))
		if not v.take_off(HEAD):
			continue
		for i in 30:
			v.push(Vector3(0.5, 4.0, -1.0), 1.0 / 60.0, HEAD)
			v.keep_head_up(HEAD)
		var t := 0.0
		while t < 30.0 and not v.standing:
			v.coast(1.0 / 60.0, HEAD)
			v.right_up(1.0 / 60.0, HEAD)
			v.keep_head_up(HEAD)
			low = minf(low, _head_height(v))
			v.touch_down()
			t += 1.0 / 60.0
		low = minf(low, _head_height(v))
		if v.standing:
			landed += 1
			slow = maxf(slow, t)
			worst = maxf(worst, _upright(v))
		elif sp.Lc > 10.0 and absf(v.l) < sp.Lc:
			adrift += 1                 # in a long throat the field has faded (docs/gravity.md): it drifts on
	U.check(tag + "off the floor, half a second up and let go: the fall lands on the floor, upright, the head never in it",
			landed + adrift == 3 and worst < 1e-5 and low >= Viewer.HEAD_CLEAR - 1e-4,
			"%d of 3 landed, the last after %.2f s, within %s, %d still adrift in the long throat after 30 s; the head %.3f m over the floor at the least"
			% [landed, slow, _e(worst), adrift, low])


## The chord of R^4 from (l, n) to the nearest floor of its own azimuth about the vertical axis (the
## floor is a surface of revolution about it): by search along the floor's meridian there, both
## ways from the axis.
func _to_floor_chord(l: float, n: Vector3) -> float:
	var P := sp.embed(l, n)
	var az := Vector2(n.x, n.y)
	az = az.normalized() if az.length() > 1e-6 else Vector2(1.0, 0.0)
	var best := INF
	var lo := 0.0 if sp.floor_through() else sp.l_of_r(absf(sp.lift))   # the floor is from there on
	for way: float in [1.0, -1.0]:
		for sg: float in [1.0, -1.0]:
			var a: float = maxf(absf(l) - 1.5, lo)
			var b: float = maxf(absf(l) + 1.5, lo + 1e-3)
			if sg != signf(l) and absf(l) > 1.5:
				continue
			for _pass in 4:
				var at := a
				var m := 60
				var step := (b - a) / m
				for k in m + 1:
					var ll: float = a + step * k
					var rr := sp.r(ll)
					var nz := clampf(-sp.lift / rr, -1.0, 1.0)
					var s := sqrt(1.0 - nz * nz)
					var d := (sp.embed(sg * ll, Vector3(way * s * az.x, way * s * az.y, nz)) - P).length()
					if d < best:
						best = d
						at = ll
				if at < a or at > b:
					break                   # this branch holds nothing nearer
				a = maxf(at - step, lo)
				b = at + step
	return best


## The lowest of a cube's corners over the floor: where the space cuts the box's edges along E4,
## by bisection along each.
func _lowest_corner(world: BallWorld, cube: BallWorld.Cube) -> float:
	var box := world.box4(cube)
	var low := INF
	for s: Vector3 in BallWorld.CORNERS:
		var P: Vector4 = box[0] + cube.half * (s.x * box[1] + s.y * box[2] + s.z * box[3])
		var a := -cube.half
		var z := cube.half
		if sp.off_surface(P + a * box[4]) * sp.off_surface(P + z * box[4]) > 0.0:
			continue                        # this edge the space does not cut
		var up := sp.off_surface(P + z * box[4]) > 0.0
		for _it in 40:
			var m := 0.5 * (a + z)
			if (sp.off_surface(P + m * box[4]) > 0.0) == up:
				z = m
			else:
				a = m
		low = minf(low, (P + a * box[4]).z + sp.lift)
	return low


func _bodies() -> void:
	var world := BallWorld.new(sp, scene)
	var e := maxf(sp.floor_edge(), 3.0)     # a flat floor: as tests/physics_test.gd has it, to compare
	var hole := sp.floor_hole()
	var sunk := 0.0
	var gap := 0.0
	var corner := 0.0
	var lost := false
	var rested := 0
	var hover := 0.0
	for share: float in [0.15, 0.5, 0.85]:
		world.balls.clear()
		world.cubes.clear()
		var xy := Vector2(hole + share * (e - hole), 0.0).rotated(1.0 + share)
		var p := sp.floor_point(1.0, xy)
		var N := sp.floor_normal(p[0], p[1])
		var q := sp.geodesic(p[0], p[1], N, 0.6, [])
		var ball := world.add(q[0], q[1], Vector4.ZERO, 0.25, Color.WHITE)
		var p2 := sp.floor_point(-1.0, xy.rotated(2.0))
		var N2 := sp.floor_normal(p2[0], p2[1])
		var A := WormholeSpace._normal_to(p2[1])
		var q2 := sp.geodesic(p2[0], p2[1], N2, 0.6, [N2, Vector4(0.0, A.x, A.y, A.z), Vector4(1.0, 0.0, 0.0, 0.0)])
		var cube := world.add_cube(q2[0], q2[1], Vector4.ZERO, q2[2], Vector3(0.7, -0.4, 0.3), 0.2, Color.WHITE)
		var touched := INF
		for i in 720:
			world.step(BallWorld.DT, [])
			if is_nan(ball.l) or is_nan(cube.l) or is_nan(ball.U.x) or is_nan(cube.U.x):
				lost = true
				break
			if i % 4 == 0:
				var d := _to_floor_chord(ball.l, ball.n) * signf(sp.height(ball.l, ball.n))
				sunk = maxf(sunk, ball.radius - d)
				touched = minf(touched, d - ball.radius)
				corner = maxf(corner, -_lowest_corner(world, cube))
		gap = maxf(gap, touched)
		if cube.still > BallWorld.SLEEP_TIME:
			rested += 1
			hover = maxf(hover, absf(_lowest_corner(world, cube)))
	var where := "where the floor bends" if sp.floor_in_zone() else "on a flat floor"
	U.check(tag + "a ball dropped %s is held its radius from it" % where, not lost and sunk < 0.008 and gap < 0.008,
			"%.4f m into it at the most, %.4f m short of it" % [sunk, gap])
	U.check(tag + "a cube dropped there keeps its corners over it, and rests on them", not lost and corner < 0.003 and hover < 0.003,
			"%.4f m under it at the most; at rest after 4 s in %d places of 3, its lowest corner within %.4f m of the floor" % [corner, rested, hover])


func _toys() -> void:
	var toys := Toys.new(sp, scene)
	toys.spawn()
	var world := toys.world
	var bodies: Array = world.balls + world.cubes
	var low := INF
	var bent := false
	var near := INF
	var objects := INF
	for i in bodies.size():
		var b: BallWorld.Body = bodies[i]
		var cube := b as BallWorld.Cube
		var size: float = cube.half if cube else (b as BallWorld.Ball).radius
		var reach := 1.7321 * size if cube else size
		low = minf(low, _to_floor_chord(b.l, b.n) * signf(sp.height(b.l, b.n)) - size)
		var x := sp.chart_position(b.l, b.n)
		if sp.floor_edge() > 0.0 and Vector2(x.x, x.y).length() < sp.floor_edge() + size:
			bent = true
		for j in range(i + 1, bodies.size()):
			var o: BallWorld.Body = bodies[j]
			var oc := o as BallWorld.Cube
			near = minf(near, (sp.embed(b.l, b.n) - sp.embed(o.l, o.n)).length() - reach
					- (1.7321 * oc.half if oc else (o as BallWorld.Ball).radius))
		for s: Array in scene["spheres_A" if b.l > 0.0 else "spheres_B"]:
			objects = minf(objects, (x - Vector3(s[0], s[1], s[2])).length() - s[3] - reach)
		for q: Array in (scene["pillars_A"] if b.l > 0.0 else []):
			objects = minf(objects, Vector2(x.x - q[0], x.y - q[1]).length() - q[2] - reach)
		for q: Array in (scene["boxes_B"] if b.l < 0.0 else []):
			objects = minf(objects, (x - Vector3(q[0], q[1], q[2])).length() - 1.7321 * q[3] - reach)
	U.check(tag + "the toys start on the floor, where it is flat", absf(low) < 2e-3 and not bent,
			"the floor within %s m of each one's size under it" % _e(absf(low)))
	U.check(tag + "... clear of each other and of the scene's objects", near > 0.05 and objects > 0.05,
			"%.2f m between two at the least, %.2f m from an object" % [near, objects])
	var d := toys.drop_at()
	var t := sp.point_from_chart(1.0, Vector3(9.0, -1.9, 1.4))
	U.check(tag + "the throw and the drop start over the floor, clear of it", d.z >= Toys.DROP_RADIUS + 1.0
			and sp.height(t[0], t[1]) > 1.0 and t[0] > sp.L, "the drop from %.2f m, the throw from %.2f m" % [d.z, sp.height(t[0], t[1])])
	var under := INF
	var fast := 0.0
	var lost := false
	for i in 2160:
		toys.step(BallWorld.DT, [])
		if i % 30 == 29 or i == 2159:
			for b: BallWorld.Body in world.balls + world.cubes:
				if is_nan(b.l) or is_nan(b.U.x) or is_nan(b.n.x):
					lost = true
					continue
				under = minf(under, sp.height(b.l, b.n))
				fast = maxf(fast, b.U.length())
	U.check(tag + "12 s on, with the throw and the drop: every toy over the floor, none gone",
			not lost and under > 0.02 and fast < 40.0 and world.balls.size() == 6 and world.cubes.size() == 5,
			"the lowest centre %.3f m over it, the fastest %.1f m/s" % [under, fast])


func _rays() -> void:
	if not sp.floor_in_zone():
		return                              # flat floors: tests/pull_test.gd
	var rng := RandomNumberGenerator.new()
	rng.seed = 17
	var ends := 0.0
	var long := 0.0
	var up := INF
	for i in 40:
		var side := 1.0 if i % 2 == 0 else -1.0
		var p := sp.floor_point(side, _random_xy(rng, 0))
		var N := sp.floor_normal(p[0], p[1])
		var a := sp.geodesic(p[0], p[1], N, 1.0, [N])
		if sp.height(a[0], a[1]) < 0.3:
			continue                        # the floor again on the other side
		var ray := sp.ray(a[0], a[1], -(a[2][0] as Vector4), 5.0)
		var pts: Array = ray[0]
		var lens: Array = ray[1]
		ends = maxf(ends, absf((pts[pts.size() - 1] as Vector4).z + sp.lift))
		long = maxf(long, absf(lens[lens.size() - 1] - 1.0))
		ray = sp.ray(a[0], a[1], a[2][0], 0.3)
		for P: Vector4 in ray[0]:
			up = minf(up, P.z + sp.lift)
	U.check(tag + "a ray pointed at the bent floor from 1 m stops on it", ends < 1e-4 and long < 0.01 and up > 0.3,
			"its end within %s m of the floor's height, %.4f m off 1 m long" % [_e(ends), long])


func _gravity() -> void:
	var worst := 0.0
	var e := sp.floor_edge()
	for i in 60:
		var rho := 0.5 * i
		var a := 0.7 * i
		for side: float in [1.0, -1.0]:
			var p := sp.floor_point(side, Vector2(rho * cos(a), rho * sin(a)))
			worst = maxf(worst, absf(sp.potential_grad(p[0], p[1]).length() - sp.floor_gravity(rho)))
	var seam := absf(sp.floor_gravity(e + 1e-4) - sp.floor_gravity(maxf(e - 1e-4, 0.0)))
	U.check(tag + "floor_gravity is the field on the floor", worst < 1e-5 and seam < 1e-3,
			"within %s g, 0 to 29.5 m from the axis in A and B; across the bend's edge within %s g" % [_e(worst), _e(seam)])
	# the field lines, as Renderer.line_chunks starts them
	var top := sp.Rout + Renderer.LINE_TOP
	var k := int((sp.Rout + Renderer.LINE_REACH) / Renderer.LINE_STEP)
	var lines := 0
	var low := INF
	var end := 0.0
	var loose := 0
	for side: float in [1.0, -1.0]:
		for i in range(-k, k + 1):
			var y := i * Renderer.LINE_STEP
			var rr := Vector2(y, top).length()
			var pts := Renderer._field_line(sp, side * (rr - sp.Rout + sp.L), atan2(top, y),
					maxf(Vector2(rr, top).length(), Vector2(sp.Rout + Renderer.LINE_REACH, sp.lift).length()) + 1.0)
			if pts.size() < 2:
				continue
			lines += 1
			for q: Array in pts:
				low = minf(low, sp.height(q[0], Vector3(0.0, cos(q[1]), sin(q[1]))))
			var last: Array = pts[pts.size() - 1]
			var h := sp.height(last[0], Vector3(0.0, cos(last[1]), sin(last[1])))
			if h > 0.05:
				# it ends in the air: in a long throat's cylinder, where the field fades, out of steps
				loose += 1 if absf(last[0]) > sp.Lc else 0
			else:
				end = maxf(end, absf(h))
	var chunks := Renderer.line_chunks(sp)
	var finite := true
	for x: float in chunks["in"]:
		finite = finite and is_finite(x)
	var over: bool = top + sp.lift > 0.0
	U.check(tag + "the field lines start over the floor and end on it", (lines > 0) == over and low > -1e-5 and end < 1e-4 and loose == 0
			and finite and chunks["n"] <= Renderer.LINE_CHUNKS,
			"%d lines in %d chunks, the lowest point %s m over the floor, the ends within %s m of it, %d not on it" % [lines, chunks["n"], _e(low), _e(end), loose])


## The throat's top 9 cm over the floor: the floor runs round the throat's cylinder 0.74 m to each
## side of its top line, less than a body is tall.
func _low_room() -> void:
	sp = WormholeSpace.new(THROAT[0], THROAT[1], THROAT[2], -0.97 * THROAT[0])
	var v := Viewer.new(sp)
	v.stand_at(1.0, Vector2(0.2, 0.1), Vector3(0.0, -1.0, 0.0), Vector3(1.0, 0.0, 0.0))
	var rim := absf(v.l - sp.Lc) < 1e-9 and _upright(v) < 5e-6
	# along the throat, toward its middle
	var along := Vector4(-1.0, 0.0, 0.0, 0.0)
	along -= along.dot(v.frame[1]) * (v.frame[1] as Vector4)
	var low := INF
	var worst := 0.0
	for i in 40:
		v.move(0.05 * Vector4(-1.0, 0.0, 0.0, 0.0))
		low = minf(low, _head_height(v))
		worst = maxf(worst, _upright(v))
	U.check("the throat's top 9 cm over the floor: standing in the floor's hole is on its rim, and a walk into the throat keeps to the floor",
			rim and worst < 1e-5 and absf(v.l) < sp.Lc - 1.9, "within %s, l %.2f (the cylinder's end %.2f)" % [_e(worst), v.l, sp.Lc])
	U.check("... the head under the floor's other side", low >= Viewer.HEAD_CLEAR - 1e-4 and v._head_up < 1.4,
			"%.3f m over the floor at the least, %.2f m up from the feet" % [low, v._head_up])
	U.check("... and no taking off there", not v.take_off(HEAD) and v.standing)
	sp = WormholeSpace.new(THROAT[0], THROAT[1], THROAT[2], -0.5 * THROAT[0])
	v = Viewer.new(sp)
	v.stand_at(1.0, Vector2(0.2, 0.1), Vector3(0.0, -1.0, 0.0), Vector3(1.0, 0.0, 0.0))
	U.check("the throat's top 1.5 m over the floor: room to take off", v.take_off(HEAD) and not v.standing and absf(v._head_up - HEAD) < 1e-9)


## The lifts at which the floor changes its kind, and a millimetre to each side: at +-r_min the
## floor only touches the throat's cylinder along its bottom or top line, where the height has no
## gradient. Nothing may be lost there: standing and walking stay on the floor, the toys over it.
func _odd_lifts() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 19
	for cyl: float in [8.0, 0.0]:
		for base: float in [THROAT[0], -THROAT[0], THROAT[0] + THROAT[2], -THROAT[0] - THROAT[2], 0.0]:
			for d: float in [0.0, 1e-3, -1e-3]:
				sp = WormholeSpace.new(THROAT[0], THROAT[1], THROAT[2], base + d)
				sp.set_shape(THROAT[0], cyl, THROAT[2], base + d)
				var worst := 0.0
				var head := INF
				var under := INF
				var lost := false
				var v := Viewer.new(sp)
				for i in 24:
					var a := rng.randf_range(0.0, TAU)
					var xy := Vector2(rng.randf_range(0.0, 5.0), 0.0).rotated(rng.randf_range(0.0, TAU)) if i > 0 else Vector2.ZERO
					v.stand_at(1.0 if i % 2 == 0 else -1.0, xy, Vector3(cos(a), sin(a), 0.0), Vector3(-sin(a), cos(a), 0.0))
					for k in 80:
						v.move(0.05 * -(v.frame[2] as Vector4))
						var hp := v.head(HEAD)
						if is_nan(v.l) or is_nan(v.n.x) or is_nan((v.frame[0] as Vector4).x) or is_nan(hp[0]):
							lost = true
							break
						worst = maxf(worst, absf(sp.height(v.l, v.n)))
						head = minf(head, sp.height(hp[0], hp[1]))
					if lost:
						break
				var toys := Toys.new(sp, scene)
				toys.spawn()
				for i in 1440:
					toys.step(BallWorld.DT, [])
				for b: BallWorld.Body in toys.world.balls + toys.world.cubes:
					if is_nan(b.l) or is_nan(b.U.x) or is_nan(b.n.x):
						lost = true
					else:
						under = minf(under, sp.height(b.l, b.n))
				U.check("lift %+.3f, cylinder %d m, where the floor changes its kind: walks keep to the floor, the toys over it" % [base + d, roundi(cyl)],
						not lost and worst < 1e-4 and head >= Viewer.HEAD_CLEAR - 1e-5 and under > 0.02,
						"the feet within %s m of the floor, the head %.4f m over it at the least, the lowest toy's centre %.3f m" % [_e(worst), head, under])


## x as "1.5e-5"
static func _e(x: float) -> String:
	if x == 0.0 or not is_finite(x):
		return str(x)
	var ex := floori(log(absf(x)) / log(10.0))
	return "%.1fe%d" % [x / pow(10.0, ex), ex]
