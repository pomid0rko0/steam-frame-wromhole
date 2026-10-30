extends CompositorEffect
## For main's fragment ray tracer (frag_tracer.gd, the speed check's comparison) with a density map:
## this build's ray tracer foveates by its own rays (foveation.gd).
## An effect that does nothing but exist. With it on the XR camera's compositor, Godot's Mobile
## renderer draws the 3D scene in a render pass of its own and the tone mapping into the
## headset's image in another, instead of one render pass with two subpasses.
##
## Why: foveated rendering on the Steam Frame is the GPU driver's (Mesa's Turnip): it renders
## each tile of the screen at the density map's resolution there, and only when it renders in
## tiles. Godot (the version tools/setup.sh installs) gives its two subpasses a dependency without
## VK_DEPENDENCY_BY_REGION_BIT, and Turnip then renders the whole pass straight to memory, without
## tiles: the density map is ignored (godotengine/godot#124141, fixed in #124811, which that version
## lacks; tools/fdm_check.sh shows which passes render in tiles and says when "off" does too). A
## pass of its own has no such dependency, and Turnip renders it in tiles. Foveation.set_level
## turns this on and off.


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	enabled = false
