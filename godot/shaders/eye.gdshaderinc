// What every shader of the space reads (project.godot's shader globals, which Renderer sets), the
// space itself (space.gdshaderinc) and each view's eye.
//
// Multiview (stereo) in Godot: VIEW_MATRIX / INV_VIEW_MATRIX are the camera between the eyes for
// BOTH views; each eye's position and rotation relative to it are folded into that view's
// PROJECTION_MATRIX, and EYE_OFFSET is the eye's position in that shared view space. So the eye
// is at INV_VIEW_MATRIX * EYE_OFFSET; a point the camera would see at play-space position W is
// drawn at PROJECTION_MATRIX * VIEW_MATRIX * W. Without multiview EYE_OFFSET is zero. The XR
// origin is the play space (main.gd keeps it unmoved).

global uniform float sp_rho0;
global uniform float sp_R;
global uniform float sp_Lc;
global uniform float sp_L;
global uniform float sp_Rout;
global uniform sampler2D sp_tab;
global uniform sampler2D sp_ptab;
// the head (Renderer.set_head): its point (head_l, head_n), the play-space axes transported to it
// (head_f0..2, as (U_l, u)), its place in the play space
global uniform float head_l;
global uniform vec3 head_n;
global uniform vec4 head_f0;
global uniform vec4 head_f1;
global uniform vec4 head_f2;
global uniform vec3 head_pos;

#include "res://shaders/space.gdshaderinc"

// This view's eye in the space: the geodesic from the head to it, with the axes. eye: its place in
// the play space.
void sp_eye(mat4 inv_view, vec3 eye_offset, out float l, out vec3 n, out vec4 f0, out vec4 f1, out vec4 f2,
            out vec3 eye) {
    l = head_l;
    n = head_n;
    f0 = head_f0;
    f1 = head_f1;
    f2 = head_f2;
    eye = (inv_view * vec4(eye_offset, 1.0)).xyz;
    vec3 off = eye - head_pos;
    float len = length(off);
    if (len > 1e-6) {
        vec4 dir = (off.x * f0 + off.y * f1 + off.z * f2) / len;
        sp_walk(l, n, dir, len, f0, f1, f2);
    }
}
