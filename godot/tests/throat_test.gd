extends SceneTree
## Bodies at the eye's own l (desktop), exit status 1 on any failure:
##   godot --path . --resolution 640x360 -s res://tests/throat_test.gd [-- shots_prefix]
## A pink cube stands in front of a white ball round the throat, the eye at their l looking at them;
## the eye steps 0.3 mm along l at a time across them, in the cylinder and at its end (where the
## fillet starts). The geodesic to a vertex at about the eye's l is launched nearly tangent: where
## its length came out short, the ball's vertices there came in front of the cube and the ball showed
## through it in a strip that changed with every step. The ball between the cube's pixels of a row
## (where the cube's top edge sags, it is seen there) may change by at most MOVE pixels over the
## steps. Only bodies are drawn (no floor or sky, black behind).
## With a prefix, saves each step's picture.

const U := preload("res://tests/util.gd")
const STEP := 0.0003             # m of l per step
const STEPS := 30                # from -4 mm to +4.7 mm round the bodies' l
const MOVE := 20                 # pixels
const CUBE := Color(0.95, 0.45, 0.55)
const BALL := Color(0.95, 0.95, 0.97)

var main: Main
var frames := 0
var shots := ""
var places: Array = []           # the bodies' l: in the cylinder, at its end
var pi_ := 0
var k := -1
var wait := 0
var seen: Array[int] = []        # the ball's pixels between the cube's, each step of this place


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	shots = a[0] if a.size() > 0 else ""
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "none"
	root.add_child(main)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 2:
		main.menu.visible = false
		main.camera.position = Vector3(0.0, 1.6, 0.0)
		main.camera.basis = Basis.IDENTITY
		main.hold = true                 # the toys stay put
		main.toys.demo = false
		main.renderer.floor_quad.visible = false
		main.renderer.show_scene(false)
		RenderingServer.set_default_clear_color(Color.BLACK)
		places = [0.0, main.space.Lc]
		_bodies(places[0])
	if frames < 4:
		return false
	if wait > 0:
		wait -= 1
		if wait == 0:
			_look()
		return false
	k += 1
	if k >= STEPS:
		var lo: int = seen.min()
		var hi: int = seen.max()
		U.check("throat, bodies at l %.3f: none shows through one in front, eye within 4 mm" % places[pi_], hi - lo <= MOVE,
				"the ball between the cube's pixels: %d to %d pixels (eye %+.1f mm off at the most)" % [lo, hi, _off_at(seen.find(hi)) * 1000.0])
		pi_ += 1
		if pi_ >= places.size():
			U.finish(self)
			return true
		_bodies(places[pi_])
		k = 0
		seen.clear()
	main.place_on_axis(places[pi_] + _off(), 90.0, -30.0)
	main.draw_toys()
	wait = 2
	return false


func _off() -> float:
	return _off_at(k)


func _off_at(step: int) -> float:
	return -0.004 + STEP * step


## The cube round the throat at l, the ball behind it (farther round), a little cube beside.
func _bodies(l: float) -> void:
	var w: BallWorld = main.toys.world
	w.balls.clear()
	w.cubes.clear()
	main.toys.cube_in_throat(l, 0.3, 0.25, CUBE)
	main.toys.cube_in_throat(l + 0.05, 0.55, 0.15, Color(0.35, 0.8, 0.75))
	var z := 0.3 / main.space.r(l)
	var phi := 0.42
	w.add(l - 0.02, Vector3(cos(phi) * sqrt(1.0 - z * z), sin(phi) * sqrt(1.0 - z * z), z), Vector4.ZERO, 0.3, BALL)


## The ball's pixels (white) between two of the cube's in a row.
func _look() -> void:
	var img := root.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	if shots != "":
		img.save_png("%s_%d_%02d.png" % [shots, pi_, k])
	var w := img.get_width()
	var d := img.get_data()
	var n := 0
	for y in img.get_height():
		var row := y * w * 3
		var first := -1
		var last := -1
		for x in w:
			var i := row + 3 * x
			if d[i] > d[i + 1] + 40:         # the cube: red over green, lit or on its dark edges
				if first < 0:
					first = x
				last = x
		for x in range(first + 1, last):
			var i := row + 3 * x
			var lo := mini(d[i], mini(d[i + 1], d[i + 2]))
			var hi := maxi(d[i], maxi(d[i + 1], d[i + 2]))
			if lo > 100 and hi - lo < 40:    # the ball: bright, grey
				n += 1
	seen.append(n)
