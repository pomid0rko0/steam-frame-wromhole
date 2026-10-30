// The ray tracer's compute kernels (ray_pass.gd compiles them, with one of the KERNEL_* defines and
// the variant's WH_* defines in front). Plain GLSL: the frame's values come in one uniform block
// whose members carry the names wormhole_core.gdshaderinc reads, so the core is the same code
// that ref/ compiles as a fragment shader.
//
// The frame (ray_pass.gd, _pack and _render_callback, writes it in this order):

layout(set = 0, binding = 0, std140) uniform Frame {
    float wh_rho0; float wh_h; float wh_fillet; float wh_pix;
    vec4 wh_tabLo; vec4 wh_tabInv; vec4 wh_tabReg;
    vec4 grav_cyl; vec4 grav_g[2]; vec4 grav_d[2];
    vec4 wh_sph[6]; vec4 wh_pil[4]; vec4 wh_box[4];
    vec4 wh_ball[12]; vec4 wh_ballCol[12]; vec4 wh_fball[12];
    vec4 wh_cube[6]; vec4 wh_cubeE[30]; vec4 wh_cubeCol[6];
    vec4 wh_bound[4];
    ivec4 wh_bIdx; ivec4 wh_cIdx;
    int wh_nBall; int wh_nCube; int fr_views; int fr_whole;   // fr_whole: the toys kernel over every group
    vec4 head_f[3];
    vec3 head_n; float head_l;
    vec3 head_pos; float fr_pad0;
    // per view: the camera in play space, the eye's offset in it (EYE_OFFSET), the eye's point of
    // the space (l, n), the play axes f0, f1, f2 moved there and (wh_eye(l), 0, 0) (RayPass, from
    // the head along the geodesic of the eye's offset), and the inverse of its projection with
    // Vulkan's correction (INV_PROJECTION_MATRIX)
    mat4 fr_cam;
    vec4 fr_eyeOff[2];
    vec4 fr_eye[10];
    vec4 fr_rows[2];         // per view: the tables' rows from angle x to z, split at y (fr_row)
    vec4 fr_gaze[2];         // per view: the pixel the eye looks at (foveation's middle)
    vec4 fr_rings[5];        // foveation's rings: (radius, cell width, height), fr_size.w of them
    mat4 fr_invProj[2];
    ivec4 fr_size;           // the picture's width and height, the views, the rings
    ivec4 fr_tab;            // the tables' rows a grid and columns (FR_HALF, FR_COLS)
};

layout(set = 0, binding = 1) uniform sampler2D wh_tab;
layout(rgba16f, set = 0, binding = 2) uniform restrict image2DArray fr_out;

#include_core

// The per-eye tables (KERNEL_ROWS and KERNEL_TABLES make them each frame, the world kernel reads them): the curved
// part of an eye's rays depends only on the ray's angle alpha to the eye's radial direction (+l), so
// a table over alpha holds it for every pixel of that eye. Rows: alpha in two grids split at the
// critical ray (b = rmin toward the throat: rays near it wind round the throat, and what they do
// changes ever faster with alpha), FR_HALF rows each, dense toward it (fr_warp: part linear, part
// logarithmic); for an eye outside the shell only the rays that reach it. fr_tabF: by the polar
// angle psi in the ray's plane from the eye (0..pi, FR_COLS columns), (l, path length) where the
// path has turned by psi, along the whole path (straight before and after the shell, held after its
// last point); fr_tabE: by row, (psi and path length where it leaves the shell, the universe it
// leaves into, psi where it enters it) and below it (the length of the path in the shell the toys'
// search looks along, the length before the shell); fr_tabP (only with movable objects in reach of
// the shell): by the square root of the length along the path in the shell over that length
// (FR_COLS columns: dense near the start, where the objects near the eyes are), the path's point in
// the ray's subspace (r cos psi, r sin psi, w, psi from the eye) and l there.
// (their sizes follow the picture's: RayPass._table_size)
#define FR_HALF (fr_tab.x)
#define FR_COLS (fr_tab.y)
const float FR_WLOG = 0.25;
const float FR_EPS = 1e-6;

float fr_warp(float d, float span) {
    return (1.0 - FR_WLOG) * d / span + FR_WLOG * log(1.0 + d / FR_EPS) / log(1.0 + span / FR_EPS);
}


#if defined(KERNEL_ROWS) || defined(KERNEL_TABLES)
// Two kernels: KERNEL_ROWS sets each row's ray and path up (an invocation a row, all at once),
// KERNEL_TABLES then each cell's point of its row's path (an invocation a cell). (A row a group, its
// first invocation setting it up while the rest wait, would pay a whole wave for each set-up.)
struct FrRow {
    WhPath p;
    vec4 a;     // the straight part before the shell: (psi, length, chi0, b)
    vec4 o;     // (psi and length where it leaves the shell, the universe, the search's length)
};
#endif

#ifdef KERNEL_ROWS
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(rgba32f, set = 0, binding = 7) uniform restrict writeonly image2DArray fr_outE;
layout(std430, set = 0, binding = 10) restrict writeonly buffer FrRows { FrRow fr_rowData[]; };

// the inverse of fr_warp (it grows with d)
float fr_unwarp(float x, float span) {
    float lo = 0.0;
    float hi = span;
    for (int k = 0; k < 48; k++) {
        float m = 0.5 * (lo + hi);
        if (fr_warp(m, span) < x) lo = m; else hi = m;
    }
    return 0.5 * (lo + hi);
}

void main() {
    int i = int(gl_GlobalInvocationID.x);
    int v = int(gl_WorkGroupID.z);
    if (i >= 2 * FR_HALF) return;
    float l0 = fr_eye[5 * v].x;
    float Rout = wh_Rout();
    float L = wh_Lsh();
    float sg = l0 >= 0.0 ? 1.0 : -1.0;
    vec4 rows = fr_rows[v];
    bool up = i >= FR_HALF;
    float span = max(up ? rows.z - rows.y : rows.y - rows.x, 1e-7);
    float dA = fr_unwarp((float(i - (up ? FR_HALF : 0)) + 0.5) / float(FR_HALF), span);
    float alpha = up ? rows.y + dA : rows.y - dA;
    vec2 eye = fr_eye[5 * v + 4].xy;
    float vl = cos(alpha);
    float wn = sin(alpha);
    float r0 = eye.x;
    float b = r0 * wn;
    // the straight part before the shell (an eye outside): in its plane the line at distance b
    // from the centre, chi its polar angle from the closest approach (r = b / cos chi, s = b tan chi)
    float chi0 = (vl * sg < 0.0 ? -1.0 : 1.0) * acos(min(b / r0, 1.0));
    float psiIn = 0.0;
    float sIn = 0.0;
    WhPath p;
    if (abs(l0) >= L) {
        psiIn = acos(min(b / r0, 1.0)) - acos(min(b / Rout, 1.0));
        sIn = sqrt(max(r0 * r0 - b * b, 0.0)) - sqrt(max(Rout * Rout - b * b, 0.0));
        float bR = min(b / Rout, 1.0);
        p = wh_path(sg * L, -sg * sqrt(max(1.0 - bR * bR, 0.0)), bR, vec2(Rout, 0.0));
    } else {
        p = wh_path(l0, vl, wn, eye);
    }
    // the toys' search: the path in the shell up to where it leaves it, or has turned to pi (it
    // has met the floor by then)
    float sigEnd = p.tot.y;
    if (psiIn + p.tot.x > WH_PI) sigEnd = wh_pathAt(p, WH_PI - psiIn).y;
    vec4 o = vec4(psiIn + p.tot.x, sIn + p.tot.y, p.sideC, max(sigEnd, 1e-4));
    fr_rowData[v * 2 * FR_HALF + i] = FrRow(p, vec4(psiIn, sIn, chi0, b), o);
    imageStore(fr_outE, ivec3(i, 0, v), vec4(min(o.x, 1e4), min(o.y, 1e6), p.sideC, psiIn));
    imageStore(fr_outE, ivec3(i, 1, v), vec4(o.w, sIn, 0.0, 0.0));
}
#endif

#ifdef KERNEL_TABLES
layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;
layout(rgba32f, set = 0, binding = 6) uniform restrict writeonly image2DArray fr_outF;
#ifdef FR_PATHS
layout(rgba32f, set = 0, binding = 8) uniform restrict writeonly image2DArray fr_outP;
#endif
layout(std430, set = 0, binding = 10) restrict readonly buffer FrRows { FrRow fr_rowData[]; };

void main() {
    int cell = int(gl_GlobalInvocationID.x);
    int v = int(gl_WorkGroupID.z);
    int i = cell / FR_COLS;
    int k = cell - i * FR_COLS;
    if (i >= 2 * FR_HALF) return;
    float l0 = fr_eye[5 * v].x;
    float Rout = wh_Rout();
    float L = wh_Lsh();
    float sg = l0 >= 0.0 ? 1.0 : -1.0;
    FrRow row = fr_rowData[v * 2 * FR_HALF + i];
    WhPath p = row.p;
    vec4 a = row.a;
    vec4 o = row.o;
    // column k by angle: before the shell, in it, after it (straight, held once it no longer turns)
    float psi = WH_PI * float(k) / float(FR_COLS - 1);
    vec2 ls;
    if (psi < a.x) {
        float chi = a.z + psi;
        ls = vec2(sg * (a.w / cos(chi) - Rout + L), a.w * (tan(chi) - tan(a.z)));
    } else if (psi <= o.x) {
        ls = wh_pathAt(p, psi - a.x) + vec2(0.0, a.y);
    } else {
        float chiX = acos(min(a.w / Rout, 1.0));    // leaving: from the closest approach, outward
        float chi = min(chiX + psi - o.x, 0.5 * WH_PI - 1e-3);
        ls = vec2(o.z * (a.w / cos(chi) - Rout + L), o.y + a.w * (tan(chi) - tan(chiX)));
    }
    imageStore(fr_outF, ivec3(k, i, v), vec4(ls, 0.0, 0.0));
#ifdef FR_PATHS
    float c = float(k) / float(FR_COLS - 1);
    vec3 q;
    vec4 pt = wh_pathPoint(p, o.w * c * c, q);
    float psiP = a.x + pt.y;
    imageStore(fr_outP, ivec3(k, i, v), vec4(pt.z * cos(psiP), pt.z * sin(psiP), pt.w, pt.x));
#endif
}
#endif

#if defined(KERNEL_WORLD) || defined(KERNEL_TOYS)
// the world kernel: whether a ray of the group has a movable object to search for in the shell;
// the toys kernel then traces the group again with the search (fr_tiles)
shared uint sh_toys;
#endif

#if defined(KERNEL_WORLD) || defined(KERNEL_TOYS)
layout(set = 0, binding = 4) uniform sampler2DArray fr_tabF;
layout(set = 0, binding = 5) uniform sampler2DArray fr_tabE;
#endif

#ifdef KERNEL_TOYS
layout(set = 0, binding = 9) uniform sampler2DArray fr_tabP;

// The path's point in the ray's subspace and l, sig along it in the shell (fr_tabP), row rowv of
// view v, sigEnd its row's length.
vec4 fr_path(float rowv, int v, float sig, float sigEnd) {
    float c = sqrt(clamp(sig / sigEnd, 0.0, 1.0));
    return textureLod(fr_tabP, vec3(c * float(FR_COLS - 1) / float(FR_COLS) + 0.5 / float(FR_COLS), rowv, float(v)), 0.0);
}

// The distance in R^4 from the subspace point q to object i (ball i, or cube i - WH_MAXB), its
// centre seen in the subspace cb, its distance from it squared perp2; negative inside.
float fr_dist(int i, vec3 q, vec3 cb, float perp2, vec3 e1, vec3 e2) {
    if (i < WH_MAXB) {
        vec3 a = q - cb;
        return sqrt(dot(a, a) + perp2) - wh_ballCol[i].w;
    }
    int c = i - WH_MAXB;
    float o2 = 0.0;
    float inside = -1e9;
    for (int k = 0; k < 4 + min(wh_nCube, 0); k++) {
        vec4 Ek = wh_cubeE[5 * c + k];
        float u = abs(dot(q, vec3(dot(Ek.xyz, e1), dot(Ek.xyz, e2), Ek.w)) - wh_cubeE[5 * c + 4][k]) - 1.0;
        o2 += u > 0.0 ? u * u : 0.0;
        inside = max(inside, u);
    }
    return (o2 > 0.0 ? sqrt(o2) : inside) * wh_cubeCol[c].w;
}

// Whether the chord q0 -> q1 meets object i grown by g (for a cube: its box grown, a superset).
bool fr_chord(int i, vec3 q0, vec3 q1, float g, vec3 cb, float perp2, vec3 e1, vec3 e2) {
    vec3 D = q1 - q0;
    if (i < WH_MAXB) {
        vec3 a = q0 - cb;
        float rr = wh_ballCol[i].w + g;
        float A = max(dot(D, D), 1e-14);
        float B = dot(a, D);
        float C = dot(a, a) + perp2 - rr * rr;
        float disc = B * B - A * C;
        float t = (-B - sqrt(max(disc, 0.0))) / A;
        return C <= 0.0 || (disc >= 0.0 && t >= 0.0 && t <= 1.0);
    }
    int c = i - WH_MAXB;
    float gk = 1.0 + g / wh_cubeCol[c].w;
    float tin = 0.0;
    float tout = 1.0;
    for (int k = 0; k < 4 + min(wh_nCube, 0); k++) {
        vec4 Ek = wh_cubeE[5 * c + k];
        vec3 ek = vec3(dot(Ek.xyz, e1), dot(Ek.xyz, e2), Ek.w);
        float a0 = dot(q0, ek) - wh_cubeE[5 * c + 4][k];
        float dk = dot(D, ek);
        float idk = 1.0 / (abs(dk) > 1e-9 ? dk : 1e-9);
        float t0 = (-gk - a0) * idk;
        float t1 = (gk - a0) * idk;
        tin = max(tin, min(t0, t1));
        tout = min(tout, max(t0, t1));
    }
    return tin <= tout;
}

// Where along the path in the shell (0 .. send) it enters object i, or -1: research's bounded
// search (PR #20). The path runs at unit speed, so a chord is no longer than its arc: far from the
// object (distance d at least its size) a step of d cannot reach it; near it, chords of half its size,
// each tested against the object grown by the chord's sag (the space's curvature 1 / min(R, rho0)
// at most), and one that meets it split in 8, the entry refined by regula falsi. At most 24 steps.
// A ray that starts inside an object does not see it from inside.
float fr_search(int i, float rowv, int v, float sigEnd, float send, vec3 cb, float perp2, float size, vec3 e1, vec3 e2) {
    float kmax = 1.0 / min(wh_fillet, wh_rho0);
    float s = 0.0;
    vec3 q = fr_path(rowv, v, s, sigEnd).xyz;
    float d = fr_dist(i, q, cb, perp2, e1, e2);
    if (d <= 0.0) return -1.0;
    for (int it = 0; it < 24 + min(wh_nBall, 0); it++) {
        if (s >= send) break;
        if (d >= size) {
            float sp = s;
            float dp = d;
            s += d;
            q = fr_path(rowv, v, s, sigEnd).xyz;
            d = fr_dist(i, q, cb, perp2, e1, e2);
            if (d <= 0.0) {
                // a step of the distance ends at most on it, by the tables' error just inside: the
                // entry is between, refined from both ends
                if (s >= send) break;
                float sa = sp;
                float da = dp;
                float sb = s;
                float db = d;
                for (int r = 0; r < 3 + min(wh_nBall, 0); r++) {
                    float sx = (sa * db - sb * da) / (db - da);
                    float dx = fr_dist(i, fr_path(rowv, v, sx, sigEnd).xyz, cb, perp2, e1, e2);
                    if (dx > 0.0) { sa = sx; da = dx; } else { sb = sx; db = dx; }
                }
                return sb;
            }
            continue;
        }
        float step = min(0.5 * size, send - s);
        float s1 = s + step;
        vec3 q1 = fr_path(rowv, v, s1, sigEnd).xyz;
        if (fr_chord(i, q, q1, kmax * step * step * 0.125 + 1e-5, cb, perp2, e1, e2)) {
            float sa = s;
            float da = d;
            for (int j = 1; j <= 8 + min(wh_nBall, 0); j++) {
                float sb = s + step * float(j) * 0.125;
                float db = fr_dist(i, fr_path(rowv, v, sb, sigEnd).xyz, cb, perp2, e1, e2);
                if (db <= 0.0) {
                    for (int r = 0; r < 3 + min(wh_nBall, 0); r++) {
                        float sx = (sa * db - sb * da) / (db - da);
                        float dx = fr_dist(i, fr_path(rowv, v, sx, sigEnd).xyz, cb, perp2, e1, e2);
                        if (dx > 0.0) { sa = sx; da = dx; } else { sb = sx; db = dx; }
                    }
                    return sb;
                }
                sa = sb;
                da = db;
            }
        }
        s = s1;
        q = q1;
        d = fr_dist(i, q, cb, perp2, e1, e2);
    }
    return -1.0;
}
#endif

#if defined(KERNEL_WORLD) || defined(KERNEL_TOYS)

// The row's texture coordinate for angle alpha: the grid below the split in [0, 0.5), above in
// [0.5, 1), each kept half a row inside its own (the grids are not neighbours in alpha).
float fr_row(float alpha, vec4 rows) {
    bool up = alpha >= rows.y;
    float d = max(up ? alpha - rows.y : rows.y - alpha, 0.0);
    float span = max(up ? rows.z - rows.y : rows.y - rows.x, 1e-7);
    float x = clamp(fr_warp(d, span), 0.5 / float(FR_HALF), 1.0 - 0.5 / float(FR_HALF));
    return ((up ? 1.0 : 0.0) + x) * 0.5;
}

// wh_trace with the curved part from view v's tables: what the ray ends on.
WhEnd fr_trace(float l0, vec3 n0, float vl, vec3 w, int v) {
    float side = l0 > 0.0 ? 1.0 : -1.0;
    vec3 x = vec3(0.0);
    vec3 d = vec3(0.0);
    float dist = 0.0;
    int kind = -1;
    float fl = 0.0;
    vec3 fn = vec3(1.0, 0.0, 0.0);
    vec3 col = vec3(0.0);
    vec3 nrm = vec3(0.0, 0.0, 1.0);
#ifdef WH_ARROWS
    vec3 slc = vec3(-1.0);
#endif
    // the ray's plane: e1 the eye's n, e2 its direction's part across (as wh_curved)
    vec3 we = w + 1e-7 * (abs(n0.x) < 0.9 ? vec3(0.0, n0.z, -n0.y) : vec3(-n0.z, 0.0, n0.x));
    vec3 e2 = we * inversesqrt(dot(we, we));
    float wn = min(dot(w, e2), 1.0);
    vec3 e1 = n0;
    bool curved = abs(l0) < wh_Lsh();
    bool withShell = !curved;
    if (!curved) {
        x = wh_M(side, (abs(l0) - wh_Lsh() + wh_Rout()) * n0);
        d = wh_M(side, side * vl * n0 + w);
    }
    for (int seg = 0; seg < 2; seg++) {
        if (curved) {
            if (seg == 1) {
                // after the straight part: the direction at the eye again, from d (vl and w are not
                // held through that part's tests: registers)
                vec3 md = wh_M(side, d);
                vl = side * dot(md, n0);
                w = md - side * vl * n0;
                we = w + 1e-7 * (abs(n0.x) < 0.9 ? vec3(0.0, n0.z, -n0.y) : vec3(-n0.z, 0.0, n0.x));
                e2 = we * inversesqrt(dot(we, we));
                wn = min(dot(w, e2), 1.0);
            }
            float rowv = fr_row(wh_atan2(wn, vl), fr_rows[v]);
            vec4 E = texture(fr_tabE, vec3(rowv, 0.25, float(v)));  // psi out, s out, side, psi in
            float psiF = wh_atan2(e1.z, -e2.z);                     // n.z = 0 there: the floor
            bool floorHit = psiF < E.x;
#ifdef WH_NO_SHELL_TOYS
            // a movable object within reach of the ray's subspace (wh_curved's candidates)
            for (int i = wh_bIdx.x; i < wh_bIdx.w; i++) {
                vec4 Cb = wh_ball[i];
                float c1 = dot(Cb.xyz, e1);
                float c2 = dot(Cb.xyz, e2);
                if (dot(Cb.xyz, Cb.xyz) - c1 * c1 - c2 * c2 < wh_ballCol[i].w * wh_ballCol[i].w) sh_toys = 1u;
            }
            for (int i = wh_cIdx.x; i < wh_cIdx.w; i++) {
                vec4 Cc = wh_cube[i];
                float rad = 2.0 * wh_cubeCol[i].w;
                float c1 = dot(Cc.xyz, e1);
                float c2 = dot(Cc.xyz, e2);
                if (dot(Cc.xyz, Cc.xyz) - c1 * c1 - c2 * c2 < rad * rad) sh_toys = 1u;
            }
#endif
#ifdef KERNEL_TOYS
            // the movable objects within reach of the shell, along the path, up to the floor
            vec4 E1 = texture(fr_tabE, vec3(rowv, 0.75, float(v)));    // the search's length, the length before
            float send = E1.x;
            if (floorHit)
                send = min(send, texture(fr_tabF, vec3(psiF / WH_PI * float(FR_COLS - 1) / float(FR_COLS) + 0.5 / float(FR_COLS), rowv, float(v))).y - E1.y);
            int hitI = -1;
            for (int i = wh_bIdx.x; i < wh_bIdx.w + wh_cIdx.w - wh_cIdx.x; i++) {
                bool isCube = i >= wh_bIdx.w;
                int k = isCube ? i - wh_bIdx.w + wh_cIdx.x : i;
                vec4 C = isCube ? wh_cube[k] : wh_ball[k];
                float size = isCube ? wh_cubeCol[k].w : wh_ballCol[k].w;
                float reach = isCube ? 2.0 * size : size;
                vec3 cb = vec3(dot(C.xyz, e1), dot(C.xyz, e2), C.w);
                float perp2 = dot(C.xyz, C.xyz) - cb.x * cb.x - cb.y * cb.y;
                if (perp2 >= reach * reach) continue;
                float sh = fr_search(isCube ? WH_MAXB + k : k, rowv, v, E1.x, send, cb, max(perp2, 0.0), size, e1, e2);
                if (sh >= 0.0 && sh < send) {
                    send = sh;
                    hitI = isCube ? WH_MAXB + k : k;
                }
            }
            if (hitI >= 0) {
                // as wh_trace's: the normal the R^4 offset from the centre projected onto the space,
                // a cube's the face's (its largest body-axis coordinate)
                vec4 Q = fr_path(rowv, v, send, E1.x);
                float hl = Q.w;
                vec3 hn = (Q.x * e1 + Q.y * e2) * inversesqrt(Q.x * Q.x + Q.y * Q.y);
                vec4 pr = wh_prof(hl);
                bool isCube = hitI >= WH_MAXB;
                int ci = hitI - WH_MAXB;
                vec4 N4 = vec4(pr.x * hn, pr.y) - (isCube ? wh_cube[ci] : wh_ball[hitI]);
                dist = E1.y + send;
                if (isCube) {
                    col = wh_cubeLook(ci, N4, dist);
                    vec3 sd = vec3(dot(N4, wh_cubeE[5 * ci]), dot(N4, wh_cubeE[5 * ci + 1]), dot(N4, wh_cubeE[5 * ci + 2]));
                    vec3 ad = abs(sd);
                    int k = ad.x >= ad.y && ad.x >= ad.z ? 0 : (ad.y >= ad.z ? 1 : 2);
                    N4 = (sd[k] >= 0.0 ? 1.0 : -1.0) * wh_cubeE[5 * ci + k];
                } else {
                    col = wh_ballCol[hitI].rgb;
                }
                float rad = dot(N4.xyz, hn);
                side = hl >= 0.0 ? 1.0 : -1.0;
                kind = 2;
                nrm = normalize(wh_M(side, side * (pr.z * rad + pr.w * N4.w) * hn + N4.xyz - rad * hn));
                // the ray ends there: the arrows' surface counts up to it (below)
                floorHit = false;
                E.x = wh_atan2(Q.y, Q.x);
            }
#endif
#ifdef WH_ARROWS
            if (slc.z < 0.0) {
                // n.x = 0: the first zero in the shell, unless the ray ends first (wh_curved)
                float sx = e1.x >= 0.0 ? 1.0 : -1.0;
                float psiS = wh_atan2(abs(e1.x), -sx * e2.x);
                if (psiS >= E.w && psiS < (floorHit ? psiF : E.x)) {
                    vec2 ls = texture(fr_tabF, vec3(psiS / WH_PI * float(FR_COLS - 1) / float(FR_COLS) + 0.5 / float(FR_COLS), rowv, float(v))).xy;
                    vec3 nS = cos(psiS) * e1 + sin(psiS) * e2;
                    slc = vec3(ls.x, wh_atan2(nS.z, nS.y), ls.y);
                }
            }
#endif
#ifdef KERNEL_TOYS
            if (kind == 2) break;
#endif
            if (floorHit) {
                vec2 ls = texture(fr_tabF, vec3(psiF / WH_PI * float(FR_COLS - 1) / float(FR_COLS) + 0.5 / float(FR_COLS), rowv, float(v))).xy;
                kind = 1;
                fl = ls.x;
                fn = (e1.z * e2 - e2.z * e1) * inversesqrt(e1.z * e1.z + e2.z * e2.z);
                dist = ls.y;
                break;
            }
            // leaves the shell where the path has turned by psi out, into universe E.z
            float c = cos(E.x);
            float sn = sin(E.x);
            vec3 n = c * e1 + sn * e2;
            vec3 tt = c * e2 - sn * e1;
            float bR = fr_eye[5 * v + 4].x * wn / wh_Rout();
            side = E.z > 0.0 ? 1.0 : -1.0;
            x = wh_M(side, wh_Rout() * n);
            d = wh_M(side, sqrt(max(1.0 - bR * bR, 0.0)) * n + bR * tt);
            dist = E.y;
            curved = false;
            withShell = false;
            seg = 1;
        }
        WhHit h = wh_traceFlat(side, x, d, withShell);
#ifdef WH_ARROWS
        float tS = -x.x / (abs(d.x) > 1e-9 ? d.x : 1e-9);
        if (slc.z < 0.0 && tS > 0.0 && tS < h.t) {
            vec3 q = x + tS * d;
            float iq = inversesqrt(dot(q, q));
            slc = vec3(side * (dot(q, q) * iq - wh_Rout() + wh_Lsh()), wh_atan2(q.z, q.y), dist + tS);
        }
#endif
        if (h.kind == 3) {
            // into the shell: the tables go on from the eye, with the same plane
            curved = true;
            continue;
        }
        vec3 q = x + h.t * d;
        if (h.kind == 0) {
            kind = 0;
        } else if (h.kind == 1) {
            kind = 1;
            float iq = inversesqrt(dot(q, q));
            fn = wh_M(side, q) * iq;
            fl = side * (dot(q, q) * iq - wh_Rout() + wh_Lsh());
            dist += h.t;
        } else {
            kind = 2;
            col = h.col;
            nrm = h.nrm;
            dist += h.t;
#ifndef WH_NO_BALLS
            if (h.kind == 5) col = wh_cubeLook(h.idx, vec4(wh_M(side, q), side * wh_h) - wh_cube[h.idx], dist);
#endif
        }
        break;
    }
    if (kind == 1) side = fl > 0.0 ? 1.0 : -1.0;
    WhEnd e;
    e.kind = kind; e.side = side; e.fl = fl; e.fn = fn; e.col = col; e.nrm = nrm; e.d = d; e.dist = dist;
#ifdef WH_ARROWS
    e.slc = slc;
#endif
    return e;
}
#endif

#if defined(KERNEL_WORLD) || defined(KERNEL_TOYS)
// A ray per invocation, 16 x 8 of them a group (one wave of 128 on the Frame's GPU), in quads of
// 2 x 2 as a fragment shader's: the grid's screen derivatives are the quad's differences, through
// shared memory. Foveation: the picture is split into blocks of 64 x 32 pixels, each traced in
// cells of cs = (1, 2 or 4) x (1, 2 or 4) pixels by the ring (fr_rings) its middle is in, a ray
// through each cell's middle, its colour over the cell; a block takes (4 / cs.x) x (4 / cs.y) of
// the groups laid out over it, the others have nothing to do.
layout(local_size_x = 16, local_size_y = 8, local_size_z = 1) in;
shared vec2 sh_g[128];
// the groups for the toys kernel: the dispatch's group count (x, 1, 1), then each group's (x, y,
// view)
layout(set = 0, binding = 3, std430) restrict buffer Tiles { uvec4 fr_tiles[]; };

// Group wg's cells: their size cs and where its first one starts (p0, pixels); false: none.
bool fr_cells(uvec3 wg, out ivec2 cs, out ivec2 p0) {
    int v = int(wg.z);
    ivec2 blk = ivec2(wg.xy) >> 2;              // 4 x 4 groups' places a block
    ivec2 sub = ivec2(wg.xy) & 3;
    vec2 mid = (vec2(blk) + 0.5) * vec2(64.0, 32.0);
    vec2 q = (mid - fr_gaze[v].xy) / (0.5 * vec2(fr_size.xy));
    float r = length(q);
    cs = ivec2(1);
    for (int k = 0; k < fr_size.w; k++) {
        if (r < fr_rings[k].x) { cs = ivec2(fr_rings[k].yz); break; }
    }
    p0 = blk * ivec2(64, 32) + sub * ivec2(16, 8) * cs;
    return all(lessThan(sub * cs, ivec2(4))) && all(lessThan(p0, fr_size.xy));
}

// The ray of the cell at p0 + cs * this invocation's place (pixels, size cs) of view v, traced and
// shaded (the group's invocations together: the derivatives), stored over the cell.
void fr_cell(ivec2 p0, ivec2 cs, int v) {
    ivec2 sz = fr_size.xy;
    ivec2 px = p0 + ivec2(gl_LocalInvocationID.xy) * cs;
    vec4 E0 = fr_eye[5 * v];
    vec4 f0 = fr_eye[5 * v + 1];
    vec4 f1 = fr_eye[5 * v + 2];
    vec4 f2 = fr_eye[5 * v + 3];
    // this cell's ray: the line from the eye through its middle unprojected onto the near plane
    // (depth 0: fr_invProj maps depths 0..1, near to far), turned into play space and onto the
    // eye's axes
    vec2 ndc = (vec2(min(px, sz - 1)) + 0.5 * vec2(cs)) / vec2(sz) * 2.0 - 1.0;
    vec4 pa = fr_invProj[v] * vec4(ndc, 0.0, 1.0);
    vec3 pd = mat3(fr_cam) * (pa.xyz / pa.w - fr_eyeOff[v].xyz);
    vec4 V = normalize(pd.x * f0 + pd.y * f1 + pd.z * f2);
    WhEnd e = fr_trace(E0.x, E0.yzw, V.x, V.yzw, v);
    vec2 g = wh_gridAt(e);
    uint li = gl_LocalInvocationIndex;
    sh_g[li] = g;
    barrier();
    // the quad's differences, right minus left and lower minus upper, as a fine derivative
    uint lx = gl_LocalInvocationID.x;
    uint ly = gl_LocalInvocationID.y;
    vec2 gdx = sh_g[(ly << 4) | (lx | 1u)] - sh_g[(ly << 4) | (lx & ~1u)];
    vec2 gdy = sh_g[((ly | 1u) << 4) | lx] - sh_g[((ly & ~1u) << 4) | lx];
    vec4 c = vec4(wh_shadeEnd(e, g, gdx, gdy), 1.0);
    px = p0 + ivec2(gl_LocalInvocationID.xy) * cs;
    for (int j = 0; j < cs.y; j++)
        for (int i = 0; i < cs.x; i++) {
            ivec2 q = px + ivec2(i, j);
            if (all(lessThan(q, sz))) imageStore(fr_out, ivec3(q, v), c);
        }
}
#endif

#ifdef KERNEL_WORLD
void main() {
    ivec2 cs;
    ivec2 p0;
    if (!fr_cells(gl_WorkGroupID, cs, p0)) return;
#ifdef WH_NO_SHELL_TOYS
    if (gl_LocalInvocationIndex == 0u) sh_toys = 0u;
    barrier();
#endif
    fr_cell(p0, cs, int(gl_WorkGroupID.z));
#ifdef WH_NO_SHELL_TOYS
    barrier();
    if (gl_LocalInvocationIndex == 0u && (sh_toys != 0u || fr_whole != 0)) {
        uint k = atomicAdd(fr_tiles[0].x, 1u);
        fr_tiles[k + 1u] = uvec4(gl_WorkGroupID, 0u);
    }
#endif
}
#endif

#ifdef KERNEL_TOYS
// The groups the world kernel listed, again, with the search for the movable objects.
void main() {
    uvec3 wg = fr_tiles[gl_WorkGroupID.x + 1u].xyz;
    ivec2 cs;
    ivec2 p0;
    fr_cells(wg, cs, p0);
    fr_cell(p0, cs, int(wg.z));
}
#endif
