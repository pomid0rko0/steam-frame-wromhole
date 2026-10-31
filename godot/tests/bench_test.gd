extends SceneTree
## The speed check (bench.gd) on the desktop, with short timings: it goes through every place each
## way of VARIANTS (the cube before the eyes drawn in its own), logs a line per place, and gives
## back the foveation, the cube and where the viewer stood. The menu has its row.
##   godot --path . -s res://tests/bench_test.gd

const U := preload("res://tests/util.gd")

var main: Main
var frames := 0
var pose_before: Array
var started := false


func check(name: String, good: bool, got: Variant = "") -> void:
	U.check(name, good, str(got))


func _initialize() -> void:
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "none"
	root.add_child(main)


func _process(_d: float) -> bool:
	frames += 1
	var b: Bench = main.bench
	if frames == 3:
		var has_row := false
		for r in main.menu.rows:
			has_row = has_row or r.key == "bench"
		check("the menu has the speed check's row", has_row)
		main.place(Vector3(9.0, 1.0, 0.0), Vector3(-1.0, 0.2, 0.0))
		pose_before = main.get_pose()
		b.warm = 0.1
		b.time = 0.2
		b.start()
		started = true
		check("running", b.running)
		print("variants: ", b.variants.map(func(v: Bench.Setup) -> String: return v.label))
		return false
	if started and frames > 3:
		if b.running and b.step >= 0:
			var place: Array = b.PLACES[b.plan[b.step].x]
			if absf(main.foot_l - b._l(place[0])) > 0.3:
				check("at the place being timed", false, "%.2f vs %.2f" % [main.foot_l, b._l(place[0])])
				started = false
			var v := b.variants[b.plan[b.step].y]
			if b.near != v.near or (b.near and main.renderer.cubes.multimesh.visible_instance_count != main.toys.world.cubes.size() + 1):
				check("the segment's cube before the eyes", false, b.plan[b.step].y)
				started = false
			if main.foveation.level != v.foveation or main.foveation.split_pass.enabled != ((v.foveation > 0 and v.foveation <= Foveation.LEVELS) or v.split):
				check("the segment's foveation", false, "%d %s" % [main.foveation.level, main.foveation.split_pass.enabled])
				started = false
		if not b.running:
			check("finished", true, "%d frames" % frames)
			var all_timed := true
			for r in b.results:
				for v in r:
					all_timed = all_timed and v.size() == (2 if b.variants.size() > 1 else 1)
			check("every segment timed", all_timed, "%d variants" % b.variants.size())
			check("each way of VARIANTS", b.variants.size() == b.VARIANTS.size())
			var p: Array = main.get_pose()
			check("back where it stood", absf(p[0] - pose_before[0]) < 1e-4 and p[1].is_equal_approx(pose_before[1])
					and p[2][2].is_equal_approx(pose_before[2][2]), "l %.3f" % p[0])
			check("no cube before the eyes after it", not b.near and main.renderer.cubes.multimesh.visible_instance_count == main.toys.world.cubes.size())
			check("the foveation back (off)", main.foveation.level == 0 and not main.foveation.split_pass.enabled)
			check("the menu shows the foveation's result", main.menu.bench_text.contains("фовеация"), main.menu.bench_text)
			U.finish(self)
			return true
	if Time.get_ticks_msec() > 600_000:
		check("finished in 10 minutes", false)
		U.finish(self)
		return true
	return false
