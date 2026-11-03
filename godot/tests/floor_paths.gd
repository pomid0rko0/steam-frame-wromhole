extends SceneTree
## A scene for tools/adreno_stats.sh --paths (not a test): the floor's shader (floor.gdshaderinc,
## its ray's way out of the curved zone in geo.gdshaderinc's geo_exit and along the straight line
## after it in lens.gdshaderinc's lens_trace, pasted in for it) with each of its ways through forced
## by replacing its branches' conditions, drawn one at a time, so that the compiler gives each way's
## statistics after a line "variant <name>". Each runs WAIT seconds, and the scene as it starts START
## seconds before the first: Godot specialises a pipeline on a thread of its own, after the first
## draw. The lens list holds the scene's static objects and the demo's toys (the bodies' loop: a
## test of the ray's plane each, an intersection where it passes).
##   godot --path . --resolution 320x180 -s res://tests/floor_paths.gd

const U := preload("res://tests/util.gd")

const START := 4.0
const WAIT := 1.5
# the branches' conditions, as written there
const STRAIGHT := "if (!in_) return false;"
const EYE_FLAT := "if (le >= L) {"
const EYE_FILLET := "} else if (le > Lc) {"
const FLOOR := "if (dir.z < 0.0) {"
const BODY := "if (t < tmax) {"

var main: Main
var t := 0.0
var vi := -1
var names: Array[String] = []
var shaders: Array[Shader] = []


func _initialize() -> void:
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "none"
	main.toys.demo = false
	root.add_child(main)
	var lens := [[STRAIGHT, "if (false) return false;"]]
	var eye_flat := [[EYE_FLAT, "if (true) {"]]
	var eye_fillet := [[EYE_FLAT, "if (false) {"], [EYE_FILLET, "} else if (true) {"]]
	var eye_cyl := [[EYE_FLAT, "if (false) {"], [EYE_FILLET, "} else if (false) {"]]
	var floor_ := [[FLOOR, "if (true) {"], [BODY, "if (false) {"]]
	var sky := [[FLOOR, "if (false) {"], [BODY, "if (false) {"]]
	var body := [[BODY, "if (true) {"]]
	_variant("straight: the floor", [[STRAIGHT, "if (true) return false;"], [FLOOR, "if (true) {"]])
	_variant("straight: the sky", [[STRAIGHT, "if (true) return false;"], [FLOOR, "if (false) {"]])
	_variant("through the zone: the floor, the eye in a flat universe", lens + eye_flat + floor_)
	_variant("through the zone: the sky, the eye in a flat universe", lens + eye_flat + sky)
	_variant("through the zone: a body, the eye in a flat universe", lens + eye_flat + body)
	_variant("through the zone: the floor, the eye on the fillet", lens + eye_fillet + floor_)
	_variant("through the zone: the floor, the eye on the cylinder", lens + eye_cyl + floor_)


func _variant(name: String, swaps: Array) -> void:
	var code := FileAccess.get_file_as_string("res://shaders/floor.gdshaderinc")
	for f in ["geo", "lens"]:
		var inc := "#include \"res://shaders/%s.gdshaderinc\"" % f
		assert(code.count(inc) == 1, "floor.gdshaderinc no longer includes %s.gdshaderinc once" % f)
		code = code.replace(inc, FileAccess.get_file_as_string("res://shaders/%s.gdshaderinc" % f))
	for s: Array in swaps:
		assert(code.count(s[0]) == 1, "the floor's shader no longer has one '%s'" % s[0])
		code = code.replace(s[0], s[1])
	var sh := Shader.new()
	sh.code = "shader_type spatial;\n" + code
	names.append(name)
	shaders.append(sh)


func _process(delta: float) -> bool:
	t += delta
	if t < (START if vi == -1 else WAIT):
		return false
	t = 0.0
	if vi == -1:
		main.menu.visible = false
		main.place(Vector3(9.0, 0.0, 0.0), Vector3(-1.0, 0.0, 0.0))
	vi += 1
	if vi >= shaders.size():
		print("variant end")
		U.finish(self)
		return true
	print("variant ", names[vi])
	main.renderer.floor_mats[0].shader = shaders[vi]
	main.renderer.upload_space()        # a material keeps only its shader's uniforms
	return false
