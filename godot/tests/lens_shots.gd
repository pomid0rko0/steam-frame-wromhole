extends SceneTree
## Pictures of the app on the desktop at fixed places, to look at (not a check): the lifted
## wormhole from the start, from under it, from beside it, from inside the throat and from B.
##   godot --path . --resolution 1280x720 -s res://tests/lens_shots.gd -- out_prefix [gravity|arrows|zone] [names...]
## zone: the toys away, bodies in the curved zone instead (ZONE_BODIES).
## Writes out_prefix_<place>.png.

# [name, the feet's chart A place (z: flying that high), looking toward (chart A), the head's pitch in degrees]
const PLACES := [["start", Vector3(10.0, 0.0, 0.0), Vector3(0.0, 0.0, 5.0), 0.0],
	["under", Vector3(1.5, 0.0, 0.0), Vector3(0.0, 0.0, 5.0), 0.0],
	["level", Vector3(9.0, 0.0, 3.4), Vector3(0.0, 0.0, 5.0), 0.0],
	["close", Vector3(5.3, 0.6, 3.4), Vector3(0.0, 0.0, 5.0), 0.0],
	["side", Vector3(3.0, 9.0, 0.0), Vector3(0.0, 0.0, 5.0), 0.0],
	["far", Vector3(22.0, 6.0, 0.0), Vector3(0.0, 0.0, 5.0), 0.0]]

# [kind, l, n (the throat's angular direction), radius or half size, colour]
const ZONE_BODIES := [["ball", 0.0, Vector3(1.0, 0.0, 0.0), 0.5, Color(0.9, 0.15, 0.1)],
	["ball", 0.5, Vector3(-1.0, 0.0, 0.1), 0.5, Color(0.95, 0.85, 0.2)],
	["cube", -3.0, Vector3(0.3, 1.0, 0.2), 0.35, Color(0.2, 0.8, 0.3)],
	["ball", 4.5, Vector3(0.2, -1.0, -0.3), 0.4, Color(0.3, 0.4, 0.95)]]

var main: Main
var frames := 0
var place := -1
var wait := 0
var names: Array = []


func _initialize() -> void:
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "none"
	main.show_check = false
	main.toys.demo = false              # no throw: the toys stay where they start
	root.add_child(main)
	var args := OS.get_cmdline_user_args()
	for a in args.slice(1):
		if a != "gravity" and a != "arrows" and a != "zone":
			names.append(a)
	if args.has("zone"):
		main.toys.enabled = false


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 2:
		main.menu.visible = false
		var args := OS.get_cmdline_user_args()
		if args.has("gravity"):
			main.set_gravity_view(1)
		if args.has("arrows"):
			main.set_gravity_view(2)
		main.camera.position = Vector3(0.0, 1.6, 0.0)
		main.camera.basis = Basis.IDENTITY
		main.hold = true
	if frames < 4:
		return false
	if OS.get_cmdline_user_args().has("zone"):
		_zone_bodies()
	if wait > 0:
		wait -= 1
		if wait == 0:
			var img := root.get_texture().get_image()
			img.convert(Image.FORMAT_RGB8)
			img.save_png("%s_%s.png" % [OS.get_cmdline_user_args()[0], PLACES[place][0]])
			print("saved ", PLACES[place][0])
		return false
	place += 1
	while place < PLACES.size() and not names.is_empty() and not names.has(PLACES[place][0]):
		place += 1
	if place >= PLACES.size():
		quit()
		return false
	var p: Array = PLACES[place]
	var at: Vector3 = p[1]
	var to: Vector3 = p[2]
	main.place(Vector3(at.x, at.y, 0.0), to - at)
	if at.z > 0.0:
		var v: Viewer = main.viewer
		v.take_off()
		v.move(at.z * (v.frame[1] as Vector4))
	# pitch the camera so the head looks at to
	var head := Vector3(at.x, at.y, at.z + 1.6)
	var d := (to - head).normalized()
	main.camera.basis = Basis.from_euler(Vector3(asin(d.z) + deg_to_rad(p[3]), 0.0, 0.0))
	wait = 3
	return false


func _zone_bodies() -> void:
	var sp := main.space
	var pos := PackedVector4Array()
	var col := PackedVector4Array()
	var cpos := PackedVector4Array()
	var axes := PackedVector4Array()
	var ccol := PackedVector4Array()
	for b: Array in ZONE_BODIES:
		var n: Vector3 = (b[2] as Vector3).normalized()
		var C := sp.embed(b[1], n)
		var c: Color = b[4]
		if b[0] == "ball":
			pos.append(C)
			col.append(Vector4(c.r, c.g, c.b, b[3]))
		else:
			var e: Array = main.renderer._tangent_pair(C)
			cpos.append(C)
			axes.append_array([e[0], (0.6 * e[0] + 0.8 * e[1]).normalized() if false else e[1]])
			ccol.append(Vector4(c.r, c.g, c.b, b[3]))
	main.renderer.set_objects(pos, col, cpos, axes, ccol)
