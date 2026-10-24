extends SceneTree
## For tools/adreno_cost.py: puts the viewer at a speed check pose, renders a frame and writes what
## the ray tracer gets (the head's point and frame, the camera) and the picture, so the emulated
## shader can be fed the same inputs and checked against the picture.
##   godot --path . --resolution WxH -s res://tests/emu_dump.gd -- out.json "l,yaw,pitch;..." [fov] [plain|balls] [shader]
## Each pose gives out_<i>.png and an entry in out.json. fov: vertical, degrees (default 90);
## shader: another ray tracer's path (res://shaders/ab/1/wormhole.gdshader).

var main: Node3D
var frames := 0
var out := ""
var poses: Array = []
var fov := 90.0
var entries: Array = []
var i := 0
var shader_path := ""


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
	main.show_check = a.size() > 3 and a[3] == "balls"
	root.add_child(main)
	if a.size() > 4 and a[4] != "":
		shader_path = a[4]


func _process(_d: float) -> bool:
	frames += 1
	if frames == 1 and shader_path != "":
		main.material.shader = load(shader_path)
	if frames == 2:
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
			"balls": main.material.shader == main.SHADER_BALLS,
		})
		i += 1
	return false


static func _v3(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


static func _v4(v: Vector4) -> Array:
	return [v.x, v.y, v.z, v.w]
