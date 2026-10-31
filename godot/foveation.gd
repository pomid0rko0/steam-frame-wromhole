class_name Foveation
extends RefCounted
## Foveated rendering: what lies away from where the eyes look is rendered coarser. Level 0 is
## off, 1..3 the runtime's density map at its level low, medium, high, 4 and 5 our own, wide and
## narrow (floor_fov.gd); split: the 3D scene in a render pass of its own without a density map
## (the speed check times that alone).
##
## The runtime's density map: on the Steam Frame SteamVR's (XR_FB_foveation). SteamVR tracks the
## eyes and hands Godot each frame where each eye looks (XR_META_foveation_eye_tracked; Godot asks
## only with the eye gaze extension on, project.godot), and Godot hands the driver offsets that move
## the density map there (VK_QCOM_fragment_density_map_offset). The GPU driver applies a density
## map only to a pass it renders in tiles: split_pass.gd. The swapchain gets SteamVR's map when it
## is created, so project.godot asks for the high level and "off" is the viewport's density map
## taken away (vrs_mode), not the runtime's level 0. Without the runtime's map (Monado, Godot's
## "Native mobile") levels 1..3 are Godot's own, round each eye's centre. The picture stays exact
## under it: the bodies are geometry, and the floor's ray of each pixel is interpolated from the
## screen's corners (shaders/floor.gdshaderinc), so a coarse pixel gets the ray through its centre.
##
## Our own (4, 5): no density map. Only the floor and the sky cost much per pixel, so they alone
## are worked out coarser away from the gaze, smoothly, and filtered (floor_fov.gd); the bodies
## keep the full resolution.
##
## Godot asks for the eye-tracked density map's offsets in the headset's full-size pixels: at a
## render scale below 100% the sharp spot would sit beside where one looks, so foveation goes with
## 100% only.
##
## Subsampled images stay off (project.godot): SteamVR can't read them. verbose_stdout lists the
## OpenXR extensions and what the driver supports (long: keep it off).

const LEVELS := 3                    # the runtime's levels: low, medium, high
# Godot's own density map where the runtime has none (Monado, tests): its strength per level
const OWN_MAP_STRENGTH := [0.5, 1.0, 2.0]

var target: Viewport            # the XR viewport (the window's on the desktop)
var xr: XRInterface             # null on the desktop
var split_pass: CompositorEffect = preload("res://split_pass.gd").new()   # on the XR camera's compositor
var floor_fov: FloorFov         # our own (Renderer's; on the XR camera's compositor too)
var level := 0


func _init(p_target: Viewport, p_xr: XRInterface) -> void:
	target = p_target
	xr = p_xr


func set_level(p_level: int, split := false) -> void:
	level = clampi(p_level, 0, 5)
	var mode := Viewport.VRS_XR if level > 0 and level <= LEVELS else Viewport.VRS_DISABLED
	if target.vrs_mode != mode:
		target.vrs_mode = mode      # the 3D buffers are made again: not every call
	split_pass.enabled = (level > 0 and level <= LEVELS) or split
	if floor_fov:
		var size := Vector2(1, 1)
		if xr:
			size = xr.get_render_target_size()
		floor_fov.set_level(level, int(maxf(size.x, size.y)))
	if level == 0 or level > LEVELS or xr == null:
		return
	var oxr := xr as OpenXRInterface
	if oxr and oxr.is_foveation_supported():
		oxr.foveation_level = level
	elif "vrs_strength" in xr:
		xr.set("vrs_strength", OWN_MAP_STRENGTH[level - 1])
