extends SceneTree
## Scratch: both ray tracers at poses for looking at (not a test of the suite).
##   godot --path . --resolution 640x360 -s res://tests/look_check.gd -- out_prefix

const U := preload("res://tests/util.gd")
# [l, yaw, pitch, gravity view, foveation level]
const POSES := [[5.5703, 0.0, -10.0, 0, 0], [5.5711, 0.0, -10.0, 0, 0], [5.6, 0.0, -10.0, 0, 0],
	[0.0, 0.0, -10.0, 0, 0], [0.0005, 90.0, -10.0, 0, 0], [-0.0005, 90.0, -10.0, 0, 0],
	[-7.0, 180.0, -10.0, 0, 0], [5.0, 0.0, -60.0, 0, 0], [5.0, 0.0, 60.0, 0, 0],
	[8.0, 0.0, -15.0, 0, 5], [5.0, 30.0, -20.0, 1, 0], [5.0, 30.0, -20.0, 2, 0], [2.0, 120.0, -30.0, 2, 0]]

var main: Main
var hmd
var frames := 0
var i := 0
var prefix: String


func _initialize() -> void:
	prefix = OS.get_cmdline_user_args()[0]
	hmd = U.headset(0, -12.0, Vector2i(600, 660))
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "FakeHMD"
	main.toys.demo = false
	root.add_child(main)


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
	var k := (frames - 5) % 8
	if k == 0:
		if i >= POSES.size():
			U.finish(self, hmd)
			return true
		var p: Array = POSES[i]
		main.set_frag(false)
		main.set_gravity_view(p[3])
		main.foveation.set_level(p[4])
		main.place_on_axis(p[0], p[1], p[2])
		main.draw_toys()
	elif k == 3:
		U.save_eyes(main, "%s_%02d" % [prefix, i], "new")
		main.set_frag(true)
		main.foveation.set_level(0, false, true)
		main.draw_toys()
	elif k == 7:
		U.save_eyes(main, "%s_%02d" % [prefix, i], "main")
		i += 1
	return false
