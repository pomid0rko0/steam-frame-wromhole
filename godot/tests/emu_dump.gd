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
## right one in front of the chest (what the hands and grabbing add to a frame; HELD_DIST and HELD_R in
## the environment: its distance from the hand and its radius, 0.3 and 0.25 m by default);
## shader: another ray tracer's path (res://shaders/ab/1/wormhole.gdshader).

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
		"wh_cubeCol", "wh_nCube", "wh_bound", "wh_bIdx", "wh_cIdx", "wh_fball", "wh_pix", "grav_cyl", "grav_g", "grav_d"]


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
		if not main.material.shader.code.contains("stencil_mode"):
			main.set_toy_mode(main.TOYS_BARE)    # another source's: no stencil test, the whole view
	if frames == 2:
		if toys:
			# the demo after the throw and the drop, all of it at rest, then held still
			main._throw()
			main._drop()
			for k in 12 * 60:
				main.world.step(1.0 / 60.0, [])
			main.hold = true
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
		if hands:
			_hold_ball()
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
			# the stencil's proxies (main._update_proxies), chart spheres of the head's universe, or
			# none (the whole view marked, or no toys)
			"proxies": _proxies(),
		})
		i += 1
	return false


## Both hands as the app has them (main.hand_state), and with +held a ball (radius 0.25) held by the
## right one, 0.3 m in front of it: placed from the head as main._update_hands does, in the room's axes.
func _hold_ball() -> void:
	var sp: WormholeSpace = main.space
	var hp: Array = sp.geodesic(main.foot_l, main.foot_n, main.frame[1], main.DESKTOP_HEAD_HEIGHT, main.frame)
	if main.world.balls.size() > 0 and main.world.balls.back()["held"] == &"right_hand":
		main.world.balls.pop_back()
	for k in 2:
		var off := Vector3(0.22 if k == 1 else -0.22, -0.35, -0.3)
		var dir := WormholeSpace.combine(hp[2], off)
		var at: Array = sp.geodesic(hp[0], hp[1], dir / dir.length(), dir.length(), hp[2])
		main.hand_state[k] = {"on": true, "l": at[0], "n": at[1], "F": at[2], "U": Vector4.ZERO, "ready": k == 1}
		if k == 1 and held:
			var hd := float(OS.get_environment("HELD_DIST")) if OS.has_environment("HELD_DIST") else 0.3
			var hr := float(OS.get_environment("HELD_R")) if OS.has_environment("HELD_R") else 0.25
			var g: Array = sp.geodesic(at[0], at[1], -at[2][2], hd, at[2])
			var b: Dictionary = main.world.add(g[0], g[1], Vector4.ZERO, hr, Color(0.95, 0.95, 0.97))
			b["held"] = &"right_hand"
	main._upload_toys()


func _proxies() -> Array:
	var out := []
	if main.balls > 0:
		for s in main.proxy_spheres(m_head_l()):
			out.append(_v4(s))
	return out


func m_head_l() -> float:
	return main.material.get_shader_parameter("head_l")


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
		elif v is Vector4i:
			out[name] = [v.x, v.y, v.z, v.w]
		else:
			out[name] = v
	return out


static func _v3(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


static func _v4(v: Vector4) -> Array:
	return [v.x, v.y, v.z, v.w]
