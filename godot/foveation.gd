class_name Foveation
extends RefCounted
## Foveated rendering: what lies away from where the eyes look is rendered coarser. Level 0 is
## off, 1..3 the runtime's density map at its level low, medium, high, 4 and 5 our own
## (OWN_MAPS); split: the 3D scene in a render pass of its own without a density map (the speed
## check times that alone).
##
## On the Steam Frame the runtime's density map is SteamVR's (XR_FB_foveation). SteamVR tracks the
## eyes and hands Godot each frame where each eye looks (XR_META_foveation_eye_tracked; Godot asks
## only with the eye gaze extension on, project.godot), and Godot hands the driver offsets
## that move the density map there (VK_QCOM_fragment_density_map_offset), whichever map it is: so
## our own maps follow the eyes too. They are centred in each eye's picture, where SteamVR's are
## (the offsets are taken from the picture's centre). The GPU driver applies a density map only
## to a pass it renders in tiles: split_pass.gd. The swapchain gets SteamVR's map when
## it is created, so project.godot asks for the high level and "off" is the viewport's density
## map taken away (vrs_mode), not the runtime's level 0. Without the runtime's map (Monado,
## Godot's "Native mobile") levels 1..3 are Godot's own, round each eye's centre.
##
## The ray tracer stays exact under it: each pixel's ray is interpolated from the screen's
## corners (shaders/wormhole_view.gdshaderinc), and a coarse pixel gets the ray through its
## centre, as Godot's own geometry does. Nothing in it reads the pixel's screen position.
##
## Godot asks for the eye-tracked density map's offsets in the headset's full-size pixels: at a
## render scale below 100% the sharp spot would sit beside where one looks, so foveation goes with
## 100% only.
##
## Subsampled images stay off (project.godot): SteamVR can't read them. verbose_stdout lists the
## OpenXR extensions and what the driver supports (long: keep it off).

const LEVELS := 3                    # the runtime's levels: low, medium, high
# Our own density maps (levels 4 and 5), each eye alike, centred: rings out from where the eyes
# look, [radius, shading width, height in screen pixels]; the radius in each eye's picture, its
# edge at 1. Each step halves the pixels shaded, for a softer edge than the runtime's maps: the
# width first, then the height (order 1 swaps them). 4: wide, 5: narrow.
const OWN_MAPS := {
	4: [[0.7, 1, 1], [0.9, 2, 1], [1.15, 2, 2], [99.0, 4, 2]],
	5: [[0.45, 1, 1], [0.65, 2, 1], [0.85, 2, 2], [1.05, 4, 2], [99.0, 4, 4]],
}
# texels a side: the driver takes one density per tile, and a tile spans many texels (tools/fdm_check.sh
# prints the tiles' size)
const OWN_MAP_SIZE := 64
const OWN_MAP_BYTE := {1: 0, 2: 128, 4: 192}     # shading size -> colour byte (_own_map)
# Godot's own density map where the runtime has none (Monado, tests): its strength per level
const OWN_MAP_STRENGTH := [0.5, 1.0, 2.0]

var target: Viewport            # the XR viewport (the window's on the desktop)
var xr: XRInterface             # null on the desktop
var split_pass: CompositorEffect = preload("res://split_pass.gd").new()   # on the XR camera's compositor
var level := 0
var order := 0                  # our maps' order of steps (set_order)
var maps := {}                  # OWN_MAPS made into textures, by level * 2 + order (_own_map)


func _init(p_target: Viewport, p_xr: XRInterface) -> void:
	target = p_target
	xr = p_xr


func set_level(p_level: int, split := false) -> void:
	level = clampi(p_level, 0, 5)
	var mode := Viewport.VRS_DISABLED
	if OWN_MAPS.has(level):
		mode = Viewport.VRS_TEXTURE
		# a texture array, a layer per eye: Viewport.vrs_texture takes a Texture2D only. Copied
		# into the driver's map every frame: a copy made once is lost when the buffers are made again
		target.vrs_update_mode = Viewport.VRS_UPDATE_ALWAYS
		RenderingServer.viewport_set_vrs_texture(target.get_viewport_rid(), _own_map(level).get_rid())
	elif level > 0:
		mode = Viewport.VRS_XR
	if target.vrs_mode != mode:
		target.vrs_mode = mode      # the 3D buffers are made again: not every call
	split_pass.enabled = level > 0 or split
	if level == 0 or OWN_MAPS.has(level) or xr == null:
		return
	var oxr := xr as OpenXRInterface
	if oxr and oxr.is_foveation_supported():
		oxr.foveation_level = level
	elif "vrs_strength" in xr:
		xr.set("vrs_strength", OWN_MAP_STRENGTH[level - 1])


## Our maps' order of steps (OWN_MAPS): 0 the width first, 1 the height first. At once if one of
## them is on.
func set_order(p_order: int) -> void:
	order = clampi(p_order, 0, 1)
	if OWN_MAPS.has(level):
		set_level(level)


## One of OWN_MAPS as a density map Godot takes (Viewport.vrs_texture's colours: red and green
## the shading width and height), a layer per eye. Godot makes a colour c into the density 1 - c,
## and the driver a density d into a size 1/d rounded down to a power of two: hence 192, not 0.75
## (191/255 would come out 3.98, so 2).
func _own_map(lv: int) -> Texture2DArray:
	var key := lv * 2 + order
	if maps.has(key):
		return maps[key]
	var img := Image.create(OWN_MAP_SIZE, OWN_MAP_SIZE, false, Image.FORMAT_RG8)
	for y in OWN_MAP_SIZE:
		for x in OWN_MAP_SIZE:
			var r := Vector2((x + 0.5) * 2.0 / OWN_MAP_SIZE - 1.0, (y + 0.5) * 2.0 / OWN_MAP_SIZE - 1.0).length()
			for ring: Array in OWN_MAPS[lv]:
				if r < ring[0]:
					var w: int = ring[1] if order == 0 else ring[2]
					var h: int = ring[2] if order == 0 else ring[1]
					img.set_pixel(x, y, Color8(OWN_MAP_BYTE[w], OWN_MAP_BYTE[h], 0))
					break
	var tex := Texture2DArray.new()
	tex.create_from_images([img, img])
	maps[key] = tex
	return tex
