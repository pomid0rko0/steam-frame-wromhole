// The uniforms geo.gdshaderinc reads, for Godot's shaders (Renderer sets them: the throat and
// its table once, the head every frame).
uniform vec4 g_prof;
uniform vec4 g_prof2;
uniform vec4 g_tabx;
uniform sampler2D g_tab : filter_linear, repeat_disable;
uniform float head_l;
uniform vec3 head_n;
uniform vec4 head_f[3];
uniform vec3 head_pos;
// each universe's mouth (A, B): the throat's centre in its world, x and y, and the turn's cos and
// sin (WormholeSpace.mouths; look.gdshaderinc and the scene's objects read it)
uniform vec4 g_mouth[2];
