// Wormhole renderer core: plain GLSL that is also valid Godot shading language (single source for both).
// The including file declares the uniforms:
//   float wh_rho0, wh_h, wh_fillet          geometry (see below)
//   vec4 wh_sph[6], wh_pil[4], wh_box[4]    static objects: spheres 0-2 in universe A, 3-5 in B
//                                           (xyz centre, w radius); pillars in A (xy, radius, height);
//                                           boxes in B (centre, half size). Chart coordinates.
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

const float WH_PI = 3.14159265358979;

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

// min(al, ga) and |al - ga|: in the movable objects' pass worked out where used, not held through
// their search
float wh_mn(WhFil f) {
#ifndef WH_TOYS
    return f.mn;
#else
    return min(f.al, f.ga);
#endif
}

float wh_dm(WhFil f) {
#ifndef WH_TOYS
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

// A ray in the shell from a start point inside it (or on its boundary), |ls| <= L. It lies in
// the plane span(e1, e2) through the centre (e1 the start point's n), psi its angle there from
// e1, growing along the path. The path: piece A, a fillet travelled inward from the start (to the
// throat, or to the turning point); piece B, the cylinder; piece C, a fillet travelled outward to
// the shell's edge. Both fillets have the same profile, so one WhFil serves both. (psi, path
// length) of each piece: PA, PB, and for C from C0 (where on its fillet piece C starts) to the
// edge; tot of the whole path. The movable objects' pass (wormhole_toys.gdshaderinc) takes the
// same ray.
struct WhRay {
    vec3 e1; vec3 e2;
    float b;
    float zs;              // z of the start point, on its fillet
    float d;               // a passing ray's direction of travel in l
    float x0B; float DB;   // the cylinder, oriented l: from x0B, DB long
    float kc; float ivlc;  // the cylinder: dpsi / dl, dlength / dl
    float sideA; float sideC;
    bool hasA; bool hasB; bool cFromStart;
    vec2 PA; vec2 PB; vec2 C0; vec2 tot;
    bool floorHit;         // it meets the floor in the shell
};

WhRay wh_ray(float ls, vec3 ns, float vl, vec3 w, vec2 eye, out WhFil f) {
    float rho0 = wh_rho0;
    float R = wh_fillet;
    float Lc = wh_Lc();
    float th0 = wh_th0();
    float s0 = sin(0.5 * th0);
    float rmin = rho0 + 2.0 * R * s0 * s0;
    float als = abs(ls);
    WhRay Y;
    // the orbit plane's second axis and |w| from one inverse square root. A ray along the radius
    // (w = 0) takes an axis orthogonal to n: the 1e-7 of it moves any ray's direction by 1e-7 rad
    vec3 we = w + 1e-7 * (abs(ns.x) < 0.9 ? vec3(0.0, ns.z, -ns.y) : vec3(-ns.z, 0.0, ns.x));
    Y.e2 = we * inversesqrt(dot(we, we));
    // |w| <= 1 (the ray is a unit vector): rounded above 1, a ray along the throat's cylinder
    // (b = rho0 = rmin) would count as turning in a fillet it is not in
    float wn = min(dot(w, Y.e2), 1.0);
    float rs = eye.x;                // wh_eye(ls)
    float b = rs * wn;
    Y.b = b;
    Y.e1 = ns;

    bool turn = b > rmin;
    f = wh_fil(b, turn, rmin);
    // the start point's tau (when it is on a fillet)
    bool fromEdge = als >= wh_Lsh() * (1.0 - 1e-6);
    float ts = turn ? rs * vl * vl / (1.0 + wn)     // r_s - b
                    : eye.y;                        // r_s - rmin
    Y.zs = f.zhi;
    vec2 Ss = vec2(f.psi, f.arc);           // inner end -> start
    if (!fromEdge) {
        vec4 ms;
        Y.zs = wh_filMomT(f, clamp(ts / f.span, 0.0, 1.0), ms);
        Ss = vec2(dot(f.e, ms), wh_filLen(f, ms));
    }

    // pieces
    float d = vl >= 0.0 ? 1.0 : -1.0;       // passing: direction of travel in l
    float x = ls * d;                        // passing: oriented coordinate, runs to +L
    float sideS = ls > 0.0 ? 1.0 : -1.0;
    Y.d = d;
    Y.hasA = turn ? vl * sideS < 0.0 : x < -Lc;
    Y.hasB = !turn && Lc > 0.0 && x < Lc;
    Y.cFromStart = turn ? !Y.hasA : x > Lc;   // piece C starts at the start point
    Y.sideA = turn ? sideS : -d;
    Y.sideC = turn ? sideS : d;
    Y.x0B = max(x, -Lc);
    Y.DB = Y.hasB ? Lc - Y.x0B : 0.0;
    float wc = b / rho0;
    // 1 / the radial velocity on the cylinder, 1 / sqrt(1 - wc^2), with rho0^2 - b^2 as
    // (rho0 - b)(rho0 + b) and rho0 - b = rs vl^2 / (1 + wn) - (rs - rho0): 1 - wc^2 itself cancels
    // for a ray that goes round the throat (vl ~ 1e-4: wrong by half), and it put the floor's point
    // of such rays off. rs - rho0 is eye.y (rmin = rho0 when there is a cylinder), R from the edge.
    float omb = rs * vl * vl / (1.0 + wn) - (fromEdge ? R : eye.y);
    Y.ivlc = rho0 * inversesqrt(max(omb * (rho0 + b), 1e-14 * rho0 * rho0));
    Y.kc = wc / rho0 * Y.ivlc;
    Y.PA = Y.hasA ? Ss : vec2(0.0);
    Y.PB = vec2(Y.kc, Y.ivlc) * Y.DB;
    Y.C0 = Y.cFromStart ? Ss : vec2(0.0);
    Y.tot = Y.PA + Y.PB + vec2(f.psi, f.arc) - Y.C0;

    // first crossing of the floor in the orbit plane, n = cos psi e1 + sin psi e2: n.z starts
    // positive and its zeros are pi apart, so the ray meets the floor in the shell if it turns by pi
    // or more, or if n.z is negative where it leaves. Only those rays need the crossing's angle.
    Y.floorHit = ns.z > 0.0 && (Y.tot.x >= WH_PI || ns.z * cos(Y.tot.x) + Y.e2.z * sin(Y.tot.x) < 0.0);
    return Y;
}

// The floor's angle in the orbit plane (Y.floorHit): n.z = 0 along (cos psi, sin psi) = (-e2.z,
// e1.z) / |.|, the first zero, sin psi > 0
float wh_floorPsi(WhRay Y) {
    return wh_atan2(Y.e1.z, -Y.e2.z);
}

// The point of the path at angle psi (Newton on the fillet: wh_filSolve): its l and the path
// length to it
vec2 wh_atPsi(WhRay Y, WhFil f, float psi) {
    if (psi >= Y.PA.x && psi < Y.PA.x + Y.PB.x) {
        float x = (psi - Y.PA.x) / max(Y.kc, 1e-30);
        return vec2(Y.d * (Y.x0B + x), Y.PA.y + x * Y.ivlc);
    }
    bool inA = psi < Y.PA.x;
    // psi from the fillet's inner end: piece A runs toward it, piece C away from it
    float T = inA ? Y.PA.x - psi : Y.C0.x + psi - Y.PA.x - Y.PB.x;
    float t; vec4 m;
    wh_filMom(f, wh_filSolve(f, clamp(T, 0.0, f.psi)), t, m);
    return vec2(wh_filLW(f, t, inA ? Y.sideA : Y.sideC).x,
                (inA ? Y.PA.y : Y.PA.y + Y.PB.y - Y.C0.y) + (inA ? -1.0 : 1.0) * wh_filLen(f, m));
}

#ifdef WH_ARROWS
// The arrows' surface n.x = 0: if slc.z < 0 (none found before), the ray's first crossing of it
// in the shell before it ends there goes into slc: (l, the angle of n from +y toward +z, path
// length from the eye), dist0 being the path length before the shell
void wh_slice(WhRay Y, WhFil f, float dist0, inout vec3 slc) {
    if (slc.z >= 0.0) return;
    // n.x = 0 along (cos psi, sin psi) = (-e2.x, e1.x) * sign(e1.x) / |.|: the first zero, as the
    // floor's, unless the ray ends first (on the floor, or by leaving the shell)
    float sx = Y.e1.x >= 0.0 ? 1.0 : -1.0;
    float psiS = wh_atan2(abs(Y.e1.x), -sx * Y.e2.x);
    if (psiS < (Y.floorHit ? wh_floorPsi(Y) : Y.tot.x)) {
        vec2 la = wh_atPsi(Y, f, psiS);
        vec3 nS = cos(psiS) * Y.e1 + sin(psiS) * Y.e2;
        slc = vec3(la.x, wh_atan2(nS.z, nS.y), dist0 + la.y);
    }
}
#endif

// Where it leaves the shell, at its edge on side Y.sideC, in that universe's chart: (outX, outD)
void wh_exit(WhRay Y, out vec3 outX, out vec3 outD) {
    float ce = cos(Y.tot.x);
    float se = sin(Y.tot.x);
    vec3 n = ce * Y.e1 + se * Y.e2;
    vec3 tt = ce * Y.e2 - se * Y.e1;
    float bR = Y.b / wh_Rout();
    outX = wh_M(Y.sideC, wh_Rout() * n);
    outD = wh_M(Y.sideC, sqrt(max(1.0 - bR * bR, 0.0)) * n + bR * tt);
}

// The plain ray in the shell. Returns
//   0: leaves the shell, given in flat chart coordinates (outSide, outX, outD)
//   1: hits the floor at (hitL, hitN)
// arc = path length travelled inside the shell. WH_ARROWS: wh_slice, dist0 being the path length
// before the shell.
int wh_curved(float ls, vec3 ns, float vl, vec3 w, vec2 eye,
              out float hitL, out vec3 hitN,
              out float outSide, out vec3 outX, out vec3 outD, out float arc
#ifdef WH_ARROWS
              , inout vec3 slc, float dist0
#endif
              ) {
    WhFil f;
    WhRay Y = wh_ray(ls, ns, vl, w, eye, f);
    hitL = 0.0; hitN = vec3(0.0);
    outX = vec3(0.0); outD = vec3(0.0);
    outSide = Y.sideC;
#ifdef WH_ARROWS
    wh_slice(Y, f, dist0, slc);
#endif
    arc = Y.tot.y;
    if (Y.floorHit) {
        float psiF = wh_floorPsi(Y);
        hitN = (Y.e1.z * Y.e2 - Y.e2.z * Y.e1) * inversesqrt(Y.e1.z * Y.e1.z + Y.e2.z * Y.e2.z);
        vec2 la = wh_atPsi(Y, f, psiF);
        hitL = la.x;
        arc = la.y;
        return 1;
    }
    wh_exit(Y, outX, outD);
    return 0;
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

// The eye at play-space point eye: the head's point and play axes (head_l, head_n, head_f) moved
// along the geodesic of the eye's offset from the head (head_pos). The same for every pixel of an
// eye: the vertex shaders compute it.
void wh_eyeAt(vec3 eye, out float l, out vec3 n, out vec4 f0, out vec4 f1, out vec4 f2) {
    l = head_l;
    n = head_n;
    f0 = head_f[0];
    f1 = head_f[1];
    f2 = head_f[2];
    vec3 off = eye - head_pos;                         // this eye relative to the head, play space
    float len = length(off);
    if (len > 1e-6) {
        vec4 dir = (off.x * f0 + off.y * f1 + off.z * f2) / len;
        wh_geodesic(l, n, dir, len, f0, f1, f2);
    }
}

// The geodesic from (l, n) along the unit tangent V for len, in RK4 steps of at most h0: (l, n) and
// its direction there (V)
void wh_geo(inout float l, inout vec3 n, inout vec4 V, float len, float h0) {
    int steps = clamp(int(ceil(abs(len) / h0)), 1, 48);
    float h = len / float(steps);
    for (int it = 0; it < steps; it++) {
        vec4 p = wh_prof(l);
        float dl1 = V.x; vec3 dn1 = V.yzw / p.x; vec4 dV1 = wh_dU(V, V.yzw, n, p.z / p.x, p.x);
        float l2 = l + 0.5 * h * dl1; vec3 n2 = n + 0.5 * h * dn1; vec4 V2 = V + 0.5 * h * dV1;
        p = wh_prof(l2);
        float dl2 = V2.x; vec3 dn2 = V2.yzw / p.x; vec4 dV2 = wh_dU(V2, V2.yzw, n2, p.z / p.x, p.x);
        float l3 = l + 0.5 * h * dl2; vec3 n3 = n + 0.5 * h * dn2; vec4 V3 = V + 0.5 * h * dV2;
        p = wh_prof(l3);
        float dl3 = V3.x; vec3 dn3 = V3.yzw / p.x; vec4 dV3 = wh_dU(V3, V3.yzw, n3, p.z / p.x, p.x);
        float l4 = l + h * dl3; vec3 n4 = n + h * dn3; vec4 V4 = V + h * dV3;
        p = wh_prof(l4);
        float dl4 = V4.x; vec3 dn4 = V4.yzw / p.x; vec4 dV4 = wh_dU(V4, V4.yzw, n4, p.z / p.x, p.x);
        l += h / 6.0 * (dl1 + 2.0 * dl2 + 2.0 * dl3 + dl4);
        n = normalize(n + h / 6.0 * (dn1 + 2.0 * dn2 + 2.0 * dn3 + dn4));
        V += h / 6.0 * (dV1 + 2.0 * dV2 + 2.0 * dV3 + dV4);
        V.yzw -= dot(V.yzw, n) * n;
    }
}

// A vector of R^4 at (l, n) projected onto the tangent space, as (U_l, u)
vec4 wh_project(vec4 p, vec3 n, vec4 D) {
    float rad = dot(D.xyz, n);
    return vec4(p.z * rad + p.w * D.w, D.xyz - rad * n);
}

// The tangent at (l, n) whose geodesic, followed for its length, reaches (tl, tn) (as
// WormholeSpace.toward: the chord seen from (l, n) first, then two corrections by where its geodesic
// lands), the geodesic in RK4 steps of at most h0
vec4 wh_toward(float l, vec3 n, float tl, vec3 tn, float h0) {
    vec4 pe = wh_prof(l);
    vec4 pt = wh_prof(tl);
    vec4 T = vec4(pt.x * tn, pt.y);
    vec4 dT = T - vec4(pe.x * n, pe.y);
    vec4 D = wh_project(pe, n, dT);
    D *= length(dT) / max(length(D), 1e-9);
    for (int it = 0; it < 2; it++) {
        float gl = l;
        vec3 gn = n;
        float len = length(D);
        vec4 V = D / max(len, 1e-9);
        wh_geo(gl, gn, V, len, h0);
        vec4 pg = wh_prof(gl);
        D += wh_project(pe, n, T - vec4(pg.x * gn, pg.y));
    }
    return D;
}

// The cone of directions from (l, n) that can meet a toy near it, centred at (tl, tn), of chord
// radius c (ref/cull.py): (its axis, the cos of its half angle). The axis: the geodesic's direction
// to the centre (wh_toward). The space's sectional curvature is at most K = 1 / rho0^2, so (the
// hinge comparison, CAT(K)) a geodesic leaving at an angle theta from it stays at least
// asin(sin(sqrt(K) d) sin(theta)) / sqrt(K) from the centre at geodesic distance d; the toy's
// intrinsic radius is at most (2 / k) asin(k c / 2), k = 1 / min(R, rho0) the largest curvature of
// the space's geodesics in R^4.
vec4 wh_coneAt(float l, vec3 n, float tl, vec3 tn, float c, out float cth) {
    vec4 D = wh_toward(l, n, tl, tn, 0.2);
    float d = length(D);
    float k = 1.0 / min(wh_fillet, wh_rho0);
    float delta = 2.0 / k * asin(min(0.5 * k * c, 1.0));
    float sk = 1.0 / wh_rho0;
    if (d <= delta || sk * d > 0.45 * WH_PI) {
        // the eye in it, or too far for the comparison (sin(sqrt(K) d) grows only up to pi / 2)
        cth = -2.0;
    } else {
        float sn = sin(sk * delta) / sin(sk * d);
        cth = cos(min(asin(min(sn, 1.0)) + 2e-3, WH_PI));
    }
    return D / max(d, 1e-9);
}

// A screen corner's ray (clip xy), view space: the line from the eye through the corner unprojected
// at two depths (the far point, whatever the depth convention). Unnormalised, it is affine in the
// screen position, so the interpolated value is each pixel's ray exactly.
vec3 wh_cornerRay(vec2 xy, mat4 invProj, vec3 eyeOffset) {
    vec4 pa = invProj * vec4(xy, 0.001, 1.0);
    vec4 pb = invProj * vec4(xy, 0.999, 1.0);
    vec3 qa = pa.xyz / pa.w;
    vec3 qb = pb.xyz / pb.w;
    return (dot(qa, qa) > dot(qb, qb) ? qa : qb) - eyeOffset;
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
    int kind;      // 0 none, 1 floor, 2 object, 3 shell
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
    h.t = 1e9; h.kind = 0; h.nrm = vec3(0.0); h.col = vec3(0.0);
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
            float hl; vec3 hn; float arc;
            int ev = wh_curved(l0, n0, vl, w, eye, hl, hn, side, x, d, arc
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
                dbg = vec4(side > 0.0 ? 5.0 : 4.0, p);
            }
            break;
        }
        dist += h.t;
        wh_enter(side, x + h.t * d, d, l0, n0, vl, w);
        eye = vec2(wh_Rout(), 0.0);    // at the shell's edge (where r - rmin is not used)
        inShell = true;
    }
    if (kind == 1) side = fl > 0.0 ? 1.0 : -1.0;
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
