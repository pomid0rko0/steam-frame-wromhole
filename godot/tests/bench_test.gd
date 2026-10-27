extends SceneTree
## The speed check (bench.gd) on the desktop, with short timings: it goes through every scene of
## play_scenes.gd with the other ray tracers if res://shaders/ab/ holds some (tools/ab_shaders.sh),
## each scene's viewer and toys in place while it is timed, logs a line per scene, and gives back the
## shader, the foveation, where the viewer stood and the demo's toys as they were. The menu has its row.
##   godot --path . -s res://tests/bench_test.gd

var main: Node3D
var frames := 0
var ok := true
var pose_before: Array
var shader_before: Shader
var toys_before: Array
var started := false


func check(name: String, good: bool, got: Variant = "") -> void:
	ok = ok and good
	print("%-52s %-24s %s" % [name, str(got), "ok" if good else "WRONG"])


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	main.xr_name = "none"
	main.throw_toys = false
	root.add_child(main)


func _toys() -> Array:
	var out := []
	for b in main.world.balls:
		out.append(main.space.embed(b["l"], b["n"]))
	for c in main.world.cubes:
		out.append(main.space.embed(c["l"], c["n"]))
	return out


func _process(_d: float) -> bool:
	frames += 1
	var b: Node = main.bench
	if frames == 3:
		var p: Node3D = main.perf
		var has_row := false
		for r: Dictionary in p.rows:
			has_row = has_row or r.key == "bench"
		check("the menu has the speed check's row", has_row)
		main.place(1.0, Vector3(9.0, 1.0, 0.0), Vector3(-1.0, 0.2, 0.0))
		pose_before = main.get_pose()
		shader_before = main.material.shader
		toys_before = _toys()
		b.warm = 0.1
		b.time = 0.2
		b.start()
		started = true
		check("running", b.running)
		print("ray tracers: ", b.variants.map(func(v: Array) -> String: return v[0]))
		return false
	if started and frames > 3:
		if b.running and b.step >= 0 and b.phase == "segments":
			var sc: Array = PlayScenes.SCENES[b.plan[b.step][0]]
			if absf(main.foot_l - sc[2]) > 0.3:
				check("at the scene being timed", false, "%.2f vs %.2f" % [main.foot_l, sc[2]])
				started = false
			var v: Array = b.variants[b.plan[b.step][1]]
			if main.material.shader != v[1]:
				check("the segment's shader", false, b.plan[b.step][1])
				started = false
			if main.toy_mode != v[3]:
				check("the segment's stencil split", false, b.plan[b.step][1])
				started = false
			if main.foveation != v[2]:
				check("the segment's foveation", false, "%d" % main.foveation)
				started = false
			var n := 0
			for t in main.world.balls + main.world.cubes:
				n += 1 if t.has("scene") else 0
			var want: int = {"held_cubes": 4, "held_ball": 3}.get(sc[5], 0)
			if n != want:
				check("the scene's toys in place", false, "%s: %d" % [sc[0], n])
				started = false
		if not b.running:
			check("finished", true, "%d frames" % frames)
			check("every scene timed", b.results.size() == PlayScenes.SCENES.size(), b.results.size())
			var all_timed := true
			for r in b.results:
				for v in r:
					all_timed = all_timed and v.size() == (2 if b.variants.size() > 1 else 1)
			check("every segment timed", all_timed, "%d ray tracers" % b.variants.size())
			check("all the others in it, this build once (foveation off)", b.variants.size() == b.others.size() + 1)
			var p: Array = main.get_pose()
			check("back where it stood", absf(p[0] - pose_before[0]) < 1e-4 and p[1].is_equal_approx(pose_before[1])
					and p[2][2].is_equal_approx(pose_before[2][2]), "l %.3f" % p[0])
			var now := _toys()
			var same := now.size() == toys_before.size()
			for k in mini(now.size(), toys_before.size()):
				same = same and now[k].is_equal_approx(toys_before[k])
			check("the demo's toys back where they were", same, "%d of %d" % [now.size(), toys_before.size()])
			check("this build's shader back", main.material.shader == shader_before and main.toy_mode == main.TOYS_SPLIT)
			check("the foveation back (off)", main.foveation == 0 and not main.split_pass.enabled)
			check("the panel shows the dearest scenes", main.perf.bench_text.contains("дороже всего"), main.perf.bench_text)
			print("PASS" if ok else "FAIL")
			quit(0 if ok else 1)
			return true
	if Time.get_ticks_msec() > 600_000:
		check("finished in 10 minutes", false)
		print("FAIL")
		quit(1)
		return true
	return false
