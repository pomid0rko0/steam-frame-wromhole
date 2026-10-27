extends SceneTree
## WormholeSpace.geodesic (only l, l' and phi stepped, in doubles; the rest exact) at random starts,
## directions and lengths through the cylinder, the fillets and the flat universes, with a frame
## carried: against itself in very fine steps, and against RK4 on the whole state (geodesic_rk4,
## the way it used to be done: its vectors are GDScript's single precision ones, and they drift by
## 1e-5 over a thousand steps); and how long each takes for the head's geodesic. Exit status 1 if
## it errs more than it may:
##   godot --headless --path . -s res://tests/geodesic_test.gd

const RUNS := 3000

var fails := 0


func _initialize() -> void:
	var sp := WormholeSpace.new(3.0, 5.0, 1.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var cases := []
	for k in RUNS:
		var l := rng.randf_range(-sp.L - 3.0, sp.L + 3.0)
		var n := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		var dir := WormholeSpace.tangent(n, Vector4(rng.randfn(), rng.randfn(), rng.randfn(), rng.randfn())).normalized()
		if k % 10 == 0:
			# across d/dl: round the throat on the cylinder, turning at once on a fillet
			dir = WormholeSpace.tangent(n, Vector4(0.0, rng.randfn(), rng.randfn(), rng.randfn())).normalized()
		if k % 10 == 1:
			dir = Vector4(signf(rng.randfn()), 0.0, 0.0, 0.0)    # along d/dl
		var f := []
		for i in 3:
			f.append(WormholeSpace.tangent(n, Vector4(rng.randfn(), rng.randfn(), rng.randfn(), rng.randfn())))
		cases.append([l, n, dir, rng.randf_range(0.01, 3.0), f])
	var runs := ["geodesic 0.02", "geodesic 0.10", "geodesic_rk4 0.02", "geodesic_rk4 0.10"]
	var worst := {}
	for key in runs:
		worst[key] = [0.0, 0.0]
	for c in cases:
		var ref: Array = sp.geodesic(c[0], c[1], c[2], c[3], c[4], 0.0005)
		for key: String in runs:
			var parts := key.split(" ")
			var g: Array = sp.call(parts[0], c[0], c[1], c[2], c[3], c[4], float(parts[1]))
			var dp := (sp.embed(g[0], g[1]) - sp.embed(ref[0], ref[1])).length()
			var dv := 0.0
			for i in 3:
				dv = maxf(dv, (g[2][i] - ref[2][i]).length() / maxf(ref[2][i].length(), 1e-9))
			worst[key][0] = maxf(worst[key][0], dp)
			worst[key][1] = maxf(worst[key][1], dv)
	for key in runs:
		print("%s m steps against the reference: places off by %s m at most, vectors by %s"
				% [key, String.num_scientific(worst[key][0]), String.num_scientific(worst[key][1])])
	_check("geodesic in steps of WormholeSpace.STEP", worst["geodesic 0.02"][0] < 1e-5 and worst["geodesic 0.02"][1] < 1e-5)
	_check("geodesic in steps of WormholeSpace.STEP_FRAME", worst["geodesic 0.10"][0] < 2e-4 and worst["geodesic 0.10"][1] < 1e-4)
	_check("geodesic_rk4 agrees", worst["geodesic_rk4 0.02"][0] < 2e-5 and worst["geodesic_rk4 0.02"][1] < 2e-5)
	# time: the head's geodesic at the shell's edge (1.6 m up from l = 5), as main does it per frame
	var n0 := Vector3(1.0, 0.0, 0.0)
	var up := Vector4(0.0, 0.0, 0.0, 1.0)
	var fr := [Vector4(0.0, 0.0, 1.0, 0.0), up, Vector4(1.0, 0.0, 0.0, 0.0)]
	for name in ["geodesic", "geodesic_rk4"]:
		var t0 := Time.get_ticks_usec()
		for k in 200:
			sp.call(name, 5.0, n0, up, 1.6, fr, WormholeSpace.STEP_FRAME)
		print("%s: the head's geodesic %.0f us" % [name, (Time.get_ticks_usec() - t0) / 200.0])
	print("FAILURES: ", fails)
	quit(1 if fails > 0 else 0)


func _check(name: String, ok: bool) -> void:
	print(("PASS " if ok else "FAIL ") + name)
	if not ok:
		fails += 1
