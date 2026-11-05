shader_type spatial;
// zone_tail.gdshader (its top says what it draws and how), its eye handed on from the vertices as
// flat varyings, not each fragment's own: the speed check times it against that one (bench.gd's
// VARIANTS, Renderer.TAIL_SHADERS).
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled;

#define TAIL_FLAT_EYE

#include "res://shaders/geo_uniforms.gdshaderinc"
#include "res://shaders/geo.gdshaderinc"
#include "res://shaders/look.gdshaderinc"
#include "res://shaders/zone.gdshaderinc"
#include "res://shaders/zone_tail.gdshaderinc"

#include "res://shaders/zone_tail_draw.gdshaderinc"
