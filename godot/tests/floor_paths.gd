extends SceneTree
## A scene for tools/adreno_stats.sh --paths (not a test): the floor's shader (floor.gdshaderinc)
## with each of its ways through forced by replacing its branches' conditions, drawn one at a time,
## so that the compiler gives each way's statistics after a line "variant <name>". Each runs WAIT
## seconds, and the scene as it starts START seconds before the first: Godot specialises a pipeline
## on a thread of its own, after the first draw.
##   godot --path . --resolution 320x180 -s res://tests/floor_paths.gd

const START := 4.0
const WAIT := 1.5
# the branches' conditions in floor.gdshaderinc, as written there
const STRAIGHT := "if (le >= L && (ca >= 0.0 || b >= Rout)) {"
const STRAIGHT_FLOOR := "if (dc.z < 0.0) {"
const EYE_FLAT := "if (le >= L) {"
const EYE_FILLET := "} else if (le > Lc) {"
const HIT := "hit = phif < tot;"
const BEYOND := "if (target >= SL.x) {"
const CYLINDER := "} else if (pass && target <= cylL.x) {"

var main: Main
var t := 0.0
var vi := -1
var names: Array[String] = []
var shaders: Array[Shader] = []


func _initialize() -> void:
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "none"
	main.toys.enabled = false
	root.add_child(main)
	var curved := [[STRAIGHT, "if (false) {"]]
	var eye_flat := [[EYE_FLAT, "if (true) {"]]
	var eye_fillet := [[EYE_FLAT, "if (false) {"], [EYE_FILLET, "} else if (true) {"]]
	var eye_cyl := [[EYE_FLAT, "if (false) {"], [EYE_FILLET, "} else if (false) {"]]
	var sky := [[HIT, "hit = false;"]]
	var hit := [[HIT, "hit = true;"]]
	var beyond := [[BEYOND, "if (true) {"]]
	var cyl := [[BEYOND, "if (false) {"], [CYLINDER, "} else if (true) {"]]
	var fillet := [[BEYOND, "if (false) {"], [CYLINDER, "} else if (false) {"]]
	_variant("eye in a flat universe, the ray straight to the floor", [[STRAIGHT, "if (true) {"], [STRAIGHT_FLOOR, "if (true) {"]])
	_variant("eye in a flat universe, the ray straight to the sky", [[STRAIGHT, "if (true) {"], [STRAIGHT_FLOOR, "if (false) {"]])
	_variant("curved: the sky, the eye in a flat universe", curved + eye_flat + sky)
	_variant("curved: the sky, the eye on the fillet", curved + eye_fillet + sky)
	_variant("curved: the floor beyond the curved zone, the eye in a flat universe", curved + eye_flat + hit + beyond)
	_variant("curved: the floor on the throat's cylinder, the eye in a flat universe", curved + eye_flat + hit + cyl)
	_variant("curved: the floor on the fillet, the eye in a flat universe", curved + eye_flat + hit + fillet)
	_variant("curved: the floor on the fillet, the eye on the fillet", curved + eye_fillet + hit + fillet)
	_variant("curved: the floor on the fillet, the eye on the cylinder", curved + eye_cyl + hit + fillet)


func _variant(name: String, swaps: Array) -> void:
	var code := FileAccess.get_file_as_string("res://shaders/floor.gdshaderinc")
	for s: Array in swaps:
		assert(code.count(s[0]) == 1, "floor.gdshaderinc no longer has one '%s'" % s[0])
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
		main.place_on_axis(5.0, 0.0, -10.0)
	vi += 1
	if vi >= shaders.size():
		print("variant end")
		quit()
		return true
	print("variant ", names[vi])
	main.renderer.floor_mats[0].shader = shaders[vi]
	main.renderer.upload_space()        # a material keeps only its shader's uniforms
	return false
