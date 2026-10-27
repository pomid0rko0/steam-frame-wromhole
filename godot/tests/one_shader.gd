extends SceneTree
## One spatial shader on a quad over the whole view, nothing else of the app: what
## tools/adreno_stats.sh --alone compiles (the stencil's marks, which the app draws only with toys
## and only where the head is). 20 frames, then it quits.
##   godot --path . -s res://tests/one_shader.gd -- res://shaders/stencil_toys.gdshader
var frames := 0
func _initialize() -> void:
	var cam := Camera3D.new()
	root.add_child(cam)
	var q := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(2, 2)
	q.mesh = qm
	q.position = Vector3(0, 0, -1)
	q.extra_cull_margin = 16384.0
	var m := ShaderMaterial.new()
	m.shader = load(OS.get_cmdline_user_args()[0])
	m.set_shader_parameter("wh_rho0", 3.0)
	m.set_shader_parameter("wh_h", 5.0)
	m.set_shader_parameter("wh_fillet", 1.0)
	q.material_override = m
	cam.add_child(q)
func _process(_d: float) -> bool:
	frames += 1
	return frames > 20
