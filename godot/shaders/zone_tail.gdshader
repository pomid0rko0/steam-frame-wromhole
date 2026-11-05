shader_type spatial;
// The tail of the zone bodies' images, per pixel (zone_tail.gdshaderinc), only where a body's tail can
// be: per body slot and side TAIL_STRIPS + 1 instances, each a ring sector of the view round the
// eye's inward radial direction (Renderer._zone_mesh: VERTEX.x across the sector, VERTEX.y 0 its
// inner edge, 1 its outer): round the axis the azimuths whose rays' planes pass by the body
// (tail_sector: two, round its direction and the opposite), off it a strip of the angles whose rays
// can meet one copy of it (tail_strip, instance k: copy n0 + k), as long as the strips stay apart,
// and the band of those that wind round the throat's cylinder enough on their way to it from the
// first copy no strip takes (tail_band; all of it where the body has no strips: tail_strips), all
// worked out once a frame for each body and eye by ZoneSections' IMAGES pass (after a slot's images'
// texels of its cull_tex; an instance whose centre is not the one the pass took draws nothing).
// Where a pixel's ray meets that body past the meshes' images, among its instance's copies, it is
// drawn at the depth of the light's way there, as the meshes are (body.gdshaderinc), lit as they are;
// a pixel whose ray meets it not is dropped. Bodies as Renderer.set_objects has them in ZoneSections'
// slots: balls' first, cubes' from TAIL_CUBE0; instance i is of the zone's body i / (2 per) (its balls,
// then its cubes: Renderer draws only those), side i / per % 2, strip i % per (per = TAIL_STRIPS + 1;
// the last the band). A vertex costs the headset's GPU about as much whatever it does (some
// fifteen nanoseconds and more: the speed check), so the instances are few and their quads too; a
// vertex of one that draws nothing does no more than say so, and the eye is the fragment's own
// (geo_eye, as the floor's quad's corners find it), not handed on.
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled;

#include "res://shaders/geo_uniforms.gdshaderinc"
#include "res://shaders/geo.gdshaderinc"
#include "res://shaders/look.gdshaderinc"
#include "res://shaders/zone.gdshaderinc"
#include "res://shaders/zone_tail.gdshaderinc"

#include "res://shaders/zone_tail_draw.gdshaderinc"
