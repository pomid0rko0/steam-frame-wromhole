extends SceneTree
## A scene for tools/adreno_stats.sh (what the headset's compiler makes of the shaders): drawn for a
## while, so that the compiler sees the shaders the scene uses.
##   godot --path . --resolution 320x180 -s res://tests/perf.gd -- scene
## start: the start with the demo's balls and cubes; near: in front of the curved zone, the wormhole
## filling most of the view, the demo's toys; cube: in the throat with a cube right in front of the
## eyes (the speed check's worst case); gravity: near with the gravity view's floor and arrows.

var main: Main
var frames := 0
var scene: String


func _initialize() -> void:
	scene = OS.get_cmdline_user_args()[0]
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "none"
	main.show_check = false
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 2:
		main.menu.visible = false        # the scene alone
		main.hold = true
		if scene == "near" or scene == "gravity":
			main.place(Vector3(6.5, 0.0, 0.0), main.START_FORWARD)
		elif scene == "cube":
			main.place_on_axis(0.0)
		if scene == "gravity":
			main.set_gravity_view(2)
	if frames == 4 and scene == "cube":
		main.bench._cube(Bench.CUBE_AT)
	if frames == 210:           # the specialised pipelines are compiled in the background by then
		return true
	return false
