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
//   smooth and bounded, integrated with 4-point Gauss-Legendre panels.
//
// Manifold point: (l, n), n unit 3-vector. Tangent vector: (vl, w), w orthogonal to n.
// Point in R^4: E = (r n, w(l)). Flat charts: side A (l >= L): x = r n;  side B: x = P r n, P = diag(-1,1,1).
// The floor is the totally geodesic equatorial surface n.z = 0 (z = 0 in both charts).

const float WH_PI = 3.14159265358979;
const int WH_MAXB = 12;

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
    float k = sqrt(2.0 * wh_fillet) * inversesqrt(max(1.0 - s * s, 1e-6) * (r + o.b));
    return vec2(o.b / r, r) * k;
}

// 4-point Gauss-Legendre on [0, 1] (exact up to degree 7): nodes and weights
const vec4 WH_GT = vec4(0.069431844202973714, 0.33000947820757187, 0.66999052179242813, 0.93056815579702623);
const vec2 WH_GW = vec2(0.17392742256872679, 0.32607257743127321);

// integral of g from v0 over a length u >= 0 in the direction dv
vec2 wh_int(WhRay o, float v0, float dv, float u) {
    return u * (WH_GW.x * (wh_g(o, v0 + dv * u * WH_GT.x) + wh_g(o, v0 + dv * u * WH_GT.w))
              + WH_GW.y * (wh_g(o, v0 + dv * u * WH_GT.y) + wh_g(o, v0 + dv * u * WH_GT.z)));
}

// coefficients of t, t^2, t^3, t^4 in the integral from 0 to t of the cubic through the four
// nodes, per unit node value (column i: node i)
mat4 wh_gauss_poly() {
    return mat4(vec4(1.5267881254572671, -4.2730118039361003, 4.7752861180572967, -1.8551350170097369),
                vec4(-0.81363244948692737, 6.9035834628447885, -10.462740787815354, 4.6988623518887653),
                vec4(0.40076152031165047, -3.7085352107313199, 8.3327086197397069, -4.6988623518887653),
                vec4(-0.11391719628198997, 1.0779635518226309, -2.6452539499816514, 1.8551350170097372));
}

float wh_lOnFillet(WhRay o, float side, float v) {
    float th = 2.0 * asin(min(wh_S(o, v), 1.0));
    return side * (wh_Lc() + wh_fillet * (th - wh_th0()));
}

// Ray starting inside (or on the boundary of) the shell, |ls| <= L. Returns
//   0: leaves the shell, given in flat chart coordinates (outSide, outX, outD)
//   1: hits the floor at (hitL, hitN)        2: enters ball ballI at (hitL, hitN)
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
    float crad2[WH_MAXB];
    bool cin[WH_MAXB];
    int nc = 0;
    float minRad = 1e9;
    vec4 ps = wh_prof(ls);
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
        crad2[nc] = rad * rad;
        float dw0 = ps.y - C.w;
        cin[nc] = ps.x * ps.x - 2.0 * ps.x * c1 + cc + dw0 * dw0 < rad * rad;   // start: psi = 0, n = e1
        minRad = min(minRad, rad);
        nc++;
    }
    float ds = 0.35 * minRad;        // path-length sampling step while balls are in reach

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
    // a floor crossing found in a fillet panel; its last refinement runs after the loops, so that
    // neighbouring rays (which run in lockstep on a GPU) do not wait for it panel by panel
    bool floorHit = false;
    float fv0 = 0.0;  float fdv = 1.0;  float fhs = 0.0;  float fside = 1.0;  float fu = 0.0;  float ftarget = 0.0;
    for (int p = 0; p < 3; p++) {
        if (p >= np || floorHit) break;
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
            if (nc > 0) {
                int N = int(clamp(ceil(D / vlc / ds), 1.0, float(max(budget, 1))));
                budget -= N;
                float hx = D / float(N);
                for (int j = 1; j <= 160; j++) {
                    if (j > N || xB < 1e29) break;
                    float u = hx * float(j);
                    if (u > xF + hx) break;
                    float pj = psi + k * u;
                    float lj = side * (x0 + u);
                    for (int c = 0; c < WH_MAXB; c++) {
                        if (c >= nc) break;
                        float dw = lj - cdat[c].w;
                        bool inside = rho0 * rho0 - 2.0 * rho0 * (cdat[c].x * cos(pj) + cdat[c].y * sin(pj)) + cdat[c].z + dw * dw < crad2[c];
                        if (inside && !cin[c]) {
                            float lo = u - hx;
                            float hi = u;
                            for (int it = 0; it < 8; it++) {
                                float m = 0.5 * (lo + hi);
                                float pm = psi + k * m;
                                float dm = side * (x0 + m) - cdat[c].w;
                                bool im = rho0 * rho0 - 2.0 * rho0 * (cdat[c].x * cos(pm) + cdat[c].y * sin(pm)) + cdat[c].z + dm * dm < crad2[c];
                                if (im) { hi = m; } else { lo = m; }
                            }
                            if (hi < xB) { xB = hi; ballI = cand[c]; }
                        }
                        cin[c] = inside;
                    }
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
        // ---- fillet: Gauss panels in v
        float va = pa[p];
        float vb = pb[p];
        float U = abs(vb - va);
        float dv = vb >= va ? 1.0 : -1.0;
        float Nf = ceil(U / 1.5);
        if (nc > 0) {
            float gmax = max(max(wh_g(o, va).y, wh_g(o, vb).y), wh_g(o, 0.5 * (va + vb)).y);
            Nf = max(Nf, ceil(U * gmax / ds));
        }
        int N = int(clamp(Nf, 1.0, float(max(budget, 1))));
        budget -= N;
        float hs = U / float(N);
        for (int k = 0; k < 160; k++) {
            if (k >= N) break;
            float v0 = va + dv * hs * float(k);
            vec2 g1 = wh_g(o, v0 + dv * hs * WH_GT.x);
            vec2 g2 = wh_g(o, v0 + dv * hs * WH_GT.y);
            vec2 g3 = wh_g(o, v0 + dv * hs * WH_GT.z);
            vec2 g4 = wh_g(o, v0 + dv * hs * WH_GT.w);
            vec2 dI = hs * (WH_GW.x * (g1 + g4) + WH_GW.y * (g2 + g3));
            float uF = 1e30;
            float target = psiF - psi;
            if (above && dI.x >= target) {
                // where psi reaches the floor, on the integral of the cubic through the nodes (no
                // new evaluations); one Newton step on the exact integral follows after the loops
                vec4 c = hs * (wh_gauss_poly() * vec4(g1.x, g2.x, g3.x, g4.x));
                float t = target / max(dI.x, 1e-30);
                for (int it = 0; it < 4; it++) {
                    float P = t * (c.x + t * (c.y + t * (c.z + t * c.w)));
                    float dP = c.x + t * (2.0 * c.y + t * (3.0 * c.z + t * 4.0 * c.w));
                    t = clamp(t - (P - target) / max(dP, 1e-30), 0.0, 1.0);
                }
                uF = t * hs;
            }
            float uB = 1e30;
            if (nc > 0) {
                float pE = psi + dI.x;
                vec4 pr = wh_prof(wh_lOnFillet(o, side, v0 + dv * hs));
                for (int c = 0; c < WH_MAXB; c++) {
                    if (c >= nc) break;
                    float dw = pr.y - cdat[c].w;
                    bool inside = pr.x * pr.x - 2.0 * pr.x * (cdat[c].x * cos(pE) + cdat[c].y * sin(pE)) + cdat[c].z + dw * dw < crad2[c];
                    if (inside && !cin[c]) {
                        float lo = 0.0;
                        float hi = hs;
                        for (int it = 0; it < 7; it++) {
                            float m = 0.5 * (lo + hi);
                            float pm = psi + 0.5 * m * (wh_g(o, v0 + dv * m * 0.21132486540518713).x
                                                      + wh_g(o, v0 + dv * m * 0.78867513459481287).x);
                            vec4 prm = wh_prof(wh_lOnFillet(o, side, v0 + dv * m));
                            float dm = prm.y - cdat[c].w;
                            bool im = prm.x * prm.x - 2.0 * prm.x * (cdat[c].x * cos(pm) + cdat[c].y * sin(pm)) + cdat[c].z + dm * dm < crad2[c];
                            if (im) { hi = m; } else { lo = m; }
                        }
                        if (hi < uB) { uB = hi; ballI = cand[c]; }
                    }
                    cin[c] = inside;
                }
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
                floorHit = true;
                fv0 = v0;  fdv = dv;  fhs = hs;  fside = side;  fu = uF;  ftarget = target;
                arc += dI.y * uF / hs;
                break;
            }
            psi += dI.x;
            arc += dI.y;
        }
    }
    if (floorHit) {
        float u = clamp(fu - (wh_int(o, fv0, fdv, fu).x - ftarget) / max(wh_g(o, fv0 + fdv * fu).x, 1e-30), 0.0, fhs);
        hitL = wh_lOnFillet(o, fside, fv0 + fdv * u);
        hitN = cos(psiF) * e1 + sin(psiF) * e2;
        return 1;
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
    int kind;      // 0 none, 1 floor, 2 object, 3 shell, 4 ball
    int idx;       // ball index
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
    // throat circle
    float th = abs(l) / max(fwidth(l), 1e-4);
    col = mix(col, vec3(0.2, 1.0, 0.9), 1.0 - clamp(th - 1.0, 0.0, 1.0));
    return col;
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
//   balls: x = 100 + index, then the hit point's R^4 xyz (= r n)
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
