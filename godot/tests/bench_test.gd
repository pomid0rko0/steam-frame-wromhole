extends SceneTree
## The speed check (bench.gd) on the desktop, with short timings: it goes through every place,
## with the other ray tracers if res://shaders/ab/ holds some (tools/ab_shaders.sh), logs a line
## per place, with this build's ray tracer also with the passes split and with each foveation level,
## and gives back the shader, the foveation and where the viewer stood. The panel has its button.
##   godot --path . -s res://tests/bench_test.gd

var main: Node3D
var frames := 0
var ok := true
var pose_before: Array
var shader_before: Shader
var started := false


func check(name: String, good: bool, got: Variant = "") -> void:
	ok = ok and good
	print("%-52s %-24s %s" % [name, str(got), "ok" if good else "WRONG"])


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	main.xr_name = "none"
	root.add_child(main)


func _process(_d: float) -> bool:
	frames += 1
	var b: Node = main.bench
	if frames == 3:
		var p: Label3D = main.perf
		var has_button := false
		for btn in p.buttons:
			has_button = has_button or btn.kind == "bench"
		check("the panel has the speed check's button", has_button)
		main.place(1.0, Vector3(9.0, 1.0, 0.0), Vector3(-1.0, 0.2, 0.0))
		pose_before = main.get_pose()
		shader_before = main.material.shader
		b.warm = 0.1
		b.time = 0.2
		b.start()
		started = true
		check("running", b.running)
		print("ray tracers: ", b.variants.map(func(v: Array) -> String: return v[0]))
		return false
	if started and frames > 3:
		if b.running and b.step >= 0:
			var place: Array = b.PLACES[b.plan[b.step][0]]
			if absf(main.foot_l - place[0]) > 0.3:
				check("at the place being timed", false, "%.2f vs %.2f" % [main.foot_l, place[0]])
				started = false
			var v: Array = b.variants[b.plan[b.step][1]]
			if main.material.shader != v[1]:
				check("the segment's shader", false, b.plan[b.step][1])
				started = false
			if main.toy_mode != v[4]:
				check("the segment's stencil split", false, b.plan[b.step][1])
				started = false
			if main.foveation != v[2] or main.split_pass.enabled != (v[2] > 0 or v[3]):
				check("the segment's foveation", false, "%d %s" % [main.foveation, main.split_pass.enabled])
				started = false
		if not b.running:
			check("finished", true, "%d frames" % frames)
			check("every place timed", b.results.size() == b.PLACES.size(), b.results.size())
			var all_timed := true
			for r in b.results:
				for v in r:
					all_timed = all_timed and v.size() == (2 if b.variants.size() > 1 else 1)
			check("every segment timed", all_timed, "%d ray tracers" % b.variants.size())
			# this build six ways, and with toys a seventh: over the whole view
			check("all the others in it, this build six (seven) ways", b.variants.size() == b.others.size()
					+ b.FOVEATIONS.size() + (1 if main.balls > 0 else 0))
			var p: Array = main.get_pose()
			check("back where it stood", absf(p[0] - pose_before[0]) < 1e-4 and p[1].is_equal_approx(pose_before[1])
					and p[2][2].is_equal_approx(pose_before[2][2]), "l %.3f" % p[0])
			check("this build's shader back", main.material.shader == shader_before and main.toy_mode == main.TOYS_SPLIT)
			check("the foveation back (off)", main.foveation == 0 and not main.split_pass.enabled)
			check("the panel shows the foveation's result", main.perf.bench_text.contains("фовеация"), main.perf.bench_text)
			print("PASS" if ok else "FAIL")
			quit(0 if ok else 1)
			return true
	if Time.get_ticks_msec() > 600_000:
		check("finished in 10 minutes", false)
		print("FAIL")
		quit(1)
		return true
	return false
