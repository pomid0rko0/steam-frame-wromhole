// The world's uniforms: what the ray tracer of the world (wormhole_view.gdshaderinc) and the
// toys' passes (toys_view.gdshaderinc) both read. main.gd sets them on both (main._param).
uniform float wh_rho0 = 3.0;
uniform float wh_h = 5.0;
uniform float wh_fillet = 1.0;
uniform vec4 wh_sph[6];
uniform vec4 wh_pil[4];
uniform vec4 wh_box[4];
uniform float head_l = 10.0;
uniform vec3 head_n = vec3(1.0, 0.0, 0.0);
uniform vec4 head_f[3];
uniform vec3 head_pos;
#ifdef WH_TABLE
uniform sampler2D wh_tab : filter_linear, repeat_disable;
uniform vec4 wh_tabLo;
uniform vec4 wh_tabInv;
uniform vec4 wh_tabReg;
#endif
#ifdef WH_GRAVITY
uniform vec4 grav_cyl;
uniform vec4 grav_g[2];
uniform vec4 grav_d[2];
#endif
#if defined(WH_ARROWS) || defined(WH_TOYS)
uniform float wh_pix = 0.0015;      // a pixel's angle: the arrows' soft edges, the cubes' edge lines
#endif

