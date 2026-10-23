extends XRInterfaceExtension
## A simulated headset for tests: Godot's real multiview path with eyes we choose, including
## what a real headset may do and the "Native mobile" interface never does: canted (rotated)
## eyes, asymmetric frusta and an arbitrary head pose.

var head := Transform3D.IDENTITY       # head pose in the play space (the XROrigin)
var eyes: Array[Transform3D] = []      # each eye relative to the head
var frusta: Array[Vector4] = []        # tan of the half-angles: left, right, bottom, top
var size := Vector2i(1000, 1100)
var tracker: XRPositionalTracker
var ready_ok := false


func setup(head_pose: Transform3D, ipd: float, cant_deg: float, left_frustum: Vector4) -> void:
	head = head_pose
	var c := deg_to_rad(cant_deg)
	# canted outward: the left eye turns left (+yaw), the right eye turns right
	eyes = [Transform3D(Basis(Vector3.UP, c), Vector3(-0.5 * ipd, 0.0, 0.0)),
			Transform3D(Basis(Vector3.UP, -c), Vector3(0.5 * ipd, 0.0, 0.0))]
	# the right eye's frustum mirrors the left one
	frusta = [left_frustum, Vector4(-left_frustum.y, -left_frustum.x, left_frustum.z, left_frustum.w)]


func _get_name() -> StringName:
	return &"FakeHMD"


func _get_capabilities() -> int:
	return XRInterface.XR_STEREO | XRInterface.XR_VR


func _is_initialized() -> bool:
	return ready_ok


func _initialize() -> bool:
	tracker = XRPositionalTracker.new()
	tracker.type = XRServer.TRACKER_HEAD
	tracker.name = &"head"
	XRServer.add_tracker(tracker)
	_publish()
	ready_ok = true
	return true


func _uninitialize() -> void:
	ready_ok = false


func _get_tracking_status() -> XRInterface.TrackingStatus:
	return XRInterface.XR_NORMAL_TRACKING


func _get_render_target_size() -> Vector2:
	return Vector2(size)


func _get_view_count() -> int:
	return 2


func _get_camera_transform() -> Transform3D:
	return XRServer.world_origin * head


func _get_transform_for_view(view: int, origin_transform: Transform3D) -> Transform3D:
	return origin_transform * head * eyes[view]


func _get_projection_for_view(view: int, _aspect: float, z_near: float, z_far: float) -> PackedFloat64Array:
	var f: Vector4 = frusta[view]
	var p := Projection.create_frustum(f.x * z_near, f.y * z_near, f.z * z_near, f.w * z_near, z_near, z_far)
	var out := PackedFloat64Array()
	for c in 4:
		for r in 4:
			out.append(p[c][r])
	return out


func _process() -> void:
	_publish()


func _pre_draw_viewport(_render_target: RID) -> bool:
	return true


func _publish() -> void:
	tracker.set_pose(&"default", head, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
