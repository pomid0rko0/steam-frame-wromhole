extends SceneTree
## #147's scenes: the head in the throat's cylinder (fake headset case 1, 400 x 400 an eye), a cube
## (half 0.15 to 0.3) near it turned at random, then turned round the throat's axis (an isometry) so
## that a corner, an edge's point or a face's point of it lies on one eye's axis (the line through that
## eye and the throat's centre, round which the zone's meshes are built), or next to it (1e-4 to 1e-2
## rad). The cube in the log's teal. Each scene's draws come from the seed in order: scene i of a seed
## is the same whichever others are drawn. Prints each scene's parameters ("conf") and its cube in R^4
## with the eye ("cube": C, E1, E2, E3, the half size; the eye whose axis it is: l, n; the direction
## the feature is at; the head's l, n), and saves both eyes' pictures.
##   (from godot/, the script as res://tests/repro147_tmp.gd: run.sh)
##   godot --path . -s res://tests/repro147_tmp.gd -- out_prefix count seed [i,j,...: only these]

const U := preload("res://tests/util.gd")

var main: Main
var hmd
var frames := 0
var i := 0
var n := 0
var prefix := ""
var rng := RandomNumberGenerator.new()
var conf := {}
var only: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	prefix = args[0]
	n = int(args[1])
	rng.seed = int(args[2])
	if args.size() > 3:
		only = Array(args[3].split(",")).map(func(x): return int(x))
	hmd = U.headset(1, 0.0, Vector2i(400, 400))
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "FakeHMD"
	main.show_check = false
	main.toys.enabled = false
	root.add_child(main)


func _rv(a: float) -> Vector3:
	return Vector3(rng.randf_range(-a, a), rng.randf_range(-a, a), rng.randf_range(-a, a))


func _process(_delta: float) -> bool:
	frames += 1
	if frames < 4:
		return false
	if frames == 4:
		main.menu.visible = false
		main.hold = true
	var phase := (frames - 4) % 4
	if phase == 0:
		var kind := rng.randi_range(0, 2)
		var x := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
		var k := rng.randi_range(0, 2)
		if kind == 0:
			x = x.sign()
		elif kind == 1:
			var v: float = x[k]
			x = x.sign()
			x[k] = v
		else:
			x[k] = signf(x[k])
		conf = {"l": rng.randf_range(-3.0, 3.0), "yaw": rng.randf_range(0.0, 50.0) if rng.randf() < 0.5 else rng.randf_range(130.0, 180.0),
			"pitch": rng.randf_range(-35.0, 35.0), "roll": rng.randf_range(-15.0, 15.0),
			"dir": Vector3(rng.randf_range(-0.6, 0.6), rng.randf_range(-0.6, 0.6), -1.0).normalized(),
			"gap": rng.randf_range(0.0, 0.5), "half": [0.15, 0.25, 0.3][rng.randi_range(0, 2)],
			"turn": _rv(PI), "kind": kind, "x": x, "eye": rng.randi_range(0, 1),
			"near": [0.0, 1e-4, 1e-3, 1e-2][rng.randi_range(0, 3)], "nearv": _rv(1.0).normalized()}
		if not only.is_empty() and not (i in only):
			i += 1
			frames -= 1
			if i >= n:
				U.finish(self, hmd)
				return true
			return false
		main.place_on_axis(conf.l, conf.yaw, conf.pitch, conf.roll)
	elif phase == 1:
		_bodies()
	elif phase == 3:
		U.save_eyes(main, "%s_%03d" % [prefix, i], "app")
		print("conf %d: %s" % [i, conf])
		i += 1
		if i >= n:
			U.finish(self, hmd)
			return true
	return false


static func cross4(a: Vector4, b: Vector4, c: Vector4) -> Vector4:
	var ayzw := Vector3(a.y, a.z, a.w); var byzw := Vector3(b.y, b.z, b.w); var cyzw := Vector3(c.y, c.z, c.w)
	var axzw := Vector3(a.x, a.z, a.w); var bxzw := Vector3(b.x, b.z, b.w); var cxzw := Vector3(c.x, c.z, c.w)
	var axyw := Vector3(a.x, a.y, a.w); var bxyw := Vector3(b.x, b.y, b.w); var cxyw := Vector3(c.x, c.y, c.w)
	var axyz := Vector3(a.x, a.y, a.z); var bxyz := Vector3(b.x, b.y, b.z); var cxyz := Vector3(c.x, c.y, c.z)
	return Vector4(ayzw.dot(byzw.cross(cyzw)), -axzw.dot(bxzw.cross(cxzw)), axyw.dot(bxyw.cross(cxyw)), -axyz.dot(bxyz.cross(cxyz)))


static func rot4(R: Basis, v: Vector4) -> Vector4:
	var p := R * Vector3(v.x, v.y, v.z)
	return Vector4(p.x, p.y, p.z, v.w)


func _bodies() -> void:
	var sp: WormholeSpace = main.space
	var hp: Array = main._head_pose
	var head: Transform3D = hmd.head
	var half: float = conf.half
	var c: Vector3 = (conf.dir as Vector3) * (conf.gap + half * 1.2)
	var turn: Basis = head.basis * Basis.from_euler(conf.turn)
	var g := _walk(sp, hp, head.basis * c)
	var C := sp.embed(g[0], g[1])
	var E: Array[Vector4] = []
	for ax in [turn.x, turn.y]:
		var A: Vector4 = ax.x * g[2][0] + ax.y * g[2][1] + ax.z * g[2][2]
		E.append(sp.embed_vector(g[0], g[1], A).normalized())
	var N := sp.normal4(g[0], g[1])
	E.append(-cross4(E[0], E[1], N))
	# the feature on the cylinder (|xyz| = rho0, N = (-n_C, 0)): C + half x.E moved along N onto it
	var x: Vector3 = conf.x
	var Q: Vector4 = C + half * (x.x * E[0] + x.y * E[1] + x.z * E[2])
	var q := Vector3(Q.x, Q.y, Q.z)
	var nc := Vector3(C.x, C.y, C.z).normalized()
	var qa := q.dot(nc)
	var qp := q - qa * nc
	var rho0: float = sp.rho0
	var P := q - qa * nc + sqrt(maxf(rho0 * rho0 - qp.length_squared(), 0.0)) * nc
	# the eye: walked from the head as geo_eye does
	var eo := Vector3(-0.5 * U.IPD if conf.eye == 0 else 0.5 * U.IPD, 0.0, 0.0)
	var ge := _walk(sp, hp, head.basis * eo)
	var ne: Vector3 = ge[1]
	# the turn of the angular sphere taking P's direction onto the eye's (then off by near)
	var nP := P.normalized()
	var target := ne
	if conf.near > 0.0:
		var v: Vector3 = conf.nearv
		v = (v - v.dot(ne) * ne).normalized()
		target = (ne * cos(conf.near) + v * sin(conf.near)).normalized()
	var axis := nP.cross(target)
	var R := Basis.IDENTITY
	if axis.length() > 1e-12:
		R = Basis(axis.normalized(), atan2(axis.length(), nP.dot(target)))
	C = rot4(R, C)
	var cpos := PackedVector4Array([C])
	var axes := PackedVector4Array([rot4(R, E[0]), rot4(R, E[1])])
	var ccol := PackedVector4Array([Vector4(0.35, 0.8, 0.75, half)])
	var E3r := rot4(R, E[2])
	print("cube %d: C %s E1 %s E2 %s E3 %s half %s | eye %d l %s n %s | axis n %s | head l %s n %s" % [i, _v4(C), _v4(axes[0]), _v4(axes[1]), _v4(E3r), half, conf.eye, ge[0], _v3(ne), _v3(target), hp[0], _v3(hp[1])])
	conf["P_l"] = Q.w
	conf["eye_l"] = ge[0]
	conf["C_dist"] = (C - sp.embed(hp[0], hp[1])).length()
	main.renderer.set_objects(PackedVector4Array(), PackedVector4Array(), cpos, axes, ccol)


static func _v4(v: Vector4) -> String:
	return "(%.9f, %.9f, %.9f, %.9f)" % [v.x, v.y, v.z, v.w]


static func _v3(v: Vector3) -> String:
	return "(%.9f, %.9f, %.9f)" % [v.x, v.y, v.z]


static func _walk(sp: WormholeSpace, hp: Array, d: Vector3) -> Array:
	var f: Array = hp[2]
	var T: Vector4 = d.x * f[0] + d.y * f[1] + d.z * f[2]
	return sp.geodesic(hp[0], hp[1], T / T.length(), T.length(), f)
