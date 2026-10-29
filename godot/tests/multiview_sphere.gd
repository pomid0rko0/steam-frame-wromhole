extends SceneTree
## Stereo correctness against Godot itself, through the real multiview path.
## A sphere in front of the viewer (flat universe A) is drawn either by our ray tracer
## (mode "ray": a ball in the shader) or by Godot's rasterizer (mode "mesh": a plain
## SphereMesh at the same play-space position). Godot's own rendering is correct stereo
## by definition, so in each eye the two silhouettes must coincide.
##   godot --path . -s res://tests/multiview_sphere.gd -- out_prefix ray|mesh

const U := preload("res://tests/util.gd")
const CHART := Vector3(8.0, -0.5, 1.4)      # sphere centre, chart A
const RADIUS := 0.3

var main: Node3D
var frames := 0
var mode: String


func _initialize() -> void:
	mode = OS.get_cmdline_user_args()[1]
	var mvr := XRServer.find_interface("Native mobile")
	mvr.set("iod", 6.4)
	mvr.set("eye_height", 1.6)
	mvr.set("k1", 0.0)
	mvr.set("k2", 0.0)
	mvr.initialize()
	XRServer.primary_interface = mvr
	main = load("res://main.tscn").instantiate()
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
		if mode == "ray":
			var p := Vector4(CHART.x, CHART.y, CHART.z, main.space.h)     # point of R^4 in sheet A
			main.tracer.set_objects(PackedVector4Array([p]), PackedVector4Array([Vector4(1.0, 0.0, 0.0, RADIUS)]))
		else:
			var m := U.red(U.sphere(RADIUS))
			m.position = Vector3(CHART.y, CHART.z, CHART.x - main.START_POS.x)
			main.origin.add_child(m)
	if frames == 12:
		U.save_eyes(main, OS.get_cmdline_user_args()[0], mode)
		print("saved ", mode, " views at head ", main.camera.transform.origin)
		return true
	return false
