extends SceneTree
## The speed check (bench.gd) on the desktop, with short timings: it goes through every place each
## way of VARIANTS (the viewer there: standing on the floor, or flying with the head on the axis; the
## cube before the eyes drawn in its own), logs a line per place, and gives back the foveation, the
## cube and where the viewer stood. The menu has its row. In a small window: nothing here looks at
## the picture, and what is timed is the speed check's own flow (a frame costs by its pixels).
##   godot --path . --resolution 160x90 -s res://tests/bench_test.gd

const U := preload("res://tests/util.gd")

var main: Main
var frames := 0
var pose_before: Array
var started := false


func check(name: String, good: bool, got: Variant = "") -> void:
	U.check(name, good, str(got))


## How far the viewer is from a place of Bench.PLACES (bench.gd's top): on the axis, the head from
## (l, +x); standing, the feet from the chart point, on the floor.
func _off_place(where: Variant) -> float:
	var sp: WormholeSpace = main.space
	var v := main.viewer
	if where is float and not is_inf(where):
		var hp := v.head(main.camera.transform.origin.y)
		return 1e9 if v.standing else (sp.embed(hp[0], hp[1]) - sp.embed(main.bench._axis_l(where), Vector3(1.0, 0.0, 0.0))).length()
	var at: Vector3 = Vector3(main.START_POS.x, main.START_POS.y, 1.0) if where is float else where
	var p := sp.point_from_chart(at.z, Vector3(at.x, at.y, 0.0))
	return 1e9 if not v.standing else (sp.embed(v.l, v.n) - sp.embed(p[0], p[1])).length()


## The cubes the renderer draws (out in a flat universe or in the curved zone).
func _cubes() -> int:
	return main.renderer.bodies.filter(func(x: Array) -> bool: return x[0] == "cube").size()


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
			var miss := _off_place(place[0])
			if miss > 1e-3:
				check("at the place being timed", false, "%s: %.4f m off" % [b._name(place[0]), miss])
				started = false
			var cyl: float = place[3] if place.size() > 3 else b.saved_length
			if not is_equal_approx(2.0 * main.space.Lc, cyl):
				check("the place's throat", false, "%.2f m, not %.2f" % [2.0 * main.space.Lc, cyl])
				started = false
			var v := b.variants[b.plan[b.step].y]
			if b.near != v.near or (b.near and _cubes() != main.toys.world.cubes.size() + 1):
				check("the segment's cube before the eyes", false, b.plan[b.step].y)
				started = false
			if b.throat != v.throat or (b.throat and main.renderer.zone_count.y < 1):
				check("the segment's ball and cube in the throat", false, b.plan[b.step].y)
				started = false
			if main.renderer.tail_shown != v.tail:
				check("the segment's tail", false, b.plan[b.step].y)
				started = false
			if main.foveation.level != v.foveation or main.foveation.enabled != (v.foveation > 0):
				check("the segment's foveation", false, "%d %s" % [main.foveation.level, main.foveation.enabled])
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
			check("no cube before the eyes after it", not b.near and _cubes() == main.toys.world.cubes.size())
			check("the throat's length back", is_equal_approx(2.0 * main.space.Lc, Main.LENGTH), "%.2f m" % (2.0 * main.space.Lc))
			check("the foveation back (off)", main.foveation.level == 0 and not main.foveation.enabled)
			check("the tail drawn again", main.renderer.tail_shown)
			check("the menu shows the foveation's result and the tail's", main.menu.bench_text.contains("фовеация")
					and main.menu.bench_text.contains("хвост"), main.menu.bench_text)
			U.finish(self)
			return true
	if Time.get_ticks_msec() > 600_000:
		check("finished in 10 minutes", false)
		U.finish(self)
		return true
	return false
