extends RefCounted
## What the test scripts share. A test's checks print "PASS <name>  <detail>" or "FAIL <name>
## <detail>", and it ends with "FAILURES: n" and exit status 1 on any (tools/test.sh shows the FAIL
## lines). Also: keys, the simulated headset and controllers, both eyes' pictures, Godot's own red
## geometry for the stereo tests to compare the ray tracer with.
## In a test script main._ready has not run during _initialize: set main's fields there, touch its
## nodes from _process, frame 2 or later.

const FakeHmd := preload("res://tests/fake_hmd.gd")
const FRAME := "/interaction_profiles/valve/frame_controller_valve"
const GENERIC := "/interaction_profiles/khr/generic_controller"
const TOUCH := "/interaction_profiles/oculus/touch_controller"
# action name -> the binding paths openxr_action_map.tres has for it, per profile, exactly (one
# path a runtime rejects drops the profile's bindings, so nothing the app does not read): the Steam
# Frame's own (paths from Valve's page «Steam Frame Input»), the KHR generic controller (SteamVR's
# fallback when an app offers no Frame profile), Touch (SteamVR's next fallback), the eyes
const L := "/user/hand/left/"
const R := "/user/hand/right/"
const POSES := {"aim_pose": [L + "input/aim/pose", R + "input/aim/pose"],
	"grip_pose": [L + "input/grip/pose", R + "input/grip/pose"]}
const STICKS := {"trigger": [L + "input/trigger/value", R + "input/trigger/value"],
	"grip": [L + "input/squeeze/value", R + "input/squeeze/value"],
	"primary": [L + "input/thumbstick", R + "input/thumbstick"],
	"primary_click": [L + "input/thumbstick/click", R + "input/thumbstick/click"],
	"haptic": [L + "output/haptic", R + "output/haptic"]}
const BINDINGS := {
	FRAME: {
		"menu_button": [L + "input/view/click", R + "input/menu/click"],
		"ax_button": [R + "input/a/click"],
		"by_button": [R + "input/b/click"],
		"dpad_up": [L + "input/dpad_up/click"],
		"dpad_down": [L + "input/dpad_down/click"],
		"dpad_left": [L + "input/dpad_left/click"],
		"dpad_right": [L + "input/dpad_right/click"],
	},
	GENERIC: {
		"ax_button": [L + "input/primary/click", R + "input/primary/click"],
		"by_button": [L + "input/secondary/click", R + "input/secondary/click"],
	},
	TOUCH: {
		"menu_button": [L + "input/menu/click"],
		"ax_button": [L + "input/x/click", R + "input/a/click"],
		"by_button": [L + "input/y/click", R + "input/b/click"],
	},
	"/interaction_profiles/ext/eye_gaze_interaction": {
		"eye_gaze_pose": ["/user/eyes_ext/input/gaze_ext/pose"],
	},
}

static var fails := 0


static func check(name: String, ok: bool, detail := "") -> bool:
	print(("PASS " if ok else "FAIL ") + name + ("  " + detail if detail != "" else ""))
	if not ok:
		fails += 1
	return ok


## The last line and the exit status. A simulated headset and controller trackers are taken down
## first: left up at exit, they abort Godot, and the exit status would say nothing.
static func finish(tree: SceneTree, hmd: XRInterface = null, trackers: Array = []) -> void:
	print("FAILURES: ", fails)
	for t: XRTracker in trackers:
		XRServer.remove_tracker(t)
	if hmd:
		XRServer.primary_interface = null
		hmd.uninitialize()
		XRServer.remove_interface(hmd)
	tree.quit(1 if fails > 0 else 0)


## A key press or release, as the desktop's input: seen from the next frame on, or at once with
## flush (for a test that calls main._process itself).
static func key(code: Key, down: bool, flush := false) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = down
	Input.parse_input_event(ev)
	if flush:
		Input.flush_buffered_events()


## The simulated headset (fake_hmd.gd, or hmd: an instance of a script that extends it), made the
## primary interface. case 0: the head straight up at 1.6 m, parallel eyes, symmetric frusta;
## 1: the head turned 30 degrees, pitched (pitch, degrees) and rolled 8, displaced, the eyes canted
## 10 degrees outward, asymmetric frusta.
static func headset(case := 0, pitch := -12.0, size := Vector2i(1000, 1100), hmd: XRInterface = null) -> XRInterface:
	if hmd == null:
		hmd = FakeHmd.new()
	hmd.size = size
	if case == 0:
		hmd.setup(Transform3D(Basis.IDENTITY, Vector3(0.0, 1.6, 0.0)), 0.064, 0.0, Vector4(-1.0, 1.0, -1.1, 1.1))
	else:
		var b := Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(30.0), deg_to_rad(8.0)))
		hmd.setup(Transform3D(b, Vector3(0.35, 1.5, -0.25)), 0.064, 10.0, Vector4(-1.2, 0.9, -1.15, 1.0))
	XRServer.add_interface(hmd)
	hmd.initialize()
	XRServer.primary_interface = hmd
	return hmd


## A controller tracker with the app's inputs at rest.
static func controller(tracker_name: StringName) -> XRControllerTracker:
	var t := XRControllerTracker.new()
	t.name = tracker_name
	t.profile = GENERIC
	t.set_input(&"primary", Vector2.ZERO)
	t.set_input(&"trigger", 0.0)
	t.set_input(&"grip", 0.0)
	for b in [&"primary_click", &"ax_button", &"by_button", &"menu_button", &"dpad_up", &"dpad_down",
			&"dpad_left", &"dpad_right"]:
		t.set_input(b, false)
	XRServer.add_tracker(t)
	return t


## The bindings a profile should have: its own (BINDINGS) and, on a controller, the poses, sticks,
## triggers, grips and haptics.
static func bindings(path: String) -> Dictionary:
	var want: Dictionary = BINDINGS[path].duplicate()
	if path != "/interaction_profiles/ext/eye_gaze_interaction":
		want.merge(POSES)
		want.merge(STICKS)
	return want


## openxr_action_map.tres has exactly these profiles, and in each exactly the bindings above.
static func check_bindings() -> void:
	var am: OpenXRActionMap = load("res://openxr_action_map.tres")
	check("action map: these profiles only", am.get_interaction_profile_count() == BINDINGS.size(),
			"%d profiles" % am.get_interaction_profile_count())
	for path: String in BINDINGS:
		var profile := am.find_interaction_profile(path)
		if profile == null:
			check("action map has " + path, false, "no such profile")
			continue
		var have := {}
		for i in profile.get_binding_count():
			var b := profile.get_binding(i)
			have[b.action.resource_name] = have.get(b.action.resource_name, []) + [b.binding_path]
		var want := bindings(path)
		var actions := want.duplicate()
		actions.merge(have)
		for action: String in actions:
			var h: Array = have.get(action, [])
			var w: Array = want.get(action, [])
			h.sort()
			w.sort()
			check("%s: %s" % [path.get_file(), action], h == w, "bound to %s, expected %s" % [h, w])


## Both eyes' pictures of the XR view: <prefix>_<mode>_left.png and _right.png.
static func save_eyes(main: Node, prefix: String, mode: String) -> void:
	var rid: RID = main.xr_view.get_texture().get_rid()
	for i in 2:
		var img: Image = RenderingServer.texture_2d_layer_get(rid, i)
		img.convert(Image.FORMAT_RGB8)
		img.save_png(prefix + "_" + mode + ("_left.png" if i == 0 else "_right.png"))


## Godot's own geometry in flat red, drawn over the ray tracer (after its opaque quad), for the
## stereo tests to compare silhouettes.
static func red(mesh: Mesh) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.0, 0.0)
	mat.no_depth_test = true
	mat.render_priority = 10
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.material_override = mat
	return m


## A sphere mesh fine enough that its outline is a sphere's within a fraction of a pixel.
static func sphere(radius: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = radius
	s.height = 2.0 * radius
	s.radial_segments = 256
	s.rings = 128
	return s
