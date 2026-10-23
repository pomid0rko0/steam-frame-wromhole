extends Label3D
## Diagnostic text drawn by Godot itself, fixed in the world, on a dark plate so it stands out
## against the light scene: frames per second against the headset's refresh rate, and the GPU
## time per frame against the time one frame may take.

var target: Viewport          # the viewport the scene is rendered into
var xr: OpenXRInterface       # null on the desktop
var rate_hint := "курок"      # the button that steps the refresh rate
var t := 0.0
var frames := 0
var gpu := 0.0
var plate: MeshInstance3D


func _ready() -> void:
	no_depth_test = true
	render_priority = 20
	pixel_size = 0.0014
	font_size = 40
	outline_size = 0
	modulate = Color(1.0, 0.92, 0.45)
	horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.05, 0.06, 0.09, 0.9)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.render_priority = 19
	plate = MeshInstance3D.new()
	plate.mesh = QuadMesh.new()
	plate.material_override = mat
	add_child(plate)
	RenderingServer.viewport_set_measure_render_time(target.get_viewport_rid(), true)
	_set_text("...")


func _process(delta: float) -> void:
	t += delta
	frames += 1
	gpu += RenderingServer.viewport_get_measured_render_time_gpu(target.get_viewport_rid())
	if t >= 1.0:
		var refresh := xr.display_refresh_rate if xr else 0.0
		var hz := "%.0f Гц" % refresh if refresh > 0.0 else "? Гц"
		var budget := "из %.1f" % (1000.0 / refresh) if refresh > 0.0 else ""
		var rates := ""
		if xr:
			var list: Array = xr.get_available_display_refresh_rates()
			list.sort()
			rates = "\n%s: %s Гц" % [rate_hint, " ".join(list.map(func(r): return "%.0f" % r))]
		_set_text("%.0f кадр/с  (шлем %s)\nGPU %.1f мс %s%s" % [frames / t, hz, gpu / frames, budget, rates])
		t = 0.0
		frames = 0
		gpu = 0.0


func _set_text(s: String) -> void:
	text = s
	# the plate covers the (centred) text with a margin; sized from the font, since the label
	# rebuilds its own geometry only later
	var f: Font = font if font else ThemeDB.fallback_font
	var size := f.get_multiline_string_size(s, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size) * pixel_size
	(plate.mesh as QuadMesh).size = size + Vector2(0.08, 0.06)
	plate.position = Vector3(0.0, 0.0, -0.005)
