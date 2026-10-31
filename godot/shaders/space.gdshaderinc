// The wormhole space for the shaders: plain GLSL that is also Godot's shading language (ref/ compiles
// it as GLSL and checks it against ref/space.py). The including file declares the uniforms:
//   sp_rho0, sp_R, sp_Lc, sp_L, sp_Rout   the profile (docs/geometry.md): throat radius, fillet
//                                         radius, the cylinder's half length, the curved zone's
//                                         edge in l, its radius in the charts
//   sp_tab, sp_ptab                       the fillet's tables (Space.fillet_tables in space.gd)
//
// A point is (l, n), n a unit 3-vector; a tangent vector (V_l, v), v orthogonal to n, as a vec4
// (V_l, v). The charts: side A (l >= L) x = r n, side B x = M r n, M = diag(-1, 1, 1). The floor is
// n.z = 0.
//
// A ray lies in the plane of n and its direction, n(phi) = cos(phi) n0 + sin(phi) t; phi is its
// sweep, b = r sin(angle to the radial direction) is kept. On a fillet s = sin(theta / 2), r = rho0
// + 2 R s^2, sig = (b - rho0) / 2R, k = sqrt(1/2 - sig); z, the distance in the fillet's variable
// y (docs/geometry.md) from the fillet's outer end, runs from 0 there to Y at its inner end (the
// cylinder, or the turning point). The sweep over z from the outer end is Psi(z) = A0 z + E(b, z),
// the path length P0 z + F(b, z): A0 and P0 closed forms, E and F from the tables. Between two
// points of a ray a sweep is a difference of such values, never of large ones (the cylinder's sweep
// grows without bound as b -> rho0, so a ray's legs are summed only where it runs).
//
// Godot's shading language reserves E, PI and TAU; constants reach the GPU with 14 decimals.

const float SP_PI = 3.14159265358979;
const float SP_S1 = 0.70710678118655;       // s at a fillet's outer end
const float SP_ZCAP = 6.0;                  // the tables' last z (beyond it E and F are constant)
const float SP_NB = 256.0;                  // the tables' columns (b) and z knots (Space.TABLE_*)
const float SP_NZ = 64.0;
#ifndef SP_ZIT
#define SP_ZIT 6
#endif

vec3 sp_M(float side, vec3 v) { return side > 0.0 ? v : vec3(-v.x, v.y, v.z); }

// r at |l| = al
float sp_r(float al) {
    if (al <= sp_Lc) return sp_rho0;
    if (al <= sp_L) {
        float s = sin((al - sp_Lc) / (2.0 * sp_R));
        return sp_rho0 + 2.0 * sp_R * s * s;
    }
    return al - sp_L + sp_Rout;
}

// dr/dl at l (odd in l)
float sp_dr(float l) {
    float al = abs(l);
    float d = al <= sp_Lc ? 0.0 : (al <= sp_L ? sin((al - sp_Lc) / sp_R) : 1.0);
    return l < 0.0 ? -d : d;
}

// The fillet's s at |l| = al (Lc <= al <= L)
float sp_s(float al) { return sin((al - sp_Lc) / (2.0 * sp_R)); }

// What a ray of impact parameter b needs on a fillet: x b, y A0 (the sweep per z at s = 0), z k,
// w sig; and the table's column coordinate.
struct SpRay {
    float b;
    float A0;
    float P0;
    float k;
    float sig;
    float u;        // the tables' column, fractional
    float Y;        // z at the inner end
    float PsiY;     // the sweep over the whole fillet
};

// bmr: b - rho0, which near rho0 the caller often knows more precisely than that difference
SpRay sp_ray(float b, float bmr) {
    SpRay q;
    q.b = b;
    float sq = sqrt(2.0 * sp_R / (sp_rho0 + b));
    q.A0 = b * sq / sp_rho0;
    q.P0 = sp_rho0 * sq;
    q.sig = bmr / (2.0 * sp_R);
    q.k = sqrt(max(0.5 - q.sig, 0.0));
    // columns: b in [0, rho0] and [rho0, Rout], each by the square root of its distance from rho0
    float u = bmr <= 0.0 ? 0.5 - 0.5 * sqrt(min(-bmr / sp_rho0, 1.0))
                         : 0.5 + 0.5 * sqrt(min(bmr / (sp_Rout - sp_rho0), 1.0));
    q.u = u * (SP_NB - 1.0);
    q.Y = log((SP_S1 + q.k) / sqrt(max(abs(q.sig), 1e-12)));
    q.PsiY = 0.0;
    return q;
}

// A table at column q.u and z: Hermite in z between knots (value, slope times the knot spacing at
// each), linear across columns.
float sp_tabAt(sampler2D tab, SpRay q, float z) {
    float v = sqrt(clamp(z, 0.0, SP_ZCAP) / SP_ZCAP) * (SP_NZ - 1.0);
    float j = min(floor(v), SP_NZ - 2.0);
    float f = v - j;
    float i = min(floor(q.u), SP_NB - 2.0);
    float g = q.u - i;
    vec4 c0 = texelFetch(tab, ivec2(int(i), int(j)), 0);
    vec4 c1 = texelFetch(tab, ivec2(int(i) + 1, int(j)), 0);
    vec4 c = mix(c0, c1, g);
    float f2 = f * f;
    float f3 = f2 * f;
    return c.x * (2.0 * f3 - 3.0 * f2 + 1.0) + c.y * (f3 - 2.0 * f2 + f) + c.z * (3.0 * f2 - 2.0 * f3) + c.w * (f3 - f2);
}

float sp_Psi(SpRay q, float z) { return q.A0 * z + sp_tabAt(sp_tab, q, z); }
float sp_Pth(SpRay q, float z) { return q.P0 * z + sp_tabAt(sp_ptab, q, z); }

SpRay sp_rayFull(float b, float bmr) {
    SpRay q = sp_ray(b, bmr);
    q.PsiY = sp_Psi(q, q.Y);
    return q;
}

// z of the fillet point s; q2 = s^2 - sig (passed when known more precisely than that difference)
float sp_z(SpRay q, float s, float q2) {
    return log((SP_S1 + q.k) / (s + sqrt(max(q2, 0.0))));
}

// s at z (negative past a passing ray's inner end)
float sp_sAt(SpRay q, float z) {
    float e = exp(z);
    return 0.5 * (q.sig * e / (SP_S1 + q.k) + (SP_S1 + q.k) / e);
}

// the sweep per z at s
float sp_A(SpRay q, float s) {
    float r = sp_rho0 + 2.0 * sp_R * s * s;
    return q.b * sqrt(2.0 * sp_R / ((r + q.b) * max(1.0 - s * s, 1e-6))) / r;
}

// the z where the sweep from the outer end is T, between za and zb (Psi there: pa, pb)
float sp_zAt(SpRay q, float T, float za, float pa, float zb, float pb) {
    float z = za + (zb - za) * clamp((T - pa) / (abs(pb - pa) > 1e-12 ? pb - pa : 1e-12), 0.0, 1.0);
    for (int it = 0; it < SP_ZIT; it++) {
        float d = sp_Psi(q, z) - T;
        z -= d / max(sp_A(q, sp_sAt(q, z)), 1e-9);
        z = clamp(z, min(za, zb), max(za, zb));
    }
    return z;
}

// the angle of a straight line of impact b from its closest point to the centre at radius r;
// rb2 = r^2 - b^2
float sp_flatPhi(float b, float rb2) { return atan(sqrt(max(rb2, 0.0)), b); }

// the cylinder's sweep and path per length, b < rho0; q2 = rho0^2 - b^2
vec2 sp_cylRate(float b, float q2) {
    float iq = inversesqrt(max(q2, 1e-14));
    return vec2(b * iq / sp_rho0, sp_rho0 * iq);
}

// ---------------------------------------------------------------- a pixel's ray
// The ray from (l0, n0) along the unit V to the floor or the sky. Returns the kind (0 sky, 1 floor)
// and fills: side (of what it ends in), d (sky: the chart direction; floor: the floor point's n),
// fl (floor: its l), dist (an estimate of the path length, for the fog).
int sp_trace(float l0, vec3 n0, vec4 V, out float side, out vec3 d, out float fl, out float dist) {
    side = l0 >= 0.0 ? 1.0 : -1.0;
    vec3 v = V.yzw;
    float st = length(v);
    vec3 t = st > 1e-7 ? v / st : normalize(cross(n0, abs(n0.z) < 0.9 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0)));
    float al = abs(l0);
    float b;
    float vl = V.x;
    float acc = 0.0;        // the sweep from n0 to the start of the curved part
    dist = 0.0;
    fl = 0.0;
    d = vec3(0.0);
    if (al >= sp_L) {
        // a flat region: a straight line until the curved zone's sphere
        vec3 X = sp_M(side, (al - sp_L + sp_Rout) * n0);
        vec3 D = sp_M(side, side * vl * n0 + v);
        float tc = -dot(X, D);
        float d2 = dot(X, X) - tc * tc;
        float tf = D.z < 0.0 ? -X.z / D.z : 1e30;
        bool enters = tc > 0.0 && d2 < sp_Rout * sp_Rout;
        float tin = tc - sqrt(max(sp_Rout * sp_Rout - d2, 0.0));
        if (!enters || tf < tin) {
            if (D.z < 0.0) {
                vec3 p = X + tf * D;
                float rp = length(p);
                d = sp_M(side, p) / rp;
                fl = side * (rp - sp_Rout + sp_L);
                dist = tf;
                return 1;
            }
            d = D;
            return 0;
        }
        vec3 xin = X + tin * D;
        vec3 nin = sp_M(side, xin) / sp_Rout;
        acc = atan(length(cross(n0, nin)), dot(n0, nin));
        dist = tin;
        b = sqrt(max(d2, 0.0));
        al = sp_L;
        vl = -side;
    } else {
        b = sp_r(al) * st;
    }
    // the floor: where n(phi).z = 0 first
    float phf = atan(n0.z, -t.z);
    phf = phf < 0.0 ? phf + 2.0 * SP_PI : phf;
    phf -= acc;
    vec3 ns = cos(acc) * n0 + sin(acc) * t;          // the start of the curved part
    vec3 ts = -sin(acc) * n0 + cos(acc) * t;
    SpRay q = sp_rayFull(b, b - sp_rho0);
    bool passing = b < sp_rho0;
    bool inward = side * vl < 0.0;
    // rho0^2 - b^2: on the cylinder (rho0 vl)^2 exactly
    vec2 cyl = passing || al <= sp_Lc ? sp_cylRate(b, al <= sp_Lc ? sp_rho0 * sp_rho0 * vl * vl : (sp_rho0 - b) * (sp_rho0 + b)) : vec2(0.0);
    passing = passing || al <= sp_Lc;
    // the legs: a = in along the fillet from the start (z0 -> Y), c = the cylinder, o = out along a
    // fillet (Y -> 0, on the side the ray leaves by); a ray going out from a fillet point has only
    // a part of o
    float z0 = 0.0;
    float p0 = 0.0;
    float lcyl = 0.0;       // the cylinder's length run
    float lc0 = 0.0;        // l where the cylinder leg starts
    float cdir = 1.0;
    if (al > sp_Lc) {
        float s0 = sp_s(al);
        // s0^2 - sig = (r - b) / 2R = r vl^2 / (1 + |v|) / 2R, without the difference
        z0 = al >= sp_L ? 0.0 : sp_z(q, s0, sp_r(al) * vl * vl / ((1.0 + st) * 2.0 * sp_R));
        p0 = sp_Psi(q, z0);
        if (passing && inward) {
            lcyl = 2.0 * sp_Lc;
            lc0 = side * sp_Lc;
            cdir = -side;
        }
    } else {
        // on the cylinder (b <= rho0)
        cdir = vl >= 0.0 ? 1.0 : -1.0;
        lcyl = sp_Lc - cdir * l0;
        lc0 = l0;
        inward = false;
        z0 = q.Y;
        p0 = q.PsiY;
    }
    float swA = inward ? q.PsiY - p0 : 0.0;
    float swC = lcyl * cyl.x;
    float exitSide = passing && (inward || al <= sp_Lc) ? (al <= sp_Lc ? cdir : -side) : side;
    float swO = inward || al <= sp_Lc ? q.PsiY : p0;
    float total = swA + swC + swO;
    float pathC = lcyl * cyl.y;
    if (phf < total) {
        // the floor in the curved zone
        float fz;
        float fside = side;
        if (phf < swA) {
            fz = sp_zAt(q, p0 + phf, z0, p0, q.Y, q.PsiY);
        } else if (phf < swA + swC) {
            fl = lc0 + cdir * (phf - swA) / max(cyl.x, 1e-12);
            fz = -1.0;
        } else {
            float T = swO - (phf - swA - swC);       // Psi there, from the outer end
            float zs = inward || al <= sp_Lc ? q.Y : z0;
            fz = sp_zAt(q, T, 0.0, 0.0, zs, swO);
            fside = exitSide;
        }
        if (fz >= 0.0) {
            float s = clamp(sp_sAt(q, fz), 0.0, SP_S1);
            fl = fside * (sp_Lc + 2.0 * sp_R * atan(s, sqrt(1.0 - s * s)));     // not asin: imprecise on some GPUs
        }
        d = cos(phf) * ns + sin(phf) * ts;
        d.z = 0.0;
        d = normalize(d);
        side = fl >= 0.0 ? 1.0 : -1.0;
        // the path: in R^4 the chord from the start, a little short of the arc
        vec4 Es = vec4(sp_r(al) * ns, 0.0);
        vec4 Ef = vec4(sp_r(abs(fl)) * d, 0.0);
        dist += length(Es.xyz - Ef.xyz) + abs(abs(fl) - al);
        return 1;
    }
    // out of the curved zone: a straight line in the chart of exitSide
    side = exitSide;
    vec3 nx = cos(total) * ns + sin(total) * ts;
    vec3 tx = -sin(total) * ns + cos(total) * ts;
    float sb = b / sp_Rout;
    vec3 X = sp_M(side, sp_Rout * nx);
    vec3 D = sp_M(side, sqrt(max(1.0 - sb * sb, 0.0)) * nx + sb * tx);
    dist += (inward ? q.P0 * q.Y + sp_tabAt(sp_ptab, q, q.Y) - sp_Pth(q, z0) : 0.0) + pathC
            + (q.P0 * (inward || al <= sp_Lc ? q.Y : z0) + sp_tabAt(sp_ptab, q, inward || al <= sp_Lc ? q.Y : z0));
    if (D.z < 0.0) {
        float tf = -X.z / D.z;
        vec3 p = X + tf * D;
        float rp = length(p);
        d = sp_M(side, p) / rp;
        fl = side * (rp - sp_Rout + sp_L);
        dist += tf;
        return 1;
    }
    d = D;
    return 0;
}

// ---------------------------------------------------------------- a point's direction from an eye
// The sweeps along a ray of impact q.b.
// From the inner anchor (the throat's middle for a passing ray, the turning point otherwise) out to
// |l| = a; tau2 >= 0: r(a) - b, known exactly. x: sweep, y: path.
vec2 sp_out(SpRay q, float a, float tau2) {
    float b = q.b;
    if (b >= sp_Rout) {
        float r = sp_r(a);
        float rb2 = tau2 >= 0.0 ? tau2 * (r + b) : (r - b) * (r + b);
        return vec2(sp_flatPhi(b, rb2), sqrt(max(rb2, 0.0)));
    }
    vec2 tot = vec2(0.0);
    if (b < sp_rho0) {
        tot = sp_cylRate(b, -q.sig * 2.0 * sp_R * (sp_rho0 + b)) * min(a, sp_Lc);
        if (a <= sp_Lc) return tot;
    }
    if (a <= sp_L) {
        float s = sp_s(a);
        float z = sp_z(q, s, tau2 >= 0.0 ? tau2 / (2.0 * sp_R) : s * s - q.sig);
        return tot + vec2(q.PsiY - sp_Psi(q, z), sp_Pth(q, q.Y) - sp_Pth(q, z));
    }
    float r = sp_r(a);
    float rb2 = (r - b) * (r + b);
    float ro2 = (sp_Rout - b) * (sp_Rout + b);
    return tot + vec2(q.PsiY + sp_flatPhi(b, rb2) - sp_flatPhi(b, ro2), sp_Pth(q, q.Y) + sqrt(rb2) - sqrt(max(ro2, 0.0)));
}

// Between |l| = an and af (an <= af) along a ray going straight out, no turning point between;
// tau2 >= 0: r(an) - b.
vec2 sp_between(SpRay q, float an, float af, float tau2) {
    float b = q.b;
    vec2 tot = vec2(0.0);
    if (an < sp_Lc) {
        tot = sp_cylRate(b, -q.sig * 2.0 * sp_R * (sp_rho0 + b)) * (min(af, sp_Lc) - an);
        if (af <= sp_Lc) return tot;
    }
    float fa = max(an, sp_Lc);
    float fb = min(af, sp_L);
    if (fa < sp_L) {
        float sa = sp_s(fa);
        float sb = sp_s(fb);
        float za = sp_z(q, sa, an >= sp_Lc && tau2 >= 0.0 ? tau2 / (2.0 * sp_R) : sa * sa - q.sig);
        float zb = sp_z(q, sb, sb * sb - q.sig);
        tot += vec2(sp_Psi(q, za) - sp_Psi(q, zb), sp_Pth(q, za) - sp_Pth(q, zb));
    }
    if (af > sp_L) {
        float ra = max(sp_r(an), sp_Rout);
        float rf = sp_r(af);
        float ra2 = an >= sp_L && tau2 >= 0.0 ? tau2 * (ra + b) : (ra - b) * (ra + b);
        float rf2 = (rf - b) * (rf + b);
        tot += vec2(sp_flatPhi(b, rf2) - sp_flatPhi(b, ra2), sqrt(max(rf2, 0.0)) - sqrt(max(ra2, 0.0)));
    }
    return tot;
}

// The pair's sweep and path for impact b: mode 0 between (direct), 1 turning, 2 passing the throat
// (ae, ap: each point's |l|; for 0 and 1 an <= af). bmr: b - rho0; tau2: r(an) - b, or -1.
vec2 sp_pair(int mode, float an, float af, float b, float bmr, float tau2) {
    SpRay q = sp_rayFull(b, bmr);
    if (mode == 0) return sp_between(q, an, af, tau2);
    return sp_out(q, an, mode == 1 ? tau2 : -1.0) + sp_out(q, af, -1.0);
}

// The unit tangent at the eye (le, ne; r(le) = re) whose geodesic reaches (lp, np) along the minor
// arc of directions (docs/geometry.md: the only such one), and its length in dist.
vec4 sp_toward(float le, vec3 ne, float re, float lp, vec3 np, out float dist) {
    float cs = dot(ne, np);
    vec3 tv = np - cs * ne;
    float sn = length(tv);
    float delta = atan(sn, cs);
    vec3 t = sn > 1e-9 ? tv / sn : vec3(0.0);
    float ae = abs(le);
    float ap = abs(lp);
    bool same = le * lp > 0.0;
    // both in one flat region and the straight line between them clear of the curved zone
    if (same && ae >= sp_L && ap >= sp_L) {
        float side = le > 0.0 ? 1.0 : -1.0;
        vec3 Xe = (ae - sp_L + sp_Rout) * ne;
        vec3 D = (ap - sp_L + sp_Rout) * np - Xe;
        float dd = dot(D, D);
        float tc = clamp(-dot(Xe, D) / max(dd, 1e-20), 0.0, 1.0);
        vec3 c = Xe + tc * D;
        if (dot(c, c) >= sp_Rout * sp_Rout) {
            dist = sqrt(dd);
            float dl = dot(D, ne);
            return vec4(side * dl, D - dl * ne) / max(dist, 1e-20);
        }
    }
    float rp = sp_r(ap);
    float rn = same ? min(re, rp) : sp_rho0;
    float an = min(ae, ap);
    float af = max(ae, ap);
    float b;
    float tau = 0.0;
    int mode;
    vec2 res = vec2(0.0);
    bool xvar = !same || rn <= sp_rho0 * (1.0 + 1e-6);
    if (xvar) {
        // b in [0, rho0): Newton in x = b / sqrt(rho0^2 - b^2), in which the cylinder's sweep is
        // linear; from where the sweep's slope at b = 0, rho0 int dl / r^2, puts it
        mode = same ? 0 : 2;
        float k1 = same ? 0.0 : 1.0;
        float ia = 0.0;
        for (int e = 0; e < 2; e++) {
            float a0 = e == 0 ? (same ? an : 0.0) : 0.0;
            float a1 = e == 0 ? (same ? af : ae) : (same ? 0.0 : ap);
            float c0 = min(a0, sp_Lc);
            float c1 = min(a1, sp_Lc);
            ia += (c1 - c0) / (sp_rho0 * sp_rho0);
            float f0 = clamp(a0, sp_Lc, sp_L);
            float f1 = clamp(a1, sp_Lc, sp_L);
            ia += (f1 - f0) / (sp_r(f0) * sp_r(f1));
            float g0 = max(a0, sp_L);
            float g1 = max(a1, sp_L);
            ia += 1.0 / sp_r(g0) - 1.0 / sp_r(g1);
        }
        float x = delta / max(sp_rho0 * ia, 1e-9);
        float lo = 0.0;
        float hi = 1e30;
        for (int it = 0; it < 14; it++) {
            float w = sqrt(1.0 + x * x);
            b = sp_rho0 * x / w;
            res = sp_pair(mode, same ? an : ae, same ? af : ap, b, -sp_rho0 / (w * (w + x)), -1.0);
            float f = res.x - delta;
            if (abs(f) < 2e-7) break;
            if (f > 0.0) hi = x; else lo = x;
            float h = 1e-3 * max(x, 1e-2);
            float w2 = sqrt(1.0 + (x + h) * (x + h));
            float df = (sp_pair(mode, same ? an : ae, same ? af : ap, sp_rho0 * (x + h) / w2, -sp_rho0 / (w2 * (w2 + x + h)), -1.0).x - res.x) / h;
            float nx = df > 0.0 ? x - f / df : -1.0;
            x = nx > lo && nx < hi ? nx : (hi < 1e29 ? 0.5 * (lo + hi) : 2.0 * x + 1.0);
        }
    } else {
        // b = rn - tau^2: tau < 0 the direct branch, tau > 0 turning (docs/geometry.md)
        // rn - rho0 without the difference
        float sn = sp_s(min(an, sp_L));
        float rnm = an <= sp_L ? 2.0 * sp_R * sn * sn : an - sp_L + sp_R;
        float dtan = sp_pair(0, an, af, rn, rnm, 0.0).x;
        mode = delta <= dtan ? 0 : 1;
        float tmax = sqrt(rnm);
        // the parameter p: the direct branch tau = p in [-sqrt(rn), 0], a first guess from the
        // straight line between the points drawn flat (radii as distances); turning tau = tmax (1 -
        // exp(-p)), p >= 0, in which the sweep grows about linearly up to the throat's winding rays
        // (log(b - rho0) ~ -p), a first guess by the line through p = 0 (the tangent) and p = 1
        float p;
        float lo;
        float hi;
        if (mode == 0) {
            vec2 pe = vec2(re, 0.0);
            vec2 pp = rp * vec2(cos(delta), sin(delta));
            vec2 dv = pp - pe;
            float bg = min(abs(re * dv.y) / max(length(dv), 1e-12), rn);
            lo = -sqrt(rn);
            hi = 0.0;
            p = -sqrt(rn - bg);
        } else {
            lo = 0.0;
            hi = 40.0;
            float t1 = tmax * (1.0 - exp(-1.0));
            float f1 = sp_pair(1, an, af, rn - t1 * t1, rnm - t1 * t1, t1 * t1).x - delta;
            float f0 = dtan - delta;
            p = -f0 / max(f1 - f0, 1e-9);
            if (f1 < 0.0) lo = 1.0; else hi = 1.0;
            p = clamp(p, lo, hi);
        }
        float tb = 0.0;
        for (int it = 0; it < 14; it++) {
            tau = mode == 0 ? p : tmax * (1.0 - exp(-p));
            tb = tau;
            b = rn - tau * tau;
            res = sp_pair(mode, an, af, b, rnm - tau * tau, tau * tau);
            float f = res.x - delta;
            if (abs(f) < 2e-7) break;
            if (f > 0.0) hi = p; else lo = p;
            float h = mode == 0 ? -1e-4 * max(abs(p), 1e-2) : 1e-3;
            float p2 = p + h;
            float t2 = mode == 0 ? p2 : tmax * (1.0 - exp(-p2));
            float df = (sp_pair(mode, an, af, rn - t2 * t2, rnm - t2 * t2, t2 * t2).x - res.x) / h;
            float np2 = df > 0.0 ? p - f / df : 0.5 * (lo + hi);
            p = np2 > lo && np2 < hi ? np2 : 0.5 * (lo + hi);
        }
        tau = tb;
    }
    dist = res.y;
    // the eye's radial component: away from the throat on the direct branch from the nearer eye,
    // toward it otherwise; through the throat toward the point's side
    float sgn;
    if (!same) sgn = lp > le ? 1.0 : -1.0;
    else if (ae <= ap && mode == 0) sgn = le > 0.0 ? 1.0 : -1.0;
    else sgn = le > 0.0 ? -1.0 : 1.0;
    // r_e - b exactly where it is small: the eye is the nearer point and the ray near its tangent
    float reb = xvar ? re - b : (re - rn) + tau * tau;
    float cosA = sqrt(max(reb * (re + b), 0.0)) / re;
    return vec4(sgn * cosA, (b / re) * t);
}

// ---------------------------------------------------------------- geodesics
// d/ds of (l, n, V, a transported vector U): docs/geometry.md
void sp_rate(float l, vec3 n, vec4 V, out float dl, out vec3 dn, out vec4 dV, vec4 U, out vec4 dU,
             vec4 U2, out vec4 dU2, vec4 U3, out vec4 dU3) {
    float r = sp_r(abs(l));
    float k = sp_dr(l) / r;
    vec3 v = V.yzw;
    dl = V.x;
    dn = v / r;
    dV = vec4(k * dot(v, v), -k * V.x * v - (dot(v, v) / r) * n);
    dU = vec4(k * dot(v, U.yzw), -k * U.x * v - (dot(U.yzw, v) / r) * n);
    dU2 = vec4(k * dot(v, U2.yzw), -k * U2.x * v - (dot(U2.yzw, v) / r) * n);
    dU3 = vec4(k * dot(v, U3.yzw), -k * U3.x * v - (dot(U3.yzw, v) / r) * n);
}

// Follow the geodesic from (l, n) with unit direction V for length len (a few cm: an eye from the
// head) by two RK4 steps, transporting f0, f1, f2.
void sp_walk(inout float l, inout vec3 n, vec4 V, float len, inout vec4 f0, inout vec4 f1, inout vec4 f2) {
    float h = 0.5 * len;
    for (int i = 0; i < 2; i++) {
        float k1l; vec3 k1n; vec4 k1V; vec4 k1a; vec4 k1b; vec4 k1c;
        sp_rate(l, n, V, k1l, k1n, k1V, f0, k1a, f1, k1b, f2, k1c);
        float k2l; vec3 k2n; vec4 k2V; vec4 k2a; vec4 k2b; vec4 k2c;
        sp_rate(l + 0.5 * h * k1l, n + 0.5 * h * k1n, V + 0.5 * h * k1V, k2l, k2n, k2V,
                f0 + 0.5 * h * k1a, k2a, f1 + 0.5 * h * k1b, k2b, f2 + 0.5 * h * k1c, k2c);
        float k3l; vec3 k3n; vec4 k3V; vec4 k3a; vec4 k3b; vec4 k3c;
        sp_rate(l + 0.5 * h * k2l, n + 0.5 * h * k2n, V + 0.5 * h * k2V, k3l, k3n, k3V,
                f0 + 0.5 * h * k2a, k3a, f1 + 0.5 * h * k2b, k3b, f2 + 0.5 * h * k2c, k3c);
        float k4l; vec3 k4n; vec4 k4V; vec4 k4a; vec4 k4b; vec4 k4c;
        sp_rate(l + h * k3l, n + h * k3n, V + h * k3V, k4l, k4n, k4V, f0 + h * k3a, k4a, f1 + h * k3b, k4b, f2 + h * k3c, k4c);
        float w = h / 6.0;
        l += w * (k1l + 2.0 * k2l + 2.0 * k3l + k4l);
        n = normalize(n + w * (k1n + 2.0 * k2n + 2.0 * k3n + k4n));
        V += w * (k1V + 2.0 * k2V + 2.0 * k3V + k4V);
        f0 += w * (k1a + 2.0 * k2a + 2.0 * k3a + k4a);
        f1 += w * (k1b + 2.0 * k2b + 2.0 * k3b + k4b);
        f2 += w * (k1c + 2.0 * k2c + 2.0 * k3c + k4c);
        V.yzw -= dot(V.yzw, n) * n;
    }
    f0.yzw -= dot(f0.yzw, n) * n;
    f1.yzw -= dot(f1.yzw, n) * n;
    f2.yzw -= dot(f2.yzw, n) * n;
}

// ---------------------------------------------------------------- R^4
// The hypersurface's signed distance at P of R^4 (positive between the sheets, outside the
// cylinder) and its gradient.
float sp_sdf(vec4 P, out vec4 grad) {
    float rho = length(P.xyz);
    vec3 u = P.xyz / max(rho, 1e-12);
    float aw = abs(P.w);
    float sw = P.w >= 0.0 ? 1.0 : -1.0;
    if (aw <= sp_Lc && rho <= sp_Rout) {
        grad = vec4(u, 0.0);
        return rho - sp_rho0;
    }
    if (rho >= sp_Rout) {
        grad = vec4(0.0, 0.0, 0.0, -sw);
        return (sp_Lc + sp_R) - aw;
    }
    vec2 o = vec2(rho - sp_Rout, aw - sp_Lc);
    float lo = length(o);
    vec2 g = -o / max(lo, 1e-12);
    grad = vec4(g.x * u, g.y * sw);
    return sp_R - lo;
}

// The point (l, n) at a point P of R^4 on the hypersurface.
float sp_lOf(vec4 P, out vec3 n) {
    float rho = length(P.xyz);
    n = P.xyz / max(rho, 1e-12);
    float aw = abs(P.w);
    float sw = P.w >= 0.0 ? 1.0 : -1.0;
    if (aw <= sp_Lc && rho <= sp_rho0 + 0.5 * sp_R) return P.w;
    if (rho >= sp_Rout) return sw * (rho - sp_Rout + sp_L);
    return sw * (sp_Lc + sp_R * atan(aw - sp_Lc, sp_Rout - rho));
}

// The point of R^4 at (l, n)
vec4 sp_embed(float l, vec3 n) {
    float al = abs(l);
    float sw = l >= 0.0 ? 1.0 : -1.0;
    float w = al <= sp_Lc ? l : (al <= sp_L ? sw * (sp_Lc + sp_R * sin((al - sp_Lc) / sp_R)) : sw * (sp_Lc + sp_R));
    return vec4(sp_r(al) * n, w);
}

// A tangent vector of R^4 at (l, n) as (U_l, u)
vec4 sp_project(float l, vec3 n, vec4 D) {
    float al = abs(l);
    float sw = l >= 0.0 ? 1.0 : -1.0;
    float th = clamp((al - sp_Lc) / sp_R, 0.0, 0.5 * SP_PI);
    float dr = al <= sp_Lc ? 0.0 : sw * sin(th);
    float dw = al <= sp_Lc ? 1.0 : cos(th);
    float rad = dot(D.xyz, n);
    return vec4(rad * dr + D.w * dw, D.xyz - rad * n);
}
