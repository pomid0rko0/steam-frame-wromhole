// Movable objects in the curved space: how many path evaluations a ray needs to find a ball or
// a cube (chord distance in R^4, as in optozorax's 4D SDF scenes), with a bounded method:
//   far (distance >= rho): sphere tracing along the path (the path has unit speed in R^4, so a
//     chord is never longer than its arc and the distance is a safe step);
//   near: chords of length rho / 2, each tested exactly against the object inflated by the
//     chord's sag (K dS^2 / 8, K the space's largest principal curvature), then the path's own
//     entry found by regula falsi.
// Against the exact first entry (the path sampled every 2 mm, refined), per pixel of the
// headset's view (1728^2, 104 deg).
#[path = "../geom.rs"]
mod geom;
use geom::*;
use std::f64::consts::PI;

const NPX: f64 = 1728.0;
const FOV: f64 = 104.0;
const DS: f64 = 2e-3;
const KMAX: f64 = 1.0;   // the largest principal curvature of this space: 1 / fillet radius

type V3 = [f64; 3];
fn dot(a: V3, b: V3) -> f64 { a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }
fn add(a: V3, b: V3) -> V3 { [a[0] + b[0], a[1] + b[1], a[2] + b[2]] }
fn sub(a: V3, b: V3) -> V3 { [a[0] - b[0], a[1] - b[1], a[2] - b[2]] }
fn mul(a: V3, k: f64) -> V3 { [a[0] * k, a[1] * k, a[2] * k] }
fn cross(a: V3, b: V3) -> V3 { [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]] }
fn norm(a: V3) -> V3 { mul(a, 1.0 / dot(a, a).sqrt()) }

struct Cam { l: f64, n: V3, h: V3, v: V3, f: V3, rt: V3, up: V3 }

fn cam(l: f64, n: V3, yaw: f64, pitch: f64) -> Cam {
    let n = norm(n);
    let h = norm(cross([0.0, 0.0, 1.0], n));
    let v = norm(sub([0.0, 0.0, 1.0], mul(n, n[2])));
    let t0 = if l > 0.0 { -1.0 } else if l < 0.0 { 1.0 } else { -1.0 };
    let (cy, sy, cp, sp) = (yaw.to_radians().cos(), yaw.to_radians().sin(), pitch.to_radians().cos(), pitch.to_radians().sin());
    let f = [cp * cy * t0, cp * sy, sp];
    let rt = norm(cross(f, [0.0, 0.0, 1.0]));
    let up = cross(rt, f);
    Cam { l, n, h, v, f, rt, up }
}

/// the ray of the direction (tx, ty) in the camera's tangent coordinates: (v_l, w)
fn ray(c: &Cam, tx: f64, ty: f64) -> (f64, V3) {
    let d = norm(add(add(c.f, mul(c.rt, tx)), mul(c.up, ty)));
    (d[0], add(mul(c.h, d[1]), mul(c.v, d[2])))
}
fn pixel_t(px: f64) -> f64 { (px / NPX * 2.0 - 1.0) * (0.5 * FOV).to_radians().tan() }

/// A sampled path: s, l, psi every DS, until the floor (psi_f) or psi = pi or s_max
struct Path { b: f64, l: Vec<f64>, psi: Vec<f64>, end: f64, tab: Option<(std::sync::Arc<QTab>, f32)> }

/// The per-eye table of the path in the ray's subspace: rows by alpha (dense toward the critical
/// angle, as in main.rs), columns uniform in sqrt(s): (r cos psi, r sin psi, w), single precision
struct QTab { ac: f64, n: usize, ns: usize, smax: f64, rows: [Vec<f32>; 2], span: [f64; 2] }
const WLOG: f64 = 0.25;
const EPS: f64 = 1e-6;
fn warp(d: f64, span: f64) -> f64 { (1.0 - WLOG) * d / span + WLOG * (1.0 + d / EPS).ln() / (1.0 + span / EPS).ln() }
fn unwarp(x: f64, span: f64) -> f64 { let (mut lo, mut hi) = (0.0, span); for _ in 0..80 { let m = 0.5 * (lo + hi); if warp(m, span) < x { lo = m } else { hi = m } } 0.5 * (lo + hi) }

fn build_qtab(g: &Geo, l0: f64, n: usize, ns: usize, smax: f64) -> QTab {
    let re = g.r(l0);
    let ac = if re <= g.rmin + 1e-12 { 0.5 * PI } else if l0 >= 0.0 { PI - (g.rmin / re).asin() } else { (g.rmin / re).asin() };
    let span = [ac, PI - ac];
    let mut rows = [vec![0.0f32; n * ns * 3], vec![0.0f32; n * ns * 3]];
    for side in 0..2 {
        let out: Vec<(usize, Vec<f32>)> = std::thread::scope(|sc| {
            let hs: Vec<_> = (0..4).map(|t| sc.spawn(move || {
                let mut v = vec![];
                let mut i = t;
                while i < n {
                    let d = unwarp((i as f64 + 0.5) / n as f64, span[side]);
                    let a = if side == 0 { ac - d } else { ac + d };
                    let pa = path(g, l0, a.cos(), a.sin(), 10.0, smax + 0.01);
                    let mut row = vec![0.0f32; ns * 3];
                    for k in 0..ns {
                        let sk = (k as f64 / (ns - 1) as f64).powi(2) * smax;
                        let q = q_at(g, &pa, sk);
                        row[3 * k] = q[0] as f32; row[3 * k + 1] = q[1] as f32; row[3 * k + 2] = q[2] as f32;
                    }
                    v.push((i, row));
                    i += 4;
                }
                v
            })).collect();
            hs.into_iter().flat_map(|h| h.join().unwrap()).collect()
        });
        for (i, row) in out { rows[side][i * ns * 3..(i + 1) * ns * 3].copy_from_slice(&row); }
    }
    QTab { ac, n, ns, smax, rows, span }
}

/// the table's point at (alpha, s), bilinear in single precision
fn q_tab(t: &QTab, alpha: f32, s: f64) -> V3 {
    let side = if (alpha as f64) < t.ac { 0 } else { 1 };
    let d = ((alpha - t.ac as f32) * if side == 0 { -1.0 } else { 1.0 }).max(0.0);
    let sp = t.span[side] as f32;
    let x = (1.0 - WLOG as f32) * d / sp + WLOG as f32 * (d / EPS as f32).ln_1p() / (sp / EPS as f32).ln_1p();
    let u = (x * t.n as f32 - 0.5).clamp(0.0, (t.n - 1) as f32);
    let i0 = (u.floor() as usize).min(t.n - 2);
    let fa = u - i0 as f32;
    let c = ((s as f32 / t.smax as f32).max(0.0).sqrt() * (t.ns - 1) as f32).min((t.ns - 1) as f32);
    let k0 = (c.floor() as usize).min(t.ns - 2);
    let fc = c - k0 as f32;
    let r = &t.rows[side];
    let at = |i: usize, k: usize, j: usize| r[(i * t.ns + k) * 3 + j];
    let mut q = [0.0; 3];
    for j in 0..3 {
        let v = (at(i0, k0, j) * (1.0 - fc) + at(i0, k0 + 1, j) * fc) * (1.0 - fa) + (at(i0 + 1, k0, j) * (1.0 - fc) + at(i0 + 1, k0 + 1, j) * fc) * fa;
        q[j] = v as f64;
    }
    q
}

fn path(g: &Geo, l0: f64, vl: f64, wn: f64, psi_f: f64, s_max: f64) -> Path {
    let r0 = g.r(l0);
    let b = r0 * wn;
    let (mut l, mut p, mut psi) = (l0, vl, 0.0);
    let mut out = Path { b, l: vec![l], psi: vec![psi], end: 0.0, tab: None };
    let d = |l: f64, p: f64| { let (r, dr) = g.prof(l); (p, b * b * dr / (r * r * r), b / (r * r)) };
    let mut s = 0.0;
    while s < s_max {
        let k1 = d(l, p);
        let k2 = d(l + 0.5 * DS * k1.0, p + 0.5 * DS * k1.1);
        let k3 = d(l + 0.5 * DS * k2.0, p + 0.5 * DS * k2.1);
        let k4 = d(l + DS * k3.0, p + DS * k3.1);
        let nl = l + DS / 6.0 * (k1.0 + 2.0 * k2.0 + 2.0 * k3.0 + k4.0);
        let np = p + DS / 6.0 * (k1.1 + 2.0 * k2.1 + 2.0 * k3.1 + k4.1);
        let npsi = psi + DS / 6.0 * (k1.2 + 2.0 * k2.2 + 2.0 * k3.2 + k4.2);
        if npsi >= psi_f {
            let f = (psi_f - psi) / (npsi - psi);
            out.end = s + f * DS;
            out.l.push(l + f * (nl - l));
            out.psi.push(psi_f);
            return out;
        }
        l = nl; p = np; psi = npsi; s += DS;
        out.l.push(l);
        out.psi.push(psi);
    }
    out.end = s;
    out
}

/// the path's point at s in the ray's subspace of R^4: (r cos psi, r sin psi, w)
fn q_at(g: &Geo, pa: &Path, s: f64) -> V3 {
    if let Some((t, a)) = &pa.tab { return q_tab(t, *a, s); }
    let x = (s / DS).clamp(0.0, (pa.l.len() - 1) as f64);
    let i = (x.floor() as usize).min(pa.l.len() - 2);
    let f = x - i as f64;
    let l = pa.l[i] + f * (pa.l[i + 1] - pa.l[i]);
    let psi = pa.psi[i] + f * (pa.psi[i + 1] - pa.psi[i]);
    let r = g.r(l);
    [r * psi.cos(), r * psi.sin(), g.w4(l)]
}

/// An object seen in the ray's subspace: a ball (centre, perpendicular distance^2, radius) or a
/// box (centre, four axes / half size seen in the subspace, the axes' perpendicular offsets)
enum Obj { Ball { c: V3, perp2: f64, rho: f64 }, Box { c: V3, ax: [V3; 4], off: [f64; 4], half: f64 } }

impl Obj {
    /// distance in R^4 from the point q of the subspace (exact for the ball; for the box the
    /// exact distance to a box, from the slab coordinates)
    fn dist(&self, q: V3) -> f64 {
        match self {
            Obj::Ball { c, perp2, rho } => { let a = sub(q, *c); (dot(a, a) + perp2).sqrt() - rho }
            Obj::Box { c, ax, off, half } => {
                let a = sub(q, *c);
                let mut o2 = 0.0;
                let mut inside = f64::NEG_INFINITY;
                for k in 0..4 {
                    let u = (dot(a, ax[k]) - off[k]).abs() - 1.0;   // in half sizes
                    if u > 0.0 { o2 += u * u; }
                    inside = inside.max(u);
                }
                if o2 > 0.0 { o2.sqrt() * half } else { inside * half }
            }
        }
    }
    fn reach(&self) -> f64 { match self { Obj::Ball { rho, .. } => *rho, Obj::Box { half, .. } => *half } }
    /// the chord q0 -> q1 against the object grown by `grow`: the first fraction it is inside, or None
    fn chord(&self, q0: V3, q1: V3, grow: f64) -> Option<f64> {
        let dq = sub(q1, q0);
        match self {
            Obj::Ball { c, perp2, rho } => {
                let a = sub(q0, *c);
                let rr = (rho + grow) * (rho + grow);
                let aa = dot(dq, dq);
                let bb = dot(a, dq);
                let cc = dot(a, a) + perp2 - rr;
                if cc <= 0.0 { return Some(0.0); }
                let disc = bb * bb - aa * cc;
                if disc < 0.0 { return None; }
                let t = (-bb - disc.sqrt()) / aa;
                if t >= 0.0 && t <= 1.0 { Some(t) } else { None }
            }
            Obj::Box { c, ax, off, half } => {
                // slabs grown by grow / half: a superset of the rounded grown box
                let gk = 1.0 + grow / half;
                let a = sub(q0, *c);
                let (mut tin, mut tout) = (0.0f64, 1.0f64);
                for k in 0..4 {
                    let a0 = dot(a, ax[k]) - off[k];
                    let dk = dot(dq, ax[k]);
                    if dk.abs() < 1e-12 { if a0.abs() > gk { return None; } continue; }
                    let (t0, t1) = ((-gk - a0) / dk, (gk - a0) / dk);
                    tin = tin.max(t0.min(t1));
                    tout = tout.min(t0.max(t1));
                }
                if tin <= tout { Some(tin) } else { None }
            }
        }
    }
}

const LEVELS: u32 = 3;
/// The chord s0 -> s1 met the object grown by its sag: split it at its middle (the sag a quarter
/// each time) until a path point is inside (then regula falsi to the entry) or no half meets
/// the grown object. Depth LEVELS: at most 2^LEVELS - 1 middles.
fn refine(g: &Geo, pa: &Path, o: &Obj, s0: f64, q0: V3, d0: f64, s1: f64, q1: V3, lev: u32, s_tol: f64, ev: &mut u32) -> Option<f64> {
    let sm = 0.5 * (s0 + s1);
    let qm = q_at(g, pa, sm); *ev += 1;
    let dm = o.dist(qm);
    if dm <= 0.0 {
        // regula falsi (Illinois) between (s0, d0 > 0) and (sm, dm <= 0)
        let (mut lo, mut glo, mut hi, mut gh) = (s0, d0, sm, dm);
        let mut side = 0;
        for _ in 0..12 {
            if hi - lo < s_tol { break; }
            let sx = (lo * gh - hi * glo) / (gh - glo);
            let gx = o.dist(q_at(g, pa, sx)); *ev += 1;
            if gx > 0.0 { lo = sx; glo = gx; if side == -1 { gh *= 0.5; } side = -1; }
            else { hi = sx; gh = gx; if side == 1 { glo *= 0.5; } side = 1; }
        }
        return Some(hi);
    }
    if lev + 1 >= LEVELS {
        // the last level: the chord's own entry, if the chord itself meets the object (the path is
        // within the sag, ~K step^2 / 8 / 4^LEVELS, of it)
        let step = s1 - s0;
        if let Some(t) = o.chord(q0, qm, 0.0) { return Some(s0 + t * 0.5 * step); }
        if let Some(t) = o.chord(qm, q1, 0.0) { return Some(sm + t * 0.5 * step); }
        return None;
    }
    let h = 0.5 * (s1 - s0);
    let sag = KMAX * h * h / 8.0 + 1e-9;
    if o.chord(q0, qm, sag).is_some() { if let Some(x) = refine(g, pa, o, s0, q0, d0, sm, qm, lev + 1, s_tol, ev) { return Some(x); } }
    if o.chord(qm, q1, sag).is_some() { if let Some(x) = refine(g, pa, o, sm, qm, dm, s1, q1, lev + 1, s_tol, ev) { return Some(x); } }
    None
}

/// the bounded search: (hit s or None, path evaluations)
fn search(g: &Geo, pa: &Path, o: &Obj, s_tol: f64) -> (Option<f64>, u32) {
    let rho = o.reach();
    let mut ev = 0u32;
    let mut s = 0.0;
    let mut q = q_at(g, pa, s); ev += 1;
    let mut d = o.dist(q);
    if d <= 0.0 { return (None, ev); }   // starts inside: entries only
    loop {
        if s >= pa.end { return (None, ev); }
        if d >= rho {
            // far: a safe step
            s += d;
            if s >= pa.end { return (None, ev); }
            q = q_at(g, pa, s); ev += 1;
            d = o.dist(q);
            if d <= 0.0 { return (Some(s), ev); }    // cannot happen: the step was safe
            continue;
        }
        // near: a chord of rho / 2 against the object grown by its sag
        let step = (0.5 * rho).min(pa.end - s);
        let s1 = s + step;
        let q1 = q_at(g, pa, s1); ev += 1;
        let sag = KMAX * step * step / 8.0 + 1e-9;
        if o.chord(q, q1, sag).is_some() {
            if let Some(hit) = refine(g, pa, o, s, q, d, s1, q1, 0, s_tol, &mut ev) { return (Some(hit), ev); }
        }
        s = s1;
        q = q1;
        d = o.dist(q);
        if d <= 0.0 { return (Some(s), ev); }    // entered unseen (should not happen)
    }
}

fn depth_px_pre(g: &Geo, pa: &Path, ob: &Obj, ex: Option<f64>) -> f64 {
    match ex { Some(a) => { let mut m = 0.0f64; let mut ss = a; while ss < pa.end { let dd = ob.dist(q_at(g, pa, ss)); if dd > 0.0 && ss > a + 1e-3 { break; } m = m.min(dd); ss += DS / 4.0; } -m / (a.max(0.05) * 1.48e-3) } None => 0.0 }
}
/// exact first entry: every 2 mm sample, refined by bisection on the sampled path
fn exact_hit(g: &Geo, pa: &Path, o: &Obj) -> Option<f64> {
    if o.dist(q_at(g, pa, 0.0)) <= 0.0 { return None; }
    let n = pa.l.len();
    // sub-sample: 4 per DS so that grazing entries are not missed
    let mut prev = 0.0;
    let mut k = 1;
    while k < 4 * (n - 1) {
        let s = k as f64 * DS / 4.0;
        if s > pa.end { break; }
        if o.dist(q_at(g, pa, s)) <= 0.0 {
            let (mut lo, mut hi) = (prev, s);
            for _ in 0..50 { let m = 0.5 * (lo + hi); if o.dist(q_at(g, pa, m)) <= 0.0 { hi = m } else { lo = m } }
            return Some(hi);
        }
        prev = s;
        k += 1;
    }
    None
}

struct Rng(u64);
impl Rng { fn next(&mut self) -> f64 { self.0 ^= self.0 << 13; self.0 ^= self.0 >> 7; self.0 ^= self.0 << 17; (self.0 >> 11) as f64 / (1u64 << 53) as f64 } }

/// an object placed along the geodesic of camera direction (tx, ty) at distance dist: its R^4 centre
fn place(g: &Geo, c: &Cam, tx: f64, ty: f64, dist: f64) -> [f64; 4] {
    let (vl, w) = ray(c, tx, ty);
    let wn = dot(w, w).sqrt();
    let e2 = mul(w, 1.0 / wn);
    let pa = path(g, c.l, vl, wn, 10.0, dist + 0.01);
    let x = (dist / DS).min((pa.l.len() - 1) as f64) as usize;
    let (l, psi) = (pa.l[x], pa.psi[x]);
    let n = add(mul(c.n, psi.cos()), mul(e2, psi.sin()));
    let r = g.r(l);
    [r * n[0], r * n[1], r * n[2], g.w4(l)]
}

fn main() {
    let g = Geo::new(3.0, 5.0, 1.0);
    let up = |l: f64| { let r = g.r(l); let a = (1.6 / r).asin(); [a.cos(), 0.0, a.sin()] };
    // scenes: (name, eye l, yaw, pitch, objects: (kind 0 ball / 1 cube, tx, ty, distance, size))
    let scenes: Vec<(&str, f64, f64, f64, Vec<(u8, f64, f64, f64, f64)>)> = vec![
        ("held ball 25 cm at 35 cm, eye on the fillet l=5", 5.0, 0.0, -10.0, vec![(0, 0.0, -0.2, 0.35, 0.125)]),
        ("held ball 50 cm at 45 cm, eye near the outer edge l=5.5", 5.5, 20.0, -10.0, vec![(0, 0.1, -0.15, 0.45, 0.25)]),
        ("ball 70 cm at 2.5 m, eye in the throat looking sideways", 0.0, 90.0, -10.0, vec![(0, 0.0, -0.3, 2.5, 0.35)]),
        ("hand 4 cm at 40 cm, eye on the fillet l=4.6", 4.6, 0.0, -10.0, vec![(0, 0.25, -0.6, 0.4, 0.04)]),
        ("held cube 30 cm at 40 cm, eye on the fillet l=5", 5.0, 0.0, -10.0, vec![(1, -0.1, -0.3, 0.4, 0.15)]),
        ("cube 50 cm at 3 m, eye in the throat, along", 1.0, 0.0, -10.0, vec![(1, 0.05, -0.15, 3.0, 0.25)]),
    ];
    for (name, l0, yaw, pitch, objs) in &scenes {
        let c = cam(*l0, up(*l0), *yaw, *pitch);
        let centres: Vec<[f64; 4]> = objs.iter().map(|o| place(&g, &c, o.1, o.2, o.3)).collect();
        let use_tab = std::env::var("TABLE").is_ok();
        let qt = std::sync::Arc::new(if use_tab {
            let n: usize = std::env::var("TN").ok().map(|x| x.parse().unwrap()).unwrap_or(1024);
            let ns: usize = std::env::var("TS").ok().map(|x| x.parse().unwrap()).unwrap_or(512);
            build_qtab(&g, *l0, n, ns, 8.0)
        } else { QTab { ac: 0.0, n: 0, ns: 0, smax: 1.0, rows: [vec![], vec![]], span: [1.0, 1.0] } });
        // pixels: a box around each object's direction, and some over the whole view
        let mut rng = Rng(0x2545F4914F6CDD1D);
        let mut px = vec![];
        for o in objs.iter() {
            let ang = (o.4 * if o.0 == 1 { 2.0 } else { 1.0 } / o.3).min(0.99).asin() * 1.6;
            let tmax = (0.5 * FOV).to_radians().tan();
            for _ in 0..12000 {
                let tx = (o.1.atan() + (2.0 * rng.next() - 1.0) * ang).tan().clamp(-tmax, tmax);
                let ty = (o.2.atan() + (2.0 * rng.next() - 1.0) * ang).tan().clamp(-tmax, tmax);
                px.push((tx, ty));
            }
        }
        for _ in 0..3000 { px.push((pixel_t(rng.next() * NPX), pixel_t(rng.next() * NPX))); }
        let res: Vec<(u32, i32, f64, f64)> = std::thread::scope(|sc| {
            let chunks: Vec<_> = px.chunks((px.len() + 3) / 4).collect();
            let hs: Vec<_> = chunks.into_iter().map(|ch| {
                let (g, c, centres, objs) = (&g, &c, &centres, objs);
                let qt = qt.clone();
                sc.spawn(move || {
                    let mut out = vec![];
                    for &(tx, ty) in ch {
                        let (vl, w) = ray(c, tx, ty);
                        let wn = dot(w, w).sqrt();
                        let e2 = mul(w, 1.0 / wn);
                        let psi_f = c.n[2].atan2(-e2[2]);
                        let pa = path(g, c.l, vl, wn, psi_f, 8.0);
                        for (k, o) in objs.iter().enumerate() {
                            let cc = centres[k];
                            let cx = [cc[0], cc[1], cc[2]];
                            let (c1, c2) = (dot(cx, c.n), dot(cx, e2));
                            let perp2 = (dot(cx, cx) - c1 * c1 - c2 * c2).max(0.0);
                            let csub = [c1, c2, cc[3]];
                            let reach = if o.0 == 1 { 2.0 * o.4 } else { o.4 };
                            if perp2 >= reach * reach { continue; }   // the plane test: not a candidate
                            let ob = if o.0 == 0 { Obj::Ball { c: csub, perp2, rho: o.4 } } else {
                                // a cube upright in the tangent space at its centre: axes = the
                                // tangent basis there turned by 30 deg about the vertical, and the
                                // normal; seen in the subspace (u, v, w): (A.e1, A.e2, A_w) / half
                                let nc = { let m = dot(cx, cx).sqrt(); mul(cx, 1.0 / m) };
                                // the space's normal and its radial tangent at the centre, from the profile
                                let lcen = find_l(g, dot(cx, cx).sqrt(), cc[3]);
                                let (_, dr) = g.prof(lcen);
                                let dw = (1.0 - dr * dr).max(0.0).sqrt();   // dw/dl >= 0 on both sides
                                let t_l = [nc[0] * dr, nc[1] * dr, nc[2] * dr, dw];           // d/dl in R^4
                                let nrm = [-nc[0] * dw, -nc[1] * dw, -nc[2] * dw, dr];         // normal
                                let hh = norm(cross([0.0, 0.0, 1.0], nc));
                                let vv = norm(cross(nc, hh));
                                let (ca, sa) = (0.5f64.cos(), 0.5f64.sin());
                                let a1 = [hh[0] * ca, hh[1] * ca, hh[2] * ca, 0.0];
                                let a1 = [a1[0] + t_l[0] * sa, a1[1] + t_l[1] * sa, a1[2] + t_l[2] * sa, t_l[3] * sa];
                                let a2 = [-hh[0] * sa + t_l[0] * ca, -hh[1] * sa + t_l[1] * ca, -hh[2] * sa + t_l[2] * ca, t_l[3] * ca];
                                let a3 = [vv[0], vv[1], vv[2], 0.0];
                                let axes4 = [a1, a2, a3, nrm];
                                let mut ax = [[0.0; 3]; 4];
                                let mut off = [0.0; 4];
                                for k in 0..4 {
                                    let a = axes4[k];
                                    let a3v = [a[0], a[1], a[2]];
                                    ax[k] = mul([dot(a3v, c.n), dot(a3v, e2), a[3]], 1.0 / o.4);
                                    // the part of the centre offset outside the subspace: P - C has
                                    // perp component -C_perp, whose dot with the axis is constant
                                    let cperp = sub(cx, add(mul(c.n, c1), mul(e2, c2)));
                                    off[k] = dot(cperp, a3v) / o.4;
                                }
                                Obj::Box { c: csub, ax, off, half: o.4 }
                            };
                            let ex = exact_hit(g, &pa, &ob);
                            let pixel = 1.48e-3;
                            let pt = Path { b: pa.b, l: vec![], psi: vec![], end: pa.end, tab: Some((qt.clone(), (wn as f32).atan2(vl as f32))) };
                            let (h, ev) = if use_tab { search(g, &pt, &ob, 0.02 * pixel * 0.3) } else { search(g, &pa, &ob, 0.02 * pixel * 0.3) };
                            if std::env::var("DBG").is_ok() {
                                let bad = match (ex, h) { (Some(_), None) => depth_px_pre(g, &pa, &ob, ex) > 0.5, _ => false };
                                if bad {
                                    let mut prof = String::new();
                                    if let Some(a) = ex { for k in 0..13 { let ss = a - 0.06 + 0.01 * k as f64; prof += &format!(" {:.4}", ob.dist(q_at(g, &pa, ss))); } }
                                    let a = ex.unwrap();
                                    let mut mn = (0.0f64, a);
                                    let mut ss = a; while ss < a + 0.05 { let dd = ob.dist(q_at(g, &pa, ss)); if dd < mn.0 { mn = (dd, ss); } ss += 1e-5; }
                                    eprintln!("BAD ex {:.5} min dist {:.6} at +{:.5} m, depth {:.3} px; ev {}", a, mn.0, mn.1 - a, -mn.0 / (a * 1.48e-3), ev);
                                }
                            }
                            let depth_px = match ex {
                                Some(a) => {
                                    let mut m = 0.0f64;
                                    let mut ss = a;
                                    while ss < pa.end { let dd = ob.dist(q_at(g, &pa, ss)); if dd > 0.0 && ss > a + 1e-3 { break; } m = m.min(dd); ss += DS / 4.0; }
                                    -m / (a.max(0.05) * pixel)
                                }
                                None => 0.0,
                            };
                            let kind = match (ex, h) { (Some(_), Some(_)) => 1, (None, None) => 0, (Some(_), None) => -1, (None, Some(_)) => -2 };
                            let err = match (ex, h) {
                                (Some(a), Some(b)) => { let d = sub(q_at(g, &pa, a), q_at(g, &pa, b)); dot(d, d).sqrt() / (a.max(0.05) * pixel) }
                                _ => 0.0,
                            };
                            out.push((ev, kind, err, depth_px));
                        }
                    }
                    out
                })
            }).collect();
            hs.into_iter().flat_map(|h| h.join().unwrap()).collect()
        });
        let n = res.len();
        let hits = res.iter().filter(|r| r.1 == 1).count();
        let missed = res.iter().filter(|r| r.1 == -1).count();
        let false_h = res.iter().filter(|r| r.1 == -2).count();
        let mut evs: Vec<u32> = res.iter().map(|r| r.0).collect();
        evs.sort();
        let mean = evs.iter().map(|&x| x as f64).sum::<f64>() / n.max(1) as f64;
        let mut evh: Vec<u32> = res.iter().filter(|r| r.1 == 1).map(|r| r.0).collect();
        evh.sort();
        let mut errs: Vec<f64> = res.iter().filter(|r| r.1 == 1 && r.3 > 0.5).map(|r| r.2).collect();
        let lost_depth = res.iter().filter(|r| r.1 == -1).map(|r| r.3).fold(0.0f64, f64::max);
        errs.sort_by(|a, b| a.partial_cmp(b).unwrap());
        println!("{}\n    candidates {}, hits {}, lost {}, false {}; evaluations per candidate: mean {:.1}, p99 {}, max {}; on hits: mean {:.1} max {}; hit point error (rays 0.5 px or more inside) p99 {:.3} max {:.3} px; lost rays go in at most {:.3} px",
            name, n, hits, missed, false_h, mean, evs[(n - 1) * 99 / 100], evs[n - 1],
            evh.iter().map(|&x| x as f64).sum::<f64>() / evh.len().max(1) as f64, evh.last().unwrap_or(&0),
            errs.get((errs.len().max(1) - 1) * 99 / 100).unwrap_or(&0.0), errs.last().unwrap_or(&0.0), lost_depth);
    }
}

/// l of the point with |xyz| = r and w (the profile is monotone in l on each side)
fn find_l(g: &Geo, r: f64, w: f64) -> f64 {
    let sg = if w >= 0.0 { 1.0 } else { -1.0 };
    let (mut lo, mut hi) = (0.0, 30.0);
    // r + |w| grows with |l|
    for _ in 0..80 { let m = 0.5 * (lo + hi); if g.r(m) + g.w4(m).abs() < r + w.abs() { lo = m } else { hi = m } }
    sg * 0.5 * (lo + hi)
}
