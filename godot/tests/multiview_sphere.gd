extends SceneTree
## Stereo correctness against Godot itself, through the real multiview path.
## A sphere 2 m in front of the viewer (flat universe A) is drawn either by our ray tracer
## (mode "ray": a ball in the shader) or by Godot's rasterizer (mode "mesh": a plain
## SphereMesh at the same play-space position). Godot's own rendering is correct stereo
## by definition, so in each eye the two silhouettes must coincide.
##   godot --path . -s res://tests/multiview_sphere.gd -- out_prefix ray|mesh

const CHART := Vector3(8.0, -0.5, 1.4)      # sphere centre, chart A
const RADIUS := 0.3

var main: Node3D
var frames := 0
var mvr: XRInterface
var mode: String


func _initialize() -> void:
	mode = OS.get_cmdline_user_args()[1]
	mvr = XRServer.find_interface("Native mobile")
	mvr.set("iod", 6.4)
	mvr.set("eye_height", 1.6)
	mvr.set("k1", 0.0)
	mvr.set("k2", 0.0)
	mvr.initialize()
	XRServer.primary_interface = mvr
	main = load("res://main.tscn").instantiate()
	main.physics = false            # this test draws its own balls
	main.xr_name = "Native mobile"
	main.show_check = false   # its balls and grids would cover the test balls
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 2:
		main.perf.visible = false     # nothing but the balls under test

	if frames == 3:
		# the viewer stands at chart (10, 0) facing -x: play x -> chart +y, play +y -> chart +z,
		# play +z -> chart +x. So chart (cx, cy, cz) is play (cy, cz, cx - 10).
		if mode == "ray":
			var p := Vector4(CHART.x, CHART.y, CHART.z, main.space.h)     # point of R^4 in sheet A
			var pos := PackedVector4Array([p])
			var col := PackedVector4Array([Vector4(1.0, 0.0, 0.0, RADIUS)])
			main.set_balls(pos, col)
		else:
			var m := MeshInstance3D.new()
			var s := SphereMesh.new()
			s.radius = RADIUS
			s.height = 2.0 * RADIUS
			s.radial_segments = 256
			s.rings = 128
			m.mesh = s
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.albedo_color = Color(1.0, 0.0, 0.0)
			mat.no_depth_test = true
			mat.render_priority = 10
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA      # drawn after the opaque full-screen quad
			m.material_override = mat
			m.position = Vector3(CHART.y, CHART.z, CHART.x - 10.0)
			main.origin.add_child(m)
	if frames == 12:
		var rid: RID = main.xr_view.get_texture().get_rid()
		for i in 2:
			var img: Image = RenderingServer.texture_2d_layer_get(rid, i)
			img.convert(Image.FORMAT_RGB8)
			img.save_png(OS.get_cmdline_user_args()[0] + "_" + mode + ("_left.png" if i == 0 else "_right.png"))
		print("saved ", mode, " views at head ", main.camera.transform.origin)
		return true
	return false
