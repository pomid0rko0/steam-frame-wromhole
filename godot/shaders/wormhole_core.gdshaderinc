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
//   vec4 wh_cube[WH_MAXC], wh_cubeE[4 * WH_MAXC], wh_cubeCol[WH_MAXC], int wh_nCube
//                                           movable cubes: a 4D box of R^4 cut by the space, as a box
//                                           of a 4D SDF scene. Centre as a point of R^4; four orthonormal
//                                           axes of R^4 divided by the half size (three body axes tangent
//                                           to the space, then its normal); (rgb, half size). A point P
//                                           is inside when |dot(P - centre, axis)| < 1 for all four axes.
//                                           In a flat universe this is an ordinary cube.
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
//   cylinder: closed form;  fillet: with s = sin(th/2), s = q sinh v or q cosh v the integrand is
//   smooth and bounded, integrated with adaptive Simpson steps.
//
// Manifold point: (l, n), n unit 3-vector. Tangent vector: (vl, w), w orthogonal to n.
// Point in R^4: E = (r n, w(l)). Flat charts: side A (l >= L): x = r n;  side B: x = P r n, P = diag(-1,1,1).
// The floor is the totally geodesic equatorial surface n.z = 0 (z = 0 in both charts).

const float WH_PI = 3.14159265358979;
const int WH_MAXB = 12;
const int WH_MAXC = 6;
const int WH_MAXCC = 4;      // cubes a single ray can meet inside the shell

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

// ---------------------------------------------------------------- curved part
struct WhRay {
    float b;      // impact parameter (conserved angular momentum)
    float q;      // fillet: s = q sinh v (hyp) or s = q cosh v
    bool hyp;
};

float wh_S(WhRay o, float v) { return o.hyp ? o.q * sinh(v) : o.q * cosh(v); }

// v for a given s. dsq = s^2 - sig = (r(s) - b) / (2R), passed in from a cancellation-free
// expression: acosh(s/q) is ill-conditioned near s = q, asinh(sqrt(dsq)/q) is not.
float wh_V(WhRay o, float s, float dsq) { return o.hyp ? asinh(s / o.q) : asinh(sqrt(max(dsq, 0.0)) / o.q); }

// (dpsi/dv, ds/dv) on a fillet; ds/dv = r^2/b dpsi/dv is the path length
vec2 wh_g(WhRay o, float v) {
    float s = wh_S(o, v);
    float r = wh_rho0 + 2.0 * wh_fillet * s * s;
    float k = sqrt(2.0 * wh_fillet) / sqrt(max(1.0 - s * s, 1e-6) * (r + o.b));
    return vec2(o.b / r, r) * k;
}

float wh_lOnFillet(WhRay o, float side, float v) {
    float th = 2.0 * asin(min(wh_S(o, v), 1.0));
    return side * (wh_Lc() + wh_fillet * (th - wh_th0()));
}

// A cube's four slab coordinates at two successive samples of a ray, d0 and d1 (inside: all
// within [-1, 1]). Between samples the ray is taken as the chord, so thin corners and edges are
// not skipped. Returns the chord fraction where it enters the box, or -1.
float wh_chordIn(vec4 d0, vec4 d1) {
    vec4 dd = d1 - d0;
    dd = (step(vec4(0.0), dd) * 2.0 - 1.0) * max(abs(dd), vec4(1e-9));    // no division by 0
    vec4 ta = (-1.0 - d0) / dd;
    vec4 tb = (1.0 - d0) / dd;
    vec4 lo = min(ta, tb);
    vec4 hi = max(ta, tb);
    float tin = max(max(lo.x, lo.y), max(lo.z, lo.w));
    float tout = min(min(hi.x, hi.y), min(hi.z, hi.w));
    return (tin <= tout && tin >= 0.0 && tin <= 1.0) ? tin : -1.0;
}

// A ball (radius^2 r2, centre at the origin) against the chord a -> a + d between two samples of
// a ray: the chord fraction where it enters, or -1. Catches rays that only graze the ball and
// would pass in and out of it between the samples.
float wh_chordInBall(vec3 a, vec3 d, float r2) {
    float A = max(dot(d, d), 1e-20);
    float B = dot(a, d);
    float C = dot(a, a) - r2;
    float disc = B * B - A * C;
    if (C <= 0.0 || disc < 0.0) return -1.0;
    float t = (-B - sqrt(disc)) / A;
    return (t >= 0.0 && t <= 1.0) ? t : -1.0;
}

// Distance from slab coordinates d to the box |d| <= 1 (negative inside), in half sizes.
float wh_boxDist(vec4 d) {
    vec4 q = abs(d) - 1.0;
    return length(max(q, vec4(0.0))) + min(max(max(q.x, q.y), max(q.z, q.w)), 0.0);
}

// Ray starting inside (or on the boundary of) the shell, |ls| <= L. Returns
//   0: leaves the shell, given in flat chart coordinates (outSide, outX, outD)
//   1: hits the floor at (hitL, hitN)        2: enters ball ballI at (hitL, hitN)
//      (ballI >= WH_MAXB: cube ballI - WH_MAXB)
// arc = path length travelled inside the shell.
int wh_curved(float ls, vec3 ns, float vl, vec3 w,
              out float hitL, out vec3 hitN, out int ballI,
              out float outSide, out vec3 outX, out vec3 outD, out float arc) {
    float rho0 = wh_rho0;
    float R = wh_fillet;
    float Lc = wh_Lc();
    float s0 = sin(0.5 * wh_th0());
    float s1 = 0.70710678118654752;
    float rmin = rho0 + 2.0 * R * s0 * s0;
    float Rout = wh_Rout();
    float wn = length(w);
    WhRay o;
    float rs = wh_r(ls);
    o.b = rs * wn;
    float sig = (o.b - rho0) / (2.0 * R);
    o.hyp = sig <= 0.0;
    o.q = sqrt(max(abs(sig), 1e-12));
    vec3 e1 = ns;
    vec3 e2 = wn > 1e-7 ? w / wn : normalize(cross(ns, abs(ns.x) < 0.9 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0)));
    float sStart = sin(0.5 * (wh_th0() + max(abs(ls) - Lc, 0.0) / R));
    float dStart = rs * vl * vl / ((1.0 + wn) * 2.0 * R);   // (r_s - b) / 2R without cancellation
    float d0 = (rmin - o.b) / (2.0 * R);
    float d1 = (Rout - o.b) / (2.0 * R);

    hitL = 0.0; hitN = vec3(0.0); ballI = -1;
    outX = vec3(0.0); outD = vec3(0.0);
    arc = 0.0;

    // first crossing of the floor (n.z = 0) in the orbit plane
    float psiF = mod(atan(e2.z, e1.z) + 0.5 * WH_PI, WH_PI);
    bool above = ns.z > 0.0;
    float psi = 0.0;

    // Balls that this ray can reach: the whole ray lies in span(e1, e2, w-axis) of R^4,
    // so a ball whose centre is farther than its radius from that subspace is never hit.
    int cand[WH_MAXB];
    vec4 cdat[WH_MAXB];      // (c1, c2, |c_xyz|^2, w_c)
    float crad[WH_MAXB];
    bool cin[WH_MAXB];
    int nc = 0;
    float minRad = 1e9;
    // Distance in R^4 from the ray's current point to the nearest ball or cube in reach (<= 0
    // inside one). The path to any of them is at least as long as this chord, so the next sample
    // can be that far ahead without stepping over anything.
    float reach = 1e30;
    vec4 ps = wh_prof(ls);
    // the previous sample in the ray's subspace: (r cos psi, r sin psi, w)
    vec3 prevX = vec3(ps.x, 0.0, ps.y);
    for (int i = 0; i < WH_MAXB; i++) {
        if (i >= wh_nBall) break;
        vec4 C = wh_ball[i];
        float rad = wh_ballCol[i].w;
        float c1 = dot(C.xyz, e1);
        float c2 = dot(C.xyz, e2);
        float cc = dot(C.xyz, C.xyz);
        if (cc - c1 * c1 - c2 * c2 >= rad * rad) continue;
        // inside the shell |xyz| = r <= Rout: a ball entirely outside is met only in the flat sheets
        if (cc > (Rout + rad) * (Rout + rad)) continue;
        cand[nc] = i;
        cdat[nc] = vec4(c1, c2, cc, C.w);
        crad[nc] = rad;
        float dw0 = ps.y - C.w;
        float q0 = ps.x * ps.x - 2.0 * ps.x * c1 + cc + dw0 * dw0;    // start: psi = 0, n = e1
        cin[nc] = q0 < rad * rad;
        reach = min(reach, sqrt(max(q0, 0.0)) - rad);
        minRad = min(minRad, rad);
        nc++;
    }
    // Cubes in reach: their box lies within 2 half sizes of the centre. Per cube the slab
    // coordinates along the orbit plane are  d = r cos(psi) A[0] + r sin(psi) A[1] + w A[2] - A[3].
    int ccand[WH_MAXCC];
    mat4 cq[WH_MAXCC];
    vec4 cprev[WH_MAXCC];    // slab coordinates at the previous sample
    float chalf[WH_MAXCC];
    int ncc = 0;
    for (int i = 0; i < WH_MAXC; i++) {
        if (i >= wh_nCube || ncc >= WH_MAXCC) break;
        vec4 C = wh_cube[i];
        float rad = 2.0 * wh_cubeCol[i].w;
        float c1 = dot(C.xyz, e1);
        float c2 = dot(C.xyz, e2);
        float cc = dot(C.xyz, C.xyz);
        if (cc - c1 * c1 - c2 * c2 >= rad * rad) continue;
        if (cc > (Rout + rad) * (Rout + rad)) continue;
        mat4 A;
        for (int k = 0; k < 4; k++) {
            vec4 ax = wh_cubeE[4 * i + k];
            A[0][k] = dot(ax.xyz, e1);
            A[1][k] = dot(ax.xyz, e2);
            A[2][k] = ax.w;
            A[3][k] = dot(C, ax);
        }
        ccand[ncc] = i;
        cq[ncc] = A;
        cprev[ncc] = ps.x * A[0] + ps.y * A[2] - A[3];     // start: psi = 0, n = e1
        chalf[ncc] = wh_cubeCol[i].w;
        reach = min(reach, chalf[ncc] * wh_boxDist(cprev[ncc]));
        minRad = min(minRad, chalf[ncc]);
        ncc++;
    }
    bool near = nc + ncc > 0;
    float ds = 0.35 * minRad;        // the finest sampling step (path length), close to balls and cubes

    // the path inside the shell: up to three pieces (fillet, cylinder, fillet)
    int pk[3];  float pside[3];  float pa[3];  float pb[3];
    int np = 0;
    if (o.b <= rmin) {
        // passes the throat: oriented coordinate x = d l runs to +L
        float d = vl >= 0.0 ? 1.0 : -1.0;
        float x = ls * d;
        outSide = d;
        if (x < -Lc) { pk[np] = 0; pside[np] = -d; pa[np] = wh_V(o, sStart, dStart); pb[np] = wh_V(o, s0, d0); np++; }
        if (Lc > 0.0 && x < Lc) { pk[np] = 1; pside[np] = d; pa[np] = max(x, -Lc); pb[np] = Lc; np++; }
        pk[np] = 0; pside[np] = d; pa[np] = x > Lc ? wh_V(o, sStart, dStart) : wh_V(o, s0, d0); pb[np] = wh_V(o, s1, d1); np++;
    } else {
        // turns around inside the fillet on its own side
        float side = ls > 0.0 ? 1.0 : -1.0;
        outSide = side;
        float vs = wh_V(o, sStart, dStart);
        pk[0] = 0; pside[0] = side; pa[0] = vl * side < 0.0 ? -vs : vs; pb[0] = wh_V(o, s1, d1); np = 1;
    }

    int budget = 160;
    for (int p = 0; p < 3; p++) {
        if (p >= np) break;
        float side = pside[p];
        if (pk[p] == 1) {
            // ---- cylinder r = rho0, w = l: psi = psi0 + k (x - x0), path = (x - x0) / vlc
            float x0 = pa[p];
            float D = pb[p] - x0;
            float wc = o.b / rho0;
            float vlc = max(sqrt(max(1.0 - wc * wc, 0.0)), 1e-7);
            float k = wc / (rho0 * vlc);
            float xF = above ? (psiF - psi) / max(k, 1e-30) : 1e30;   // floor, measured from x0
            float xB = 1e30;
            if (near) {
                float u = 0.0;
                for (int j = 0; j < 160; j++) {
                    if (u > xF || xB < 1e29) break;
                    float hx = max(min(max(reach, ds) * vlc, D - u), (D - u) / float(max(budget, 1)));
                    bool last = hx >= D - u;
                    float un = last ? D : u + hx;
                    hx = un - u;
                    budget--;
                    float pj = psi + k * un;
                    float lj = side * (x0 + un);
                    float cp = rho0 * cos(pj);
                    float sp = rho0 * sin(pj);
                    reach = 1e30;
                    for (int c = 0; c < WH_MAXCC; c++) {
                        if (c >= ncc) break;
                        vec4 d1 = cp * cq[c][0] + sp * cq[c][1] + lj * cq[c][2] - cq[c][3];
                        float tc = wh_chordIn(cprev[c], d1);
                        if (tc >= 0.0 && u + tc * hx < xB) { xB = u + tc * hx; ballI = WH_MAXB + ccand[c]; }
                        cprev[c] = d1;
                        reach = min(reach, chalf[c] * wh_boxDist(d1));
                    }
                    vec3 X1 = vec3(cp, sp, lj);
                    for (int c = 0; c < WH_MAXB; c++) {
                        if (c >= nc) break;
                        float dw = lj - cdat[c].w;
                        float q = rho0 * rho0 - 2.0 * (cdat[c].x * cp + cdat[c].y * sp) + cdat[c].z + dw * dw;
                        bool inside = q < crad[c] * crad[c];
                        if (!inside && !cin[c]) {
                            // outside at both samples: did the chord between them graze the ball?
                            vec3 B3 = vec3(cdat[c].x, cdat[c].y, cdat[c].w);
                            float perp = cdat[c].z - cdat[c].x * cdat[c].x - cdat[c].y * cdat[c].y;
                            float tb = wh_chordInBall(prevX - B3, X1 - prevX, crad[c] * crad[c] - perp);
                            if (tb >= 0.0 && u + tb * hx < xB) { xB = u + tb * hx; ballI = cand[c]; }
                        }
                        if (inside && !cin[c]) {
                            float lo = u;
                            float hi = un;
                            for (int it = 0; it < 8; it++) {
                                float m = 0.5 * (lo + hi);
                                float pm = psi + k * m;
                                float dm = side * (x0 + m) - cdat[c].w;
                                bool im = rho0 * rho0 - 2.0 * rho0 * (cdat[c].x * cos(pm) + cdat[c].y * sin(pm)) + cdat[c].z + dm * dm < crad[c] * crad[c];
                                if (im) { hi = m; } else { lo = m; }
                            }
                            if (hi < xB) { xB = hi; ballI = cand[c]; }
                        }
                        cin[c] = inside;
                        reach = min(reach, sqrt(max(q, 0.0)) - crad[c]);
                    }
                    prevX = X1;
                    u = un;
                    if (last) break;
                }
            }
            if (xB < 1e29 && xB <= xF) {
                hitL = side * (x0 + xB);
                float ph = psi + k * xB;
                hitN = cos(ph) * e1 + sin(ph) * e2;
                arc += xB / vlc;
                return 2;
            }
            ballI = -1;
            if (xF <= D) {
                hitL = side * (x0 + xF);
                hitN = cos(psiF) * e1 + sin(psiF) * e2;
                arc += xF / vlc;
                return 1;
            }
            psi += D * k;
            arc += D / vlc;
            continue;
        }
        // ---- fillet: Simpson steps in v, at most 0.25 (the accuracy of psi); close to balls and
        // cubes at most `reach` of path (at least ds)
        float va = pa[p];
        float vb = pb[p];
        float U = abs(vb - va);
        float dv = vb >= va ? 1.0 : -1.0;
        float hBase = U / max(ceil(U / 0.25), 1.0);
        float vt = 0.0;          // |v - va| done
        vec2 ga = wh_g(o, va);
        for (int k = 0; k < 160; k++) {
            float hs = hBase;
            if (near) hs = min(hs, max(max(reach, ds) / max(ga.y, 1e-6), (U - vt) / float(max(budget, 1))));
            bool last = hs >= U - vt - 1e-4 * hBase;
            if (last) hs = U - vt;
            budget--;
            float v0 = va + dv * vt;
            vec2 gm = wh_g(o, v0 + dv * 0.5 * hs);
            vec2 gb = wh_g(o, v0 + dv * hs);
            vec2 dI = hs / 6.0 * (ga + 4.0 * gm + gb);
            float allowed = max(reach, ds);
            if (near && dI.y > 1.02 * allowed && hs > (U - vt) / float(max(budget, 1))) {
                // the path grew faster along the step than ga.y said: shorten it to `allowed`
                hs *= 0.98 * allowed / dI.y;
                last = false;
                gm = wh_g(o, v0 + dv * 0.5 * hs);
                gb = wh_g(o, v0 + dv * hs);
                dI = hs / 6.0 * (ga + 4.0 * gm + gb);
            }
            float uF = 1e30;
            if (above && psi + dI.x >= psiF) {
                float target = psiF - psi;
                float u = hs * target / max(dI.x, 1e-30);
                for (int it = 0; it < 2; it++) {
                    float I = 0.5 * u * (wh_g(o, v0 + dv * u * 0.21132486540518713).x
                                       + wh_g(o, v0 + dv * u * 0.78867513459481287).x);
                    u = clamp(u - (I - target) / max(wh_g(o, v0 + dv * u).x, 1e-30), 0.0, hs);
                }
                uF = u;
            }
            float uB = 1e30;
            if (near) {
                float pE = psi + dI.x;
                vec4 pr = wh_prof(wh_lOnFillet(o, side, v0 + dv * hs));
                float cp = pr.x * cos(pE);
                float sp = pr.x * sin(pE);
                reach = 1e30;
                for (int c = 0; c < WH_MAXCC; c++) {
                    if (c >= ncc) break;
                    vec4 d1 = cp * cq[c][0] + sp * cq[c][1] + pr.y * cq[c][2] - cq[c][3];
                    float tc = wh_chordIn(cprev[c], d1);
                    if (tc >= 0.0 && tc * hs < uB) { uB = tc * hs; ballI = WH_MAXB + ccand[c]; }
                    cprev[c] = d1;
                    reach = min(reach, chalf[c] * wh_boxDist(d1));
                }
                vec3 X1 = vec3(cp, sp, pr.y);
                for (int c = 0; c < WH_MAXB; c++) {
                    if (c >= nc) break;
                    float dw = pr.y - cdat[c].w;
                    float q = pr.x * pr.x - 2.0 * (cdat[c].x * cp + cdat[c].y * sp) + cdat[c].z + dw * dw;
                    bool inside = q < crad[c] * crad[c];
                    if (!inside && !cin[c]) {
                        vec3 B3 = vec3(cdat[c].x, cdat[c].y, cdat[c].w);
                        float perp = cdat[c].z - cdat[c].x * cdat[c].x - cdat[c].y * cdat[c].y;
                        float tb = wh_chordInBall(prevX - B3, X1 - prevX, crad[c] * crad[c] - perp);
                        if (tb >= 0.0 && tb * hs < uB) { uB = tb * hs; ballI = cand[c]; }
                    }
                    if (inside && !cin[c]) {
                        float lo = 0.0;
                        float hi = hs;
                        for (int it = 0; it < 7; it++) {
                            float m = 0.5 * (lo + hi);
                            float pm = psi + 0.5 * m * (wh_g(o, v0 + dv * m * 0.21132486540518713).x
                                                      + wh_g(o, v0 + dv * m * 0.78867513459481287).x);
                            vec4 prm = wh_prof(wh_lOnFillet(o, side, v0 + dv * m));
                            float dm = prm.y - cdat[c].w;
                            bool im = prm.x * prm.x - 2.0 * prm.x * (cdat[c].x * cos(pm) + cdat[c].y * sin(pm)) + cdat[c].z + dm * dm < crad[c] * crad[c];
                            if (im) { hi = m; } else { lo = m; }
                        }
                        if (hi < uB) { uB = hi; ballI = cand[c]; }
                    }
                    cin[c] = inside;
                    reach = min(reach, sqrt(max(q, 0.0)) - crad[c]);
                }
                prevX = X1;
            }
            if (uB < 1e29 && uB <= uF) {
                float ph = psi + 0.5 * uB * (wh_g(o, v0 + dv * uB * 0.21132486540518713).x
                                           + wh_g(o, v0 + dv * uB * 0.78867513459481287).x);
                hitL = wh_lOnFillet(o, side, v0 + dv * uB);
                hitN = cos(ph) * e1 + sin(ph) * e2;
                arc += dI.y * uB / hs;
                return 2;
            }
            ballI = -1;
            if (uF < 1e29) {
                hitL = wh_lOnFillet(o, side, v0 + dv * uF);
                hitN = cos(psiF) * e1 + sin(psiF) * e2;
                arc += dI.y * uF / hs;
                return 1;
            }
            psi += dI.x;
            arc += dI.y;
            ga = gb;
            vt += hs;
            if (last) break;
        }
    }
    vec3 n = cos(psi) * e1 + sin(psi) * e2;
    vec3 tt = -sin(psi) * e1 + cos(psi) * e2;
    float bR = o.b / Rout;
    outX = wh_M(outSide, Rout * n);
    outD = wh_M(outSide, sqrt(max(1.0 - bR * bR, 0.0)) * n + bR * tt);
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
    if (side > 0.0) {
        wh_hitSphere(x, d, wh_sph[0], vec3(0.80, 0.15, 0.10), h);
        wh_hitSphere(x, d, wh_sph[1], vec3(0.95, 0.75, 0.15), h);
        wh_hitSphere(x, d, wh_sph[2], vec3(0.75, 0.75, 0.78), h);
        for (int i = 0; i < 4; i++) wh_hitPillar(x, d, wh_pil[i], vec3(0.85, 0.80, 0.70), h);
    } else {
        wh_hitSphere(x, d, wh_sph[3], vec3(0.75, 0.15, 0.70), h);
        wh_hitSphere(x, d, wh_sph[4], vec3(0.15, 0.75, 0.30), h);
        wh_hitSphere(x, d, wh_sph[5], vec3(0.20, 0.35, 0.85), h);
        for (int i = 0; i < 4; i++) wh_hitBox(x, d, wh_box[i].xyz, vec3(wh_box[i].w), vec3(0.90, 0.90, 0.95), h);
    }
    // balls: the chord ball cut by this universe's sheet w = side*h is an ordinary sphere;
    // only entries count (a ray that starts inside a ball does not see it from inside)
    float sheet = side * wh_h;
    for (int i = 0; i < WH_MAXB; i++) {
        if (i >= wh_nBall) break;
        float dw = wh_ball[i].w - sheet;
        float rad2 = wh_ballCol[i].w * wh_ballCol[i].w - dw * dw;
        if (rad2 <= 0.0) continue;
        vec3 oc = x - wh_M(side, wh_ball[i].xyz);
        float bq = dot(oc, d);
        float cq = dot(oc, oc) - rad2;
        float disc = bq * bq - cq;
        if (cq <= 0.0 || disc < 0.0) continue;
        float t = -bq - sqrt(disc);
        if (t > 0.0 && t < h.t) { h.t = t; h.kind = 4; h.idx = i; h.nrm = (oc + t * d) * inversesqrt(rad2); h.col = wh_ballCol[i].rgb; }
    }
    // cubes: the 4D box cut by this sheet is a convex solid bounded by four pairs of planes
    // (an ordinary cube when the box's centre is in this flat universe); entries only
    // (a loop bound the compiler cannot unroll: no cost without cubes)
    vec3 md = wh_M(side, d);
    int nCube = min(wh_nCube, WH_MAXC);
    for (int i = 0; i < nCube; i++) {
        vec4 X = vec4(wh_M(side, x), sheet) - wh_cube[i];
        // first the box's bounding sphere in R^4 (radius: half diagonal, 2 half sizes)
        float rb = 2.0 * wh_cubeCol[i].w;
        float bs = dot(X.xyz, md);
        float cs = dot(X, X) - rb * rb;
        if (cs > 0.0 && (bs > 0.0 || bs * bs < cs)) continue;
        float tin = -1e30;
        float tout = 1e30;
        vec4 face = vec4(0.0);
        for (int k = 0; k < 4; k++) {
            vec4 ax = wh_cubeE[4 * i + k];
            float A = dot(X, ax);
            float B = dot(md, ax.xyz);
            if (abs(B) < 1e-9) {
                if (abs(A) >= 1.0) tin = 1e30;    // parallel to this slab and outside it
                continue;
            }
            float t0 = (-1.0 - A) / B;
            float t1 = (1.0 - A) / B;
            if (min(t0, t1) > tin) { tin = min(t0, t1); face = (B > 0.0 ? -1.0 : 1.0) * ax; }
            tout = min(tout, max(t0, t1));
        }
        if (tin <= tout && tin > 0.0 && tin < h.t) {
            h.t = tin; h.kind = 5; h.idx = i; h.nrm = normalize(wh_M(side, face.xyz)); h.col = wh_cubeCol[i].rgb;
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
vec3 wh_sunDir(float side) {
    return side > 0.0 ? normalize(vec3(-0.6, 0.55, 0.18)) : normalize(vec3(0.35, -0.45, 0.82));
}

vec3 wh_sky(float side, vec3 d) {
    vec3 s = wh_sunDir(side);
    float el = d.z;
    vec3 col;
    if (side > 0.0) {   // A: sunset
        vec3 hor = vec3(1.00, 0.55, 0.25);
        vec3 zen = vec3(0.10, 0.12, 0.35);
        col = mix(hor, zen, pow(clamp(el, 0.0, 1.0), 0.45));
        col += vec3(1.0, 0.6, 0.3) * 0.6 * pow(max(dot(d, s), 0.0), 8.0);
        col += vec3(1.0, 0.9, 0.7) * smoothstep(0.9990, 0.9995, dot(d, s)) * 4.0;
    } else {            // B: day with a big moon
        vec3 hor = vec3(0.75, 0.88, 1.00);
        vec3 zen = vec3(0.15, 0.40, 0.90);
        col = mix(hor, zen, pow(clamp(el, 0.0, 1.0), 0.6));
        col += vec3(1.0) * smoothstep(0.9993, 0.9996, dot(d, s)) * 4.0;
        vec3 m = normalize(vec3(-0.8, -0.3, 0.35));
        float md = dot(d, m);
        col = mix(col, vec3(0.85, 0.85, 0.80) * (0.6 + 0.4 * d.z), smoothstep(0.9930, 0.9940, md));
    }
    if (el < 0.0) col = mix(col, side > 0.0 ? vec3(0.35, 0.22, 0.15) : vec3(0.30, 0.35, 0.42), clamp(-el * 8.0, 0.0, 1.0));
    // faint latitude/longitude lines make the lensing readable
    float lat = asin(clamp(el, -1.0, 1.0)) * 180.0 / WH_PI;
    float lon = atan(d.y, d.x) * 180.0 / WH_PI;
    vec2 gq = vec2(lon, lat) / 15.0;
    vec2 gf = abs(fract(gq + 0.5) - 0.5) / max(fwidth(gq), vec2(1e-4));
    float line = 1.0 - clamp(min(gf.x, gf.y), 0.0, 1.0);
    col = mix(col, side > 0.0 ? vec3(1.0, 0.9, 0.8) : vec3(1.0), 0.12 * line);
    return col;
}

// floor in intrinsic coordinates: l (proper radial distance from the throat), phi
vec3 wh_floor(float l, vec3 n) {
    float phi = atan(n.y, n.x);
    vec2 q = vec2(l, phi * 24.0 / (2.0 * WH_PI));       // 1 m rings, 24 spokes
    vec2 fw = max(fwidth(q), vec2(1e-4));
    vec2 gf = abs(fract(q + 0.5) - 0.5) / fw;
    float line = 1.0 - clamp(min(gf.x, gf.y), 0.0, 1.0);
    // checker cells, faded out when they get smaller than a pixel
    vec2 cell = floor(q);
    float chk = mod(cell.x + cell.y, 2.0);
    float chkVis = 1.0 - clamp(max(fw.x, fw.y) - 0.5, 0.0, 1.0);
    float sA = smoothstep(-0.5, 0.5, l);      // which universe the floor point belongs to
    vec3 baseA = mix(vec3(0.62, 0.42, 0.28), vec3(0.72, 0.52, 0.36), mix(0.5, chk, chkVis));
    vec3 baseB = mix(vec3(0.28, 0.34, 0.44), vec3(0.38, 0.45, 0.55), mix(0.5, chk, chkVis));
    vec3 col = mix(baseB, baseA, sA);
    col = mix(col, vec3(0.95), 0.55 * line);
    // throat circle. Next to an object's silhouette fwidth(l) may come from the object's pixel
    // and be far too large; the cap keeps a cyan fringe off objects inside the throat.
    float th = abs(l) / clamp(fwidth(l), 1e-4, 0.25);
    col = mix(col, vec3(0.2, 1.0, 0.9), 1.0 - clamp(th - 1.0, 0.0, 1.0));
    return col;
}

// A cube's colour at a point with slab coordinates d (body axes): darker along the edges.
vec3 wh_cubeLook(int i, vec3 d) {
    vec3 ad = abs(d);
    float m1 = max(max(ad.x, ad.y), ad.z);
    float m3 = min(min(ad.x, ad.y), ad.z);
    float e = 1.0 - (ad.x + ad.y + ad.z - m1 - m3);    // to the nearest edge, in half sizes
    float fw = min(fwidth(e), 0.05);
    float line = 1.0 - smoothstep(0.07 - fw, 0.07 + fw, e);
    return wh_cubeCol[i].rgb * (1.0 - 0.55 * line);
}

vec3 wh_cubeSlabs(int i, vec4 P) {
    vec4 X = P - wh_cube[i];
    return vec3(dot(X, wh_cubeE[4 * i]), dot(X, wh_cubeE[4 * i + 1]), dot(X, wh_cubeE[4 * i + 2]));
}

vec3 wh_shade(float side, vec3 col, vec3 nrm) {
    float dif = max(dot(nrm, wh_sunDir(side)), 0.0);
    vec3 amb = side > 0.0 ? vec3(0.35, 0.30, 0.35) : vec3(0.35, 0.42, 0.55);
    vec3 sun = side > 0.0 ? vec3(1.2, 0.8, 0.55) : vec3(1.1, 1.1, 1.05);
    return col * (amb + sun * dif);
}

vec3 wh_fog(float side, vec3 col, float dist) {
    vec3 fc = side > 0.0 ? vec3(0.95, 0.60, 0.35) : vec3(0.70, 0.82, 0.95);
    return mix(col, fc, 1.0 - exp(-dist * 0.012));
}

// ---------------------------------------------------------------- entry point
// Ray from an eye at manifold point (l0, n0) with manifold direction (vl, w), unit length.
// dbg receives geometry for testing: x = 2*kind + (side > 0 ? 1 : 0), then
//   kind 0 sky: final chart direction    kind 1 floor: (l, n.x, n.y)    kind 2 object: chart hit point
//   balls: x = 100 + index, cubes: x = 200 + index, then the hit point's R^4 xyz (= r n)
vec3 wh_shadeFlat(float side, vec3 x, vec3 d, WhHit h, float dist, out vec4 dbg) {
    if (h.kind == 0) {
        dbg = vec4(side > 0.0 ? 1.0 : 0.0, normalize(d));
        return wh_sky(side, d);
    }
    vec3 p = x + h.t * d;
    if (h.kind == 1) {
        vec3 np = wh_M(side, p) / length(p);
        float lp = side * (length(p) - wh_Rout() + wh_Lsh());
        dbg = vec4(side > 0.0 ? 3.0 : 2.0, lp, np.xy);
        return wh_fog(side, wh_floor(lp, np), dist + h.t);
    }
    if (h.kind == 5) {
        dbg = vec4(200.0 + float(h.idx), wh_M(side, p));
        vec3 col = wh_cubeLook(h.idx, wh_cubeSlabs(h.idx, vec4(wh_M(side, p), side * wh_h)));
        return wh_fog(side, wh_shade(side, col, h.nrm), dist + h.t);
    }
    dbg = h.kind == 4 ? vec4(100.0 + float(h.idx), wh_M(side, p)) : vec4(side > 0.0 ? 5.0 : 4.0, p);
    return wh_fog(side, wh_shade(side, h.col, h.nrm), dist + h.t);
}

// a ball hit inside the shell: normal = R^4 offset from the centre projected onto the tangent space
vec3 wh_shadeBallCurved(int i, float l, vec3 n, float dist, out vec4 dbg) {
    vec4 pr = wh_prof(l);
    vec4 N4 = vec4(pr.x * n, pr.y) - wh_ball[i];
    float rad = dot(N4.xyz, n);
    float ul = pr.z * rad + pr.w * N4.w;
    vec3 u = N4.xyz - rad * n;
    float side = l >= 0.0 ? 1.0 : -1.0;
    vec3 nrm = normalize(wh_M(side, side * ul * n + u));
    dbg = vec4(100.0 + float(i), pr.x * n);
    return wh_fog(side, wh_shade(side, wh_ballCol[i].rgb, nrm), dist);
}

// a cube hit inside the shell: the normal of the face hit (largest slab coordinate) projected
// onto the tangent space
vec3 wh_shadeCubeCurved(int i, float l, vec3 n, float dist, out vec4 dbg) {
    vec4 pr = wh_prof(l);
    vec3 d = wh_cubeSlabs(i, vec4(pr.x * n, pr.y));
    vec3 ad = abs(d);
    int k = ad.x >= ad.y && ad.x >= ad.z ? 0 : (ad.y >= ad.z ? 1 : 2);
    vec4 N4 = (d[k] >= 0.0 ? 1.0 : -1.0) * wh_cubeE[4 * i + k];
    float rad = dot(N4.xyz, n);
    float ul = pr.z * rad + pr.w * N4.w;
    vec3 u = N4.xyz - rad * n;
    float side = l >= 0.0 ? 1.0 : -1.0;
    vec3 nrm = normalize(wh_M(side, side * ul * n + u));
    dbg = vec4(200.0 + float(i), pr.x * n);
    return wh_fog(side, wh_shade(side, wh_cubeLook(i, d), nrm), dist);
}

vec3 wh_render(float l0, vec3 n0, float vl, vec3 w, out vec4 dbg) {
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
    for (int seg = 0; seg < 2; seg++) {
        if (inShell) {
            float hl; vec3 hn; int bi; float arc;
            int ev = wh_curved(l0, n0, vl, w, hl, hn, bi, side, x, d, arc);
            if (ev == 1) {
                float fs = hl > 0.0 ? 1.0 : -1.0;
                dbg = vec4(fs > 0.0 ? 3.0 : 2.0, hl, hn.xy);
                return wh_fog(fs, wh_floor(hl, hn), dist + arc);
            }
            if (ev == 2 && bi >= WH_MAXB) return wh_shadeCubeCurved(bi - WH_MAXB, hl, hn, dist + arc, dbg);
            if (ev == 2) return wh_shadeBallCurved(bi, hl, hn, dist + arc, dbg);
            dist += arc;
            inShell = false;
            shellAhead = false;
        }
        WhHit h = wh_traceFlat(side, x, d, shellAhead);
        if (h.kind != 3) return wh_shadeFlat(side, x, d, h, dist, dbg);
        dist += h.t;
        wh_enter(side, x + h.t * d, d, l0, n0, vl, w);
        inShell = true;
    }
    dbg = vec4(-1.0);
    return vec3(1.0, 0.0, 1.0);
}
