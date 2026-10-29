extends SceneTree
## The split (tracer.gd, «The split») draws what the ray tracer with the toys draws over the whole
## view: at each pose the picture with the split and with Tracer.whole, pixel by pixel. The demo's
## toys at rest (as tests/emu_dump.gd leaves them: thrown, dropped, 12 s later), and at each pose
## both hands' balls and a ball held in front of the right one where tests/emu_dump.gd puts them
## (with +held), and a small ball just in front of the eye toward the view's corner. Poses: in front
## of the throat, at and inside the shell's edge, in the throat, in world B, also at the start.
## Desktop (run with --fixed-fps 60 under a display: xvfb-run), exit status 1 on any failure:
##   godot --path . --resolution 256x256 --fixed-fps 60 -s res://tests/split_test.gd
## Each pose also reports the share of pixels the world's ray tracer leaves to the one with the toys
## (drawn magenta by a ray tracer that draws only that: _share). The pictures would be the same with
## the two drawn the other way round: the order is checked from the materials.

const U := preload("res://tests/util.gd")
# [l, degrees right, degrees up] (Main.place_on_axis); START: the start's l
const POSES := [[INF, 0.0, -20.0], [6.2, 0.0, 0.0], [6.0, 20.0, -15.0], [5.7, 20.0, -15.0], [5.5, 160.0, 10.0],
		[5.0, 65.0, -10.0], [4.5, 75.0, -14.0], [2.3, 33.0, -1.0], [0.0, 90.0, 0.0], [-0.2, 137.0, -17.0],
		[-5.0, 180.0, 0.0], [-6.2, 180.0, 0.0]]
const DIFFER := 0.06            # a pixel differs: its channels' differences add up to more

var main: Main
var frames := 0
var i := 0
var pics := {}
var magenta := ShaderMaterial.new()
var saved: Shader               # the ray tracer with the toys, while the magenta one stands in


func _initialize() -> void:
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "none"
	main.toys.demo = false
	root.add_child(main)
	# a ray tracer that draws only where the world's leaves the pixel: magenta
	var sh := Shader.new()
	sh.code = "shader_type spatial;\nrender_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;\nstencil_mode read, compare_not_equal, 1;\nvoid vertex() { POSITION = vec4(VERTEX.xy, 1.0, 1.0); }\nvoid fragment() { ALBEDO = vec3(1.0, 0.0, 1.0); }\n"
	magenta.shader = sh


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 2:
		main.menu.visible = false
		U.check("the world's ray tracer draws first", main.tracer.world_material.render_priority
				< main.tracer.material.render_priority, "render priorities %d, %d" % [main.tracer.world_material.render_priority,
				main.tracer.material.render_priority])
		main.toys.throw()
		main.toys.drop()
		for k in 12 * 60:
			main.toys.world.step(1.0 / 60.0, [])
		main.hold = true
	# a pose takes 9 frames: set, the split (render, read back), the whole view, the share
	if frames < 4:
		return false
	var k := (frames - 4) % 9
	if k == 0:
		if i >= POSES.size():
			U.finish(self)
			return true
		var p: Array = POSES[i]
		var l: float = p[0] if p[0] != INF else main.space.point_from_chart(1.0, main.START_POS)[0]
		main.place_on_axis(l, p[1], p[2])
		_hold_ball()
		main.tracer.whole = false
	elif k == 2:
		pics["split"] = _picture()
		main.tracer.whole = true
	elif k == 5:
		pics["whole"] = _picture()
		main.tracer.whole = false
		_share(true)
	elif k == 8:
		var share := _magenta(_picture())
		_share(false)
		_compare(POSES[i], pics["split"], pics["whole"], share)
		i += 1
	return false


func _picture() -> Image:
	var img := root.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img


## The magenta ray tracer in place of the one with the toys, or the latter back.
func _share(on: bool) -> void:
	var m: ShaderMaterial = main.tracer.material
	if on:
		saved = m.shader
		m.shader = magenta.shader
	else:
		m.shader = saved


static func _magenta(img: Image) -> float:
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.r > 0.9 and c.g < 0.1 and c.b > 0.9:
				n += 1
	return float(n) / (img.get_width() * img.get_height())


func _compare(pose: Array, split: Image, whole: Image, share: float) -> void:
	var differ := 0
	var where := Vector2i(-1, -1)
	for y in split.get_height():
		for x in split.get_width():
			var a := split.get_pixel(x, y)
			var b := whole.get_pixel(x, y)
			if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > DIFFER:
				differ += 1
				where = Vector2i(x, y)
	U.check("pose %s: the split draws as the whole view" % [pose], differ == 0,
			"%d pixels differ%s; the ray tracer with the toys draws %.0f%%" % [differ,
			(" (one at %s)" % where) if differ > 0 else "", 100.0 * share])


## Both hands' balls and a ball held in the right one, as tests/emu_dump.gd puts them, and a ball
## of 2 cm 10 cm from the head toward the upper left corner of the view.
func _hold_ball() -> void:
	var sp: WormholeSpace = main.space
	var hp: Array = sp.geodesic(main.foot_l, main.foot_n, main.frame[1], main.DESKTOP_HEAD_HEIGHT, main.frame)
	var w := main.toys.world
	while w.balls.size() > 0 and w.balls.back().held != &"":
		w.balls.pop_back()
	while main.hands.list.size() < 2:
		main.hands.list.append(Hands.Hand.new())
	for k in 2:
		var off := Vector3(0.22 if k == 1 else -0.22, -0.35, -0.3)
		var d := WormholeSpace.combine(hp[2], off)
		var at: Array = sp.geodesic(hp[0], hp[1], d / d.length(), d.length(), hp[2])
		var h: Hands.Hand = main.hands.list[k]
		h.on = true
		h.ball.l = at[0]
		h.ball.n = at[1]
		h.F = at[2]
		if k == 1:
			var g: Array = sp.geodesic(at[0], at[1], -at[2][2], 0.3, at[2])
			w.add(g[0], g[1], Vector4.ZERO, 0.25, Color(0.95, 0.95, 0.97)).held = &"right_hand"
	# toward the upper left corner of the view: in the frame the shader gets (main._process)
	var hf := Main._tilt(hp[2], deg_to_rad(main.view_pitch), deg_to_rad(main.view_roll), main._head_forward_xz())
	var cam := main.camera.global_transform.basis
	var c := -cam.z + 0.8 * (-cam.x) + 0.8 * cam.y
	var dir := WormholeSpace.combine(hf, c.normalized())
	var near: Array = sp.geodesic(hp[0], hp[1], dir / dir.length(), 0.1, hf)
	w.add(near[0], near[1], Vector4.ZERO, 0.02, Color(0.9, 0.2, 0.2)).held = &"eye"
	main.draw_toys()
