shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;
stencil_mode write, compare_always, 2;

// Where the ray tracer with the shell's toys must run, the head in the curved region (main.gd,
// _update_proxies; after stencil_mark_all.gdshader, render priority -2): the pixels whose ray's
// plane passes within reach of one of the shell's toys, those near the eye left out
// (stencil_toys_near.gdshader marks theirs: wormhole_view.gdshaderinc, WH_MARK). Elsewhere it is
// discarded, and the stencil stays 1: the ray tracer with the flat universes' toys only.
#define WH_MARK
#include "res://shaders/wormhole_view.gdshaderinc"
