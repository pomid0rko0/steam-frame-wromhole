extends SceneTree
## Same check as multiview_sphere.gd without multiview: ordinary camera at the head.
## Our ray-traced ball vs Godot's rasterized sphere at the same play-space position.
##   godot --path . --resolution 960x1080 -s res://tests/desktop_sphere.gd -- out_prefix ray|mesh

const CHART := Vector3(8.0, -0.5, 1.4)
const RADIUS := 0.3

var main: Node3D
var frames := 0
var mode: String


func _initialize() -> void:
	mode = OS.get_cmdline_user_args()[1]
	main = load("res://main.tscn").instantiate()
	main.xr_name = "none"
	main.show_check = false   # its balls and grids would cover the test balls
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1

	if frames == 2:
		main.camera.position = Vector3(0.0, 1.6, 0.0)
		main.camera.basis = Basis.IDENTITY
		main.place(1.0, Vector3(10.0, 0.0, 0.0), Vector3(-1.0, 0.0, 0.0))
	if frames == 3:
		if mode == "ray":
			var pos := PackedVector4Array([Vector4(CHART.x, CHART.y, CHART.z, main.space.h)])
			var col := PackedVector4Array([Vector4(1.0, 0.0, 0.0, RADIUS)])
			for i in 11:
				pos.append(Vector4.ZERO)
				col.append(Vector4.ZERO)
			main.material.set_shader_parameter("wh_ball", pos)
			main.material.set_shader_parameter("wh_ballCol", col)
			main.material.set_shader_parameter("wh_nBall", 1)
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
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.material_override = mat
			m.position = Vector3(CHART.y, CHART.z, CHART.x - 10.0)
			main.origin.add_child(m)
	if frames == 10:
		var img := root.get_texture().get_image()
		img.convert(Image.FORMAT_RGB8)
		img.save_png(OS.get_cmdline_user_args()[0] + "_" + mode + ".png")
		return true
	return false
