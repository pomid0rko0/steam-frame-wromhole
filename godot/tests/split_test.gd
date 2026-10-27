extends SceneTree
## The stencil's split (main._update_proxies) against the ray tracer with all the toys over the
## whole view (main.TOYS_WHOLE): the same picture at every pose, with the demo's toys, toys on the
## shell's edge on either side and on its fillets, and every other pose both hands with a ball held
## in the right one; then the speed check's scenes of play (play_scenes.gd). The ray tracers are made to colour each pixel only by what its ray ends on
## (WH_KIND_COLOUR: sky, floor, a static object, which ball or cube), so the pictures must match bit
## for bit where either shows a toy: a pixel where the split gave a ray tracer that could not see a
## toy its ray meets shows. Elsewhere the ray tracers, compiled apart, can round a ray that grazes a
## static object's edge either way: a pixel in 100 000 may differ there.
##   godot --path . --rendering-method mobile --resolution 192x192 -s res://tests/split_test.gd [-- quick] [random N]
## (under xvfb-run; quick: a quarter of the poses; random N: N poses of random places, with the
## toys moved to random places of the shell and its edges around the viewer each time, a seed each)

var main: Node3D
var frames := 0
var poses: Array = []
var i := 0
var phase := 0
var split_img: Image
var bad := 0                 # pixels that differ where either picture shows a toy
var other := 0               # pixels that differ elsewhere (a static object's edge)
var worst := ""
var checked := 0
var toys_pixels := 0
var pixels := 0


var rng := RandomNumberGenerator.new()


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var quick := args.has("quick")
	if args.has("random"):
		rng.seed = 12345
		for k in int(args[args.find("random") + 1]):
			var l := rng.randf_range(-7.0, 7.0)
			poses.append([l, rng.randf_range(-180.0, 180.0), rng.randf_range(-50.0, 40.0), "random"])
	for l in ([] if args.has("random") else [11.0, 7.0, 6.2, 5.8, 5.6, 5.5, 5.2, 4.8, 4.2, 3.0, 1.5, 0.0, -1.5, -3.0, -4.2, -5.0, -5.5, -5.8, -6.5, -8.0]):
		for y in [0.0, 40.0, 90.0, 140.0, 180.0, -60.0, -120.0]:
			for p in [-35.0, 0.0, 25.0]:
				poses.append([l, y, p])
	if quick:
		var q := []
		for k in range(0, poses.size(), 4):
			q.append(poses[k])
		poses = q
	# then the speed check's scenes of play (play_scenes.gd: cubes at the shell's edge, in the hands,
	# a ball in the hand), each also turned and tilted a little
	for sc in PlayScenes.SCENES:
		if sc[5] == "none":
			continue
		if args.has("random"):
			break
		for d in ([[0.0, 0.0], [-8.0, 0.0], [8.0, 6.0], [3.0, -10.0]] if not quick else [[0.0, 0.0]]):
			poses.append([sc[2], sc[3] + d[0], sc[4] + d[1], sc[5]])
	main = load("res://main.tscn").instantiate()
	main.xr_name = "none"
	main.physics = true
	main.throw_toys = false
	root.add_child(main)


func _process(_d: float) -> bool:
	frames += 1
	if frames == 2:
		main._throw()
		main._drop()
		for k in 12 * 60:
			main.world.step(1.0 / 60.0, [])
		_edge_toys()
		main.hold = true
		main.perf.visible = false
		main.camera.fov = 100.0
		if main.overlay:
			main.overlay.visible = false
		main._upload_toys()
		for m in [[main.material, main.SHADER_BALLS, 2], [main.near_material, main.SHADER_BALLS_NEAR, 3],
				[main.flat_material, main.SHADER_BALLS_FLAT, 1], [main.plain_material, main.SHADER_PLAIN, 0]]:
			m[0].shader = _kinds(m[1], m[2])
	if frames < 4 or main.warm_frames > 0:
		return false
	# per pose: set it (split), render, read; the whole view, render, read
	match phase:
		0:
			if i >= poses.size():
				var ok := bad == 0 and other <= pixels / 100000 and checked == poses.size()
				print("split test: %d poses, %d pixels that meet a toy: %d differ there, %d of %d elsewhere%s"
						% [checked, toys_pixels, bad, other, pixels, worst])
				print("split test: ", "ok" if ok else "FAILED")
				quit(0 if ok else 1)
				return true
			var p: Array = poses[i]
			main.set_toy_mode(main.TOYS_SPLIT)
			if p.size() > 3 and p[3] == "random":
				main.place_on_axis(p[0], p[1], p[2])
				_random_toys()
			elif p.size() > 3:
				for st in main.hand_state:
					st["on"] = false
				PlayScenes.place(main, p[3], p[0], p[1], p[2])
			else:
				main.place_on_axis(p[0], p[1], p[2])
			if p.size() > 3:
				pass
			elif i % 2 == 1:
				_hold_ball()
			else:
				for st in main.hand_state:
					st["on"] = false
				if main.world.balls.size() > 0 and main.world.balls.back().get("held", &"") == &"right_hand":
					main.world.balls.pop_back()
				main._upload_toys()
		2:
			split_img = root.get_texture().get_image()
			main.set_toy_mode(main.TOYS_WHOLE)
		4:
			var whole := root.get_texture().get_image()
			_compare(split_img, whole, poses[i])
			i += 1
	phase = (phase + 1) % 5
	return false


## A ray tracer that colours a pixel by what its ray ends on, and green by which ray tracer it is,
## the stencil's value (wormhole_core.gdshaderinc, WH_KIND_COLOUR).
static func _kinds(sh: Shader, stencil: int) -> Shader:
	var s := Shader.new()
	s.code = sh.code.replace("shader_type spatial;", "shader_type spatial;\n#define WH_KIND_COLOUR %.3f" % (0.1 + 0.2 * stencil))
	return s


func _compare(a: Image, b: Image, pose: Array) -> void:
	checked += 1
	for y in a.get_height():
		for x in a.get_width():
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			pixels += 1
			# a toy's kind is 100 or more (sRGB above 0.6); the others' at most 5 (below 0.2)
			var toy := cb.r > 0.4 or ca.r > 0.4
			if cb.r > 0.4:
				toys_pixels += 1
			if not is_equal_approx(ca.r, cb.r) or not is_equal_approx(ca.b, cb.b):
				if toy:
					bad += 1
					if bad == 1:
						worst = "; the first where a toy is: pose %s pixel (%d, %d), split %s, whole %s" % [pose, x, y,
								_kind(ca), _kind(cb)]
				else:
					other += 1


## What a pixel shows (wormhole_core.gdshaderinc's dbg.x: 100 + a ball's index, 200 + a cube's) and
## which ray tracer drew it (the stencil's value).
static func _kind(c: Color) -> String:
	var lin := c.srgb_to_linear()
	return "kind %d by ray tracer %d" % [roundi(lin.r * 255.0), roundi((lin.g - 0.1) / 0.2)]


## Toys where the split's tests are tight: on the floor at the shell's edge on both sides (one
## straddling it), on the fillets and up in the throat.
func _edge_toys() -> void:
	var sp: WormholeSpace = main.space
	var w = main.world
	var at := func(l: float, phi: float, height: float) -> Array:
		var z := height / sp.r(l)
		return [l, Vector3(cos(phi) * sqrt(1.0 - z * z), sin(phi) * sqrt(1.0 - z * z), z)]
	# move the first two lying balls, keep the rest
	var p0: Array = at.call(5.45, 0.25, 0.3)
	w.balls[0]["l"] = p0[0]; w.balls[0]["n"] = p0[1]; w.balls[0]["radius"] = 0.3
	var p1: Array = at.call(-5.65, -0.3, 0.25)
	w.balls[1]["l"] = p1[0]; w.balls[1]["n"] = p1[1]
	var p2: Array = at.call(2.0, 0.5, 2.2)
	w.balls[2]["l"] = p2[0]; w.balls[2]["n"] = p2[1]
	for b in w.balls:
		b["U"] = Vector4.ZERO
	main._cube_in_throat(4.6, 0.6, 0.25, Color(0.9, 0.5, 0.2))
	main._cube_in_throat(-5.4, -0.7, 0.3, Color(0.3, 0.6, 0.9))


## The demo's balls and cubes moved to random places: around the viewer (some within reach of the
## eyes, some up in the air), on the shell's fillets and edges on either side and in the throat;
## the hands at random places in front of the head, every other pose a ball held.
func _random_toys() -> void:
	var sp: WormholeSpace = main.space
	var w = main.world
	var head: Vector3 = main.camera.transform.origin
	var hp: Array = sp.geodesic(main.foot_l, main.foot_n, main.frame[1], maxf(head.y, 0.05), main.frame)
	var place := func() -> Array:
		if rng.randf() < 0.5:
			# around the head, 0.3 to 3 m off
			var off := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.2, 0.6), rng.randf_range(-1.0, 0.3))
			off = off.normalized() * rng.randf_range(0.3, 3.0)
			var dir := WormholeSpace.combine(hp[2], off)
			var at: Array = sp.geodesic(hp[0], hp[1], dir / dir.length(), dir.length(), hp[2])
			return [at[0], at[1]]
		# anywhere in the shell or just outside it, on the floor or above it
		var l := rng.randf_range(-sp.L - 0.6, sp.L + 0.6)
		var phi := rng.randf_range(-PI, PI)
		var z := clampf(rng.randf_range(0.0, 2.0) / sp.r(l), 0.0, 0.9)
		return [l, Vector3(cos(phi) * sqrt(1.0 - z * z), sin(phi) * sqrt(1.0 - z * z), z)]
	for b in w.balls:
		var p: Array = place.call()
		b["l"] = p[0]
		b["n"] = p[1]
		b["U"] = Vector4.ZERO
		b["radius"] = rng.randf_range(0.05, 0.35)
	var cubes: Array = w.cubes.duplicate()
	w.cubes.clear()
	for c in cubes:
		var p: Array = place.call()
		var half := rng.randf_range(0.08, BallWorld.MAX_CUBE_HALF)
		var n: Vector3 = p[1]
		var F := []
		for k in 3:
			F.append(WormholeSpace.tangent(n, Vector4(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))))
		w.add_cube(p[0], n, Vector4.ZERO, F, Vector3.ZERO, half, c["color"])
	for k in 2:
		var off := Vector3((0.22 if k == 1 else -0.22) + rng.randf_range(-0.2, 0.2), rng.randf_range(-0.6, 0.1), rng.randf_range(-0.6, -0.1))
		var dir := WormholeSpace.combine(hp[2], off)
		var at: Array = sp.geodesic(hp[0], hp[1], dir / dir.length(), dir.length(), hp[2])
		main.hand_state[k] = {"on": true, "l": at[0], "n": at[1], "F": at[2], "U": Vector4.ZERO, "ready": k == 1}
	main._upload_toys()


## Both hands, and a ball held in the right one 0.3 m in front of it (as tests/emu_dump.gd).
func _hold_ball() -> void:
	var sp: WormholeSpace = main.space
	var hp: Array = sp.geodesic(main.foot_l, main.foot_n, main.frame[1], main.DESKTOP_HEAD_HEIGHT, main.frame)
	if main.world.balls.size() > 0 and main.world.balls.back().get("held", &"") == &"right_hand":
		main.world.balls.pop_back()
	for k in 2:
		var off := Vector3(0.22 if k == 1 else -0.22, -0.35, -0.3)
		var dir := WormholeSpace.combine(hp[2], off)
		var at: Array = sp.geodesic(hp[0], hp[1], dir / dir.length(), dir.length(), hp[2])
		main.hand_state[k] = {"on": true, "l": at[0], "n": at[1], "F": at[2], "U": Vector4.ZERO, "ready": k == 1}
		if k == 1:
			var g: Array = sp.geodesic(at[0], at[1], -at[2][2], 0.3, at[2])
			var b: Dictionary = main.world.add(g[0], g[1], Vector4.ZERO, 0.25, Color(0.95, 0.95, 0.97))
			b["held"] = &"right_hand"
	main._upload_toys()
