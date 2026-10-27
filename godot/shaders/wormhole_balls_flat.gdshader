shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
// where a ray may meet a flat universe's toy but none of the shell's (stencil 1: main.gd, _update_proxies)
stencil_mode read, compare_equal, 1;

// The ray tracer with movable balls and cubes in the flat universes only: their search in the
// curved region is left out (WH_FLAT_TOYS), and with it the registers it holds: as cheap as the
// plain one where no toy is met. The fillet polynomials from a table, as the plain ray tracer.
#define WH_FLAT_TOYS
#define WH_TABLE
#include "res://shaders/wormhole_view.gdshaderinc"
