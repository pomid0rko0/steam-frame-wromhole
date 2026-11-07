extends SceneTree
## What the tail (zone_tail.gdshader) costs, through the simulated headset at each pose of the speed
## check (bench.gd's PLACES) with its ball and cube in the throat (Bench.throat), without foveation as
## its variant has it. Per pose and eye: the pixels the tail's instances cover, each a fragment that
## runs its search (a body's side at a time, its strips and band, which never overlap: the shader's
## probe, tail_probe, tail_only), and of them
## those whose ray meets the body, against the eye's pixels. Exit status 1 if an eye's tail
## fragments at a pose exceed MAX_SHARE of its pixels. With "time" after "--", also the GPU's 3D
## pass (FrameRate's last part: the bodies, the tail and the floor's quad) with the tail and without
## it, by turns ROUND frames each (a drift of the machine falls on both), the median of FRAMES
## frames each: a software GPU's times are no headset's, their ratio is the measure (the speed
## check's variant without the tail times it in the headset).
##   godot --path . --resolution 640x360 -s res://tests/tail_cost_test.gd

const U := preload("res://tests/util.gd")
const SIZE := Vector2i(1000, 1100)      # each eye's pixels (fake_hmd.gd's)
const SETTLE := 3                       # frames after a change before a picture or a timing
const FRAMES := 40                      # frames timed each way ("time")
const ROUND := 5                        # frames timed one way before the other's
const MAX_SHARE := 0.25                 # an eye's pixels the tail's fragments may cover at a pose

var main: Main
var hmd
var bench: Bench
var frames := 0
var place := -1
var stage := ""
var wait := 0
var shots: Array[int] = []              # the instances to probe at this place
var shot := -1
var counts := []                        # per eye: [fragments, meeting the body]
var times := {}                         # true / false: the 3D pass's ms with / without the tail
var timed: Array = []
var lines: Array = []
var worst := 0.0
var timing := false                     # "time" asked
var in_round := 0                       # frames timed in this round


func _initialize() -> void:
	timing = OS.get_cmdline_user_args().has("time")
	hmd = U.headset(0, 0.0, SIZE)
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "FakeHMD"
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames < 4:
		return false
	if frames == 4:
		main.menu.visible = false
		main.foveation.set_level(0)
		bench = main.bench
		bench.saved_length = 2.0 * main.space.Lc
		main.hold = true
		_next_place()
		return false
	if wait > 0:
		wait -= 1
		return false
	match stage:
		"time":
			var rate: FrameRate = main.rate
			var on := main.renderer.tail_shown
			if rate.parts_frame != (timed[0] if not timed.is_empty() else -1) and rate.parts_last.size() == FrameRate.PARTS.size():
				timed.push_front(rate.parts_frame)
				times[on].append(rate.parts_last[FrameRate.PARTS.size() - 1])
				in_round += 1
			if times[true].size() >= FRAMES and times[false].size() >= FRAMES:
				main.renderer.tail_shown = true
				_probe()
			elif in_round >= ROUND:
				# the other way: frames drawn before the switch are not its
				main.renderer.tail_shown = not on
				in_round = 0
				timed.clear()
				wait = SETTLE
		"probe":
			var rid: RID = main.xr_view.get_texture().get_rid()
			for eye in 2:
				var img: Image = RenderingServer.texture_2d_layer_get(rid, eye)
				img.convert(Image.FORMAT_RGB8)
				var c := _count(img)
				counts[eye][0] += c.x + c.y
				counts[eye][1] += c.y
			_next_shot()
	return stage == "done" and _finish()


func _next_place() -> void:
	place += 1
	if place >= Bench.PLACES.size():
		stage = "done"
		return
	bench._put_place(Bench.PLACES[place])
	bench.throat = true
	counts = [[0, 0], [0, 0]]
	times = {true: [], false: []}
	timed.clear()
	in_round = 0
	wait = SETTLE
	if timing:
		stage = "time"
	else:
		stage = "probe"
		wait = 0
		_probe()


func _probe() -> void:
	main.renderer.tail_mat.set_shader_parameter("tail_probe", 1)
	stage = "probe"
	shot = -1
	_next_shot()


## The next side of a body in the zone to probe (2 slot + side: Renderer's slots, balls' from 0,
## cubes' from its MAX_BALLS), or the place's line once all are.
func _next_shot() -> void:
	if shot < 0:
		shots.clear()
		var zc: Vector2i = main.renderer.zone_count
		for s in zc.x:
			shots.append_array([2 * s, 2 * s + 1])
		for s in zc.y:
			shots.append_array([2 * (Renderer.MAX_BALLS + s), 2 * (Renderer.MAX_BALLS + s) + 1])
	shot += 1
	if shot < shots.size():
		main.renderer.tail_mat.set_shader_parameter("tail_only", shots[shot])
		wait = SETTLE
		return
	main.renderer.tail_mat.set_shader_parameter("tail_probe", 0)
	main.renderer.tail_mat.set_shader_parameter("tail_only", -1)
	var px := float(SIZE.x * SIZE.y)
	var eyes := []
	for eye in 2:
		var share: float = counts[eye][0] / px
		worst = maxf(worst, share)
		eyes.append("%s %d fragments (%.1f%% of its pixels), %d meet the body" % [["left", "right"][eye], counts[eye][0], 100.0 * share, counts[eye][1]])
	var p: Array = Bench.PLACES[place]
	var line := "%s, %.0f deg right, %.0f deg up, cylinder %.0f m, %d balls %d cubes in the zone: %s" % [
			bench._name(p[0]), p[1], p[2], 2.0 * main.space.Lc, main.renderer.zone_count.x, main.renderer.zone_count.y,
			", ".join(eyes)]
	if timing:
		var on := _median(times[true])
		var off := _median(times[false])
		line += "; the 3D pass %.2f ms with the tail, %.2f without (%+.1f%%)" % [on, off, 100.0 * (on / off - 1.0) if off > 0.0 else 0.0]
	print(line)
	lines.append(line)
	_next_place()


## Probe pixels: (red: its ray meets no body, green: it does).
static func _count(img: Image) -> Vector2i:
	var red := 0
	var green := 0
	var data := img.get_data()
	for i in range(0, data.size(), 3):
		if data[i] == 255 and data[i + 1] == 0 and data[i + 2] == 0:
			red += 1
		elif data[i] == 0 and data[i + 1] == 255 and data[i + 2] == 0:
			green += 1
	return Vector2i(red, green)


static func _median(xs: Array) -> float:
	if xs.is_empty():
		return 0.0
	var s := xs.duplicate()
	s.sort()
	return s[s.size() / 2]


func _finish() -> bool:
	bench._restore()
	U.check("at every pose the tail's fragments cover at most %.0f%% of an eye's pixels" % (100.0 * MAX_SHARE),
			worst <= MAX_SHARE, "%.1f%% at most" % (100.0 * worst))
	U.finish(self, hmd)
	return true
