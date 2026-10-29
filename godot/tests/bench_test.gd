extends SceneTree
## The speed check (bench.gd) on the desktop, with short timings: it goes through every place,
## with the other ray tracers in res://shaders/ab/ (tools/ab_shaders.sh) of the kind this build
## runs (Bench.comparable), logs a line
## per place, with this build's ray tracer also with the passes split and with each of FOVEATIONS,
## and gives back the shader, the foveation and where the viewer stood. The menu has its row.
##   godot --path . -s res://tests/bench_test.gd

const U := preload("res://tests/util.gd")

var main: Node3D
var frames := 0
var pose_before: Array
var shader_before: Shader
var started := false


func check(name: String, good: bool, got: Variant = "") -> void:
	U.check(name, good, str(got))


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	main.xr_name = "none"
	root.add_child(main)


func _process(_d: float) -> bool:
	frames += 1
	var b: Node = main.bench
	if frames == 3:
		var p: Node3D = main.menu
		var has_row := false
		for r: Dictionary in p.rows:
			has_row = has_row or r.key == "bench"
		check("the menu has the speed check's row", has_row)
		main.place(Vector3(9.0, 1.0, 0.0), Vector3(-1.0, 0.2, 0.0))
		pose_before = main.get_pose()
		shader_before = main.tracer.material.shader
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
			if main.tracer.material.shader != v[1]:
				check("the segment's shader", false, b.plan[b.step][1])
				started = false
			if main.tracer.toy_mode != v[4]:
				check("the segment's stencil split", false, b.plan[b.step][1])
				started = false
			if main.foveation.level != v[2] or main.foveation.split_pass.enabled != (v[2] > 0 or v[3]):
				check("the segment's foveation", false, "%d %s" % [main.foveation.level, main.foveation.split_pass.enabled])
				started = false
		if not b.running:
			check("finished", true, "%d frames" % frames)
			check("every place timed", b.results.size() == b.PLACES.size(), b.results.size())
			var all_timed := true
			for r in b.results:
				for v in r:
					all_timed = all_timed and v.size() == (2 if b.variants.size() > 1 else 1)
			check("every segment timed", all_timed, "%d ray tracers" % b.variants.size())
			# the others of this kind, this build each way of FOVEATIONS, and with toys one more: over
			# the whole view
			check("the others of this kind in it, this build each way", b.variants.size() == b.comparable().size()
					+ b.FOVEATIONS.size() + (1 if main.tracer.toy_count > 0 else 0))
			var p: Array = main.get_pose()
			check("back where it stood", absf(p[0] - pose_before[0]) < 1e-4 and p[1].is_equal_approx(pose_before[1])
					and p[2][2].is_equal_approx(pose_before[2][2]), "l %.3f" % p[0])
			check("this build's shader back", main.tracer.material.shader == shader_before and main.tracer.toy_mode == Tracer.SPLIT)
			check("the foveation back (off)", main.foveation.level == 0 and not main.foveation.split_pass.enabled)
			check("the menu shows the foveation's result", main.menu.bench_text.contains("фовеация"), main.menu.bench_text)
			U.finish(self)
			return true
	if Time.get_ticks_msec() > 600_000:
		check("finished in 10 minutes", false)
		U.finish(self)
		return true
	return false
