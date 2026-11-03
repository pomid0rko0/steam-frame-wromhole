extends SceneTree
## Stereo correctness against Godot itself, through the real multiview path.
## A sphere in front of the viewer (flat universe A) is drawn by Godot's standard renderer (mode
## "mesh": a plain SphereMesh at the same play-space position), then by the app's renderer (mode
## "app": one of its balls), each eye's picture saved (util.gd's save_eyes). Godot's own rendering is
## correct stereo by definition, so in each eye the two silhouettes must coincide.
##   godot --path . -s res://tests/multiview_sphere.gd -- out_prefix

const U := preload("res://tests/util.gd")
const CHART := Vector3(8.0, -0.5, 1.4)      # sphere centre, chart A
const RADIUS := 0.3

var main: Main
var frames := 0
var ball: MeshInstance3D


func _initialize() -> void:
	var mvr := XRServer.find_interface("Native mobile")
	mvr.set("iod", 6.4)
	mvr.set("eye_height", 1.6)
	mvr.set("k1", 0.0)
	mvr.set("k2", 0.0)
	mvr.initialize()
	XRServer.primary_interface = mvr
	main = load("res://main.tscn").instantiate() as Main
	main.toys.enabled = false            # this test draws its own ball
	main.xr_name = "Native mobile"
	main.show_check = false             # its balls and grids would cover the test ball
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 2:
		main.menu.visible = false     # nothing but the ball under test
	if frames == 3:
		# the viewer stands at main.START_POS facing -x (START_FORWARD, main places it so): play x ->
		# chart +y, play +y -> chart +z, play +z -> chart +x. So chart (cx, cy, cz) is play
		# (cy, cz, cx - START_POS.x).
		ball = U.red(U.sphere(RADIUS))
		ball.position = Vector3(CHART.y, CHART.z, CHART.x - main.START_POS.x)
		main.origin.add_child(ball)
	if frames == 12:
		U.save_eyes(main, OS.get_cmdline_user_args()[0], "mesh")
		ball.visible = false
		var p := Vector4(CHART.x, CHART.y, CHART.z - main.space.lift, main.space.h)     # point of R^4 in sheet A
		main.renderer.set_objects(PackedVector4Array([p]), PackedVector4Array([Vector4(1.0, 0.0, 0.0, RADIUS)]))
	if frames == 14:
		U.save_eyes(main, OS.get_cmdline_user_args()[0], "app")
		print("saved mesh and app views at head ", main.camera.transform.origin)
		U.finish(self)
		return true
	return false
