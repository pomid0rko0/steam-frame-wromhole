extends SceneTree
## A scene for tools/adreno_stats.sh (what the headset's compiler makes of its ray tracer): drawn
## for a while, so that the compiler sees the shaders the scene uses.
##   godot --path . --resolution 320x180 -s res://tests/perf.gd -- scene [shader]
## plain: the start, no movable objects; balls: the same with the stereo check's red balls;
## check: the stereo check scene (with its cube); near: in front of the curved zone, the wormhole
## filling most of the view (the costly rays); away: the same spot looking away from it. shader:
## another ray tracer's path (res://shaders/ab/1/wormhole.gdshader from tools/ab_shaders.sh), set before
## anything is drawn, so only it is compiled.

var main: Node3D
var frames := 0
var scene: String
var shader_path := ""


func _initialize() -> void:
	scene = OS.get_cmdline_user_args()[0]
	if OS.get_cmdline_user_args().size() > 1:
		shader_path = OS.get_cmdline_user_args()[1]
	main = load("res://main.tscn").instantiate()
	main.toys.enabled = false           # the scenes set their own
	main.xr_name = "none"
	main.show_check = scene == "check"
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 1 and shader_path != "":
		main.tracer.material.shader = load(shader_path)
	if frames == 2:
		main.menu.visible = false        # the scene alone
		if scene == "near":
			main.place(Vector3(6.5, 0.0, 0.0), main.START_FORWARD)
		elif scene == "away":
			main.place(Vector3(6.5, 0.0, 0.0), -main.START_FORWARD)
		elif scene == "balls":
			var pos := PackedVector4Array()
			var col := PackedVector4Array()
			for c in CheckScene.BALLS:
				pos.append(Vector4(c.x, c.y, c.z, main.space.h))
				var k := CheckScene.BALL_COLOR
				col.append(Vector4(k.r, k.g, k.b, CheckScene.BALL_RADIUS))
			main.tracer.set_objects(pos, col)
	if frames == 210:           # the specialised pipelines are compiled in the background by then
		return true
	return false
