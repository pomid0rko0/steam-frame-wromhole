extends SceneTree
## For tools/adreno_cost.py: puts the viewer at a speed check pose, renders a frame and writes what
## the ray tracer gets (the head's point and frame, the camera) and the picture, so the emulated
## shader can be fed the same inputs and checked against the picture.
##   godot --path . --resolution WxH -s res://tests/emu_dump.gd -- out.json "l,yaw,pitch;..." [fov] [scene] [shader]
## Each pose gives out_<i>.png and an entry in out.json with the ray tracer's path and its
## uniforms. fov: vertical, degrees (default 90); scene: plain (default), balls (the stereo
## check's), toys (the demo after the throw and the drop, everything at rest: 8 balls, 4 cubes),
## with +gravity1 or +gravity2 the gravity view (main.set_gravity_view), e.g. toys+gravity2; with
## +hands also both hands' balls where hands are at every pose, with +held also a ball held in the
## right one in front of the chest (main.bench_hands, as the speed check has them);
## shader: another ray tracer's path (res://shaders/ab/1/wormhole.gdshader).
## Each entry also has the toys' passes' uniforms (toys_flat, toys_shell) and their proxies: the
## spheres they are drawn over, in the chart of the head's universe (none: the shell's pass covers
## the whole view).

var main: Node3D
var frames := 0
var out := ""
var poses: Array = []
var fov := 90.0
var entries: Array = []
var i := 0
var shader_path := ""
var gravity := 0
var toys := false
var held := false
var hands := false
const UNIFORMS := ["wh_sph", "wh_pil", "wh_box", "wh_ball", "wh_ballCol", "wh_nBall", "wh_cube", "wh_cubeE",
		"wh_cubeCol", "wh_nCube", "wh_fball", "wh_pix", "grav_cyl", "grav_g", "grav_d", "wht_side", "wht_full",
		"wht_cx", "wht_cy", "wht_cz", "wht_r2", "wht_lo", "wht_hi", "wht_fs", "wht_bit", "wht_t1", "wht_t2",
		"wht_phiBin", "wht_bBin", "wht_bStep", "wht_cone", "wht_coneR", "wht_coneIdx"]


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	out = a[0]
	for p in a[1].split(";"):
		var v := p.split(",")
		poses.append([float(v[0]), float(v[1]), float(v[2])])
	if a.size() > 2:
		fov = float(a[2])
	main = load("res://main.tscn").instantiate()
	main.xr_name = "none"
	var scene: String = a[3] if a.size() > 3 else "plain"
	main.show_check = scene.begins_with("balls")
	main.physics = scene.begins_with("toys")
	main.throw_toys = false
	toys = main.physics
	held = scene.contains("held")
	hands = held or scene.contains("hands")
	if scene.contains("gravity"):
		gravity = int(scene.substr(scene.find("gravity") + 7, 1))
	root.add_child(main)
	if a.size() > 4 and a[4] != "":
		shader_path = a[4]


func _process(_d: float) -> bool:
	frames += 1
	if frames == 1 and shader_path != "":
		main.material.shader = load(shader_path)
		main.toys_shown = false     # another source's: a ray tracer of the world only
	if frames == 2:
		if toys:
			# the demo after the throw and the drop, all of it at rest, then held still
			main.settle_demo()
			main.hold = true
			main.bench_hands = 2 if held else (1 if hands else 0)
		if gravity > 0:
			main.set_gravity_view(gravity)
		main.perf.visible = false
		main.camera.fov = fov
		if main.overlay:
			main.overlay.visible = false
	# a pose takes 3 frames: set, render, read back
	if frames < 4:
		return false
	var k := (frames - 4) % 3
	if k == 0:
		if i >= poses.size():
			var f := FileAccess.open(out, FileAccess.WRITE)
			f.store_string(JSON.stringify(entries, " "))
			return true
		var p: Array = poses[i]
		main.place_on_axis(p[0], p[1], p[2])
	elif k == 2:
		var img := root.get_texture().get_image()
		var png := out.get_basename() + "_%d.png" % i
		img.save_png(png)
		var m: ShaderMaterial = main.material
		var hf: PackedVector4Array = m.get_shader_parameter("head_f")
		var cam: Transform3D = main.camera.global_transform
		var proj: Projection = main.camera.get_camera_projection()
		entries.append({
			"pose": poses[i], "png": png,
			"head_l": m.get_shader_parameter("head_l"),
			"head_n": _v3(m.get_shader_parameter("head_n")),
			"head_f": [_v4(hf[0]), _v4(hf[1]), _v4(hf[2])],
			"head_pos": _v3(m.get_shader_parameter("head_pos")),
			"cam_basis": [_v3(cam.basis.x), _v3(cam.basis.y), _v3(cam.basis.z)],
			"cam_origin": _v3(cam.origin),
			"proj": [_v4(proj.x), _v4(proj.y), _v4(proj.z), _v4(proj.w)],
			"size": [img.get_width(), img.get_height()],
			"shader": m.shader.resource_path,
			"uniforms": _uniforms(m),
			"toys_flat": _uniforms(main.toys_flat_mat),
			"toys_shell": _uniforms(main.toys_shell_mat),
			# the toys' passes' proxies (main._update_toy_draws): chart spheres of the head's
			# universe, [bit, centre, radius] for the flat pass's, none with the head in the
			# curved region or without toys
			"proxies": _proxies(),
		})
		i += 1
	return false


func _proxies() -> Dictionary:
	var l: float = main.material.get_shader_parameter("head_l")
	if main.balls == 0 or not main.toys_shown or absf(l) <= main.space.L:
		return {}
	var side := 1.0 if l > 0.0 else -1.0
	var toys := []
	for bit in main.toy_proxies(side):
		var c: Vector4 = main.toy_chart[bit][1]
		toys.append([bit, _v3(Vector3(c.x, c.y, c.z)), (c.w + main.PROXY_MARGIN) * main.PROXY_SLACK])
	return {"shell": _v4(main.shell_proxy()), "toys": toys}


## The material's values of the uniforms the cost model needs, as numbers and lists.
static func _uniforms(m: ShaderMaterial) -> Dictionary:
	var out := {}
	for name in UNIFORMS:
		var v: Variant = m.get_shader_parameter(name)
		if v == null:
			continue
		if v is PackedVector4Array:
			var rows := []
			for q in v:
				rows.append(_v4(q))
			out[name] = rows
		elif v is Vector4:
			out[name] = _v4(v)
		elif v is Vector3:
			out[name] = _v3(v)
		elif v is Vector4i:
			out[name] = [v.x, v.y, v.z, v.w]
		else:
			out[name] = v
	return out


static func _v3(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


static func _v4(v: Vector4) -> Array:
	return [v.x, v.y, v.z, v.w]
