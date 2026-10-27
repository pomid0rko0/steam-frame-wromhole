// The movable balls and cubes (the toys): passes of their own, drawn before the world's ray tracer
// (main.gd). Each writes the depth of what it hits; the world's ray tracer, at the far plane, is then
// skipped by the GPU wherever a toy is seen, and runs where none is. So the world's ray tracer has
// no toys' code at all (it would take registers in every pixel), and a toy's pixels cost the
// toy's pass only. Two passes:
//  - a flat universe's toys seen straight from an eye there (wht_flat): each over a sphere around
//    it in the room (its proxy), exact: a ball is a sphere, a cube four pairs of planes;
//  - everything a ray meets after it enters the shell, or from an eye inside it (wht_shell): over a
//    sphere around the shell, or the whole view. Most rays there have no toy near their plane and
//    stop at once; the others search the curved path for each toy near it (below), then, if the
//    ray leaves the shell, test the flat toys of the universe it goes into.
// A toy hidden by the world (the floor, a static object, the shell before it) is not drawn: each
// pass tests what lies before its hit itself (wh_traceFlat), the floor in the shell bounds the
// search.
// The including file declares the core's uniforms (wormhole_core.gdshaderinc) and
//   vec4 wh_ball[WH_MAXB], wh_ballCol[WH_MAXB]   a ball: centre as a point of R^4 (xyz, w); (rgb,
//                                           radius). Every point of space whose chord distance in
//                                           R^4 to the centre is below the radius.
//   vec4 wh_fball[WH_MAXB]                  the same ball in the flat universe whose sheet cuts it:
//                                           the sphere cut, in that universe's chart (centre,
//                                           radius squared; < 0: none)
//   vec4 wh_cube[WH_MAXC], wh_cubeE[5 * WH_MAXC], wh_cubeCol[WH_MAXC], int wh_nCube
//                                           a cube: a 4D box of R^4 cut by the space, as a box of a
//                                           4D SDF scene. Centre as a point of R^4; per cube five
//                                           vectors: four orthonormal axes of R^4 divided by the half
//                                           size (three body axes tangent to the space, then its
//                                           normal), then dot(centre, axis) for the four; (rgb, half
//                                           size). A point P is inside when |dot(P, axis) -
//                                           dot(centre, axis)| < 1 for all four axes.
//   int wh_nBall                            balls in use (a loop bound the compiler cannot see)
//   vec4 wht_cx[5], ..., ivec4 wht_bit[5], wht_t1, wht_t2, wht_phiBin, wht_bBin, wht_bStep
//                                           the shell's pass's toys, a list in groups of four
//                                           (wht_near; ball i is bit i, cube i bit 16 + i)
//   float wh_pix                            a pixel's angle (the cubes' edge lines, the arrows)
// and WH_TOYS defined before the core (toys_view.gdshaderinc).

const int WH_MAXB = 12;
const int WH_MAXC = 6;
const int WHT_MAXT = 18;       // WH_MAXB + WH_MAXC
const int WHT_CONES = 4;       // toys near the head with a cone of their own
const int WHT_ITER = 24;       // points of the march along a ray in the shell, at most

// a toy's centre (R^4) and its reach: a ball's radius, a cube's half diagonal (2 half sizes)
vec4 wht_centre(int bit) {
    return bit >= 16 ? wh_cube[bit - 16] : wh_ball[bit];
}

float wht_size(int bit) {
    return bit >= 16 ? wh_cubeCol[bit - 16].w : wh_ballCol[bit].w;
}

#ifndef WHT_FLAT
// The toys a ray of the shell's pass can meet at all, before any search (ref/cull.py checks that
// none it drops is ever met). The pass's toys are a list (main.set_objects) in groups of four vec4s:
// wht_cx, wht_cy, wht_cz their centres, wht_r2 their reach squared (a ball's radius, a cube's half
// diagonal; -1: an empty place), wht_lo, wht_hi the l window of their points' meridian (lo > hi:
// none), wht_fs the flat universe whose sheet cuts them (+-1, 0: none), wht_bit their bits.
//  - the plane: a ray's whole path lies in span(e1, e2, the w axis), and a toy farther than its reach
//    from that subspace is never met. N = n x w for a ray at (n, w), or the chart point x d for a
//    straight one (as R^4 xyz); b = |N| r (the impact parameter);
//  - l: a ray reaches the l on its way on from l0 (the eye, or the shell's edge): away from the
//    throat or through it (b <= rho0) every l beyond l0 in its direction, one that turns only |l| at
//    least its turning point's, on its side; it leaves the shell on the eye's side, or through the
//    throat on the other: a flat universe's toy is met after the shell only by a ray that leaves
//    into it;
//  - skip: toys near the eye whose cone of directions (toys_view.gdshaderinc) the ray is outside.
// The space's symmetry makes the first two one test of the ray's plane's normal's azimuth round the
// radial axis and one of its impact parameter and direction along l: main._update_bins marks, per
// frame, each toy in the bins of those (wht_phiBin: 32 azimuths of N round the head's radial axis,
// in the frame wht_t1, wht_t2; wht_bBin: 32 b of wht_bStep each, for rays moving toward +l, then
// toward -l) a ray from either eye can meet it from, so a pixel tests only the few toys of its two
// bins exactly. Returns the list's toys to search in the shell (as bits of their places in the
// list), flatNear: those to test after it.
int wht_near(vec3 N, float b, float l0, float vl, int skip, out int flatNear) {
    float N2 = dot(N, N);
    float s = l0 > 0.0 ? 1.0 : -1.0;
    float sig = vl > 0.0 ? 1.0 : -1.0;
    int pb = clamp(int((wh_atan2(dot(N, wht_t2), dot(N, wht_t1)) + WH_PI) * (16.0 / WH_PI)), 0, 31);
    int bb = clamp(int(b / wht_bStep), 0, 31) + (sig > 0.0 ? 0 : 32);
    int cand = wht_phiBin[pb >> 2][pb & 3] & wht_bBin[bb >> 2][bb & 3] & ~skip;
    flatNear = 0;
    if (cand == 0) return 0;
    bool along = sig * l0 >= 0.0 || b <= wh_rho0;
    // the l it reaches: s' l >= lr (s' = sig along, s turning), and the side it leaves on
    float lr = along ? sig * l0 : wh_Lc() + wh_fillet * (acos(clamp(1.0 - (b - wh_rho0) / wh_fillet, -1.0, 1.0)) - wh_th0());
    float sr = along ? sig : s;
    int out_mask = 0;
    for (int m = cand; m != 0; m &= m - 1) {
        int k = findLSB(m);
        int g = k >> 2;
        int j = k & 3;
        float c = N.x * wht_cx[g][j] + N.y * wht_cy[g][j] + N.z * wht_cz[g][j];
        if (c * c > wht_r2[g][j] * N2) continue;
        float lo = wht_lo[g][j];
        float hi = wht_hi[g][j];
        if (lo <= hi && (sr > 0.0 ? hi >= lr : lo <= -lr)) out_mask |= 1 << k;
        if (wht_fs[g][j] == sr) flatNear |= 1 << k;
    }
    return out_mask;
}

// The toy bits of the list's places in m (wht_near)
int wht_bits(int m) {
    int out_mask = 0;
    for (; m != 0; m &= m - 1) {
        int k = findLSB(m);
        out_mask |= 1 << wht_bit[k >> 2][k & 3];
    }
    return out_mask;
}

#endif

// ---------------------------------------------------------------- flat universes
// Ball i along x + t d in a chart: where it enters the sphere its sheet cuts (wh_fball), or -1. Only
// entries count: a ray that starts inside does not see it from inside.
float wht_flatBall(int i, vec3 x, vec3 d) {
    vec4 S = wh_fball[i];
    vec3 oc = x - S.xyz;
    float bq = dot(oc, d);
    float cq = dot(oc, oc) - S.w;
    float disc = bq * bq - cq;
    return S.w > 0.0 && cq > 0.0 && bq < 0.0 && disc >= 0.0 ? -bq - sqrt(disc) : -1.0;
}

// Cube i cut by universe side's sheet (a convex solid bounded by four pairs of planes, an ordinary
// cube when the box's centre is on the sheet) along x + t d in its chart: the entry, or -1; face:
// the entry face's axis k + 1, negative for -axis
float wht_flatCube(int i, float side, vec3 x, vec3 d, out int face) {
    vec4 X = vec4(wh_M(side, x), side * wh_h) - wh_cube[i];
    vec3 md = wh_M(side, d);
    float tin = -1e30;
    float tout = 1e30;
    face = 0;
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
    return tin <= tout && tin > 0.0 ? tin : -1.0;
}

// The nearest of the toys in mask (of universe side) along x + t d before t: t, its bit (-1 none)
// and a cube's face
int wht_flatNearest(int mask, float side, vec3 x, vec3 d, inout float t, out int face) {
    int hit = -1;
    face = 0;
    for (int mm = mask; mm != 0; mm &= mm - 1) {
        int bit = findLSB(mm);
        int fc = 0;
        float tb = bit >= 16 ? wht_flatCube(bit - 16, side, x, d, fc) : wht_flatBall(bit, x, d);
        if (tb > 0.0 && tb < t) { t = tb; hit = bit; face = fc; }
    }
    return hit;
}

// A cube's colour at the point X (relative to its centre, in R^4): darker along the edges, lines
// about as wide as a pixel at the path length dist
vec3 wht_cubeLook(int i, vec4 X, float dist) {
    vec3 ad = abs(vec3(dot(X, wh_cubeE[5 * i]), dot(X, wh_cubeE[5 * i + 1]), dot(X, wh_cubeE[5 * i + 2])));
    float m1 = max(max(ad.x, ad.y), ad.z);
    float m3 = min(min(ad.x, ad.y), ad.z);
    float e = 1.0 - (ad.x + ad.y + ad.z - m1 - m3);    // to the nearest edge, in half sizes
    float fw = min(dist * wh_pix / wh_cubeCol[i].w, 0.05);
    float line = 1.0 - smoothstep(0.07 - fw, 0.07 + fw, e);
    return wh_cubeCol[i].rgb * (1.0 - 0.55 * line);
}

// A flat hit's colour, lit, in the fog: the toy bit at p = x + t d in universe side's chart
vec3 wht_flatLook(int bit, int face, float side, vec3 p, float dist) {
    vec3 col;
    vec3 nrm;
    if (bit >= 16) {
        int i = bit - 16;
        col = wht_cubeLook(i, vec4(wh_M(side, p), side * wh_h) - wh_cube[i], dist);
        int k = abs(face) - 1;
        nrm = normalize(wh_M(side, (face > 0 ? 1.0 : -1.0) * wh_cubeE[5 * i + k].xyz));
    } else {
        vec4 S = wh_fball[bit];
        col = wh_ballCol[bit].rgb;
        nrm = (p - S.xyz) * inversesqrt(S.w);
    }
    return mix(wh_shade(side, col, nrm), side > 0.0 ? vec3(0.95, 0.60, 0.35) : vec3(0.70, 0.82, 0.95),
               1.0 - exp(-dist * 0.012));
}

#ifdef WH_ARROWS
// A straight segment's crossing of the arrows' surface x = 0 (both charts) before tmax, into slc
// if none was found before (dist: the path length at x)
void wht_sliceFlat(float side, vec3 x, vec3 d, float tmax, float dist, inout vec3 slc) {
    float tS = -x.x / (abs(d.x) > 1e-9 ? d.x : 1e-9);
    if (slc.z < 0.0 && tS > 0.0 && tS < tmax) {
        vec3 p = x + tS * d;
        float ip = inversesqrt(dot(p, p));
        slc = vec3(side * (dot(p, p) * ip - wh_Rout() + wh_Lsh()), wh_atan2(p.z, p.y), dist + tS);
    }
}

// The arrow over a toy's colour c at path length dist, if its crossing comes first
vec3 wht_arrowOver(vec3 c, vec3 slc, float dist) {
    if (slc.z < 0.0 || slc.z >= dist) return c;
    vec4 ar = wh_arrow(slc.x, slc.y, slc.z * wh_pix);
    float side = slc.x >= 0.0 ? 1.0 : -1.0;
    vec3 a = mix(ar.rgb, side > 0.0 ? vec3(0.95, 0.60, 0.35) : vec3(0.70, 0.82, 0.95), 1.0 - exp(-slc.z * 0.012));
    return mix(c, a, ar.a);
}
#endif

// A toy of a flat universe seen straight from an eye there: the ray x + t d in universe side's chart
// (d unit) meets toy bit, nothing of the world before it. Returns (colour, the path length), w < 0:
// not seen. dbg: as wh_renderE's (balls 100 + i, cubes 200 + i, then the hit's R^4 xyz).
vec4 wht_flat(int bit, float side, vec3 x, vec3 d, out vec4 dbg) {
    dbg = vec4(-1.0);
    int face = 0;
    float t = bit >= 16 ? wht_flatCube(bit - 16, side, x, d, face) : wht_flatBall(bit, x, d);
    if (t <= 0.0) return vec4(-1.0);
    // the world before it: the floor, a static object, the shell (beyond its edge the ray bends)
    if (wh_traceFlat(side, x, d, true).t < t) return vec4(-1.0);
    vec3 p = x + t * d;
    vec3 c = wht_flatLook(bit, face, side, p, t);
#ifdef WH_ARROWS
    vec3 slc = vec3(-1.0);
    wht_sliceFlat(side, x, d, t, 0.0, slc);
    c = wht_arrowOver(c, slc, t);
#endif
    dbg = vec4(bit >= 16 ? 184.0 + float(bit) : 100.0 + float(bit), wh_M(side, p));
    return vec4(c, t);
}

#ifndef WHT_FLAT
// ---------------------------------------------------------------- the curved region
// The acceleration in R^4 of a geodesic of the space (the ray's subspace's coordinates), at radius r,
// angle (cos, sin) = (c, s) in the ray's plane, on the side side of the throat, impact parameter b,
// on the cylinder or a fillet: II(T, T) nu, the normal nu = (w' n, -r') of the profile (r, w)(l),
// II = l'^2 (w' r'' - r' w'') - (w' / r) (b / r)^2, l'^2 = 1 - (b / r)^2: on a fillet (a circle of
// radius R in the profile, th its angle) nu = (cos th n, -side sin th), w' r'' - r' w'' = 1 / R; on the
// cylinder nu = (n, 0) and only the second term (ref/toys.py checks it against differences of
// wht_point).
vec3 wht_accel(float r, float c, float s, float side, float b, bool cyl) {
    float br = b / r;
    if (cyl) return -(br * br / r) * vec3(c, s, 0.0);
    float X = r - wh_rho0;
    float cth = 1.0 - X / wh_fillet;
    float sth = sqrt(max(X * (2.0 * wh_fillet - X), 0.0)) / wh_fillet;
    float II = (1.0 - br * br) / wh_fillet - cth / r * br * br;
    return II * vec3(cth * c, cth * s, -side * sth);
}

// The path's point at the fraction sg of piece p (0 A, 1 B, 2 C: wh_ray), in the ray's subspace of
// R^4, coordinates (u, v, w) along (e1, e2, the w axis): Q = (r cos psi, r sin psi, w), and dQ =
// dQ / dsg exactly: the search steps by it. Fillets: sg runs z linearly (the
// moments' variable, smooth through a turning point), and dw / dz is taken in a form without the
// 0 / 0 where the fillet meets the cylinder (sin th = 0): dw/dz = side 2 (R - X) sqrt(span) H /
// sqrt(2R - X), X = r - rho0, H = sqrt(t + ga) (regime 0) or z / sqrt(t + al) (1, 2). A: the path's
// acceleration in path length (wht_accel).
void wht_point(WhRay Y, WhFil f, int p, float sg, out vec3 Q, out vec3 dQ, out float psi, out vec3 A) {
    float rho0 = wh_rho0;
    float R = wh_fillet;
    float r;
    float dr;
    float dpsi;
    if (p == 1) {
        psi = Y.PA.x + Y.PB.x * sg;
        dpsi = Y.PB.x;
        r = rho0;
        dr = 0.0;
        Q.z = Y.d * (Y.x0B + Y.DB * sg);
        dQ.z = Y.d * Y.DB;
    } else {
        bool pA = p == 0;
        float z0 = pA || Y.cFromStart ? Y.zs : f.zlo;
        float dz = (pA ? f.zlo : f.zhi) - z0;
        float z = z0 + dz * sg;
        float t;
        vec4 m;
        float dtz;
        float H;
        if (f.reg == 0) {
            float Es = f.E0 * exp(z);                  // sqrt(t + al) + sqrt(t + ga)
            float sm = 0.5 * (Es - wh_dm(f) / Es);     // sqrt(t + mn)
            float so = Es - sm;                        // sqrt(t + mx)
            t = max(sm * sm - wh_mn(f), 0.0);
            m = wh_filRec(f, z, t, sm * so);
            dtz = 2.0 * sm * so;
            H = f.al <= f.ga ? so : sm;
        } else {
            float mn = wh_mn(f);
            t = max(z * z - mn, 0.0);
            if (f.reg == 1) {                          // as wh_filMom
                float n0 = max(z - f.zlo, 0.0);
                float ty = t * z;
                float n1 = (ty - 2.0 * mn * n0) / 3.0;
                ty *= t;
                float n2 = (ty - 4.0 * mn * n1) / 5.0;
                m = vec4(n0, n1, n2, (ty * t - 6.0 * mn * n2) / 7.0);
            } else {
                float t2 = t * t;
                m = vec4(0.5 * t, 0.25 * t2, t2 * t / 6.0, 0.125 * t2 * t2);
            }
            dtz = 2.0 * z;
            H = f.al <= f.ga ? 1.0 : z * inversesqrt(t + f.al);
        }
        float pin = dot(f.e, m);                       // psi from the inner end
        float dpin = wh_poly(f.e, t) * (f.reg == 2 ? z : 1.0) * dz;
        psi = pA ? Y.PA.x - pin : Y.PA.x + Y.PB.x - Y.C0.x + pin;
        dpsi = pA ? -dpin : dpin;
        r = f.ra + f.span * t;
        dr = f.span * dtz * dz;
        float X = r - rho0;
        float q = 2.0 * R - X;
        float side = pA ? Y.sideA : Y.sideC;
        Q.z = side * (wh_h - R + sqrt(max(X * q, 0.0)));
        dQ.z = side * 2.0 * (R - X) * sqrt(f.span) * H * inversesqrt(q) * dz;
    }
    float c = cos(psi);
    float s = sin(psi);
    Q.xy = r * vec2(c, s);
    dQ.xy = dr * vec2(c, s) + r * dpsi * vec2(-s, c);
    A = wht_accel(r, c, s, p == 0 ? Y.sideA : Y.sideC, Y.b, p == 1);
}


// The first of the toys in mask (their bits) the ray meets in the shell before the floor (psiEnd):
// hitK (2 (piece - 1) + sg) and hitBit (< 0: none). One march along the path for all of them, from the
// start of the first piece any can be met on (st: the ray's start, (l, vl, |w|)). A toy's centre seen
// in the ray's subspace, cb, its distance from it sqrt(perp2), its reach ball's shadow on the ray's
// plane: a disc, seen from the centre within +-dps of psc. Along the path psi only grows, and the
// whole path in the shell turns by less than pi (it meets the floor by then): so the toy can be met
// only while psi is in [psc - dps, psc + dps], once; past it, it is dropped. At each point every toy
// still in the march gives the longest step that cannot pass its entry, and the march takes the
// shortest: it reaches the nearest entry without passing any. k, the path's largest curvature in R^4
// on a piece: on a fillet 1 / min(R, rho0) (its profile's, or a parallel's at most), on the cylinder
// its helix's b^2 / rho0^3.
//  - a ball: F = |P - C|^2 - radius^2 along the path, F'' = 2 (1 + (P - C) . A) in path length, A the
//    path's acceleration (wht_accel: exact for the path wht_point gives within 2% of k), whose change
//    is at most j3 per metre; |P - C| <= |D| + s: so for s <= S F is at least F + F' s + m s^2 / 2,
//    m = F'' - 2 (|D| + S) (j3 S / 3 + 0.02 k), and a step goes to the first root of that (S: three
//    tangent steps, within |P - C| < 0.9 / k, where F is convex: past the closest approach (F' >= 0)
//    there is no entry). Farther away a step goes to 0.8 of |P - C| - radius. Within 0.1 mm of the
//    entry is the hit. Near the eye this takes 2-3 points of the path where the bound by k alone took
//    4-6 (ref/toys.py);
//  - a cube: a slab's signed distance h along the path has |h''| <= k, so |h| cannot fall to the
//    half size sooner than at the smallest D >= 0 with |h| - half - v D - k D^2 / 2 <= 0 (v: the
//    speed toward it): its step goes to the latest of the four slabs' earliest; past it once outside
//    its reach ball moving away.
// The ray's start is a point of the path known without wht_point. Only entries count: a ray that
// starts inside a toy does not see it from inside.
void wht_march(WhRay Y, WhFil f, int mask, float psiEnd, vec3 st, out float hitK, out int hitBit) {
    hitK = 4.0;
    hitBit = -1;
    // the toys whose shadow the path reaches before the floor, and the first piece any is on
    float lo = 10.0;
    for (int mm = mask; mm != 0; mm &= mm - 1) {
        int bit = findLSB(mm);
        vec4 C = wht_centre(bit);
        float reach = (bit >= 16 ? 2.0 : 1.0) * wht_size(bit);
        vec3 cb = vec3(dot(C.xyz, Y.e1), dot(C.xyz, Y.e2), C.w);
        float rho2 = dot(cb.xy, cb.xy);
        float re2 = reach * reach - max(dot(C.xyz, C.xyz) - rho2, 0.0);
        float psc = wh_atan2(cb.y, cb.x);
        psc = psc < -0.5 * WH_PI ? psc + 2.0 * WH_PI : psc;    // the copy that can meet [0, pi)
        float dps = re2 < rho2 ? wh_asin(sqrt(re2 / rho2)) : 10.0;
        if (re2 <= 0.0 || psc + dps < 0.0 || psc - dps > psiEnd)
            mask &= ~(1 << bit);
        else
            lo = min(lo, psc - dps);
    }
    if (mask == 0) return;
    int p0 = Y.hasA ? 0 : (Y.hasB ? 1 : 2);
    int p = p0;
    if (p == 0 && lo > Y.PA.x) p = Y.hasB ? 1 : 2;
    if (p == 1 && lo > Y.PA.x + Y.PB.x) p = 2;
    bool start = p == p0;       // sg = 0 is the ray's start
    float sg = 0.0;
    float sgo = -1.0;           // a point of this piece known outside them all, or < 0
    // the point: Q, its unit tangent T and acceleration A, psi, and dpath / dsg (speed)
    vec3 Q = vec3(0.0); vec3 T = vec3(0.0); vec3 A = vec3(0.0);
    float psi = 0.0;
    float speed = 1.0;
    bool have = start;
    if (start) {
        vec4 pr = wh_prof(st.x);
        Q = vec3(pr.x, 0.0, pr.y);
        T = vec3(st.y * pr.z, st.z, st.y * pr.w);
        A = wht_accel(pr.x, 1.0, 0.0, st.x > 0.0 ? 1.0 : -1.0, Y.b, p == 1);
        // psi = (b / r^2) path on the way, and on a fillet dpsi / dsg is wht_point's
        speed = p == 1 ? length(vec2(wh_rho0 * Y.PB.x, Y.DB))
                       : pr.x * pr.x * f.ib * abs(wh_poly(f.e, Y.ts) * (f.reg == 2 ? Y.zs : 1.0)
                                                  * ((p == 0 ? f.zlo : f.zhi) - Y.zs));
    }
    float kf = 1.0 / min(wh_fillet, wh_rho0);
    for (int it = 0; it < WHT_ITER + min(wh_nBall, 0); it++) {
        if (!have) {
            vec3 dQ;
            wht_point(Y, f, p, sg, Q, dQ, psi, A);
            speed = max(length(dQ), 1e-30);
            T = dQ / speed;
        }
        have = false;
        if (psi > psiEnd) return;
        float kp = p == 1 ? Y.b * Y.b / (wh_rho0 * wh_rho0 * wh_rho0) : kf;
        float j3 = p == 1 ? kp * Y.b / (wh_rho0 * wh_rho0)
                          : kf * kf + 1.155 * (1.0 / (wh_fillet * wh_rho0) + 1.0 / (wh_rho0 * wh_rho0));
        float step = 1e9;
        for (int mm = mask; mm != 0; mm &= mm - 1) {
            int bit = findLSB(mm);
            bool isCube = bit >= 16;
            vec4 C = wht_centre(bit);
            float size = wht_size(bit);
            float reach = isCube ? 2.0 * size : size;
            vec3 cb = vec3(dot(C.xyz, Y.e1), dot(C.xyz, Y.e2), C.w);
            float rho2 = dot(cb.xy, cb.xy);
            float perp2 = max(dot(C.xyz, C.xyz) - rho2, 0.0);
            float re2 = reach * reach - perp2;
            vec3 D = Q - cb;
            float D2 = dot(D, D) + perp2;
            // past its shadow: the angle from cb to Q in the plane beyond dps
            float cr = cb.x * Q.y - cb.y * Q.x;
            bool drop = re2 < rho2 && cr > 0.0 && cr * sqrt(rho2 - re2) > dot(cb.xy, Q.xy) * sqrt(re2);
            float ds = 1e9;
            if (!drop && !isCube) {
                float F = D2 - reach * reach;
                float Fs = 2.0 * dot(D, T);
                if (F <= 0.0) {
                    // the eye in it: not seen; else past its entry by rounding: Newton back
                    drop = start;
                    if (!drop) {
                        float nx = Fs < 0.0 ? sg - F / (Fs * speed) : sg;
                        hitK = 2.0 * float(p - 1) + (sgo < 0.0 ? nx : max(nx, sgo));
                        hitBit = bit;
                        return;
                    }
                } else {
                    float Dn = sqrt(D2);
                    if (Dn * kp < 0.9) {
                        drop = Fs >= 0.0;              // past the closest approach: no entry
                        float S = min(0.9 / kp - Dn, -3.0 * F / Fs);
                        float m = 2.0 * (1.0 + dot(D, A)) - 2.0 * (Dn + S) * (j3 * S / 3.0 + 0.02 * kp);
                        float disc = Fs * Fs - 2.0 * m * F;
                        float r1 = 2.0 * F / (-Fs + sqrt(max(disc, 0.0)));
                        bool root = disc >= 0.0 && r1 <= S;
                        ds = root ? r1 : S;
                        if (!drop && root && r1 < 1e-4) {
                            hitK = 2.0 * float(p - 1) + sg + r1 / speed;
                            hitBit = bit;
                            return;
                        }
                    } else {
                        ds = 0.8 * (Dn - reach);
                    }
                }
            } else if (!drop) {
                // the signed distances h (m) to the four mid-planes, and the speeds toward them; an
                // axis seen in the ray's subspace (it is used at once: not held)
                int ci = bit - 16;
                bool inside = true;
                float Ds = 0.0;
                for (int j = 0; j < 4 + min(wh_nCube, 0); j++) {
                    vec4 Ek = wh_cubeE[5 * ci + j];
                    vec3 ek = vec3(dot(Ek.xyz, Y.e1), dot(Ek.xyz, Y.e2), Ek.w);
                    float h = size * (dot(Q, ek) - wh_cubeE[5 * ci + 4][j]);
                    float e = abs(h) - size;
                    if (e > 0.0) {
                        inside = false;
                        float v = -sign(h) * size * dot(T, ek);
                        Ds = max(Ds, 2.0 * e / (v + sqrt(v * v + 2.0 * kp * e)));
                    }
                }
                drop = inside ? start : D2 > reach * reach && dot(D, T) > 0.0;
                if (!drop && (inside || Ds < 1e-6)) {
                    hitK = 2.0 * float(p - 1) + sg;
                    hitBit = bit;
                    return;
                }
                ds = Ds;
            }
            if (drop)
                mask &= ~(1 << bit);
            else
                step = min(step, ds);
        }
        if (mask == 0) return;
        start = false;
        sgo = sg;
        float nsg = sg + step / speed;
        if (nsg >= 1.0) {
            // on to the next piece, at its start
            if (p == 2) return;
            p = p == 0 && Y.hasB ? 1 : 2;
            nsg = 0.0;
            sgo = -1.0;
        }
        sg = nsg;
    }
}

// The hit at hitK of the shell's search: its l and n, the path length to it
void wht_at(WhRay Y, WhFil f, float key, out float hl, out vec3 hn, out float arc) {
    int p = min(int(floor(0.5 * key)) + 1, 2);
    float q = key - 2.0 * float(p - 1);
    vec2 cum;
    if (p == 1) {
        float xh = Y.DB * q;
        cum = Y.PA + vec2(Y.kc, Y.ivlc) * xh;
        hl = Y.d * (Y.x0B + xh);
    } else {
        float z0 = p == 0 || Y.cFromStart ? Y.zs : f.zlo;
        float z1 = p == 0 ? f.zlo : f.zhi;
        float t;
        cum = (p == 0 ? Y.PA : Y.PA + Y.PB - Y.C0) + (p == 0 ? -1.0 : 1.0) * wh_filAt(f, mix(z0, z1, q), t);
        hl = wh_filLW(f, t, p == 0 ? Y.sideA : Y.sideC).x;
    }
    hn = cos(cum.x) * Y.e1 + sin(cum.x) * Y.e2;
    arc = cum.y;
}

// A toy's colour at its hit in the curved region, at (hl, hn), path length dist: lit by the
// universe of the hit's side. A ball's normal is its R^4 offset from the centre projected onto the
// space's tangent space; a cube's, the normal of the face hit (its largest slab coordinate),
// projected the same way.
vec3 wht_curvedLook(int bit, float hl, vec3 hn, float dist) {
    vec4 pr = wh_prof(hl);
    bool isCube = bit >= 16;
    int ci = bit - 16;
    vec4 N4 = vec4(pr.x * hn, pr.y) - wht_centre(bit);
    vec3 col;
    if (isCube) {
        col = wht_cubeLook(ci, N4, dist);
        vec3 sd = vec3(dot(N4, wh_cubeE[5 * ci]), dot(N4, wh_cubeE[5 * ci + 1]), dot(N4, wh_cubeE[5 * ci + 2]));
        vec3 ad = abs(sd);
        int k = ad.x >= ad.y && ad.x >= ad.z ? 0 : (ad.y >= ad.z ? 1 : 2);
        N4 = (sd[k] >= 0.0 ? 1.0 : -1.0) * wh_cubeE[5 * ci + k];
    } else {
        col = wh_ballCol[bit].rgb;
    }
    float rad = dot(N4.xyz, hn);
    float side = hl >= 0.0 ? 1.0 : -1.0;
    vec3 nrm = normalize(wh_M(side, side * (pr.z * rad + pr.w * N4.w) * hn + N4.xyz - rad * hn));
    return mix(wh_shade(side, col, nrm), side > 0.0 ? vec3(0.95, 0.60, 0.35) : vec3(0.70, 0.82, 0.95),
               1.0 - exp(-dist * 0.012));
}

// Everything a ray meets once it is in the shell: from an eye inside it, or from an eye in a flat
// universe through the shell (the straight part before is the flat pass's). l0, n0, (vl, w): the
// ray at the eye, as wh_renderE takes it; eye = wh_eye(l0). Returns (colour, the path length), w < 0:
// none (no toy met, or the world before it).
vec4 wht_shell(float l0, vec3 n0, float vl, vec3 w, vec2 eye, int skip, out vec4 dbg) {
    dbg = vec4(-1.0);
    float side = l0 > 0.0 ? 1.0 : -1.0;
    bool outside = abs(l0) >= wh_Lsh();
    vec3 x = vec3(0.0);
    vec3 d = vec3(0.0);
    float dist = 0.0;
    vec3 N = cross(n0, w);
    float b = eye.x * length(w);
    float le = l0;
    float ve = vl;
    if (outside) {
        // straight to the shell
        x = wh_M(side, (abs(l0) - wh_Lsh() + wh_Rout()) * n0);
        d = wh_M(side, side * vl * n0 + w);
        float bq = dot(x, d);
        float disc = bq * bq - dot(x, x) + wh_Rout() * wh_Rout();
        if (disc <= 0.0 || bq >= 0.0) return vec4(-1.0);
        dist = -bq - sqrt(disc);
        N = cross(wh_M(side, x), wh_M(side, d));
        b = length(N);
        le = side * wh_Lsh();
        ve = -side;
    }
    // the toys the ray can meet: most rays have none and stop here
    int flatNear;
    int near = wht_near(N, b, le, ve, skip, flatNear);
    if ((near | flatNear) == 0) return vec4(-1.0);
    if (outside) {
        wh_enter(side, x + dist * d, d, l0, n0, vl, w);
        eye = vec2(wh_Rout(), 0.0);
    }
    WhFil f;
    WhRay Y = wh_ray(l0, n0, vl, w, eye, f);
    float psiEnd = Y.floorHit ? wh_floorPsi(Y) : Y.tot.x;
    float hitK;
    int hitBit;
    wht_march(Y, f, wht_bits(near), psiEnd, vec3(l0, vl, length(w)), hitK, hitBit);
    vec3 c;
    float at;
#ifdef WH_ARROWS
    vec3 slc = vec3(-1.0);
    if (outside) wht_sliceFlat(side, x, d, dist, 0.0, slc);
    wh_slice(Y, f, dist, slc);
#endif
    if (hitBit >= 0) {
        float hl; vec3 hn; float arc;
        wht_at(Y, f, hitK, hl, hn, arc);
        at = dist + arc;
        c = wht_curvedLook(hitBit, hl, hn, at);
        dbg = vec4(hitBit >= 16 ? 184.0 + float(hitBit) : 100.0 + float(hitBit), wh_prof(hl).x * hn);
    } else {
        if (Y.floorHit) return vec4(-1.0);
        // out of the shell into a flat universe: its toys there, straight
        vec3 X; vec3 D;
        wh_exit(Y, X, D);
        float t = 1e9;
        int face;
        int bitF = wht_flatNearest(wht_bits(flatNear), Y.sideC, X, D, t, face);
        if (bitF < 0 || wh_traceFlat(Y.sideC, X, D, false).t < t) return vec4(-1.0);
        at = dist + Y.tot.y + t;
        vec3 p = X + t * D;
        c = wht_flatLook(bitF, face, Y.sideC, p, at);
#ifdef WH_ARROWS
        wht_sliceFlat(Y.sideC, X, D, t, dist + Y.tot.y, slc);
#endif
        dbg = vec4(bitF >= 16 ? 184.0 + float(bitF) : 100.0 + float(bitF), wh_M(Y.sideC, p));
    }
    // the world before the shell: the floor or a static object hides it all
    if (outside && wh_traceFlat(side, x, d, true).kind != 3) {
        dbg = vec4(-1.0);
        return vec4(-1.0);
    }
#ifdef WH_ARROWS
    c = wht_arrowOver(c, slc, at);
#endif
    return vec4(c, at);
}

#endif
