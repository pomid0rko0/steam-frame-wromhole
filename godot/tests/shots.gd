extends SceneTree
## Pictures of the app on the desktop at fixed poses, to look at (not a check): the start, the
## curved zone's edge, the throat, universe B, each also with the speed check's cube before the
## eyes (bench.gd, NEAR_CUBE), the toys held where the demo puts them.
##   godot --path . --resolution 1280x720 -s res://tests/shots.gd -- out_prefix [gravity|arrows]
## Writes out_prefix_<pose>.png.

# [name, l (INF: the start), degrees right, degrees up, the cube before the eyes]
const POSES := [["start", INF, 0.0, -8.0, false], ["edge", 6.2, 0.0, -10.0, false],
	["inside", 5.0, 20.0, -10.0, false], ["throat", 0.0, 0.0, -10.0, false],
	["throat_side", 0.0, 90.0, -5.0, false], ["b_edge", -5.7, 160.0, -5.0, false],
	["start_cube", INF, 0.0, -8.0, true], ["edge_cube", 5.0, 0.0, -10.0, true],
	["throat_cube", 0.0, 30.0, -10.0, true]]

var main: Main
var frames := 0
var pose := -1
var wait := 0


func _initialize() -> void:
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "none"
	main.show_check = false
	main.toys.demo = false              # no throw: the toys stay where they start
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 2:
		main.menu.visible = false
		var args := OS.get_cmdline_user_args()
		if args.has("gravity"):
			main.set_gravity_view(1)
		if args.has("arrows"):
			main.set_gravity_view(2)
		main.camera.position = Vector3(0.0, 1.6, 0.0)
		main.camera.basis = Basis.IDENTITY
		main.hold = true
	if frames < 4:
		return false
	if wait > 0:
		wait -= 1
		if wait == 0:
			var img := root.get_texture().get_image()
			img.convert(Image.FORMAT_RGB8)
			img.save_png("%s_%s.png" % [OS.get_cmdline_user_args()[0], POSES[pose][0]])
			print("saved ", POSES[pose][0])
		return false
	pose += 1
	if pose >= POSES.size():
		quit()
		return false
	var p: Array = POSES[pose]
	var l: float = main.space.point_from_chart(1.0, main.START_POS)[0] if is_inf(p[1]) else p[1]
	main.place_on_axis(l, p[2], p[3])
	main.bench.near = p[4]
	wait = 3
	return false
