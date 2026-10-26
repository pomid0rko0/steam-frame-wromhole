// Wormhole renderer core: plain GLSL that is also valid Godot shading language (single source for both).
// The including file declares the uniforms:
//   float wh_rho0, wh_h, wh_fillet          geometry (see below)
//   vec4 wh_sph[6], wh_pil[4], wh_box[4]    static objects: spheres 0-2 in universe A, 3-5 in B
//                                           (xyz centre, w radius); pillars in A (xy, radius, height);
//                                           boxes in B (centre, half size). Chart coordinates.
//   vec4 wh_ball[WH_MAXB], wh_ballCol[WH_MAXB], int wh_nBall
//                                           movable balls: centre as a point of R^4 (xyz, w) and
//                                           (rgb, radius). A ball is every point of space whose chord
//                                           distance in R^4 to the centre is below the radius.
//   ivec4 wh_bIdx                          the balls sorted by where they are (main.set_objects):
//                                           those a flat universe's sheet cuts, A's first and B's
//                                           last, those within reach of the shell between them:
//                                           A 0 .. y, the shell x .. w, B z .. wh_nBall
//   vec4 wh_fball[WH_MAXB]                  the same balls in a flat universe: the sphere the
//                                           sheet cuts from it, in that universe's chart (centre,
//                                           radius squared)
//   vec4 wh_cube[WH_MAXC], wh_cubeE[5 * WH_MAXC], wh_cubeCol[WH_MAXC], int wh_nCube, float wh_pix
//                                           movable cubes: a 4D box of R^4 cut by the space, as a box
//                                           of a 4D SDF scene. Centre as a point of R^4; per cube five
//                                           vectors: four orthonormal axes of R^4 divided by the half size
//                                           (three body axes tangent to the space, then its normal), then
//                                           dot(centre, axis) for the four (one index base for the search);
//                                           (rgb, half size). A point P is inside when |dot(P, axis) -
//                                           dot(centre, axis)| < 1 for all four axes.
//                                           In a flat universe this is an ordinary cube. wh_pix: a
//                                           pixel's angle (the edge lines' width). ivec4 wh_cIdx:
//                                           the cubes sorted as the balls.
//                                           With WH_NO_BALLS defined first the balls' and cubes' code is
//                                           left out; with WH_FLAT_TOYS only their search in the curved
//                                           region is (the flat universes' rays still meet them): the
//                                           pixels whose rays can meet no toy of the shell (main.gd,
//                                           _update_proxies) run that one, with the plain one's registers.
//   with WH_KIND_COLOUR defined: the colour says only what the ray ends on (tests/split_test.gd)
//   with WH_CAND_MASK defined (an int): the shell's toys looked for in the curved region, as bits
//                                           of the candidates (ball i: i, cube i: 16 + i): the near
//                                           ones are left out where the stencil says no ray can meet
//                                           them (main.gd, _update_near)
//   with WH_TABLE defined: sampler2D wh_tab, vec4 wh_tabLo, wh_tabInv, wh_tabReg
//                                           the fillet polynomials by impact parameter
//                                           (WormholeSpace.fillet_table), instead of per ray
//   with WH_GRAVITY defined: vec4 grav_cyl, grav_g[2], grav_d[2]
//                                           the gravity view (WormholeSpace.gravity_shader): the
//                                           floor coloured by the strength of gravity
//   with WH_ARROWS defined too: float wh_pix   also arrows of the field on the vertical surface
//                                           n.x = 0 through the wormhole; wh_pix is a pixel's
//                                           angle (the arrows' soft edges)
//
// Geometry: optozorax's SDF world, union_round(planes w = +-h, extrude_w(sphere rho0, h), fillet) in R^4.
// It is SO(3)-symmetric, so its induced metric is exactly
//   ds^2 = dl^2 + r(l)^2 dOmega^2      (l = arc length of the profile curve from the middle)
//   cylinder |l| <= Lc:      r = rho0,                         w = l
//   fillet   Lc <= |l| <= L: r = rho0 + R (1 - cos th),        w = +-(h - R + R sin th),  th = th0 + (|l| - Lc) / R
//   flat     |l| >= L:       r = |l| - L + Rout   (Euclidean), w = +-h
//   Lc = max(h - R, 0), th0 = asin(max(1 - h/R, 0)), L = Lc + R (pi/2 - th0), Rout = rho0 + R.
//   h < R: the two fillets meet at a crease, there is no cylinder and no photon sphere.
// Static spacetime -dt^2 + ds^2, so light rays are geodesics of ds^2. Each ray stays in a plane
// through the centre; its angle in that plane is  dpsi = b dl / (r sqrt(r^2 - b^2)):
//   cylinder: closed form;  fillet: product integration, no loops (see "curved part").
//
// Manifold point: (l, n), n unit 3-vector. Tangent vector: (vl, w), w orthogonal to n.
// Point in R^4: E = (r n, w(l)). Flat charts: side A (l >= L): x = r n;  side B: x = P r n, P = diag(-1,1,1).
// The floor is the totally geodesic equatorial surface n.z = 0 (z = 0 in both charts).

// the toys' search in the curved region: with toys, unless only the flat universes' are wanted
#ifndef WH_NO_BALLS
#ifndef WH_FLAT_TOYS
#ifndef WH_CURVED_TOYS
#define WH_CURVED_TOYS
#endif
#endif
#endif

const float WH_PI = 3.14159265358979;
const int WH_MAXB = 12;
const int WH_MAXC = 6;

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

// atan(y, x) for arguments of order 1 (components of unit vectors): one range reduction and a
// minimax polynomial, error below 2e-6 rad. The built-in atan reduces twice and guards against
// huge arguments.
float wh_atan2(float y, float x) {
    float ax = abs(x);
    float ay = abs(y);
    float t = min(ax, ay) / max(max(ax, ay), 1e-30);
    float t2 = t * t;
    float t4 = t2 * t2;
    // in pairs (Estrin): a shorter chain of dependent steps than one product after another
    float p = t * ((0.999977219 - 0.332622826 * t2) + t4 * ((0.193540363 - 0.116426447 * t2)
            + t4 * (0.052647312 - 0.0117191196 * t2)));
    p = ay > ax ? 0.5 * WH_PI - p : p;
    p = x < 0.0 ? WH_PI - p : p;
    return y < 0.0 ? -p : p;
}

// asin, for the sky's latitude lines: pi/2 - sqrt(1 - |x|) P(|x|), no division, error 5e-6 rad
float wh_asin(float x) {
    float a = min(abs(x), 1.0);
    float p = (1.57079153 - 0.214280613 * a) + a * a * ((0.0856383856 - 0.0376182282 * a) + 0.00973297445 * a * a);
    float r = 0.5 * WH_PI - sqrt(1.0 - a) * p;
    return x < 0.0 ? -r : r;
}

// The values of a ray's start point that do not depend on its direction: (r, r - rmin), the
// second as a product (no cancellation near the fillet's inner end). The same for every pixel
// of an eye: the view shader computes them per eye (wh_render's eye argument).
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
// about as wide as a pixel at the path length dist
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
// The potential is g f(l) n_z (WormholeSpace.gravity_f: Laplace's equation on the space itself,
// as in optozorax's video about gravity and portals). (f / r, d(f / r)/dl, f') at l: f / r is the
// strength of gravity on the floor, in g. Cylinder: f = a cosh(k l); fillet: polynomials of degree 7
// in x = (|l| - Lc) / (L - Lc); flat: f = r + beta / r^2.
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

// optozorax's palette: dark is no gravity, yellow 1 g, then red and white at 10 g; bands of 0.1 g
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
// of q (wh_floor): the band coordinate depends on l alone, so its footprint is its slope times fw.x.
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

// The arrows of the field on the surface n.x = 0 (x = 0 in both charts, through the throat; totally
// geodesic, as the floor is), above the floor (0 < a < pi). At the point (l, n), n = (0, cos a, sin a): the arrow
// of the nearest node, on the rings l = k (1 m apart), spaced about 1 m along each half circle; the
// surface's metric there is dl^2 + r(l)^2 da^2. Length 0.6 m at 1 g, colour the palette. foot: a
// pixel's size there (m), for soft edges. Returns colour and coverage.
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
// A fillet in u = s^2 = (r - rho0) / 2R, s = sin(th/2):  dl = 2R ds / sqrt(1 - s^2), and with
// sig = (b - rho0) / 2R
//   dpsi = F(u) dv,  dlength = G(u) dv,   dv = ds / sqrt(s^2 - sig) = du / (2 sqrt(u (u - sig)))
//   F = b sqrt(2R) / (r sqrt((1 - u)(r + b))),  G = r^2 / b F.
// F and G are smooth on the fillet; all the trouble (the turning point, the log at b -> rmin) is in
// dv. So the integral is "product integration": F and G are interpolated by polynomials in
// tau = (u - ua) / (0.5 - ua) in [0, 1] (4 nodes: squares of the Gauss-Legendre nodes on [0, 1]),
// and their moments against the exact weight, int t^k w(t) dt, are elementary:
//   w(t) = 1 / (2 sqrt((t + al)(t + ga)))     (regime 0)
// ua is where the fillet path starts: the turning point u = sig, or the fillet's inner end s0^2.
// One of al, ga is 0 unless h < R. The moments come from a recursion that is stable while al and ga
// are below 1; a factor 1 / sqrt(t + al or ga) that is 1 or more is smooth on [0, 1] and is moved
// into the interpolated part instead (regimes 1 and 2). No loops, the same cost for every ray, and
// the integral up to any point is the same closed form: the floor crossing is a Newton solve on it.
// v ("z" below) is the variable in which that solve and the ball sampling run: in regime 0
// z = int w dt, in regimes 1 and 2 z = sqrt(t + mn).
// With 4 nodes the error in psi is below 0.004 degrees (0.0001 typical) on the profiles in use.
const vec4 WH_TAU = vec4(0.004820780989426014, 0.10890625570683385, 0.44888729929169013, 0.8659570925834785);
// e = A f: polynomial coefficients from the node values (the rows of A)
const vec4 WH_A0 = vec4(1.0635954209629264, -0.06994895315294707, 0.0072202981818859785, -0.0008667659918653305);
const vec4 WH_A1 = vec4(-13.363790651033874, 14.746483787306632, -1.5723807203730116, 0.1896875841002548);
const vec4 WH_A2 = vec4(35.770406476784, -49.259940350673936, 15.558746458518186, -2.0692125846282434);
const vec4 WH_A3 = vec4(-25.12406687051129, 37.32760503465092, -15.881390739642725, 3.6778525755030924);
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
            // int_0^t w dt = sqrt(t + mn) - sqrt(mn) = z - zlo. As t / (z + zlo) it was 0 / 0 at a
            // turning ray's turning point (z = zlo = 0), where the toys' search samples: NaN there
            // blinded the rest of the ray, and toys near the shell's edge showed a crack
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

vec4 wh_coef(vec4 v) { return vec4(dot(WH_A0, v), dot(WH_A1, v), dot(WH_A2, v), dot(WH_A3, v)); }

// The path length from the fillet's inner end, m the moments there, for the fog and the cubes'
// edge lines only: r^2 / b times psi (r^2 / b is the length per angle), r taken at the weight's
// mean tau, within 1.5% here and 7% on long fillets; the shader then holds one polynomial less
// (12 registers, waves of 128 pixels). Movable objects' hits are ordered by where on the path they
// are (piece and fraction of it, wh_curved), not by length.
float wh_filLen(WhFil f, vec4 m) {
    float re = f.ra + f.span * m.y / max(m.x, 1e-30);
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
    f.reg = f.mx < 1.0 ? 0 : (f.mn < 1.0 ? 1 : 2);
    // Of al and ga only one is the ray's own: a passing ray's al is that of every passing ray, and a
    // turning ray's ga is 0. So one square root per ray gives both roots.
    float sq = sqrt(turn ? f.al : f.ga);
    float sal = turn ? sq : sqrt((rmin - rho0) / max(wh_Rout() - rmin, 1e-6 * R));   // uniforms only
    float sga = turn ? 0.0 : sq;
    f.E0 = max(sal + sga, 1e-6);
#ifdef WH_TABLE
    // f.e depends on b alone: sampled from the row of b's regime (the regime is taken from the row,
    // so that the moments match the table), with the factor the table leaves out put back
    int row = turn ? (b >= wh_tabLo.w ? 3 : 2) : (b >= wh_tabLo.y ? 1 : 0);
    vec3 rw = turn ? (row == 3 ? vec3(wh_tabLo.w, wh_tabInv.w, wh_tabReg.w) : vec3(wh_tabLo.z, wh_tabInv.z, wh_tabReg.z))
                   : (row == 1 ? vec3(wh_tabLo.y, wh_tabInv.y, wh_tabReg.y) : vec3(wh_tabLo.x, wh_tabInv.x, wh_tabReg.x));
    f.reg = int(rw.z);
    float x = clamp((b - rw.x) * rw.y, 0.0, WH_TABN - 1.0);
    vec4 et = textureLod(wh_tab, vec2((x + 0.5) / WH_TABN, (float(row) + 0.5) * 0.25), 0.0);
    f.e = f.reg == 0 ? et : et * inversesqrt(f.mx * (f.reg == 2 ? f.mn : 1.0));
#else
    vec4 r = f.ra + f.span * WH_TAU;
    vec4 u = (r - rho0) / (2.0 * R);
    // F = b sqrt(2R) / (r sqrt(q)), q holding the factors moved out of the weight
    vec4 q = (1.0 - u) * (r + b);
    if (f.reg >= 1) q *= WH_TAU + f.mx;
    if (f.reg == 2) q *= WH_TAU + f.mn;
    vec4 k = sqrt(2.0 * R) * inversesqrt(q * r * r);
    f.e = wh_coef(b * k);
#endif
    f.ib = 1.0 / max(b, 1e-30);
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

// z where psi from the inner end reaches T (Newton; psi(z) is smooth and increasing, and two
// steps from the linear guess reach float precision)
float wh_filSolve(WhFil f, float T) {
    float z = mix(f.zlo, f.zhi, clamp(T / max(f.psi, 1e-30), 0.0, 1.0));
    for (int it = 0; it < 2; it++) {
        float t; vec4 m;
        wh_filMom(f, z, t, m);
        float dz = wh_poly(f.e, t) * (f.reg == 2 ? z : 1.0);    // dpsi/dz
        z = clamp(z - (dot(f.e, m) - T) / max(dz, 1e-30), f.zlo, f.zhi);
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

// Ray starting inside (or on the boundary of) the shell, |ls| <= L. Returns
//   0: leaves the shell, given in flat chart coordinates (outSide, outX, outD)
//   1: hits the floor at (hitL, hitN)        2: enters ball ballI at (hitL, hitN)
//      (ballI >= WH_MAXB: cube ballI - WH_MAXB)
// arc = path length travelled inside the shell. WH_ARROWS: if slc.w < 0 (none found before), the
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
    // for a ray that goes round the throat (vl ~ 1e-4: wrong by half), and it put the floor's point
    // of such rays off. rs - rho0 is eye.y (rmin = rho0 when there is a cylinder), R from the edge.
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
                float xS = (psiS - PA.x) / max(kc, 1e-30);
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

#ifdef WH_CURVED_TOYS
    // Balls and cubes this ray can reach: the whole ray lies in span(e1, e2, w-axis) of R^4, so
    // one whose centre is farther than its reach (a ball's radius, a cube's half diagonal, two half
    // sizes) from that subspace is never hit. Only those within reach of the shell are looked at
    // (wh_bIdx.x .. .w, wh_cIdx.x .. .w: main.set_objects sorts them by where they are). Each
    // candidate is searched on its own, only where the path can come within its reach:
    //  - in r = |xyz| and in w: the chord distance in R^4 is at least either difference. On a
    //    fillet r and w grow together, so the w bounds are r bounds there, and r is linear in tau;
    //  - in the angle psi in the ray's plane: the object's shadow on that plane is a disc around
    //    the centre's projection, radius sqrt(reach^2 - (distance from the subspace)^2), and a
    //    point at angle psi can lie in it only within asin(radius / the projection's distance) of
    //    the projection's angle. The whole path in the shell turns by less than pi (it meets the
    //    floor by then), so one window. On the cylinder psi is linear along the path: there it
    //    bounds the samples (a ray looking sideways in the throat winds round it slowly in l, and
    //    with r and w alone a ball in the throat was within reach for metres of its path); on a
    //    fillet psi grows along the piece too, and the window's ends are solved for z.
    // There the path is sampled at steps of a third of the object's size; between two samples
    // the ray is taken as the chord in R^4: where the chord enters the object, the path's point at
    // that fraction (one more sample) is the hit, if it lies in the object or within the chord's
    // sag of it (step^2 / 8R: a millimetre on the fillet at the usual steps). So a ray that only
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
#ifdef WH_CAND_MASK
    cand &= WH_CAND_MASK;   // a uniform: a mask made per pixel here took the shader to 32 registers
#endif
    if (cand != 0) {
        // where on the path the ray ends: 2 (piece - 1) + the fraction of it (piece 0 A from -2,
        // 1 B from 0, 2 C from 2; 4: the edge), as the hits are ordered. The cylinder's fraction
        // goes without an offset: a ray that winds round the throat meets things at ~1e-5 of it,
        // and 2 + that kept a tenth of its digits (the floor's point and an object's normal off:
        // white dashes along the throat). The floor's point itself is worked out after the
        // search, from there, as an object's hit is: the search then holds fewer numbers.
        float keyEnd = 4.0;
        if (floorHit) {
            // n.z = 0 along (cos psi, sin psi) = (-e2.z, e1.z) / |.|: the first zero, sin psi > 0
            float psiF = wh_atan2(e1.z, -e2.z);
            if (psiF >= PA.x && psiF < PA.x + PB.x) {
                keyEnd = (psiF - PA.x) / max(kc * DB, 1e-30);
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
        vec4 prs = wh_prof(ls);
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
            vec3 prevQ = vec3(prs.x, 0.0, prs.y);    // the previous sample, (u, v, w) in the subspace
            bool carry = true;                       // prevQ is where the next piece starts
            for (int p = 0; p < 3; p++) {
                // piece p: a fillet from z0 to z1 (sign sg: psi from the inner end grows with z along
                // the travel, or shrinks), or the cylinder (x0B .. x0B + DB)
                bool cyl = p == 1;
                if ((p == 0 && !hasA) || (cyl && !hasB)) continue;
                float qEnd = hitK - 2.0 * float(p - 1);  // the nearest hit so far, or the ray's end
                if (qEnd <= 0.0) break;
                float psi0 = p == 0 ? 0.0 : (cyl ? PA.x : PA.x + PB.x);    // the piece's psi range
                float psi1 = p == 0 ? PA.x : (cyl ? PA.x + PB.x : tot.x);
                // the windows: r from, to; w from, to (worked out here, not held through the search)
                vec4 win = vec4(rc - reach, rc + reach, cb.z - reach, cb.z + reach);
                // the piece's part in the windows, as fractions q of it: on the cylinder r = rho0,
                // w = l = d pz and psi = psi0 + PB.x q; on a fillet r = rho0 + R (1 - cos th) and
                // side w = h - R + R sin th, both growing with th
                vec2 qw = vec2(2.0);
                if (psc + dps >= psi0 && psc - dps <= psi1) {
                    if (cyl) {
                        vec2 pw = ((d > 0.0 ? win.zw : -win.wz) - x0B) / DB;
                        vec2 qa = PB.x > 1e-6 ? (vec2(psc - dps, psc + dps) - psi0) / PB.x : vec2(-1.0, 2.0);
                        if (rho0 >= win.x && rho0 <= win.y)
                            qw = vec2(max(min(pw.x, pw.y), qa.x), min(max(pw.x, pw.y), qa.y));
                    } else {
                        float side = p == 0 ? sideA : sideC;
                        float z0 = p == 0 || cFromStart ? zs : f.zlo;
                        float z1 = p == 0 ? f.zlo : f.zhi;
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
                        // psi bounds the samples here too: it grows along the piece (not linearly
                        // in z), so its window's ends are solved for z, as the floor's crossing is.
                        // A ray that grazes the shell near its edge stays within the r and w windows
                        // of a toy there for metres: a ball held there made the frame 3.5x dearer
                        if (dps < 9.0 && qw.y > qw.x) {
                            // psi from the fillet's inner end: piece A runs toward it, piece C away
                            vec2 ps = clamp(vec2(psc - dps, psc + dps) + vec2(-5e-3, 5e-3), psi0, psi1);
                            vec2 T = p == 0 ? PA.x - ps : C0.x + ps - PA.x - PB.x;
                            vec2 zq;
                            for (int e = 0; e < 2 + min(wh_nBall, 0); e++)     // one solve's code
                                zq[e] = wh_filSolve(f, clamp(T[e], 0.0, f.psi));
                            float dz = z1 - z0;
                            vec2 qp = (zq - z0) / (abs(dz) > 1e-12 ? dz : 1e-12);
                            qw = vec2(max(qw.x, min(qp.x, qp.y)), min(qw.y, max(qp.x, qp.y)));
                        }
                    }
                }
                qw = vec2(max(qw.x, 0.0), min(min(qw.y, 1.0), qEnd));
                if (qw.y <= qw.x) { carry = false; continue; }
                int N = int(clamp(ceil((p == 0 ? PA.y : (cyl ? PB.y : PC.y)) * (qw.y - qw.x) / (0.35 * size)), 1.0, 160.0));
                // the first sample: where the window starts, unless that is where the last one was
                int j0 = carry && qw.x <= 0.0 ? 1 : 0;
                float q0 = qw.x;
                for (int j = 0; j <= 160; j++) {
                    if (j > N) break;
                    if (j < j0) continue;
                    float qb = mix(qw.x, qw.y, float(j) / float(N));
                    float tHit = 2.0;        // the chord's fraction where it enters the object
                    float sag = 0.0;         // how far the chord can be from the path
                    // it 0: the sample at qb and the chord from the previous one; it 1: the path's
                    // point where the chord enters (one sample routine for both: its code exists once)
                    for (int it = 0; it < 2; it++) {
                        float q = it == 0 ? qb : mix(q0, qb, tHit);
                        // the point at q, from the ray's values (the piece's own would be held through the search)
                        float psi; float r; float w4;
                        if (cyl) {
                            psi = PA.x + PB.x * q;
                            r = rho0;
                            w4 = d * (x0B + DB * q);
                        } else {
                            bool pA = p == 0;
                            float t; vec4 m;
                            wh_filMom(f, mix(pA || cFromStart ? zs : f.zlo, pA ? f.zlo : f.zhi, q), t, m);
                            psi = pA ? PA.x - dot(f.e, m) : PA.x + PB.x - C0.x + dot(f.e, m);
                            r = f.ra + f.span * t;
                            float cth = rho0 + R - r;           // R cos th
                            w4 = (pA ? sideA : sideC) * (wh_h - R + sqrt(max(R * R - cth * cth, 0.0)));
                        }
                        vec3 Q1 = vec3(r * cos(psi), r * sin(psi), w4);
                        if (it == 1) {
                            // the path's point there: in the object, or within the chord's sag of it
                            float miss;
                            if (!isCube) {
                                vec3 a = Q1 - cb;
                                miss = sqrt(dot(a, a) + perp2) - size;
                            } else {
                                float mx = 0.0;
                                for (int k = 0; k < 4 + min(wh_nCube, 0); k++) {
                                    vec4 Ek = wh_cubeE[5 * i + k];
                                    mx = max(mx, abs(dot(Q1, vec3(dot(Ek.xyz, e1), dot(Ek.xyz, e2), Ek.w)) - wh_cubeE[5 * i + 4][k]));
                                }
                                miss = (mx - 1.0) * size;
                            }
                            float key = 2.0 * float(p - 1) + q;
                            if (miss <= sag && key < hitK) {
                                hitK = key;
                                hitI = isCube ? WH_MAXB + i : i;
                            }
                            break;
                        }
                        vec3 D = Q1 - prevQ;     // the chord (Q1 itself is not held: prevQ + D)
                        float tc = -1.0;
                        if (j > 0) {
                            if (!isCube) {
                                vec3 a = prevQ - cb;
                                float A = max(dot(D, D), 1e-20);
                                float B = dot(a, D);
                                float Cq = dot(a, a) + perp2 - size * size;
                                float disc = B * B - A * Cq;
                                tc = Cq > 0.0 && disc >= 0.0 ? (-B - sqrt(max(disc, 0.0))) / A : -1.0;
                            } else {
                                tc = wh_chordInCube(i, prevQ, D, e1, e2, cb, perp2);
                            }
                        }
                        prevQ += D;
                        if (tc < 0.0 || tc > 1.0) break;
                        tHit = tc;
                        sag = dot(D, D) / (8.0 * min(R, rho0)) + 1e-4;
                    }
                    q0 = qb;
                    if (2.0 * float(p - 1) + qb > hitK) break;     // a hit before here (the later pieces end there too)
                }
                carry = qw.y >= 1.0;
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
        // n.z = 0 along (cos psi, sin psi) = (-e2.z, e1.z) / |.|: the first zero, sin psi > 0
        float psiF = wh_atan2(e1.z, -e2.z);
        hitN = (e1.z * e2 - e2.z * e1) * inversesqrt(e1.z * e1.z + e2.z * e2.z);
        if (psiF >= PA.x && psiF < PA.x + PB.x) {
            float xF = (psiF - PA.x) / max(kc, 1e-30);
            hitL = d * (x0B + xF);
            arcEnd = PA.y + xF * ivlc;
        } else {
            bool inA = psiF < PA.x;
            // psi from the fillet's inner end: piece A runs toward it, piece C away from it;
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
// Geodesic equation with parallel transport, in the (U_l, u) representation:
//   dl/ds = V_l,  dn/ds = v / r,  dU_l/ds = (r'/r) v.u,  du/ds = -(r'/r) U_l v - (u.v / r) n
// for the velocity V = (V_l, v) itself and for every transported vector U.
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

// A toy near the eye (main._update_near): the directions from the eye in which a ray can meet it.
// The space's sectional curvature is at most 1 / rho0^2 (the cylinder's round sections; the
// fillets' are below it, the radial ones negative) and no geodesic loop is shorter than 2 pi rho0,
// so the space is CAT(1 / rho0^2): a geodesic from the eye at angle a to the one that reaches the
// toy's centre, D long, comes no nearer to it than on a sphere of radius rho0,
// rho0 asin(sin(D / rho0) sin a), and for a > pi / 2 no nearer than D (within pi rho0 / 2 of the
// eye). A ray meets the toy (intrinsic radius rr) only if sin a < sin(rr / rho0) / sin(D / rho0)
// with a < pi / 2: a cone round the centre's direction. (A ray in the curved region turns by less
// than pi before the floor, so none comes back to the eye's neighbourhood from farther:
// ref/test_near.py.) q: the centre seen from the eye, as main places it (P - eye in play space:
// the head's geodesic to it unrolled, P, off the eye's own by ~2 mm at a metre for the eye's 3 cm
// from the head, within the reach main adds). Returns cos of the cone's half angle, or -2: none
// (the eye within reach); a ray V with dot(V, q / |q|) below it cannot meet it.
float wh_nearCone(vec3 q, float reach) {
    float D = length(q);
    float rr = 1.02 * reach;     // chord -> intrinsic (on curves bent at most 1 / m, below 0.6 m)
    float S = sin(rr / wh_rho0) / sin(min(D, 1.5 * wh_rho0) / wh_rho0);
    return reach > 0.0 && D > rr && S < 1.0 ? cos(asin(S) + 0.005) : -2.0;
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
// Every object only offers its entry distance; the nearest one's normal and colour are worked
// out once at the end. The pillars and boxes are first tested against their bounding balls:
// most rays pass far from all of them.
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
        for (int i = 0; i < 4; i++) wh_hitPillar(x, d, wh_pil[i], vec3(0.85, 0.80, 0.70), h);
    } else {
        wh_hitSphere(x, d, wh_sph[3], vec3(0.75, 0.15, 0.70), h);
        wh_hitSphere(x, d, wh_sph[4], vec3(0.15, 0.75, 0.30), h);
        wh_hitSphere(x, d, wh_sph[5], vec3(0.20, 0.35, 0.85), h);
        float top = max(max(wh_box[0].z + wh_box[0].w, wh_box[1].z + wh_box[1].w),
                        max(wh_box[2].z + wh_box[2].w, wh_box[3].z + wh_box[3].w));
        if (x.z < top || d.z < 0.0) {
            wh_hitBox(x, d, wh_box[0].xyz, vec3(wh_box[0].w), vec3(0.90, 0.90, 0.95), h);
            wh_hitBox(x, d, wh_box[1].xyz, vec3(wh_box[1].w), vec3(0.90, 0.90, 0.95), h);
            wh_hitBox(x, d, wh_box[2].xyz, vec3(wh_box[2].w), vec3(0.90, 0.90, 0.95), h);
            wh_hitBox(x, d, wh_box[3].xyz, vec3(wh_box[3].w), vec3(0.90, 0.90, 0.95), h);
        }
    }
#ifndef WH_NO_BALLS
    // balls: the chord ball cut by this universe's sheet w = side*h is an ordinary sphere;
    // only entries count (a ray that starts inside a ball does not see it from inside)
    // The loops keep only the nearest one's distance and index (and a cube's face); its normal
    // and colour are worked out once after the loop: updating the whole hit at every candidate
    // cost the loop half its time.
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
    // this universe's balls only (main.set_objects sorts them: A's first, B's last), each as the
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
    // cubes: the 4D box cut by this sheet is a convex solid bounded by four pairs of planes (an
    // ordinary cube when the box's centre is in this flat universe); entries only
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
// place in the trace where a ray can end.
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
#ifdef WH_CURVED_TOYS
            if (ev == 2) {
                // ball: normal = R^4 offset from the centre projected onto the tangent space;
                // cube: the normal of the face hit (largest slab coordinate), projected the same way
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
#ifdef WH_KIND_COLOUR
    // tests/split_test.gd: only what the ray ends on (dbg.x: the kind and side, or which ball or
    // cube), no shading and no screen derivatives: the stencil's split must not change it anywhere;
    // green: which ray tracer (WH_KIND_COLOUR's value, as split_test.gd sets it)
    return vec3(dbg.x / 255.0, WH_KIND_COLOUR, side > 0.0 ? 0.75 : 0.25);
#endif
    // grid coordinates and their derivatives, for every pixel (d is a unit vector)
    vec3 dn = d;
    vec2 ga = kind == 1 ? fn.xy : dn.xy;
    float az = wh_atan2(ga.y, ga.x);
    vec2 gq = kind == 1 ? vec2(fl, az * 24.0 / (2.0 * WH_PI))
                        : vec2(az, wh_asin(dn.z)) * (180.0 / WH_PI / 15.0);
    // fwidth = |d/dx| + |d/dy|. Across the edge of what the rays end on (floor next to an object,
    // sky of A next to sky of B) a difference is meaningless and huge, and drew grid lines along
    // such edges: there the other screen axis stands in, and with edges both ways there are
    // no lines in that pixel. The edges are found in the same derivatives: the second coordinate
    // carries 64 per class (sky A, sky B, floor, object), and between neighbours of one class it
    // changes by 24 at most (the spokes' cut), so a change above 32 is an edge.
    float cls = kind == 0 ? (side > 0.0 ? 0.0 : 1.0) : (kind == 1 ? 2.0 : 3.0);
    vec2 gdx = dFdx(gq + vec2(0.0, 64.0 * cls));
    vec2 gdy = dFdy(gq + vec2(0.0, 64.0 * cls));
    bool ex = abs(gdx.y) > 32.0;
    bool ey = abs(gdy.y) > 32.0;
    vec2 fw = abs(ex ? gdy : gdx) + abs(ey ? gdx : gdy);
    fw = ex && ey ? vec2(1e-4) : max(fw, vec2(1e-4));     // tiny: no line, no circle
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
