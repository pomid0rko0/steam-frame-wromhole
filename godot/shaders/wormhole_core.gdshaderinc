// Wormhole renderer core: plain GLSL that is also valid Godot shading language (one source for
// both). The including file declares the uniforms (wormhole_view.gdshaderinc); what they hold:
//   wh_sph, wh_pil, wh_box  scene.json's static objects (which universe each is in: Tracer._fits_shader)
//   wh_ball, wh_cube        movable balls' and cubes' centres as points of R^4 (xyz, w)
//   wh_ballCol              (rgb, radius)
//   wh_fball                each ball in a flat universe: the sphere the sheet cuts from it, in that
//                           universe's chart (centre, radius squared)
//   wh_bIdx, wh_cIdx        the balls' and cubes' index ranges by region (Tracer.region_order)
//   wh_cubeE                five per cube: its four axes of R^4 (three body axes tangent to the space,
//                           then the normal) over the half size, then dot(centre, axis) for the four; a
//                           point P is inside when |dot(P, axis) - dot(centre, axis)| < 1 for all four
//   wh_cubeCol              (rgb, half size)
//   wh_bound                bounding spheres of the balls in A, in B, of the cubes in A, in B (centre,
//                           radius; < 0: none): a flat universe's ray that misses one tests none of them
//   wh_pix                  a pixel's angle: the soft edges of the cubes' edge lines and of the arrows
//   wh_tab...               the fillet polynomials by impact parameter (WormholeSpace.fillet_table)
//   grav_*                  the gravity view's constants (WormholeSpace.gravity_shader)
// WH_NO_BALLS leaves the balls' and cubes' code out, WH_GRAVITY colours the floor by gravity,
// WH_ARROWS adds the field's arrows.
//
// The space, its profile r(l), w(l) (Lc, L, th0, Rout) and the method: docs/geometry.md (here:
// "curved part").
//
// Manifold point: (l, n), n unit 3-vector. Tangent vector: (vl, w), w orthogonal to n.
// Point in R^4: E = (r n, w(l)). Flat charts: side A (l >= L): x = r n;  side B: x = P r n, P = diag(-1,1,1).
// The floor: n.z = 0 (z = 0 in both charts).
//
// Godot's shading language reserves E, PI and TAU: a local named so is a compile error that GLSL
// (ref/) accepts. Constants reach the GPU as Godot's shader compiler prints them, with 14 decimals
// (rtos in f2sp0, servers/rendering/shader_compiler.cpp): 1e-20 becomes 0.0, the smallest non-zero
// it prints is 1e-14, so a guard against dividing by zero is at least that (ref/ compiles this file
// as GLSL, where a smaller one would still guard). GPUs' max and min return the other operand for a
// NaN, which hides most NaNs.
//
// The compiler (Mesa's ir3 for the Frame's Adreno 750; tools/adreno_stats.sh shows what it makes):
// - Registers go to the heaviest point of the code, run or not: code for something not in view
//   still costs (hence a shader per combination: tracer.gd), and a short loop with a constant bound
//   is unrolled, a break or not, a long one is not (wh_curved: its it loop short, its j loop long).
//   Registers per pixel decide how many waves run (adreno_stats.sh).
// - An if becomes selects, even around a square root: every lane pays. A loop of one pass with a
//   bound the compiler can't see (k < 1 + min(wh_nBall, 0)) stays a branch that waves skip; the
//   same trick stops unrolling (k < 4 + min(wh_nCube, 0)).
// - Loop-invariant code is not hoisted, equal expressions are merged: a value computed before a
//   loop is held through it; computed again where it is used, from values held anyway, it is not.
// - A branch that skips work loses when its divergence costs more than the work (a bounding ball
//   before each of world B's static boxes; their one test is the boxes' top, wh_traceFlat). Near
//   the throat one group of pixels holds both skies, the floor and objects, and runs every branch
//   of the shading.
// - A screen derivative is a texture-unit (cat5) instruction, not an ALU one (tools/ir3_emu.py
//   counts them apart).
// - 16-bit math (mediump) issues at twice the rate in waves of 128 (tools/adreno_cost.py); line
//   coordinates need float32.
//
// A change here: ref/test_gpu.py prints errors, no verdict: compare with the same run on the code
// before (WH_BALLS=0 too), and try a pose at an odd width (the middle column has vl = 0) and
// viewpoints scanned around an object, which its poses may miss. Keep ref/wh.py's fast in step. A change that should not touch the compiled shader must
// give the same programs (tools/same_programs.py). Then tools/adreno_cost.sh --check. Speed:
// bench.gd.

const float WH_PI = 3.14159265358979;
const int WH_MAXB = 12;
const float WH_STEP = 0.35;      // the toys' search: its steps along a path, in the object's size
const int WH_SAMPLES = 160;      // and at most this many a piece

float wh_Lc() { return max(wh_h - wh_fillet, 0.0); }
float wh_th0() { return asin(max(1.0 - wh_h / wh_fillet, 0.0)); }
float wh_Lsh() { return wh_Lc() + wh_fillet * (0.5 * WH_PI - wh_th0()); }
float wh_Rout() { return wh_rho0 + wh_fillet; }

// profile at l: (r, w, dr/dl, dw/dl)
vec4 wh_prof(float l) {
    float al = abs(l);
    float sg = l >= 0.0 ? 1.0 : -1.0;
    float L = wh_Lsh();
    float Lc = wh_Lc();
    if (al >= L) return vec4(al - L + wh_Rout(), sg * wh_h, sg, 0.0);
    if (al <= Lc) return vec4(wh_rho0, l, 0.0, 1.0);
    float th = wh_th0() + (al - Lc) / wh_fillet;
    return vec4(wh_rho0 + wh_fillet * (1.0 - cos(th)), sg * (wh_h - wh_fillet + wh_fillet * sin(th)), sg * sin(th), cos(th));
}

float wh_r(float l) { return wh_prof(l).x; }

vec3 wh_M(float side, vec3 v) { return side > 0.0 ? v : vec3(-v.x, v.y, v.z); }

// atan(y, x) at any scale (it takes the ratio of the smaller to the larger): one range reduction and
// a minimax polynomial. The built-in atan reduces twice and guards against huge arguments.
float wh_atan2(float y, float x) {
    float ax = abs(x);
    float ay = abs(y);
    float t = min(ax, ay) / max(max(ax, ay), 1e-12);
    float t2 = t * t;
    float t4 = t2 * t2;
    // in pairs (Estrin): a shorter chain of dependent steps than one product after another
    float p = t * ((0.999977219 - 0.332622826 * t2) + t4 * ((0.193540363 - 0.116426447 * t2)
            + t4 * (0.052647312 - 0.0117191196 * t2)));
    p = ay > ax ? 0.5 * WH_PI - p : p;
    p = x < 0.0 ? WH_PI - p : p;
    return y < 0.0 ? -p : p;
}

// asin, for the sky's latitude lines and the toys' search window: pi/2 - sqrt(1 - |x|) P(|x|), no
// division
float wh_asin(float x) {
    float a = min(abs(x), 1.0);
    float p = (1.57079153 - 0.214280613 * a) + a * a * ((0.0856383856 - 0.0376182282 * a) + 0.00973297445 * a * a);
    float r = 0.5 * WH_PI - sqrt(1.0 - a) * p;
    return x < 0.0 ? -r : r;
}

// The values of a ray's start point that do not depend on its direction: (r, r - rmin), the
// second as a product (no cancellation near the fillet's inner end). The same for every pixel
// of an eye: the view shader computes them per eye (wh_renderE's eye argument).
vec2 wh_eye(float l) {
    float th0 = wh_th0();
    float ths = th0 + max(abs(l) - wh_Lc(), 0.0) / wh_fillet;
    return vec2(wh_r(l), 2.0 * wh_fillet * sin(0.5 * (ths + th0)) * sin(0.5 * (ths - th0)));
}

#ifndef WH_NO_BALLS
// Where the chord q -> q + D enters cube i's box: the chord's fraction, or -1 (also when it starts
// inside). The chord lies in the ray's subspace of R^4, span(e1, e2, the w axis): points
// q = (u, v, w) there are u e1 + v e2 + w e_w. Slab by slab, keeping only the interval so far.
float wh_chordInCube(int i, vec3 q, vec3 D, vec3 e1, vec3 e2, vec3 cb, float perp2) {
    // first the box's bounding ball (radius: half diagonal, 2 half sizes), at the chord's point
    // nearest to its centre: most chords pass it by. cb: the centre seen in the subspace, perp2:
    // its distance from it, squared
    vec3 a = q - cb;
    float rb = 2.0 * wh_cubeCol[i].w;
    float B = dot(a, D);
    float A = dot(D, D);
    float tm = clamp(-B / max(A, 1e-12), 0.0, 1.0);
    if (dot(a, a) + perp2 - rb * rb + tm * (2.0 * B + tm * A) > 0.0) return -1.0;
    float tin = 0.0;
    float tout = 1.0;
    bool inside = true;
    for (int k = 0; k < 4 + min(wh_nCube, 0); k++) {
        vec4 Ek = wh_cubeE[5 * i + k];
        vec3 ek = vec3(dot(Ek.xyz, e1), dot(Ek.xyz, e2), Ek.w);    // the axis seen in the subspace
        // the offset read here, not the cube's four before the loop: they would be held through
        // it, and picked by k
        float a0 = dot(q, ek) - wh_cubeE[5 * i + 4][k];
        float dk = dot(D, ek);
        inside = inside && abs(a0) < 1.0;
        float idk = 1.0 / (abs(dk) > 1e-9 ? dk : 1e-9);
        float t0 = (-1.0 - a0) * idk;
        float t1 = (1.0 - a0) * idk;
        tin = max(tin, min(t0, t1));
        tout = min(tout, max(t0, t1));
    }
    return !inside && tin <= tout ? tin : -1.0;
}

// A cube's colour at the point X (relative to its centre, in R^4): darker along the edges, lines
// 0.07 of the half size wide, their edges soft over two pixels at the path length dist
vec3 wh_cubeLook(int i, vec4 X, float dist) {
    vec3 ad = abs(vec3(dot(X, wh_cubeE[5 * i]), dot(X, wh_cubeE[5 * i + 1]), dot(X, wh_cubeE[5 * i + 2])));
    float m1 = max(max(ad.x, ad.y), ad.z);
    float m3 = min(min(ad.x, ad.y), ad.z);
    float e = 1.0 - (ad.x + ad.y + ad.z - m1 - m3);    // to the nearest edge, in half sizes
    float fw = min(dist * wh_pix / wh_cubeCol[i].w, 0.05);
    float line = 1.0 - smoothstep(0.07 - fw, 0.07 + fw, e);
    return wh_cubeCol[i].rgb * (1.0 - 0.55 * line);
}
#endif

#ifdef WH_GRAVITY
// ---------------------------------------------------------------- gravity
// The potential is g f(l) n_z (docs/gravity.md), f in the three pieces WormholeSpace.gravity_shader
// gives. (f / r, d(f / r)/dl, f') at l: f / r is the strength of gravity on the floor, in g.
vec3 wh_grav(float l) {
    float al = abs(l);
    float sg = l < 0.0 ? -1.0 : 1.0;
    float L = wh_Lsh();
    float Lc = wh_Lc();
    if (al >= L) {
        float rr = al - L + wh_Rout();
        float b = grav_cyl.w / (rr * rr * rr);
        return vec3(1.0 + b, -3.0 * b / rr * sg, (1.0 - 2.0 * b) * sg);
    }
    if (al <= Lc) {
        float e = exp(grav_cyl.y * al);
        float ie = 1.0 / e;
        return vec3(0.5 * grav_cyl.x * (e + ie), 0.5 * grav_cyl.x * grav_cyl.y * (e - ie) * sg,
                    0.5 * grav_cyl.z * (e - ie) * sg);
    }
    float is = 1.0 / (L - Lc);
    float x = (al - Lc) * is;
    vec4 a = grav_g[0];
    vec4 b = grav_g[1];
    float g = a.x + x * (a.y + x * (a.z + x * (a.w + x * (b.x + x * (b.y + x * (b.z + x * b.w))))));
    float dg = a.y + x * (2.0 * a.z + x * (3.0 * a.w + x * (4.0 * b.x + x * (5.0 * b.y + x * (6.0 * b.z + x * 7.0 * b.w)))));
    vec4 c = grav_d[0];
    vec4 e = grav_d[1];
    float fp = c.x + x * (c.y + x * (c.z + x * (c.w + x * (e.x + x * (e.y + x * (e.z + x * e.w))))));
    return vec3(g, dg * is * sg, fp * sg);
}

// optozorax's palette (docs/gravity.md, «Показ»); bands of 0.1 g
// below 1 g and of a tenth of a decade above. wh_gravBand(g) is the band coordinate.
float wh_gravBand(float g) {
    return g < 1.0 ? 10.0 * g : 10.0 + 4.342944819 * log(g);
}

vec3 wh_gravColour(float t) {
    float band = floor(t);
    float u = clamp((band + 0.5) / 10.0, 0.0, 1.0);
    vec3 c = u < 0.5 ? mix(vec3(0.03, 0.03, 0.10), vec3(0.45, 0.08, 0.50), u * 2.0)
                     : mix(vec3(0.45, 0.08, 0.50), vec3(0.95, 0.40, 0.12), u * 2.0 - 1.0);
    c = mix(c, vec3(0.95, 0.80, 0.18), smoothstep(0.85, 0.95, u));
    if (t >= 10.0) {
        float v = clamp((band - 9.5) / 10.0, 0.0, 1.0);
        c = v < 0.5 ? mix(vec3(0.95, 0.80, 0.18), vec3(0.95, 0.12, 0.05), v * 2.0)
                    : mix(vec3(0.95, 0.12, 0.05), vec3(1.0), v * 2.0 - 1.0);
    }
    return c;
}

// The floor in the colour of its gravity: the band's colour, darker at the bands' edges (the
// contours), the checker kept as brightness. q.x is the floor point's l, fw the screen footprint
// of q (wh_renderE): the band coordinate depends on l alone, so its footprint is its slope times fw.x.
vec3 wh_gravFloor(vec2 q, vec2 fw) {
    vec2 cell = floor(q);
    float chk = mix(0.5, mod(cell.x + cell.y, 2.0), 1.0 - clamp(max(fw.x, fw.y) - 0.5, 0.0, 1.0));
    vec3 G = wh_grav(q.x);
    float t = wh_gravBand(G.x);
    float dt = abs(G.y) * (G.x < 1.0 ? 10.0 : 4.342944819 / G.x) * fw.x;
    float edge = clamp(abs(fract(t + 0.5) - 0.5) / max(dt, 1e-4), 0.0, 1.0);
    return wh_gravColour(t) * (0.8 + 0.2 * edge) * (0.85 + 0.15 * chk);
}

#ifdef WH_ARROWS
const float WH_ARROW_REACH = 4.5;     // arrows up to this far outside the shell

// The arrows of the field on the surface n.x = 0 (x = 0 in both charts, through the throat), above
// the floor (0 < a < pi). At the point (l, n), n = (0, cos a, sin a): the arrow of the nearest
// node, on the rings l = k (1 m apart), spaced about 1 m along each half circle; the surface's
// metric there is dl^2 + r(l)^2 da^2. Length 0.6 m at 1 g, colour the palette. foot: a pixel's size
// there (m), for soft edges. Returns colour and coverage.
vec4 wh_arrow(float l, float a, float foot) {
    if (a <= 0.0 || abs(l) > wh_Lsh() + WH_ARROW_REACH) return vec4(0.0);
    float lk = round(l);
    float rk = wh_r(lk);
    float N = max(1.0, round(WH_PI * rk));
    float j = min(floor(a * N / WH_PI), N - 1.0);
    float aj = (j + 0.5) * WH_PI / N;
    vec3 G = wh_grav(lk);
    // the field at the node, along l and along a (unit vectors), in g
    vec2 g = vec2(-G.z * sin(aj), -G.x * cos(aj));
    float gm = length(g);
    vec2 u = g / max(gm, 1e-6);
    vec2 q = vec2(l - lk, rk * (a - aj));
    float s = dot(q, u);
    float c = abs(dot(q, vec2(-u.y, u.x)));
    float len = 0.6 * min(gm, 1.4);
    float hl = min(0.3, 0.6 * len);       // the head's length
    float hw = 0.13;                      // the head's half width
    float sw = 0.035;                     // the shaft's half width
    float s0 = 0.5 * len - hl;
    float dShaft = max(c - sw, max(-0.5 * len - s, s - s0));
    float dHead = max(s0 - s, ((s - s0) * hw + (c - hw) * hl) * inversesqrt(hw * hw + hl * hl));
    float d = min(dShaft, dHead);
    float f = max(foot, 1e-4);
    float cover = clamp(0.5 - d / f, 0.0, 1.0);
    float rim = clamp(0.5 - (d + 0.02) / f, 0.0, 1.0);    // a dark outline
    vec3 col = mix(vec3(0.02), 1.15 * wh_gravColour(wh_gravBand(gm)), rim);
    return vec4(col, gm > 1e-4 ? 0.92 * cover : 0.0);
}
#endif
#endif

// ---------------------------------------------------------------- curved part
// A fillet in u, sig, F and dv as docs/geometry.md («Почему луч считается быстро», 3) has them;
// the path length is dlength = G dv with G = r^2 / b F. F is interpolated by a polynomial in
// tau = (u - ua) / (0.5 - ua) in [0, 1] (4 nodes: squares of the Gauss-Legendre nodes on [0, 1]),
// and its moments against the exact weight, int t^k w(t) dt, are elementary (G, the path length,
// is estimated instead: wh_filLen):
//   w(t) = 1 / (2 sqrt((t + al)(t + ga)))     (regime 0)
// ua is where the fillet path starts: the turning point u = sig, or the fillet's inner end s0^2.
// One of al, ga is 0 unless h < R. The moments come from a recursion that is stable while al and ga
// are below 1; where one of them is 1 or more, its factor 1 / sqrt(t + al or ga) is smooth on
// [0, 1] and is moved into the interpolated part instead (regimes 1 and 2). No loops, the same
// cost for every ray; the floor crossing is a Newton solve on the closed form. z is the variable in
// which that solve and the toys' search run: z = int w dt in regime 0, sqrt(t + mn) in regimes 1
// and 2. The method's accuracy: docs/geometry.md, «Точность».
// WormholeSpace.fillet_table works the polynomial out by b (its nodes and the matrix to the
// coefficients: _TAU, _A) and the shader samples it.
const float WH_TABN = 256.0;     // knots per row of wh_tab (WormholeSpace.TABLE_N)

struct WhFil {
    vec4 e;                // psi integrand (times the factor moved out of the weight), powers of tau
    float ib;              // 1 / b
    float al; float ga; float mn; float mx;
    int reg;
    float E0;              // sqrt(al) + sqrt(ga)
    float zlo; float zhi;  // z at tau = 0 and 1
    float psi; float arc;  // the whole fillet, tau 0 -> 1
    float ra; float span;  // r = ra + span tau
};

// min(al, ga) and |al - ga|: with movable objects worked out where used, not held through their
// search
float wh_mn(WhFil f) {
#ifdef WH_NO_BALLS
    return f.mn;
#else
    return min(f.al, f.ga);
#endif
}

float wh_dm(WhFil f) {
#ifdef WH_NO_BALLS
    return f.mx - f.mn;
#else
    return abs(f.al - f.ga);
#endif
}

// regime 0: the moments from z, tau and S = sqrt((t + al)(t + ga))
vec4 wh_filRec(WhFil f, float z, float t, float S) {
    float B = f.al + f.ga;
    float C = f.al * f.ga;
    float D0 = 2.0 * z;
    float D1 = S - sqrt(C) - 0.5 * B * D0;
    float tS = t * S;
    float D2 = 0.5 * (tS - 1.5 * B * D1 - C * D0);
    float D3 = (tS * t - 2.5 * B * D2 - 2.0 * C * D1) / 3.0;
    return 0.5 * vec4(D0, D1, D2, D3);
}

// tau and the moments int_0^tau t^k w dt, k = 0..3, at z
void wh_filMom(WhFil f, float z, out float t, out vec4 m) {
    if (f.reg == 0) {
        float Es = f.E0 * exp(z);                      // sqrt(t + al) + sqrt(t + ga)
        float sm = 0.5 * (Es - wh_dm(f) / Es);         // sqrt(t + mn)
        t = max(sm * sm - wh_mn(f), 0.0);
        m = wh_filRec(f, z, t, sm * (Es - sm));
    } else {
        float mn = wh_mn(f);
        t = max(z * z - mn, 0.0);
        if (f.reg == 1) {                              // w = 1 / (2 sqrt(t + mn))
            // int_0^t w dt = sqrt(t + mn) - sqrt(mn) = z - zlo. As t / (z + zlo) it would be 0 / 0 at
            // a turning ray's turning point (z = zlo = 0), where the toys' search samples: a NaN
            // there blinds the rest of the ray (a crack in toys near the shell's edge)
            float n0 = max(z - f.zlo, 0.0);
            float ty = t * z;
            float n1 = (ty - 2.0 * mn * n0) / 3.0;
            ty *= t;
            float n2 = (ty - 4.0 * mn * n1) / 5.0;
            m = vec4(n0, n1, n2, (ty * t - 6.0 * mn * n2) / 7.0);
        } else {                                       // w = 1/2
            float t2 = t * t;
            m = vec4(0.5 * t, 0.25 * t2, t2 * t / 6.0, 0.125 * t2 * t2);
        }
    }
}

// z at tau = t and the moments there
float wh_filMomT(WhFil f, float t, out vec4 m) {
    if (f.reg == 0) {
        float sa = sqrt(t + f.al);
        float sg = sqrt(t + f.ga);
        float z = log((sa + sg) / f.E0);
        m = wh_filRec(f, z, t, sa * sg);
        return z;
    }
    float z = sqrt(t + wh_mn(f));
    float tz;
    wh_filMom(f, z, tz, m);
    return z;
}

float wh_poly(vec4 c, float t) { return c.x + t * (c.y + t * (c.z + t * c.w)); }

// The path length from the fillet's inner end, m the moments there, as an estimate: r^2 / b times
// psi (r^2 / b is the length per angle), r taken at the weight's mean tau; the shader then holds one
// polynomial less. The fog, the cubes' edge lines, the arrows and the number of samples of the
// movable objects' search (wh_curved) use it. Their hits are ordered by where on the path they are
// (piece and fraction of it), not by length.
float wh_filLen(WhFil f, vec4 m) {
    // m.y <= m.x (tau in [0, 1]): below the floor the ratio only gets smaller; m.x is 0 at the
    // fillet's inner end and at a turning point
    float re = f.ra + f.span * m.y / max(m.x, 1e-12);
    return re * re * dot(f.e, m) * f.ib;
}

// the fillet of a ray with impact parameter b; turn: it turns around inside the fillet (b > rmin)
WhFil wh_fil(float b, bool turn, float rmin) {
    WhFil f;
    float rho0 = wh_rho0;
    float R = wh_fillet;
    f.ra = turn ? b : rmin;
    f.span = max(wh_Rout() - f.ra, 1e-6 * R);
    f.al = ((turn ? b : rmin) - rho0) / f.span;
    f.ga = turn ? 0.0 : (rmin - b) / f.span;
    f.mn = min(f.al, f.ga);
    f.mx = max(f.al, f.ga);
    // Of al and ga only one is the ray's own: a passing ray's al is that of every passing ray, and a
    // turning ray's ga is 0. So one square root per ray gives both roots.
    float sq = sqrt(turn ? f.al : f.ga);
    float sal = turn ? sq : sqrt((rmin - rho0) / max(wh_Rout() - rmin, 1e-6 * R));   // uniforms only
    float sga = turn ? 0.0 : sq;
    f.E0 = max(sal + sga, 1e-6);
    // f.e depends on b alone: sampled from the row of b's regime (the regime is taken from the row,
    // so that the moments match the table), with the factor the table leaves out put back
    int row = turn ? (b >= wh_tabLo.w ? 3 : 2) : (b >= wh_tabLo.y ? 1 : 0);
    vec3 rw = turn ? (row == 3 ? vec3(wh_tabLo.w, wh_tabInv.w, wh_tabReg.w) : vec3(wh_tabLo.z, wh_tabInv.z, wh_tabReg.z))
                   : (row == 1 ? vec3(wh_tabLo.y, wh_tabInv.y, wh_tabReg.y) : vec3(wh_tabLo.x, wh_tabInv.x, wh_tabReg.x));
    f.reg = int(rw.z);
    float x = clamp((b - rw.x) * rw.y, 0.0, WH_TABN - 1.0);
    vec4 et = textureLod(wh_tab, vec2((x + 0.5) / WH_TABN, (float(row) + 0.5) * 0.25), 0.0);
    f.e = f.reg == 0 ? et : et * inversesqrt(f.mx * (f.reg == 2 ? f.mn : 1.0));
    // b is 0 for a ray along the radius exactly: f.e is 0 then, and the fillet's length estimate
    // (wh_filLen) comes out 0, short by the fillet's arc, instead of 0 times infinity
    f.ib = 1.0 / max(b, 1e-12);
    f.zlo = f.reg == 0 ? 0.0 : min(sal, sga);    // sqrt(mn)
    vec4 m;
    f.zhi = wh_filMomT(f, 1.0, m);
    f.psi = dot(f.e, m);
    f.arc = wh_filLen(f, m);
    return f;
}

// (psi, path length) from the fillet's inner end to z
vec2 wh_filAt(WhFil f, float z, out float t) {
    vec4 m;
    wh_filMom(f, z, t, m);
    return vec2(dot(f.e, m), wh_filLen(f, m));
}

// z where psi from the inner end reaches T (Newton from the linear guess; psi(z) is smooth and
// increasing; ref/test_gpu.py measures the paths it gives against RK4)
float wh_filSolve(WhFil f, float T) {
    float z = mix(f.zlo, f.zhi, clamp(T / max(f.psi, 1e-12), 0.0, 1.0));
    for (int it = 0; it < 2; it++) {
        float t; vec4 m;
        wh_filMom(f, z, t, m);
        float dz = wh_poly(f.e, t) * (f.reg == 2 ? z : 1.0);    // dpsi/dz
        z = clamp(z - (dot(f.e, m) - T) / max(dz, 1e-12), f.zlo, f.zhi);
    }
    return z;
}

// profile point at tau: (l, w)
vec2 wh_filLW(WhFil f, float t, float side) {
    float R = wh_fillet;
    float s = sqrt(clamp((f.ra + f.span * t - wh_rho0) / (2.0 * R), 0.0, 0.5));
    return side * vec2(wh_Lc() + R * (2.0 * asin(s) - wh_th0()),
                       wh_h - R + 2.0 * R * s * sqrt(1.0 - s * s));
}

#ifndef WH_NO_BALLS
// (cos, sin) of a + dp from those of a (c, s), for |dp| up to 0.6 (to 1e-7 there): no
// transcendental. The movable objects' search turns its angle by steps of at most that
vec2 wh_rot(float c, float s, float dp) {
    float d2 = dp * dp;
    float cd = 1.0 + d2 * (-0.5 + d2 * (1.0 / 24.0 + d2 * (-1.0 / 720.0 + d2 * (1.0 / 40320.0))));
    float sd = dp * (1.0 + d2 * (-1.0 / 6.0 + d2 * (1.0 / 120.0 + d2 * (-1.0 / 5040.0))));
    return vec2(c * cd - s * sd, s * cd + c * sd);
}

// The point at the fraction q of piece p of wh_curved's path (0, 2 the fillets from z0 to z1 on side
// side, 1 the cylinder): (psi, r, w in R^4, path length per unit of q there). On a fillet that is
// dpsi/dz (wh_filSolve) times r^2 / b (the length per angle) times dz/dq.
vec4 wh_pathAt(WhFil f, int p, float q, float z0, float z1, float side, vec2 PA, vec2 PB, float C0x,
               float x0B, float DB, float d) {
    if (p == 1) return vec4(PA.x + PB.x * q, wh_rho0, d * (x0B + DB * q), PB.y);
    float R = wh_fillet;
    float z = mix(z0, z1, q);
    float t; vec4 m;
    wh_filMom(f, z, t, m);
    float ps = dot(f.e, m);
    float r = f.ra + f.span * t;
    float cth = wh_rho0 + R - r;           // R cos th
    return vec4(p == 0 ? PA.x - ps : PA.x + PB.x - C0x + ps, r, side * (wh_h - R + sqrt(max(R * R - cth * cth, 0.0))),
                abs(z1 - z0) * r * r * f.ib * wh_poly(f.e, t) * (f.reg == 2 ? z : 1.0));
}

// How far the point Q = (u, v, w) of the subspace u e1 + v e2 + w e_w is from toy i at least, in
// R^4 (negative inside): a ball's distance; a cube's largest distance outside one of its slabs
// (the cube's search, wh_curved). cb, perp2: the toy's centre seen in the subspace and its distance
// from it, squared.
float wh_toyDist(bool isCube, int i, vec3 Q, vec3 cb, float perp2, float size, vec3 e1, vec3 e2) {
    if (!isCube) {
        vec3 a = Q - cb;
        return sqrt(dot(a, a) + perp2) - size;
    }
    vec3 X = Q.x * e1 + Q.y * e2;          // the point in R^4: (X, Q.z)
    vec4 o = wh_cubeE[5 * i + 4];
    vec4 a = vec4(dot(X, wh_cubeE[5 * i].xyz), dot(X, wh_cubeE[5 * i + 1].xyz), dot(X, wh_cubeE[5 * i + 2].xyz),
                  dot(X, wh_cubeE[5 * i + 3].xyz))
             + Q.z * vec4(wh_cubeE[5 * i].w, wh_cubeE[5 * i + 1].w, wh_cubeE[5 * i + 2].w, wh_cubeE[5 * i + 3].w) - o;
    a = abs(a);
    return (max(max(a.x, a.y), max(a.z, a.w)) - 1.0) * size;
}
#endif

// Ray starting inside (or on the boundary of) the shell, |ls| <= L. Returns
//   0: leaves the shell, given in flat chart coordinates (outSide, outX, outD)
//   1: hits the floor at (hitL, hitN)        2: enters ball ballI at (hitL, hitN)
//      (ballI >= WH_MAXB: cube ballI - WH_MAXB)
// arc = path length travelled inside the shell. WH_ARROWS: if slc.z < 0 (none found before), the
// first crossing of the arrows' surface n.x = 0 before the ray's end goes into slc: (l, the angle
// of n from +y toward +z, path length from the eye), dist0 being the path length before the shell.
// The path: piece A, a fillet travelled inward from the start (to the throat, or to the turning
// point); piece B, the cylinder; piece C, a fillet travelled outward to the shell's edge. Both
// fillets have the same profile, so one WhFil serves both.
int wh_curved(float ls, vec3 ns, float vl, vec3 w, vec2 eye,
              out float hitL, out vec3 hitN, out int ballI,
              out float outSide, out vec3 outX, out vec3 outD, out float arc
#ifdef WH_ARROWS
              , inout vec3 slc, float dist0
#endif
              ) {
    float rho0 = wh_rho0;
    float R = wh_fillet;
    float Lc = wh_Lc();
    float th0 = wh_th0();
    float Rout = wh_Rout();
    float s0 = sin(0.5 * th0);
    float rmin = rho0 + 2.0 * R * s0 * s0;
    float als = abs(ls);
    // the orbit plane's second axis and |w| from one inverse square root. A ray along the radius
    // (w = 0) takes an axis orthogonal to n: the 1e-7 of it moves any ray's direction by 1e-7 rad
    vec3 we = w + 1e-7 * (abs(ns.x) < 0.9 ? vec3(0.0, ns.z, -ns.y) : vec3(-ns.z, 0.0, ns.x));
    vec3 e2 = we * inversesqrt(dot(we, we));
    // |w| <= 1 (the ray is a unit vector): rounded above 1, a ray along the throat's cylinder
    // (b = rho0 = rmin) would count as turning in a fillet it is not in
    float wn = min(dot(w, e2), 1.0);
    float rs = eye.x;                // wh_eye(ls)
    float b = rs * wn;
    vec3 e1 = ns;
    hitL = 0.0; hitN = vec3(0.0); ballI = -1;
    outX = vec3(0.0); outD = vec3(0.0);

    bool turn = b > rmin;
    WhFil f = wh_fil(b, turn, rmin);
    // the start point's tau (when it is on a fillet)
    bool fromEdge = als >= wh_Lsh() * (1.0 - 1e-6);
    float ts = turn ? rs * vl * vl / (1.0 + wn)     // r_s - b
                    : eye.y;                        // r_s - rmin
    float zs = f.zhi;
    vec2 Ss = vec2(f.psi, f.arc);           // inner end -> start
    if (!fromEdge) {
        vec4 ms;
        zs = wh_filMomT(f, clamp(ts / f.span, 0.0, 1.0), ms);
        Ss = vec2(dot(f.e, ms), wh_filLen(f, ms));
    }

    // pieces
    float d = vl >= 0.0 ? 1.0 : -1.0;       // passing: direction of travel in l
    float x = ls * d;                        // passing: oriented coordinate, runs to +L
    float sideS = ls > 0.0 ? 1.0 : -1.0;
    bool hasA = turn ? vl * sideS < 0.0 : x < -Lc;
    bool hasB = !turn && Lc > 0.0 && x < Lc;
    bool cFromStart = turn ? !hasA : x > Lc;   // piece C starts at the start point
    float sideA = turn ? sideS : -d;
    float sideC = turn ? sideS : d;
    outSide = sideC;
    float x0B = max(x, -Lc);
    float DB = hasB ? Lc - x0B : 0.0;
    float wc = b / rho0;
    // 1 / the radial velocity on the cylinder, 1 / sqrt(1 - wc^2), with rho0^2 - b^2 as
    // (rho0 - b)(rho0 + b) and rho0 - b = rs vl^2 / (1 + wn) - (rs - rho0): 1 - wc^2 itself cancels
    // for a ray that goes round the throat (small vl), and so would the floor's point of such
    // rays. rs - rho0 is eye.y (rmin = rho0 when there is a cylinder), R from the edge.
    float omb = rs * vl * vl / (1.0 + wn) - (fromEdge ? R : eye.y);
    float ivlc = rho0 * inversesqrt(max(omb * (rho0 + b), 1e-14 * rho0 * rho0));
    float kc = wc / rho0 * ivlc;
    vec2 PA = hasA ? Ss : vec2(0.0);                       // (psi, path length) of each piece
    vec2 PB = vec2(kc, ivlc) * DB;
    vec2 C0 = cFromStart ? Ss : vec2(0.0);                 // piece C starts here on the fillet
    vec2 PC = vec2(f.psi, f.arc) - C0;
    vec2 tot = PA + PB + PC;

    // first crossing of the floor in the orbit plane, n = cos psi e1 + sin psi e2: n.z starts
    // positive and its zeros are pi apart, so the ray meets the floor in the shell if it turns by pi
    // or more, or if n.z is negative where it leaves. Only those rays need the crossing's angle.
    float ct = cos(tot.x);
    float st = sin(tot.x);
    bool floorHit = ns.z > 0.0 && (tot.x >= WH_PI || ns.z * ct + e2.z * st < 0.0);

#ifdef WH_ARROWS
    if (slc.z < 0.0) {
        // n.x = 0 along (cos psi, sin psi) = (-e2.x, e1.x) * sign(e1.x) / |.|: the first zero, as
        // the floor's, unless the ray ends first (on the floor, or by leaving the shell)
        float sx = e1.x >= 0.0 ? 1.0 : -1.0;
        float psiS = wh_atan2(abs(e1.x), -sx * e2.x);
        if (psiS < (floorHit ? wh_atan2(e1.z, -e2.z) : tot.x)) {
            float lS; float aS;
            if (psiS >= PA.x && psiS < PA.x + PB.x) {
                float xS = (psiS - PA.x) / max(kc, 1e-12);
                lS = d * (x0B + xS);
                aS = PA.y + xS * ivlc;
            } else {
                bool inA = psiS < PA.x;
                float T = inA ? PA.x - psiS : C0.x + psiS - PA.x - PB.x;
                float t; vec4 m;
                wh_filMom(f, wh_filSolve(f, clamp(T, 0.0, f.psi)), t, m);
                lS = wh_filLW(f, t, inA ? sideA : sideC).x;
                aS = (inA ? PA.y : PA.y + PB.y - C0.y) + (inA ? -1.0 : 1.0) * wh_filLen(f, m);
            }
            vec3 nS = cos(psiS) * e1 + sin(psiS) * e2;
            slc = vec3(lS, wh_atan2(nS.z, nS.y), dist0 + aS);
        }
    }
#endif

#ifndef WH_NO_BALLS
    // Balls and cubes this ray can reach: the whole ray lies in span(e1, e2, w-axis) of R^4, so
    // one whose centre is farther than its reach (a ball's radius, a cube's half diagonal, two half
    // sizes) from that subspace is never hit. Only those within reach of the shell are looked at
    // (wh_bIdx.x .. .w, wh_cIdx.x .. .w: Tracer.set_objects sorts them by where they are). Each
    // candidate is searched on its own, only where the path can come within its reach:
    //  - in r = |xyz| and in w: the chord distance in R^4 is at least either difference. On a
    //    fillet r and w grow together, so the w bounds are r bounds there, and r is linear in tau;
    //  - in the angle psi in the ray's plane: the object's shadow on that plane is a disc around
    //    the centre's projection, radius sqrt(reach^2 - (distance from the subspace)^2), and a
    //    point at angle psi can lie in it only within asin(radius / the projection's distance) of
    //    the projection's angle. The whole path in the shell turns by less than pi (it meets the
    //    floor by then), so one window. On the cylinder psi is linear along the path: there it
    //    bounds the samples (a ray looking sideways in the throat winds round it slowly in l, and
    //    with r and w alone a ball in the throat would be within reach for metres of its path); on a
    //    fillet psi grows along the piece too, and the window's ends are solved for z.
    // There the path is sampled at steps of WH_STEP of the object's radius or half size (at most
    // WH_SAMPLES of them a piece, longer steps past that); between two samples
    // the ray is taken as the chord in R^4: where the chord enters the object, the path's point at
    // that fraction (one more sample) is the hit, if it lies in the object or within the chord's
    // sag of it (step^2 / 8 min(R, rho0), plus 0.1 mm). So a ray that only
    // grazes one, or meets the floor right after entering it, still finds it, and a long chord of a
    // ray that winds round the throat cannot cut across an object the path passes by. Only entries
    // count: a ray that starts inside one does not see it from inside. Hits are ordered by where
    // on the path they are, 2 (piece - 1) + fraction (as keyEnd), and each search ends at the
    // nearest one so far.
    int cand = 0;          // bit i: ball i is in reach; bit 16 + i: cube i
    for (int i = wh_bIdx.x; i < wh_bIdx.w; i++) {
        vec4 Cb = wh_ball[i];
        float rad = wh_ballCol[i].w;
        float c1 = dot(Cb.xyz, e1);
        float c2 = dot(Cb.xyz, e2);
        if (dot(Cb.xyz, Cb.xyz) - c1 * c1 - c2 * c2 < rad * rad) cand |= 1 << i;
    }
    for (int i = wh_cIdx.x; i < wh_cIdx.w; i++) {
        vec4 Cc = wh_cube[i];
        float rad = 2.0 * wh_cubeCol[i].w;
        float c1 = dot(Cc.xyz, e1);
        float c2 = dot(Cc.xyz, e2);
        if (dot(Cc.xyz, Cc.xyz) - c1 * c1 - c2 * c2 < rad * rad) cand |= 1 << (16 + i);
    }
    if (cand != 0) {
        // where on the path the ray ends: 2 (piece - 1) + the fraction of it (piece 0 A from -2,
        // 1 B from 0, 2 C from 2; 4: the edge), as the hits are ordered. The cylinder's fraction
        // goes without an offset: a ray that winds round the throat meets things at small fractions
        // of it, whose digits 2 + q would lose (the floor's point and an object's normal off: white
        // dashes along the throat). The floor's point itself is worked out after the
        // search, from there, as an object's hit is: the search then holds fewer numbers.
        float keyEnd = 4.0;
        if (floorHit) {
            // n.z = 0 along (cos psi, sin psi) = (-e2.z, e1.z) / |.|: the first zero, sin psi > 0
            float psiF = wh_atan2(e1.z, -e2.z);
            if (psiF >= PA.x && psiF < PA.x + PB.x) {
                keyEnd = (psiF - PA.x) / max(kc * DB, 1e-12);
            } else {
                bool inA = psiF < PA.x;
                // psi from the fillet's inner end: piece A runs toward it, piece C away from it
                float T = inA ? PA.x - psiF : C0.x + psiF - PA.x - PB.x;
                float zF = wh_filSolve(f, clamp(T, 0.0, f.psi));
                float z0 = inA || cFromStart ? zs : f.zlo;
                float dz = (inA ? f.zlo : f.zhi) - z0;
                keyEnd = (inA ? -2.0 : 2.0) + clamp((zF - z0) / (abs(dz) > 1e-12 ? dz : 1e-12), 0.0, 1.0);
            }
        }
        float hitK = keyEnd;   // where the nearest hit so far is, or the ray's end
        int hitI = -1;         // its object: ball i, or WH_MAXB + cube i
        float Rk = min(R, rho0);                    // the path bends by at most 1 / Rk in R^4
        float dsMax = min(1.5 * Rk, 0.5 * rmin);    // a far step's longest chord
        for (int mm = cand; mm != 0; mm &= mm - 1) {
            int bit = findLSB(mm);
            bool isCube = bit >= 16;
            int i = isCube ? bit - 16 : bit;
            vec4 C = isCube ? wh_cube[i] : wh_ball[i];
            float size = isCube ? wh_cubeCol[i].w : wh_ballCol[i].w;
            float reach = isCube ? 2.0 * size : size;
            vec3 cb = vec3(dot(C.xyz, e1), dot(C.xyz, e2), C.w);   // the centre seen in the subspace
            float cc = dot(C.xyz, C.xyz);
            float perp2 = max(cc - cb.x * cb.x - cb.y * cb.y, 0.0);  // its distance from it, squared
            float rc = sqrt(cc);
            float rho2 = dot(cb.xy, cb.xy);
            float re2 = reach * reach - perp2;
            float psc = wh_atan2(cb.y, cb.x);
            psc = psc < -0.5 * WH_PI ? psc + 2.0 * WH_PI : psc;     // the copy that can meet [0, pi)
            float dps = re2 < rho2 ? wh_asin(sqrt(re2 / rho2)) : 10.0;
            float fine = WH_STEP * size;             // a fine step's path length
            for (int p = 0; p < 3; p++) {
                // piece p: a fillet from z0 to z1 (psi from the inner end grows with z along the
                // travel, or shrinks), or the cylinder (x0B .. x0B + DB)
                bool cyl = p == 1;
                if ((p == 0 && !hasA) || (cyl && !hasB)) continue;
                float qEnd = hitK - 2.0 * float(p - 1);  // the nearest hit so far, or the ray's end
                if (qEnd <= 0.0) break;
                float psi0 = p == 0 ? 0.0 : (cyl ? PA.x : PA.x + PB.x);    // the piece's psi range
                float psi1 = p == 0 ? PA.x : (cyl ? PA.x + PB.x : tot.x);
                if (psc + dps < psi0 || psc - dps > psi1) continue;
                bool pA = p == 0;
                float side = pA ? sideA : sideC;
                float z0 = pA || cFromStart ? zs : f.zlo;
                float z1 = pA ? f.zlo : f.zhi;
                // the windows: r from, to; w from, to (worked out here, not held through the search)
                vec4 win = vec4(rc - reach, rc + reach, cb.z - reach, cb.z + reach);
                // the piece's part in the windows, as fractions q of it: on the cylinder r = rho0,
                // w = l = d (x0B + DB q) and psi = psi0 + PB.x q; on a fillet r = rho0 + R (1 - cos th) and
                // side w = h - R + R sin th, both growing with th
                vec2 qw = vec2(2.0);
                if (cyl) {
                    vec2 pw = ((d > 0.0 ? win.zw : -win.wz) - x0B) / DB;
                    vec2 qa = PB.x > 1e-6 ? (vec2(psc - dps, psc + dps) - psi0) / PB.x : vec2(-1.0, 2.0);
                    if (rho0 >= win.x && rho0 <= win.y)
                        qw = vec2(max(min(pw.x, pw.y), qa.x), min(max(pw.x, pw.y), qa.y));
                } else {
                    vec2 y = (side > 0.0 ? win.zw : -win.wz) - (wh_h - R);     // R sin th at the w bounds
                    if (y.y >= 0.0 && y.x <= R) {
                        vec2 yc = clamp(y, 0.0, R);
                        vec2 rw = rho0 + R - sqrt(R * R - yc * yc);
                        vec2 tw = clamp((vec2(max(win.x, rw.x), y.y >= R ? win.y : min(win.y, rw.y)) - f.ra) / f.span, 0.0, 1.0);
                        // z at those tau (wh_filMomT without the moments)
                        vec2 zw = f.reg == 0 ? log((sqrt(tw + f.al) + sqrt(tw + f.ga)) / f.E0) : sqrt(tw + wh_mn(f));
                        float dz = z1 - z0;
                        vec2 qz = (zw - z0) / (abs(dz) > 1e-12 ? dz : 1e-12);
                        if (tw.y > tw.x) qw = vec2(min(qz.x, qz.y), max(qz.x, qz.y));
                    }
                }
                qw = vec2(max(qw.x, 0.0), min(min(qw.y, 1.0), qEnd));
                if (qw.y <= qw.x) continue;
                // the march through the window: P (psi, r, w, path length per q) at q, Q its point
                // (u, v, w) in the subspace, (cs, sn) the cosine and sine of its psi, g its distance
                float q = qw.x;
                vec4 P = wh_pathAt(f, p, q, z0, z1, side, PA, PB, C0.x, x0B, DB, d);
                float cs = cos(P.x);
                float sn = sin(P.x);
                vec3 Q = vec3(P.y * cs, P.y * sn, P.z);
                float g = wh_toyDist(isCube, i, Q, cb, perp2, size, e1, e2);
                float dsdq = max(P.w, 1e-3);         // the path length per q for the next step
                for (int j = 0; j < WH_SAMPLES; j++) {
                    if (q >= qw.y) break;
                    bool far = g > fine;
                    float q1 = min(q + (far ? min(0.9 * g, dsMax) : fine) / dsdq, qw.y);
                    vec4 P1 = wh_pathAt(f, p, q1, z0, z1, side, PA, PB, C0.x, x0B, DB, d);
                    vec2 r1 = wh_rot(cs, sn, P1.x - P.x);
                    vec3 Q1 = vec3(P1.y * r1.x, P1.y * r1.y, P1.z);
                    vec3 D = Q1 - Q;
                    float c2 = dot(D, D);
                    if (far) {
                        // the path from Q to Q1 is no longer than c (1 + c^2 / 12 Rk^2) (a curve that
                        // bends by at most 1 / Rk, c the chord up to 1.5 Rk; its length is below pi Rk,
                        // as psi grows by less than pi and r and w go one way along a piece): within
                        // g, it cannot reach the toy. Else the same step again, half as long
                        float k = 1.0 + c2 / (12.0 * Rk * Rk);
                        if (c2 * k * k > g * g || c2 > dsMax * dsMax) {
                            dsdq *= 2.0;
                            continue;
                        }
                    }
                    // a fine step: where the chord enters the toy (a loop of one pass, a branch
                    // that waves of far steps skip)
                    float tc = -1.0;
                    for (int u = 0; u < (far ? 0 : 1) + min(wh_nBall, 0); u++) {
                        if (!isCube) {
                            vec3 a = Q - cb;
                            // two samples at the same point: no chord, no entry
                            float A = max(c2, 1e-12);
                            float B = dot(a, D);
                            float Cq = dot(a, a) + perp2 - size * size;
                            float disc = B * B - A * Cq;
                            tc = Cq > 0.0 && disc >= 0.0 ? (-B - sqrt(max(disc, 0.0))) / A : -1.0;
                        } else {
                            tc = wh_chordInCube(i, Q, D, e1, e2, cb, perp2);
                        }
                    }
                    // the path's point at that fraction: the hit, if it lies in the toy or within
                    // the chord's sag of it
                    for (int u = 0; u < (tc >= 0.0 && tc <= 1.0 ? 1 : 0) + min(wh_nBall, 0); u++) {
                        float qh = mix(q, q1, tc);
                        vec4 Ph = wh_pathAt(f, p, qh, z0, z1, side, PA, PB, C0.x, x0B, DB, d);
                        vec2 rh = wh_rot(cs, sn, Ph.x - P.x);
                        float miss = wh_toyDist(isCube, i, vec3(Ph.y * rh.x, Ph.y * rh.y, Ph.z), cb, perp2, size, e1, e2);
                        float key = 2.0 * float(p - 1) + qh;
                        if (miss <= c2 / (8.0 * Rk) + 1e-4 && key < hitK) {
                            hitK = key;
                            hitI = isCube ? WH_MAXB + i : i;
                        }
                    }
                    q = q1;
                    P = P1;
                    Q = Q1;
                    cs = r1.x;
                    sn = r1.y;
                    dsdq = max(P1.w, 1e-3);
                    g = wh_toyDist(isCube, i, Q, cb, perp2, size, e1, e2);
                    if (2.0 * float(p - 1) + q > hitK) break;     // a hit before here (the later pieces end there too)
                }
            }
        }
        if (hitI >= 0 || floorHit) {
            // the hit's point (an object's, or the floor's), from where on the path it is
            int p = min(int(floor(0.5 * hitK)) + 1, 2);
            float q = hitK - 2.0 * float(p - 1);
            vec2 cum;
            if (p == 1) {
                float xh = DB * q;
                cum = PA + vec2(kc, ivlc) * xh;
                hitL = d * (x0B + xh);
            } else {
                float z0 = p == 0 ? zs : (cFromStart ? zs : f.zlo);
                float z1 = p == 0 ? f.zlo : f.zhi;
                float t;
                cum = (p == 0 ? PA : PA + PB - C0) + (p == 0 ? -1.0 : 1.0) * wh_filAt(f, mix(z0, z1, q), t);
                hitL = wh_filLW(f, t, p == 0 ? sideA : sideC).x;
            }
            hitN = cos(cum.x) * e1 + sin(cum.x) * e2;
            ballI = hitI;
            arc = cum.y;
            if (hitI < 0) return 1;
    #ifdef WH_ARROWS
            if (slc.z > dist0 + arc) slc = vec3(-1.0);     // the arrows' surface behind it
    #endif
            return 2;
        }
        // leaves the shell at its edge, on side sideC, worked out after the search from the half
        // angle: cos and sin of the whole turn are taken before it (floorHit), and the compiler
        // would merge the same expressions and hold them through the search
        float ch = cos(0.5 * tot.x);
        float sh = sin(0.5 * tot.x);
        float ce = ch * ch - sh * sh;
        float se = 2.0 * sh * ch;
        vec3 n = ce * e1 + se * e2;
        vec3 tt = ce * e2 - se * e1;
        float bR = b / Rout;
        outX = wh_M(outSide, Rout * n);
        outD = wh_M(outSide, sqrt(max(1.0 - bR * bR, 0.0)) * n + bR * tt);
        arc = tot.y;
        return 0;
    }
#endif
    // No movable object within reach (most rays), or no such objects at all: the floor's point,
    // or where it leaves the shell, straight away
    float arcEnd = tot.y;
    if (floorHit) {
        // the floor's psi and T as in the toys' search above
        float psiF = wh_atan2(e1.z, -e2.z);
        hitN = (e1.z * e2 - e2.z * e1) * inversesqrt(e1.z * e1.z + e2.z * e2.z);
        if (psiF >= PA.x && psiF < PA.x + PB.x) {
            float xF = (psiF - PA.x) / max(kc, 1e-12);
            hitL = d * (x0B + xF);
            arcEnd = PA.y + xF * ivlc;
        } else {
            bool inA = psiF < PA.x;
            // the path length is a0 + sa * (length from the inner end)
            float T = inA ? PA.x - psiF : C0.x + psiF - PA.x - PB.x;
            float sa = inA ? -1.0 : 1.0;
            float a0 = inA ? PA.y : PA.y + PB.y - C0.y;
            float side = inA ? sideA : sideC;
            float t; vec4 m;
            wh_filMom(f, wh_filSolve(f, clamp(T, 0.0, f.psi)), t, m);
            hitL = wh_filLW(f, t, side).x;
            arcEnd = a0 + sa * wh_filLen(f, m);
        }
    } else {
        // leaves the shell at its edge, on side sideC
        vec3 n = ct * e1 + st * e2;
        vec3 tt = ct * e2 - st * e1;
        float bR = b / Rout;
        outX = wh_M(outSide, Rout * n);
        outD = wh_M(outSide, sqrt(max(1.0 - bR * bR, 0.0)) * n + bR * tt);
    }
    arc = arcEnd;
    return floorHit ? 1 : 0;
}

// ---------------------------------------------------------------- moving an observer
// The geodesic equation with parallel transport: docs/geometry.md («Движение наблюдателя и
// предметов»).
vec4 wh_dU(vec4 U, vec3 v, vec3 n, float k, float r) {
    return vec4(k * dot(v, U.yzw), -k * U.x * v - dot(U.yzw, v) / r * n);
}

// Move (l, n) along the geodesic with initial unit direction dir for length len,
// transporting the frame f0, f1, f2. Two RK4 steps: meant for short moves (eye offsets).
void wh_geodesic(inout float l, inout vec3 n, vec4 dir, float len, inout vec4 f0, inout vec4 f1, inout vec4 f2) {
    vec4 V = dir;
    float h = 0.5 * len;
    for (int it = 0; it < 2; it++) {
        vec4 p = wh_prof(l);
        float k1r = p.z / p.x;
        float dl1 = V.x; vec3 dn1 = V.yzw / p.x;
        vec4 dV1 = wh_dU(V, V.yzw, n, k1r, p.x);
        vec4 d01 = wh_dU(f0, V.yzw, n, k1r, p.x); vec4 d11 = wh_dU(f1, V.yzw, n, k1r, p.x); vec4 d21 = wh_dU(f2, V.yzw, n, k1r, p.x);

        float l2 = l + 0.5 * h * dl1; vec3 n2 = n + 0.5 * h * dn1; vec4 V2 = V + 0.5 * h * dV1;
        vec4 g0 = f0 + 0.5 * h * d01; vec4 g1 = f1 + 0.5 * h * d11; vec4 g2 = f2 + 0.5 * h * d21;
        p = wh_prof(l2); float k2r = p.z / p.x;
        float dl2 = V2.x; vec3 dn2 = V2.yzw / p.x;
        vec4 dV2 = wh_dU(V2, V2.yzw, n2, k2r, p.x);
        vec4 d02 = wh_dU(g0, V2.yzw, n2, k2r, p.x); vec4 d12 = wh_dU(g1, V2.yzw, n2, k2r, p.x); vec4 d22 = wh_dU(g2, V2.yzw, n2, k2r, p.x);

        float l3 = l + 0.5 * h * dl2; vec3 n3 = n + 0.5 * h * dn2; vec4 V3 = V + 0.5 * h * dV2;
        g0 = f0 + 0.5 * h * d02; g1 = f1 + 0.5 * h * d12; g2 = f2 + 0.5 * h * d22;
        p = wh_prof(l3); float k3r = p.z / p.x;
        float dl3 = V3.x; vec3 dn3 = V3.yzw / p.x;
        vec4 dV3 = wh_dU(V3, V3.yzw, n3, k3r, p.x);
        vec4 d03 = wh_dU(g0, V3.yzw, n3, k3r, p.x); vec4 d13 = wh_dU(g1, V3.yzw, n3, k3r, p.x); vec4 d23 = wh_dU(g2, V3.yzw, n3, k3r, p.x);

        float l4 = l + h * dl3; vec3 n4 = n + h * dn3; vec4 V4 = V + h * dV3;
        g0 = f0 + h * d03; g1 = f1 + h * d13; g2 = f2 + h * d23;
        p = wh_prof(l4); float k4r = p.z / p.x;
        float dl4 = V4.x; vec3 dn4 = V4.yzw / p.x;
        vec4 dV4 = wh_dU(V4, V4.yzw, n4, k4r, p.x);
        vec4 d04 = wh_dU(g0, V4.yzw, n4, k4r, p.x); vec4 d14 = wh_dU(g1, V4.yzw, n4, k4r, p.x); vec4 d24 = wh_dU(g2, V4.yzw, n4, k4r, p.x);

        l += h / 6.0 * (dl1 + 2.0 * dl2 + 2.0 * dl3 + dl4);
        n = normalize(n + h / 6.0 * (dn1 + 2.0 * dn2 + 2.0 * dn3 + dn4));
        V += h / 6.0 * (dV1 + 2.0 * dV2 + 2.0 * dV3 + dV4);
        f0 += h / 6.0 * (d01 + 2.0 * d02 + 2.0 * d03 + d04);
        f1 += h / 6.0 * (d11 + 2.0 * d12 + 2.0 * d13 + d14);
        f2 += h / 6.0 * (d21 + 2.0 * d22 + 2.0 * d23 + d24);
        // keep the tangential parts tangent to the new n (removes round-off only)
        V.yzw -= dot(V.yzw, n) * n; f0.yzw -= dot(f0.yzw, n) * n; f1.yzw -= dot(f1.yzw, n) * n; f2.yzw -= dot(f2.yzw, n) * n;
    }
}

// Flat chart point/direction on the shell boundary -> manifold state
void wh_enter(float side, vec3 x, vec3 d, out float l, out vec3 n, out float vl, out vec3 w) {
    n = wh_M(side, x) / length(x);
    vec3 md = wh_M(side, d);
    float rad = dot(md, n);
    l = side * wh_Lsh();
    vl = side * rad;
    w = md - rad * n;
}

// ---------------------------------------------------------------- flat scene
// Each static object is tested in turn and writes its normal and colour when it is the nearest so
// far; world B's boxes are skipped by rays that go up above all of them. The movable balls and
// cubes: only those of this universe, after their bounding spheres (wh_bound).
struct WhHit {
    float t;
    int kind;      // 0 none, 1 floor, 2 object, 3 shell, 4 ball, 5 cube
    int idx;       // ball or cube index
    vec3 nrm;
    vec3 col;
};

void wh_hitSphere(vec3 x, vec3 d, vec4 s, vec3 col, inout WhHit h) {
    vec3 oc = x - s.xyz;
    float bq = dot(oc, d);
    float cq = dot(oc, oc) - s.w * s.w;
    float disc = bq * bq - cq;
    if (disc < 0.0) return;
    float t = -bq - sqrt(disc);
    if (t > 1e-4 && t < h.t) { h.t = t; h.kind = 2; h.nrm = (x + t * d - s.xyz) / s.w; h.col = col; }
}

void wh_hitPillar(vec3 x, vec3 d, vec4 p, vec3 col, inout WhHit h) {
    vec2 oc = x.xy - p.xy;
    float A = dot(d.xy, d.xy);
    if (A < 1e-9) return;
    float B = dot(oc, d.xy);
    float C = dot(oc, oc) - p.z * p.z;
    float disc = B * B - A * C;
    if (disc < 0.0) return;
    float t = (-B - sqrt(disc)) / A;
    float zz = x.z + t * d.z;
    if (t > 1e-4 && t < h.t && zz > 0.0 && zz < p.w) {
        h.t = t; h.kind = 2; h.nrm = vec3((x.xy + t * d.xy - p.xy) / p.z, 0.0); h.col = col;
    }
    if (d.z < 0.0) {   // flat top
        float tt = (p.w - x.z) / d.z;
        vec2 q = x.xy + tt * d.xy - p.xy;
        if (tt > 1e-4 && tt < h.t && dot(q, q) < p.z * p.z) { h.t = tt; h.kind = 2; h.nrm = vec3(0.0, 0.0, 1.0); h.col = col; }
    }
}

void wh_hitBox(vec3 x, vec3 d, vec3 c, vec3 hs, vec3 col, inout WhHit h) {
    vec3 inv = 1.0 / d;
    vec3 t0 = (c - hs - x) * inv;
    vec3 t1 = (c + hs - x) * inv;
    vec3 tn = min(t0, t1);
    vec3 tf = max(t0, t1);
    float tin = max(max(tn.x, tn.y), tn.z);
    float tout = min(min(tf.x, tf.y), tf.z);
    if (tin > tout || tin < 1e-4 || tin >= h.t) return;
    h.t = tin; h.kind = 2; h.col = col;
    h.nrm = tin == tn.x ? vec3(-sign(d.x), 0.0, 0.0) : (tin == tn.y ? vec3(0.0, -sign(d.y), 0.0) : vec3(0.0, 0.0, -sign(d.z)));
}

WhHit wh_traceFlat(float side, vec3 x, vec3 d, bool withShell) {
    WhHit h;
    h.t = 1e9; h.kind = 0; h.idx = -1; h.nrm = vec3(0.0); h.col = vec3(0.0);
    if (d.z < 0.0) {
        float t = -x.z / d.z;
        if (t > 0.0) { h.t = t; h.kind = 1; h.nrm = vec3(0.0, 0.0, 1.0); }
    }
    // the boxes stand on the floor: a ray above the tallest one's top going up passes over all of
    // them (whole regions of the view at once: the sky). The pillars test themselves.
    if (side > 0.0) {
        wh_hitSphere(x, d, wh_sph[0], vec3(0.80, 0.15, 0.10), h);
        wh_hitSphere(x, d, wh_sph[1], vec3(0.95, 0.75, 0.15), h);
        wh_hitSphere(x, d, wh_sph[2], vec3(0.75, 0.75, 0.78), h);
        for (int i = 0; i < wh_pil.length(); i++) wh_hitPillar(x, d, wh_pil[i], vec3(0.85, 0.80, 0.70), h);
    } else {
        wh_hitSphere(x, d, wh_sph[3], vec3(0.75, 0.15, 0.70), h);
        wh_hitSphere(x, d, wh_sph[4], vec3(0.15, 0.75, 0.30), h);
        wh_hitSphere(x, d, wh_sph[5], vec3(0.20, 0.35, 0.85), h);
        float top = 0.0;
        for (int i = 0; i < wh_box.length(); i++) top = max(top, wh_box[i].z + wh_box[i].w);
        if (x.z < top || d.z < 0.0) {
            for (int i = 0; i < wh_box.length(); i++)
                wh_hitBox(x, d, wh_box[i].xyz, vec3(wh_box[i].w), vec3(0.90, 0.90, 0.95), h);
        }
    }
#ifndef WH_NO_BALLS
    // balls: the chord ball cut by this universe's sheet w = side*h is an ordinary sphere;
    // only entries count (a ray that starts inside a ball does not see it from inside)
    // The loops keep only the nearest one's distance and index (and a cube's face); its normal
    // and colour are worked out once after the loop.
    float sheet = side * wh_h;
    float bt = h.t;
    int bi = -1;
    // the bounding spheres of this universe's balls and cubes: a ray that misses one, or meets
    // it beyond what it already hit, tests none of them. The ray meets a sphere ahead (bq < 0)
    // from outside (cq > 0) at -bq - sqrt(bq^2 - cq), before t when -bq - t < sqrt(bq^2 - cq):
    // no square root for those it misses
    vec4 bb = wh_bound[side > 0.0 ? 0 : 1];
    vec3 ob = x - wh_M(side, bb.xyz);
    float bqb = dot(ob, d);
    float cqb = dot(ob, ob) - bb.w * bb.w;
    float dsb = bqb * bqb - cqb;
    float eb = -bqb - bt;
    bool nearB = bb.w > 0.0 && (cqb <= 0.0 || (bqb < 0.0 && dsb >= 0.0 && (eb < 0.0 || eb * eb < dsb)));
    // this universe's balls only (Tracer.set_objects sorts them: A's first, B's last), each as the
    // sphere its sheet cuts from it in this chart (wh_fball: centre, radius squared)
    for (int i = side > 0.0 ? 0 : wh_bIdx.z; i < (nearB ? (side > 0.0 ? wh_bIdx.y : wh_nBall) : 0); i++) {
        vec4 S = wh_fball[i];
        vec3 oc = x - S.xyz;
        float bq = dot(oc, d);
        float cq = dot(oc, oc) - S.w;
        float disc = bq * bq - cq;
        float e = -bq - bt;
        // a branch that waves whose rays all miss skip: the compiler turns an if into selects (the
        // root then taken for every ball), but not a loop (one pass: wh_nBall >= 0)
        if (cq > 0.0 && bq < 0.0 && disc >= 0.0 && (e < 0.0 || e * e < disc)) {
            for (int k = 0; k < 1 + min(wh_nBall, 0); k++) {
                bt = -bq - sqrt(disc);
                bi = i;
            }
        }
    }
    if (bi >= 0) {
        vec4 S = wh_fball[bi];
        h.t = bt; h.kind = 4; h.idx = bi;
        h.nrm = (x + bt * d - S.xyz) * inversesqrt(S.w);
        h.col = wh_ballCol[bi].rgb;
    }
    // cubes: the 4D box cut by this sheet is a convex solid bounded by four pairs of planes; entries
    // only
    vec3 md = wh_M(side, d);
    vec3 mx = wh_M(side, x);
    int bf = 0;                    // the nearest cube's entry face: axis k + 1, negative for -axis
    bi = -1;
    bb = wh_bound[side > 0.0 ? 2 : 3];
    ob = x - wh_M(side, bb.xyz);
    bqb = dot(ob, d);
    cqb = dot(ob, ob) - bb.w * bb.w;
    dsb = bqb * bqb - cqb;
    eb = -bqb - bt;
    bool nearC = bb.w > 0.0 && (cqb <= 0.0 || (bqb < 0.0 && dsb >= 0.0 && (eb < 0.0 || eb * eb < dsb)));
    for (int i = side > 0.0 ? 0 : wh_cIdx.z; i < (nearC ? (side > 0.0 ? wh_cIdx.y : wh_nCube) : 0); i++) {
        vec4 X = vec4(mx, sheet) - wh_cube[i];
        // first the box's bounding sphere in R^4 (radius: half diagonal, 2 half sizes)
        float rb = 2.0 * wh_cubeCol[i].w;
        float bs = dot(X.xyz, md);
        float cs = dot(X, X) - rb * rb;
        if (cs > 0.0 && (bs > 0.0 || bs * bs < cs)) continue;
        float tin = -1e30;
        float tout = 1e30;
        int face = 0;
        for (int k = 0; k < 4 + min(wh_nCube, 0); k++) {
            vec4 ax = wh_cubeE[5 * i + k];
            float A = dot(X, ax);
            float B = dot(md, ax.xyz);
            if (abs(B) < 1e-9) {
                if (abs(A) >= 1.0) tin = 1e30;    // parallel to this slab and outside it
                continue;
            }
            float t0 = (-1.0 - A) / B;
            float t1 = (1.0 - A) / B;
            if (min(t0, t1) > tin) { tin = min(t0, t1); face = B > 0.0 ? -(k + 1) : k + 1; }
            tout = min(tout, max(t0, t1));
        }
        if (tin <= tout && tin > 0.0 && tin < bt) { bt = tin; bi = i; bf = face; }
    }
    if (bi >= 0) {
        int k = abs(bf) - 1;
        h.t = bt; h.kind = 5; h.idx = bi;
        h.nrm = normalize(wh_M(side, (bf > 0 ? 1.0 : -1.0) * wh_cubeE[5 * bi + k].xyz));
        h.col = wh_cubeCol[bi].rgb;
    }
#endif
    if (withShell) {
        float R = wh_Rout();
        float bq = dot(x, d);
        float cq = dot(x, x) - R * R;
        float disc = bq * bq - cq;
        if (disc > 0.0) {
            float t = -bq - sqrt(disc);
            if (t > 0.0 && t < h.t) { h.t = t; h.kind = 3; }
        }
    }
    return h;
}

#ifndef WH_NO_BALLS
// ---------------------------------------------------------------- the stencil's mark
// Whether the ray from (l0, n0) along (vl, w) may meet a movable ball or cube anywhere on its way:
// stencil_mark.gdshader marks the pixels where it may, and only there the ray tracer with them runs
// (tracer.gd, «The stencil split»). A toy is met only
//  - near the ray's plane: the whole ray lies in span(e1, e2, w axis) of R^4 (wh_curved), the
//    straight parts outside the shell too, so a toy whose centre is farther than its reach from
//    that subspace is never met;
//  - within reach of the w the ray passes: w(l) grows with l, so a ray that does not turn round
//    in a fillet (b <= rmin) passes the w from its start to the sheet it goes to, and one that
//    turns those from its start, or from where it turns (r = b), to its own side's sheet;
//  - and from a flat universe, if the ray misses the shell: on its straight line, as one of that
//    universe's toys (each in its sphere in the chart, wh_traceFlat's).
// Reaches a thousandth larger, plus 0.1 mm, and a band round b = rmin taken both ways: the ray
// tracer works these out from where the ray enters the shell, with other round-off.
bool wh_mayMeetToy(float l0, vec3 n0, float vl, vec3 w) {
    float side = l0 > 0.0 ? 1.0 : -1.0;
    float h = wh_h;
    float R = wh_fillet;
    float b;               // the impact parameter
    float w0;              // w where the ray starts in the shell, or enters it
    bool inward = true;    // toward the throat there
    if (abs(l0) < wh_Lsh()) {
        vec4 pr = wh_prof(l0);
        b = pr.x * length(w);
        w0 = pr.y;
        inward = vl * side < 0.0;
    } else {
        vec3 x = wh_M(side, (abs(l0) - wh_Lsh() + wh_Rout()) * n0);
        vec3 d = wh_M(side, side * vl * n0 + w);
        float bq = dot(x, d);
        float Ro = 1.001 * wh_Rout() + 1e-4;
        float cq = dot(x, x) - Ro * Ro;
        bool shell = bq < 0.0 && bq * bq >= cq;
        // this universe's balls (the sphere its sheet cuts from each) and cubes (their bounding
        // spheres in R^4 cut by the sheet), along the line
        bool A = side > 0.0;
        for (int i = A ? 0 : wh_bIdx.z; i < (A ? wh_bIdx.y : wh_nBall); i++) {
            vec4 S = wh_fball[i];
            float rr = 1.001 * sqrt(max(S.w, 0.0)) + 1e-4;
            vec3 oc = x - S.xyz;
            float bb = dot(oc, d);
            float c = dot(oc, oc) - rr * rr;
            if (S.w > 0.0 && (c <= 0.0 || (bb < 0.0 && bb * bb >= c))) return true;
        }
        for (int i = A ? 0 : wh_cIdx.z; i < (A ? wh_cIdx.y : wh_nCube); i++) {
            vec4 Cc = wh_cube[i];
            float dw = side * h - Cc.w;
            float rb = 2.0 * wh_cubeCol[i].w;
            float rr = 1.001 * sqrt(max(rb * rb - dw * dw, 0.0)) + 1e-4;
            vec3 oc = x - wh_M(side, Cc.xyz);
            float bb = dot(oc, d);
            float c = dot(oc, oc) - rr * rr;
            if (c <= 0.0 || (bb < 0.0 && bb * bb >= c)) return true;
        }
        if (!shell) return false;
        b = length(cross(x, d));
        w0 = side * h;
    }
    // the w the path passes, [wlo, whi]
    float s0 = sin(0.5 * wh_th0());
    float rmin = wh_rho0 + 2.0 * R * s0 * s0;
    vec2 wr = vec2(-h, h);
    if (!inward) {
        wr = side > 0.0 ? vec2(w0, h) : vec2(-h, w0);
    } else if (b > 1.0001 * rmin + 1e-4) {
        float c = clamp(1.0 - (b - wh_rho0) / R, 0.0, 1.0);    // cos th where r = b
        float wt = h - R + R * sqrt(1.0 - c * c);
        wr = side > 0.0 ? vec2(min(wt, w0), h) : vec2(-h, max(-wt, w0));
    } else if (b < 0.9999 * rmin - 1e-4) {
        wr = side > 0.0 ? vec2(-h, w0) : vec2(w0, h);
    }
    // the subspace, as wh_curved takes it
    vec3 we = w + 1e-7 * (abs(n0.x) < 0.9 ? vec3(0.0, n0.z, -n0.y) : vec3(-n0.z, 0.0, n0.x));
    vec3 e2 = we * inversesqrt(dot(we, we));
    bool any = false;
    for (int i = 0; i < wh_nBall; i++) {
        vec4 c = wh_ball[i];
        float c1 = dot(c.xyz, n0);
        float c2 = dot(c.xyz, e2);
        float rr = 1.001 * wh_ballCol[i].w + 1e-4;
        any = any || (dot(c.xyz, c.xyz) - c1 * c1 - c2 * c2 < rr * rr && c.w + rr >= wr.x && c.w - rr <= wr.y);
    }
    for (int i = 0; i < wh_nCube; i++) {
        vec4 c = wh_cube[i];
        float c1 = dot(c.xyz, n0);
        float c2 = dot(c.xyz, e2);
        float rr = 2.002 * wh_cubeCol[i].w + 1e-4;
        any = any || (dot(c.xyz, c.xyz) - c1 * c1 - c2 * c2 < rr * rr && c.w + rr >= wr.x && c.w - rr <= wr.y);
    }
    return any;
}
#endif

// ---------------------------------------------------------------- shading
// Grid lines need screen-space derivatives (fwidth), which are only defined in uniform control
// flow: the line coordinates of the sky or the floor are computed for every pixel, their fwidth
// once, and passed in.
vec3 wh_sunDir(float side) {
    return side > 0.0 ? normalize(vec3(-0.6, 0.55, 0.18)) : normalize(vec3(0.35, -0.45, 0.82));
}

// The sky of either universe, one code for both (the GPU runs pixels of both skies together near
// the throat): A a sunset, B a day with a big moon. d: unit direction in the chart.
vec3 wh_sky(float side, vec3 d) {
    bool A = side > 0.0;
    float el = d.z;
    float sd = dot(d, wh_sunDir(side));
    vec3 col = mix(A ? vec3(1.00, 0.55, 0.25) : vec3(0.75, 0.88, 1.00),
                   A ? vec3(0.10, 0.12, 0.35) : vec3(0.15, 0.40, 0.90),
                   pow(clamp(el, 0.0, 1.0), A ? 0.45 : 0.6));
    float glow = max(sd, 0.0);         // A: the sun's glow, glow^8
    glow *= glow; glow *= glow;
    col += A ? vec3(0.6, 0.36, 0.18) * glow * glow : vec3(0.0);
    // the sun's disc: smoothstep(0.9990, 0.9995) in A, (0.9993, 0.9996) in B
    float t = clamp((sd - (A ? 0.9990 : 0.9993)) * (A ? 2000.0 : 1.0 / 0.0003), 0.0, 1.0);
    col += (A ? vec3(4.0, 3.6, 2.8) : vec3(4.0)) * (t * t * (3.0 - 2.0 * t));
    // B: the moon
    float mk = A ? 0.0 : smoothstep(0.9930, 0.9940, dot(d, normalize(vec3(-0.8, -0.3, 0.35))));
    col = mix(col, vec3(0.85, 0.85, 0.80) * (0.6 + 0.4 * d.z), mk);
    // below the horizon
    return mix(col, A ? vec3(0.35, 0.22, 0.15) : vec3(0.30, 0.35, 0.42), clamp(-el * 8.0, 0.0, 1.0));
}

// floor in intrinsic coordinates: q = (l, phi * 24 / 2pi), l the proper radial distance from the
// throat: 1 m rings, 24 spokes (drawn with the sky's lines in wh_renderE); checker cells, faded out
// when they get smaller than a pixel
vec3 wh_floor(vec2 q, vec2 fw) {
    vec2 cell = floor(q);
    float chk = mix(0.5, mod(cell.x + cell.y, 2.0), 1.0 - clamp(max(fw.x, fw.y) - 0.5, 0.0, 1.0));
    float sA = smoothstep(-0.5, 0.5, q.x);      // which universe the floor point belongs to
    vec3 baseA = mix(vec3(0.62, 0.42, 0.28), vec3(0.72, 0.52, 0.36), chk);
    vec3 baseB = mix(vec3(0.28, 0.34, 0.44), vec3(0.38, 0.45, 0.55), chk);
    return mix(baseB, baseA, sA);
}

vec3 wh_shade(float side, vec3 col, vec3 nrm) {
    float dif = max(dot(nrm, wh_sunDir(side)), 0.0);
    vec3 amb = side > 0.0 ? vec3(0.35, 0.30, 0.35) : vec3(0.35, 0.42, 0.55);
    vec3 sun = side > 0.0 ? vec3(1.2, 0.8, 0.55) : vec3(1.1, 1.1, 1.05);
    return col * (amb + sun * dif);
}

// ---------------------------------------------------------------- entry point
// Ray from an eye at manifold point (l0, n0) with manifold direction (vl, w), unit length;
// eye = wh_eye(l0).
// dbg receives geometry for testing: x = 2*kind + (side > 0 ? 1 : 0), then
//   kind 0 sky: final chart direction    kind 1 floor: (l, n.x, n.y)    kind 2 object: chart hit point
//   balls: x = 100 + index, cubes: x = 200 + index, then the hit point's R^4 xyz (= r n)
// The ray is traced first (flat, curved, flat) to what it ends on, and that is shaded once: in a
// wave of pixels that end on different things each kind of shading then runs once, not once per
// place in the trace where a ray can end (but a cube's colour, wh_cubeLook, is taken where its hit
// is found, in both places).
vec3 wh_renderE(float l0, vec3 n0, float vl, vec3 w, vec2 eye, out vec4 dbg) {
    float side = l0 > 0.0 ? 1.0 : -1.0;
    vec3 x = vec3(0.0);
    vec3 d = vec3(0.0);
    float dist = 0.0;
    bool inShell = abs(l0) < wh_Lsh();
    bool shellAhead = !inShell;     // a straight ray that has left the shell never re-enters it
    if (!inShell) {
        x = wh_M(side, (abs(l0) - wh_Lsh() + wh_Rout()) * n0);
        d = wh_M(side, side * vl * n0 + w);
    }
    // what the ray ends on: 0 sky (side, d), 1 floor (fl, fn), 2 a lit surface (side, col, nrm)
    int kind = -1;
    float fl = 0.0;
    vec3 fn = vec3(1.0, 0.0, 0.0);
    vec3 col = vec3(0.0);
    vec3 nrm = vec3(0.0, 0.0, 1.0);
    dbg = vec4(-1.0);
#ifdef WH_ARROWS
    vec3 slc = vec3(-1.0);          // the arrows' surface: (l, angle, path length), z < 0: none
#endif
    for (int seg = 0; seg < 2; seg++) {
        if (inShell) {
            float hl; vec3 hn; int bi; float arc;
            int ev = wh_curved(l0, n0, vl, w, eye, hl, hn, bi, side, x, d, arc
#ifdef WH_ARROWS
                               , slc, dist
#endif
                               );
            dist += arc;
            if (ev == 1) {
                kind = 1; fl = hl; fn = hn;
                dbg = vec4(hl > 0.0 ? 3.0 : 2.0, hl, hn.xy);
                break;
            }
#ifndef WH_NO_BALLS
            if (ev == 2) {
                // ball: normal = R^4 offset from the centre projected onto the tangent space;
                // cube: the normal of the face hit (the largest of its three body-axis coordinates),
                // projected the same way
                vec4 pr = wh_prof(hl);
                bool isCube = bi >= WH_MAXB;
                int ci = bi - WH_MAXB;
                vec4 N4 = vec4(pr.x * hn, pr.y) - (isCube ? wh_cube[ci] : wh_ball[bi]);
                if (isCube) {
                    col = wh_cubeLook(ci, N4, dist);
                    vec3 sd = vec3(dot(N4, wh_cubeE[5 * ci]), dot(N4, wh_cubeE[5 * ci + 1]), dot(N4, wh_cubeE[5 * ci + 2]));
                    vec3 ad = abs(sd);
                    int k = ad.x >= ad.y && ad.x >= ad.z ? 0 : (ad.y >= ad.z ? 1 : 2);
                    N4 = (sd[k] >= 0.0 ? 1.0 : -1.0) * wh_cubeE[5 * ci + k];
                } else {
                    col = wh_ballCol[bi].rgb;
                }
                float rad = dot(N4.xyz, hn);
                side = hl >= 0.0 ? 1.0 : -1.0;
                kind = 2;
                nrm = normalize(wh_M(side, side * (pr.z * rad + pr.w * N4.w) * hn + N4.xyz - rad * hn));
                dbg = vec4((isCube ? 200.0 + float(ci) : 100.0 + float(bi)), pr.x * hn);
                break;
            }
#endif
            inShell = false;
            shellAhead = false;
        }
        WhHit h = wh_traceFlat(side, x, d, shellAhead);
#ifdef WH_ARROWS
        // a straight segment's crossing of x = 0 before what it ends on
        float tS = -x.x / (abs(d.x) > 1e-9 ? d.x : 1e-9);
        if (slc.z < 0.0 && tS > 0.0 && tS < h.t) {
            vec3 p = x + tS * d;
            float ip = inversesqrt(dot(p, p));
            slc = vec3(side * (dot(p, p) * ip - wh_Rout() + wh_Lsh()), wh_atan2(p.z, p.y), dist + tS);
        }
#endif
        if (h.kind != 3) {
            vec3 p = x + h.t * d;
            if (h.kind == 0) {
                kind = 0;
                dbg = vec4(side > 0.0 ? 1.0 : 0.0, normalize(d));
            } else if (h.kind == 1) {
                kind = 1;
                float ip = inversesqrt(dot(p, p));
                fn = wh_M(side, p) * ip;
                fl = side * (dot(p, p) * ip - wh_Rout() + wh_Lsh());
                dist += h.t;
                dbg = vec4(side > 0.0 ? 3.0 : 2.0, fl, fn.xy);
            } else {
                kind = 2;
                col = h.col;
                nrm = h.nrm;
                dist += h.t;
                dbg = h.kind == 4 ? vec4(100.0 + float(h.idx), wh_M(side, p)) : vec4(side > 0.0 ? 5.0 : 4.0, p);
#ifndef WH_NO_BALLS
                if (h.kind == 5) {
                    col = wh_cubeLook(h.idx, vec4(wh_M(side, p), side * wh_h) - wh_cube[h.idx], dist);
                    dbg = vec4(200.0 + float(h.idx), wh_M(side, p));
                }
#endif
            }
            break;
        }
        dist += h.t;
        wh_enter(side, x + h.t * d, d, l0, n0, vl, w);
        eye = vec2(wh_Rout(), 0.0);    // at the shell's edge (where r - rmin is not used)
        inShell = true;
    }
    if (kind == 1) side = fl > 0.0 ? 1.0 : -1.0;
    // grid coordinates and their derivatives, for every pixel: the sky's by its direction (d, a
    // unit vector there), the floor's by l and n; an object's azimuth fixed (it has no grid lines,
    // and a ray that ends on one in the shell has d = 0, whose angle has none)
    vec3 dn = d;
    vec2 ga = kind == 1 ? fn.xy : (kind == 0 ? dn.xy : vec2(1.0, 0.0));
    float az = wh_atan2(ga.y, ga.x);
    vec2 gq = kind == 1 ? vec2(fl, az * 24.0 / (2.0 * WH_PI))
                        : vec2(az, wh_asin(dn.z)) * (180.0 / WH_PI / 15.0);
    // fwidth = |d/dx| + |d/dy|. Across the edge of what the rays end on (floor next to an object,
    // sky of A next to sky of B) a difference is meaningless and huge and would draw grid lines
    // along such edges: there the other screen axis stands in, and with edges both ways there are
    // no lines in that pixel. The edges are found in the same derivatives: the second coordinate
    // carries 64 per class (sky A, sky B, floor, object), and between neighbours of one class it
    // changes by 24 at most (the spokes' cut), so a change above 32 is an edge.
    float cls = kind == 0 ? (side > 0.0 ? 0.0 : 1.0) : (kind == 1 ? 2.0 : 3.0);
    vec2 gdx = dFdx(gq + vec2(0.0, 64.0 * cls));
    vec2 gdy = dFdy(gq + vec2(0.0, 64.0 * cls));
    bool ex = abs(gdx.y) > 32.0;
    bool ey = abs(gdy.y) > 32.0;
    vec2 fw = abs(ex ? gdy : gdx) + abs(ey ? gdx : gdy);
    fw = ex && ey ? vec2(1e-4) : max(fw, vec2(1e-4));     // tiny: no line
    vec3 c;
    if (kind == 0) c = wh_sky(side, dn);
#ifdef WH_GRAVITY
    else if (kind == 1) c = wh_gravFloor(gq, fw);
#else
    else if (kind == 1) c = wh_floor(gq, fw);
#endif
    else if (kind == 2) c = wh_shade(side, col, nrm);
    else c = vec3(1.0, 0.0, 1.0);
    // what the kinds share: the grid lines (sky faint, floor bright) and fog on the floor and on
    // objects
    vec2 ifw = vec2(fw.y, fw.x) / (fw.x * fw.y);       // 1 / fw, one division
    vec2 gf = abs(fract(gq + 0.5) - 0.5) * ifw;
    float line = 1.0 - clamp(min(gf.x, gf.y), 0.0, 1.0);
    c = mix(c, kind == 1 ? vec3(0.95) : (side > 0.0 ? vec3(1.0, 0.9, 0.8) : vec3(1.0)),
            (kind == 1 ? 0.55 : (kind == 0 ? 0.12 : 0.0)) * line);
    float fog = kind == 1 || kind == 2 ? 1.0 - exp(-dist * 0.012) : 0.0;
#ifdef WH_ARROWS
    // an arrow lies over what the ray ends on, in the fog of its own distance
    if (slc.z >= 0.0) {
        vec4 ar = wh_arrow(slc.x, slc.y, slc.z * wh_pix);
        c = mix(c, ar.rgb, ar.a);
        fog = mix(fog, 1.0 - exp(-slc.z * 0.012), ar.a);
        if (ar.a > 0.5) side = slc.x >= 0.0 ? 1.0 : -1.0;       // the fog of the arrow's universe
    }
#ifdef WH_SLICE_OUT
    WH_SLICE_OUT = slc;           // ref/test_slice.py: the crossing itself
#endif
#endif
    return mix(c, side > 0.0 ? vec3(0.95, 0.60, 0.35) : vec3(0.70, 0.82, 0.95), fog);
}

vec3 wh_render(float l0, vec3 n0, float vl, vec3 w, out vec4 dbg) {
    return wh_renderE(l0, n0, vl, w, wh_eye(l0), dbg);
}
