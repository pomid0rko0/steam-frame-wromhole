extends SceneTree
## The frame's render time at poses on the desktop, to compare two builds at the same poses: a
## relative measure of the work a frame does, and no more (the headset's speed check, bench.gd,
## decides). Software Vulkan (lavapipe) shades vertices on one core and pixels on all, so there the
## bodies' vertices read several times dearer against the pixels than on a GPU. Prints "ft <label>
## <ms> <triangles>" per pose: the median frame of FRAMES. BARE=1: no bodies, the floor and the sky
## alone.
##   godot --path . --resolution 1280x720 -s res://tests/frame_time.gd

const FRAMES := 12
# [label, l, degrees right, degrees up, a cube that many m in front (0: none)]
const POSES := [["start", 11.57, 0.0, 0.0, 0.0], ["edge", 5.0, 0.0, 0.0, 0.0], ["edge_down", 5.0, 0.0, -35.0, 0.0],
	["throat", 0.0, 0.0, 0.0, 0.0], ["throat_side", 0.0, 90.0, 0.0, 0.0], ["b_edge", -5.7, 160.0, -5.0, 0.0],
	["start_cube", 11.57, 0.0, 0.0, 0.25], ["edge_cube", 5.0, 0.0, 0.0, 0.25], ["edge_down_cube", 5.0, 0.0, -35.0, 0.25],
	["throat_cube", 0.0, 0.0, 0.0, 0.25], ["boundary_cube", 5.6, 0.0, -10.0, 0.2]]

var main: Main
var frames := 0
var pose := -1
var times: Array = []
var cube: BallWorld.Cube


var bare := OS.get_environment("BARE") != ""     # no bodies: the floor and the sky alone (new build)


func _initialize() -> void:
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "none"
	if bare:
		main.toys.enabled = false
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 2:
		main.menu.visible = false
		main.hold = true
		main.camera.position = Vector3(0.0, 1.6, 0.0)
		RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
		if bare:
			main.renderer.show_statics(false)
			main.renderer.set_objects(PackedVector4Array(), PackedVector4Array())
		_next()
		return false
	if pose < 0:
		return false
	var t := RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
	if frames > 6:
		times.append(t)
	if times.size() >= FRAMES:
		times.sort()
		print("ft %s %.2f %d" % [POSES[pose][0], times[times.size() / 2],
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)])
		if pose + 1 >= POSES.size():
			return true
		_next()
	return false


func _next() -> void:
	pose += 1
	frames = 2
	times.clear()
	var p: Array = POSES[pose]
	main.place_on_axis(p[1], p[2], p[3])
	if cube:
		main.toys.world.cubes.erase(cube)
		cube = null
	if p[4] > 0.0 and not bare:
		var sp: WormholeSpace = main.space
		var hp := sp.geodesic(main.foot_l, main.foot_n, main.frame[1], 1.6, main.frame)
		var hf: Array = hp[2]
		var at := sp.geodesic(hp[0], hp[1], -hf[2], p[4] + 0.25, hf)
		var F: Array = at[2]
		cube = main.toys.world.add_cube(at[0], at[1], Vector4.ZERO, [F[0], F[1], F[2]], Vector3.ZERO, 0.25, Color(0.95, 0.45, 0.55))
