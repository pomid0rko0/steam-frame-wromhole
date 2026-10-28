extends SceneTree
# CPU time of main._process (all of the app's script work in a frame: input, walking, the toys'
# physics, the hands, the uploads, the stencil's proxies) with the demo's toys moving, at 120 fps:
# timed by two nodes processed right before and right after main.
var main: Node
var frame := 0
var stamps := {"t0": 0, "t1": 0}
var times := []

func _mk(prio: int, key: String) -> Node:
	var s := GDScript.new()
	s.source_code = "extends Node\nvar box: Dictionary\nvar key: String\nfunc _process(_d):\n\tbox[key] = Time.get_ticks_usec()\n"
	s.reload()
	var n := Node.new()
	n.set_script(s)
	n.box = stamps
	n.key = key
	n.process_priority = prio
	return n

func _initialize() -> void:
	root.add_child(_mk(-1000, "t0"))
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	root.add_child(_mk(1000, "t1"))

func _process(_dt: float) -> bool:
	frame += 1
	if frame > 3 and stamps.t1 > stamps.t0:
		times.append((stamps.t1 - stamps.t0) / 1000.0)
	if frame % 120 == 0 and times.size() >= 100:
		var a: Array = times.slice(-100)
		a.sort()
		var moving := 0
		for b in main.world.balls:
			if (b["U"] as Vector4).length() > 0.01:
				moving += 1
		var awake := 0
		for c in main.world.cubes:
			if c["still"] <= main.world.SLEEP_TIME:
				awake += 1
		print("t %4.1f s: balls %d (moving %d) cubes %d (awake %d) | main._process median %.2f ms, p90 %.2f, max %.2f"
			% [frame / 120.0, main.world.balls.size(), moving, main.world.cubes.size(), awake, a[50], a[90], a[99]])
	return frame >= 120 * 40
