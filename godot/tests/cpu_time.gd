extends SceneTree
## The CPU time of the app's scripts in a frame, through the headset's code path: from a node
## processed before main to one processed after main and the nodes under it (main._process: the
## walk, the head, the hands, the toys' physics, what goes to the shader; then the menu's, the frame
## rate's and the speed check's own). The simulated headset (tests/fake_hmd.gd)
## and both controllers moving, the right hand holding a new ball, the demo's toys at rest around.
## It prints the median, the 90th percentile and the largest of SECONDS of frames, and the median of
## each part of main._process (Main.PARTS), with the feet at
## the start (a flat universe) and on the fillet (l 5), each after about WARM frames there. A measurement,
## not a test (tools/test.sh does not run it): the times are this machine's.
##   godot --path . --fixed-fps 120 --resolution 320x180 -s res://tests/cpu_time.gd    (under xvfb-run)
## The headset's log has main._process alone (Main.scripts_ms) in its lines about late frames
## (frame_rate.gd).

const U := preload("res://tests/util.gd")
const SECONDS := 4.0
const RATE := 120.0             # frames a second (--fixed-fps)
const WARM := 40                # frames at a place before timing: the ball made, the pipelines compiled

var main: Main
var hmd
var left: XRControllerTracker
var right: XRControllerTracker
var frame := 0
var stamps := {"t0": 0, "t1": 0}
var times: Array[float] = []
var parts: Array = []           # per frame, Main.parts_ms
# [label, l to put the feet at (Main.place_on_axis)]; the first is where main puts them at the start
var places := [["start (flat)", null], ["fillet (l 5)", 5.0]]
var place := 0
var place_frame := 0


## A node that notes the time, processed before every node of priority 0 or after them all
## (process_priority): main and the nodes under it are of 0.
func _stamp(prio: int, key: String) -> Node:
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
	hmd = U.headset(0, 0.0, Vector2i(64, 64))
	left = U.controller(&"left_hand")
	right = U.controller(&"right_hand")
	root.add_child(_stamp(-1000, "t0"))
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "FakeHMD"
	main.toys.demo = false
	root.add_child(main)
	root.add_child(_stamp(1000, "t1"))


func _process(_delta: float) -> bool:
	frame += 1
	var t := frame / RATE
	left.set_pose(&"grip", Transform3D(Basis(Vector3.UP, 0.5 * sin(t)), Vector3(-0.25 + 0.1 * sin(2.0 * t), 1.1, -0.35)),
			Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	right.set_pose(&"grip", Transform3D(Basis(Vector3.RIGHT, 0.4 * sin(1.3 * t)), Vector3(0.25, 1.1 + 0.1 * sin(1.7 * t), -0.35)),
			Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	# the grip closed, then B: a new ball in the right hand
	right.set_input(&"grip", 1.0 if frame >= 10 else 0.0)
	right.set_input(&"by_button", frame >= 12 and frame < 14)
	if frame - place_frame > WARM and stamps.t1 > stamps.t0:
		times.append((stamps.t1 - stamps.t0) / 1000.0)
		parts.append(main.parts_ms.duplicate())
	if times.size() >= SECONDS * RATE:
		times.sort()
		var k := times.size()
		print("%s, a ball in the right hand %s: scripts median %.2f ms, 90%% %.2f ms, largest %.2f ms"
				% [places[place][0], main.hands.list[1].held != null, times[k / 2], times[k * 9 / 10], times[k - 1]])
		var each := []
		for i in Main.PARTS.size():
			var v: Array[float] = []
			for p: PackedFloat32Array in parts:
				v.append(p[i])
			v.sort()
			each.append("%s %.3f" % [Main.PARTS[i], v[v.size() / 2]])
		print("    main's parts, median ms: " + ", ".join(each))
		parts.clear()
		place += 1
		place_frame = frame
		times.clear()
		if place == places.size():
			U.finish(self, hmd, [left, right])
			return true
		main.place_on_axis(places[place][1])
	return false
