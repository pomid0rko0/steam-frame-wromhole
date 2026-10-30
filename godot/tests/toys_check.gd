extends SceneTree
## This build's ray tracer (compute kernels, the toys' search along the per-eye path tables)
## against main's fragment ray tracer (frag_tracer.gd, the analytic search) in the simulated
## headset: the demo's toys at rest (balls and cubes before the throat, a cube in it), both hands
## and a ball of 25 cm held 0.3 m in front of the right one, at the speed check's places (Bench.PLACES)
## and at the places of the toys kernel's worst cases (research in PR #20: a ball near the eyes at
## the edge, one in the throat looking sideways). Each place is drawn by both and saved:
## <prefix>_<place>_<new|main>_<left|right>.png; tools/compare/same_toys.py compares them.
##   godot --path . --resolution 640x360 -s res://tests/toys_check.gd -- out_prefix

const U := preload("res://tests/util.gd")
const EXTRA := [[5.5, 0.0, -20.0], [4.6, 10.0, -25.0], [0.0, 90.0, -10.0]]

var main: Main
var hmd
var frames := 0
var places: Array = []
var i := 0
var prefix: String


func _initialize() -> void:
	prefix = OS.get_cmdline_user_args()[0]
	hmd = U.headset(0, -12.0, Vector2i(480, 528))
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "FakeHMD"
	main.toys.demo = false
	root.add_child(main)
	places = Bench.PLACES.duplicate(true) + EXTRA


func _process(_d: float) -> bool:
	frames += 1
	if frames == 3:
		main.menu.visible = false
		main.toys.throw()
		main.toys.drop()
		for k in 12 * 60:
			main.toys.world.step(1.0 / 60.0, [])
		main.hold = true
	if frames < 5:
		return false
	# a place takes 8 frames: this build's ray tracer set, drawn, read back; main's the same
	var k := (frames - 5) % 8
	if k == 0:
		if i >= places.size():
			print("toys_check: %d places" % places.size())
			U.finish(self, hmd)
			return true
		var p: Array = places[i]
		var l: float = main.space.point_from_chart(1.0, main.START_POS)[0] if is_inf(p[0]) else p[0]
		main.set_frag(false)
		main.place_on_axis(l, p[1], p[2])
		_hold_ball()
		main.draw_toys()
	elif k == 3:
		U.save_eyes(main, "%s_%02d" % [prefix, i], "new")
		main.set_frag(true)
		main.draw_toys()
	elif k == 7:
		U.save_eyes(main, "%s_%02d" % [prefix, i], "main")
		i += 1
	return false


## Both hands where tests/emu_dump.gd puts them, and a ball held 0.3 m in front of the right one.
func _hold_ball() -> void:
	var sp: WormholeSpace = main.space
	var hp: Array = sp.geodesic(main.foot_l, main.foot_n, main.frame[1], U.HEAD_0.y, main.frame)
	if main.toys.world.balls.size() > 0 and main.toys.world.balls.back().held == &"right_hand":
		main.toys.world.balls.pop_back()
	while main.hands.list.size() < 2:
		main.hands.list.append(Hands.Hand.new())
	for k in 2:
		var off := Vector3(0.22 if k == 1 else -0.22, -0.35, -0.3)
		var dir := WormholeSpace.combine(hp[2], off)
		var at: Array = sp.geodesic(hp[0], hp[1], dir / dir.length(), dir.length(), hp[2])
		var h: Hands.Hand = main.hands.list[k]
		h.on = true
		h.ready = k == 1
		h.ball.l = at[0]
		h.ball.n = at[1]
		h.F = at[2]
		if k == 1:
			var fwd := WormholeSpace.combine(at[2], Vector3(0.0, 0.0, -0.3))
			var bp: Array = sp.geodesic(at[0], at[1], fwd / fwd.length(), 0.3, at[2])
			var b := main.toys.world.add(bp[0], bp[1], Vector4.ZERO, 0.25, Color(0.9, 0.3, 0.2))
			b.held = &"right_hand"
