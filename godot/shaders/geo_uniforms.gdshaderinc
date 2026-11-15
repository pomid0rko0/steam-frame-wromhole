// The uniforms geo.gdshaderinc reads, for Godot's shaders (Renderer sets them: the throat and
// its table once, the head every frame).
uniform vec4 g_prof;
uniform vec4 g_prof2;
uniform vec4 g_tabx;
uniform float g_lift;              // the throat's centre above the floor
uniform float g_beta;              // gravity's dipole outside (look.gdshaderinc, look_grav_floor)
#ifdef GRAVITY
uniform vec2 g_grav;               // gravity on the throat's cylinder: (a, k) (look.gdshaderinc, look_grav_at)
uniform sampler2D g_gravtab : filter_linear, repeat_disable;   // and on a fillet: (f, f') at its nodes
#endif
uniform sampler2D g_tab : filter_linear, repeat_disable;
uniform float head_l;
uniform vec3 head_n;
uniform vec4 head_f[3];
uniform vec3 head_pos;
