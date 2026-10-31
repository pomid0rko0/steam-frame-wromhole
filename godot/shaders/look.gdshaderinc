// How things look: the skies, the floor, the bodies' light, the fog, the gravity view's colours
// and arrows (docs/gravity.md, «Показ»). After eye.gdshaderinc. Each universe has its own sky and
// sun; a body is lit by the sun of the universe its point is in.

global uniform vec4 grav_cyl;     // WormholeSpace.gravity_shader
global uniform vec4 grav_g0;
global uniform vec4 grav_g1;
global uniform vec4 grav_d0;
global uniform vec4 grav_d1;

vec3 lk_sunDir(float side) {
    return side > 0.0 ? normalize(vec3(-0.6, 0.55, 0.18)) : normalize(vec3(0.35, -0.45, 0.82));
}

// A sunset in A, a day with a big moon in B; d: a unit direction in the chart.
vec3 lk_sky(float side, vec3 d) {
    bool A = side > 0.0;
    float el = d.z;
    float sd = dot(d, lk_sunDir(side));
    vec3 col = mix(A ? vec3(1.00, 0.55, 0.25) : vec3(0.75, 0.88, 1.00),
                   A ? vec3(0.10, 0.12, 0.35) : vec3(0.15, 0.40, 0.90),
                   pow(clamp(el, 0.0, 1.0), A ? 0.45 : 0.6));
    float glow = max(sd, 0.0);
    glow *= glow; glow *= glow;
    col += A ? vec3(0.6, 0.36, 0.18) * glow * glow : vec3(0.0);
    float t = clamp((sd - (A ? 0.9990 : 0.9993)) * (A ? 2000.0 : 1.0 / 0.0003), 0.0, 1.0);
    col += (A ? vec3(4.0, 3.6, 2.8) : vec3(4.0)) * (t * t * (3.0 - 2.0 * t));
    float mk = A ? 0.0 : smoothstep(0.9930, 0.9940, dot(d, normalize(vec3(-0.8, -0.3, 0.35))));
    col = mix(col, vec3(0.85, 0.85, 0.80) * (0.6 + 0.4 * d.z), mk);
    return mix(col, A ? vec3(0.35, 0.22, 0.15) : vec3(0.30, 0.35, 0.42), clamp(-el * 8.0, 0.0, 1.0));
}

// The floor at q = (l, azimuth * 24 / 2pi): 1 m rings, 24 spokes; checker cells, faded out where
// they get smaller than a pixel (fw: q's footprint)
vec3 lk_floor(vec2 q, vec2 fw) {
    vec2 cell = floor(q);
    float chk = mix(0.5, mod(cell.x + cell.y, 2.0), 1.0 - clamp(max(fw.x, fw.y) - 0.5, 0.0, 1.0));
    float sA = smoothstep(-0.5, 0.5, q.x);
    vec3 baseA = mix(vec3(0.62, 0.42, 0.28), vec3(0.72, 0.52, 0.36), chk);
    vec3 baseB = mix(vec3(0.28, 0.34, 0.44), vec3(0.38, 0.45, 0.55), chk);
    return mix(baseB, baseA, sA);
}

vec3 lk_shade(float side, vec3 col, vec3 nrm) {
    float dif = max(dot(nrm, lk_sunDir(side)), 0.0);
    vec3 amb = side > 0.0 ? vec3(0.35, 0.30, 0.35) : vec3(0.35, 0.42, 0.55);
    vec3 sun = side > 0.0 ? vec3(1.2, 0.8, 0.55) : vec3(1.1, 1.1, 1.05);
    return col * (amb + sun * dif);
}

vec3 lk_fog(float side, vec3 c, float dist) {
    return mix(c, side > 0.0 ? vec3(0.95, 0.60, 0.35) : vec3(0.70, 0.82, 0.95), 1.0 - exp(-dist * 0.012));
}

// ---------------------------------------------------------------- gravity
// The potential is g f(l) n_z (docs/gravity.md). (f / r, d(f / r)/dl, f') at l: f / r is the
// strength of gravity on the floor, in g.
vec3 lk_grav(float l) {
    float al = abs(l);
    float sg = l < 0.0 ? -1.0 : 1.0;
    if (al >= sp_L) {
        float rr = al - sp_L + sp_Rout;
        float b = grav_cyl.w / (rr * rr * rr);
        return vec3(1.0 + b, -3.0 * b / rr * sg, (1.0 - 2.0 * b) * sg);
    }
    if (al <= sp_Lc) {
        float e = exp(grav_cyl.y * al);
        float ie = 1.0 / e;
        return vec3(0.5 * grav_cyl.x * (e + ie), 0.5 * grav_cyl.x * grav_cyl.y * (e - ie) * sg,
                    0.5 * grav_cyl.z * (e - ie) * sg);
    }
    float is = 1.0 / (sp_L - sp_Lc);
    float x = (al - sp_Lc) * is;
    vec4 a = grav_g0;
    vec4 b = grav_g1;
    float g = a.x + x * (a.y + x * (a.z + x * (a.w + x * (b.x + x * (b.y + x * (b.z + x * b.w))))));
    float dg = a.y + x * (2.0 * a.z + x * (3.0 * a.w + x * (4.0 * b.x + x * (5.0 * b.y + x * (6.0 * b.z + x * 7.0 * b.w)))));
    vec4 c = grav_d0;
    vec4 e = grav_d1;
    float fp = c.x + x * (c.y + x * (c.z + x * (c.w + x * (e.x + x * (e.y + x * (e.z + x * e.w))))));
    return vec3(g, dg * is * sg, fp * sg);
}

// optozorax's palette; bands of 0.1 g below 1 g and of a tenth of a decade above
float lk_gravBand(float g) {
    return g < 1.0 ? 10.0 * g : 10.0 + 4.342944819 * log(g);
}

vec3 lk_gravColour(float t) {
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

// The floor in the colour of its gravity, darker at the bands' edges, the checker kept as brightness
vec3 lk_gravFloor(vec2 q, vec2 fw) {
    vec2 cell = floor(q);
    float chk = mix(0.5, mod(cell.x + cell.y, 2.0), 1.0 - clamp(max(fw.x, fw.y) - 0.5, 0.0, 1.0));
    vec3 G = lk_grav(q.x);
    float t = lk_gravBand(G.x);
    float dt = abs(G.y) * (G.x < 1.0 ? 10.0 : 4.342944819 / G.x) * fw.x;
    float edge = clamp(abs(fract(t + 0.5) - 0.5) / max(dt, 1e-4), 0.0, 1.0);
    return lk_gravColour(t) * (0.8 + 0.2 * edge) * (0.85 + 0.15 * chk);
}

const float LK_ARROW_REACH = 4.5;     // arrows up to this far outside the curved zone

// The field's arrows on the surface n.x = 0 (through the throat), above the floor (0 < a < pi), at
// (l, n), n = (0, cos a, sin a): the arrow of the nearest node, on the rings l = k (1 m apart),
// about 1 m apart along each half circle. Length 0.6 m at 1 g. foot: a pixel's size there (m).
// Returns colour and coverage.
vec4 lk_arrow(float l, float a, float foot) {
    if (a <= 0.0 || abs(l) > sp_L + LK_ARROW_REACH) return vec4(0.0);
    float lk = round(l);
    float rk = sp_r(abs(lk));
    float N = max(1.0, round(SP_PI * rk));
    float j = min(floor(a * N / SP_PI), N - 1.0);
    float aj = (j + 0.5) * SP_PI / N;
    vec3 G = lk_grav(lk);
    vec2 g = vec2(-G.z * sin(aj), -G.x * cos(aj));
    float gm = length(g);
    vec2 u = g / max(gm, 1e-6);
    vec2 q = vec2(l - lk, rk * (a - aj));
    float s = dot(q, u);
    float c = abs(dot(q, vec2(-u.y, u.x)));
    float len = 0.6 * min(gm, 1.4);
    float hl = min(0.3, 0.6 * len);
    float hw = 0.13;
    float sw = 0.035;
    float s0 = 0.5 * len - hl;
    float dShaft = max(c - sw, max(-0.5 * len - s, s - s0));
    float dHead = max(s0 - s, ((s - s0) * hw + (c - hw) * hl) * inversesqrt(hw * hw + hl * hl));
    float d = min(dShaft, dHead);
    float f = max(foot, 1e-4);
    float cover = clamp(0.5 - d / f, 0.0, 1.0);
    float rim = clamp(0.5 - (d + 0.02) / f, 0.0, 1.0);
    vec3 col = mix(vec3(0.02), 1.15 * lk_gravColour(lk_gravBand(gm)), rim);
    return vec4(col, gm > 1e-4 ? 0.92 * cover : 0.0);
}

// ---------------------------------------------------------------- the floor and the sky
// What sp_trace found, shaded: grid lines need screen-space derivatives, defined only in uniform
// control flow, so they are taken here for every pixel. A pixel's grid coordinates can jump (the
// azimuth's seam, the sky against the floor): a coordinate class is folded into y, and a
// derivative across a jump is replaced by the other direction's (the azimuth's seam: none drawn).
vec3 lk_background(int kind, float side, vec3 d, float fl, float dist) {
    float az = atan(d.y, d.x);
    float el = atan(d.z, length(d.xy));
    vec2 gq = kind == 1 ? vec2(fl, az * 24.0 / (2.0 * SP_PI)) : vec2(az, el) * (180.0 / SP_PI / 15.0);
    float cls = kind == 0 ? (side > 0.0 ? 0.0 : 1.0) : 2.0;
    vec2 gdx = dFdx(gq + vec2(0.0, 64.0 * cls));
    vec2 gdy = dFdy(gq + vec2(0.0, 64.0 * cls));
    bool ex = abs(gdx.y) > 32.0;
    bool ey = abs(gdy.y) > 32.0;
    vec2 fw = abs(ex ? gdy : gdx) + abs(ey ? gdx : gdy);
    fw = ex && ey ? vec2(1e-4) : max(fw, vec2(1e-4));
    vec3 c;
    if (kind == 0) {
        c = lk_sky(side, d);
    } else {
#ifdef LK_GRAVITY
        c = lk_gravFloor(gq, fw);
#else
        c = lk_floor(gq, fw);
#endif
    }
    vec2 ifw = vec2(fw.y, fw.x) / (fw.x * fw.y);
    vec2 gf = abs(fract(gq + 0.5) - 0.5) * ifw;
    float line = 1.0 - clamp(min(gf.x, gf.y), 0.0, 1.0);
    c = mix(c, kind == 1 ? vec3(0.95) : (side > 0.0 ? vec3(1.0, 0.9, 0.8) : vec3(1.0)), (kind == 1 ? 0.55 : 0.12) * line);
    return kind == 1 ? lk_fog(side, c, dist) : c;
}
