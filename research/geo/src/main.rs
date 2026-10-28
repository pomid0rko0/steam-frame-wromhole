// Per-eye ray tables against exact geodesics, in pixels of the headset's view (1728^2, 104 deg).
// For an eye at l_E the curved part of a ray depends only on its angle alpha to the radial
// direction: tables over alpha (1D: where it leaves, its direction at infinity) and over
// (alpha, psi) (2D: l at polar angle psi in its plane) give every pixel's floor point or sky
// direction. Here: how far that is from the exact answer, as a shift on the screen in pixels.
mod geom;
use geom::*;
use std::f64::consts::PI;

#[derive(Clone, Copy, Debug)]
struct V3 { x: f64, y: f64, z: f64 }
impl V3 {
    fn new(x: f64, y: f64, z: f64) -> V3 { V3 { x, y, z } }
    fn dot(self, o: V3) -> f64 { self.x * o.x + self.y * o.y + self.z * o.z }
    fn add(self, o: V3) -> V3 { V3::new(self.x + o.x, self.y + o.y, self.z + o.z) }
    fn sub(self, o: V3) -> V3 { V3::new(self.x - o.x, self.y - o.y, self.z - o.z) }
    fn mul(self, k: f64) -> V3 { V3::new(self.x * k, self.y * k, self.z * k) }
    fn cross(self, o: V3) -> V3 { V3::new(self.y * o.z - self.z * o.y, self.z * o.x - self.x * o.z, self.x * o.y - self.y * o.x) }
    fn len(self) -> f64 { self.dot(self).sqrt() }
    fn norm(self) -> V3 { self.mul(1.0 / self.len()) }
}

/// The eye: l, n (unit), and a camera frame in the tangent space, as (v_l, w) pairs: the
/// tangent basis {d_l, h, v} (h horizontal, v vertical, both orthogonal to n).
struct Eye { l: f64, n: V3, h: V3, v: V3, f: [f64; 3], rt: [f64; 3], up: [f64; 3] }

fn eye(l: f64, n: V3, yaw: f64, pitch: f64) -> Eye {
    let n = n.norm();
    let ez = V3::new(0.0, 0.0, 1.0);
    let h = ez.cross(n).norm();
    let v = ez.sub(n.mul(n.z)).norm();
    let t0 = if l > 0.0 { -1.0 } else if l < 0.0 { 1.0 } else { -1.0 };   // toward the throat along d_l
    let (cy, sy) = (yaw.to_radians().cos(), yaw.to_radians().sin());
    let (cp, sp) = (pitch.to_radians().cos(), pitch.to_radians().sin());
    let f = [cp * cy * t0, cp * sy, sp];
    // right = f x vertical, up = right x f (in the coordinates of {d_l, h, v})
    let vert = [0.0, 0.0, 1.0];
    let cr = |a: [f64; 3], b: [f64; 3]| [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
    let nm = |a: [f64; 3]| { let k = (a[0] * a[0] + a[1] * a[1] + a[2] * a[2]).sqrt(); [a[0] / k, a[1] / k, a[2] / k] };
    let rt = nm(cr(f, vert));
    let up = cr(rt, f);
    Eye { l, n, h, v, f, rt, up }
}

const NPX: usize = 1728;
const FOV: f64 = 104.0;

/// the pixel's ray: (v_l, w)
fn pixel_ray(e: &Eye, px: f64, py: f64) -> (f64, V3) {
    let t = (0.5 * FOV).to_radians().tan();
    let tx = (px / NPX as f64 * 2.0 - 1.0) * t;
    let ty = (1.0 - py / NPX as f64 * 2.0) * t;
    let mut d = [0.0; 3];
    for k in 0..3 { d[k] = e.f[k] + tx * e.rt[k] + ty * e.up[k]; }
    let k = (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]).sqrt();
    (d[0] / k, e.h.mul(d[1] / k).add(e.v.mul(d[2] / k)))
}

#[derive(Clone, Copy, Debug)]
struct Hit { cls: i32, side: f64, l: f64, n: V3 }    // cls 0 sky, 1 floor

fn exact(g: &Geo, e: &Eye, vl: f64, w: V3, ds: f64) -> Option<Hit> {
    let wn = w.len();
    if wn < 1e-9 { return None; }
    let e2 = w.mul(1.0 / wn);
    let psi_f = e.n.z.atan2(-e2.z);
    let mut got: Option<(f64, f64)> = None;
    let sum = trace(g, e.l, vl, wn, &[psi_f], PI + 0.2, ds, &mut |_, l, s| got = Some((l, s)));
    let nat = |psi: f64| e.n.mul(psi.cos()).add(e2.mul(psi.sin()));
    if let Some((l, _)) = got {
        return Some(Hit { cls: 1, side: l.signum(), l, n: nat(psi_f) });
    }
    if sum.exits {
        return Some(Hit { cls: 0, side: sum.side, l: 0.0, n: nat(sum.psi_inf) });
    }
    None
}

/// One side of the split at alpha_c: rows at cell centres over [a0, a0 + span]
struct Grid { a0: f64, da: f64, n: usize, ac: f64, span: f64, dir: f64, psi_exit: Vec<f32>, psi_inf: Vec<f32>, side: Vec<f32>, lt: Vec<f32> }

struct Tab { lo: f64, hi: f64, ac: f64, npsi: usize, g: [Grid; 2], outside: bool }

const WLOG: f64 = 0.25;
const EPS: f64 = 1e-6;
/// x in [0, 1] from d in [0, span]: part linear, part logarithmic (dense at d = 0, the critical ray)
fn warp(d: f64, span: f64) -> f64 { (1.0 - WLOG) * d / span + WLOG * (1.0 + d / EPS).ln() / (1.0 + span / EPS).ln() }
fn unwarp(x: f64, span: f64) -> f64 {
    let (mut lo, mut hi) = (0.0, span);
    for _ in 0..80 { let m = 0.5 * (lo + hi); if warp(m, span) < x { lo = m } else { hi = m } }
    0.5 * (lo + hi)
}
fn build_grid(g: &Geo, e: &Eye, a0: f64, a1: f64, n: usize, npsi: usize, ds: f64) -> Grid {
    let da = (a1 - a0) / n as f64;
    // the critical angle is at a1 for the lower grid, a0 for the upper one
    let warped = std::env::var("UNIFORM").is_err();
    let (ac, dir) = if (a1 - e_ac(g, e)).abs() < 1e-12 { (a1, -1.0) } else { (a0, 1.0) };
    let span = a1 - a0;
    let row_a = move |i: usize| if warped { ac + dir * unwarp((i as f64 + 0.5) / n as f64, span) } else { a0 + (i as f64 + 0.5) * da };
    let targets: Vec<f64> = (0..npsi).map(|k| k as f64 * PI / (npsi - 1) as f64).collect();
    let mut gr = Grid { a0, da, n, ac, span, dir, psi_exit: vec![0.0; n], psi_inf: vec![0.0; n], side: vec![0.0; n], lt: vec![0.0; n * npsi] };
    let rows: Vec<(usize, Vec<f32>, f32, f32, f32)> = std::thread::scope(|sc| {
        let nth = 4;
        let hs: Vec<_> = (0..nth).map(|t| {
            let targets = &targets;
            sc.spawn(move || {
                let mut out = vec![];
                let mut i = t;
                while i < n {
                    let a = row_a(i);
                    let mut lt = vec![f32::NAN; npsi];
                    let sum = trace(g, e.l, a.cos(), a.sin(), targets, PI + 0.2, ds, &mut |k, l, _| lt[k] = l as f32);
                    // beyond where the ray goes (the sky): hold the last value
                    let mut last = lt.iter().rposition(|x| !x.is_nan()).map(|k| lt[k]).unwrap_or(0.0);
                    for k in 0..npsi { if lt[k].is_nan() { lt[k] = last; } else { last = lt[k]; } }
                    let pe = if sum.exits { sum.psi_exit } else { PI + 1.0 };
                    let pi_ = if sum.exits { sum.psi_inf } else { PI + 1.0 };
                    out.push((i, lt, pe as f32, pi_ as f32, sum.side as f32));
                    i += nth;
                }
                out
            })
        }).collect();
        hs.into_iter().flat_map(|h| h.join().unwrap()).collect()
    });
    for (i, lt, pe, pi_, sd) in rows {
        gr.psi_exit[i] = pe;
        gr.psi_inf[i] = pi_;
        gr.side[i] = sd;
        gr.lt[i * npsi..(i + 1) * npsi].copy_from_slice(&lt);
    }
    gr
}

fn e_ac(g: &Geo, e: &Eye) -> f64 {
    let re = g.r(e.l);
    if re <= g.rmin + 1e-12 { 0.5 * PI } else if e.l >= 0.0 { PI - (g.rmin / re).asin() } else { (g.rmin / re).asin() }
}
fn build(g: &Geo, e: &Eye, na: usize, npsi: usize, ds: f64) -> Tab {
    let re = g.r(e.l);
    let outside = e.l.abs() >= g.l;
    let sg = e.l.signum();
    // the rays that can reach the shell, and the critical one (b = rmin, toward the throat)
    let (lo, hi) = if outside {
        let a = (g.rout / re).asin();
        if sg > 0.0 { (PI - a, PI) } else { (0.0, a) }
    } else { (0.0, PI) };
    let ac = if re <= g.rmin + 1e-12 { 0.5 * PI } else if sg >= 0.0 { PI - (g.rmin / re).asin() } else { (g.rmin / re).asin() };
    let g0 = build_grid(g, e, lo, ac, na / 2, npsi, ds);
    let g1 = build_grid(g, e, ac, hi, na / 2, npsi, ds);
    Tab { lo, hi, ac, npsi, g: [g0, g1], outside }
}

/// hardware-like linear filtering: the fraction quantised to 1/2^q (q = 0: exact float)
#[inline]
fn qf(f: f32, q: u32) -> f32 { if q == 0 { f } else { let s = (1u32 << q) as f32; (f * s).round() / s } }

fn table_hit(g: &Geo, t: &Tab, e: &Eye, vl: f64, w: V3, q: u32) -> Option<Hit> {
    // single precision from here, as the shader would
    let (vl, wx, wy, wz) = (vl as f32, w.x as f32, w.y as f32, w.z as f32);
    let wn = (wx * wx + wy * wy + wz * wz).sqrt();
    if wn < 1e-6 { return None; }
    let (e2x, e2y, e2z) = (wx / wn, wy / wn, wz / wn);
    let (nx, ny, nz) = (e.n.x as f32, e.n.y as f32, e.n.z as f32);
    let alpha = wn.atan2(vl);
    let re = g.r(e.l) as f32;
    let b = re * wn;
    let rout = g.rout as f32;
    let lsh = g.l as f32;
    let psi_f = nz.atan2(-e2z);
    let nat = |psi: f32| V3::new((nx * psi.cos() + e2x * psi.sin()) as f64, (ny * psi.cos() + e2y * psi.sin()) as f64, (nz * psi.cos() + e2z * psi.sin()) as f64);
    let alpha64 = alpha as f64;
    if t.outside && (alpha64 < t.lo || alpha64 > t.hi || b >= rout) {
        return None;   // never touches the shell: straight, exact in any method
    }
    let gr = if (alpha as f64) < t.ac { &t.g[0] } else { &t.g[1] };
    let u = if std::env::var("UNIFORM").is_err() {
        // the row coordinate: one log per pixel (single precision)
        let d = ((alpha - gr.ac as f32) * gr.dir as f32).max(0.0);
        let sp = gr.span as f32;
        let x = (1.0 - WLOG as f32) * d / sp + WLOG as f32 * (d / EPS as f32).ln_1p() / (sp / EPS as f32).ln_1p();
        (x * gr.n as f32 - 0.5).clamp(0.0, (gr.n - 1) as f32)
    } else { ((alpha - gr.a0 as f32) / gr.da as f32 - 0.5).clamp(0.0, (gr.n - 1) as f32) };
    let i0 = (u.floor() as usize).min(gr.n - 2);
    let fa = qf(u - i0 as f32, q);
    let lin = |v: &Vec<f32>| v[i0] * (1.0 - fa) + v[i0 + 1] * fa;
    let pe = lin(&gr.psi_exit);
    let pinf = lin(&gr.psi_inf);
    let side = if gr.side[i0] != 0.0 { gr.side[i0] } else { gr.side[i0 + 1] };
    if psi_f < pe {
        let np = t.npsi;
        let v = psi_f / PI as f32 * (np - 1) as f32;
        let k0 = (v.floor() as usize).min(np - 2);
        let fp = qf(v - k0 as f32, q);
        let at = |i: usize, k: usize| gr.lt[i * np + k];
        let l = (at(i0, k0) * (1.0 - fp) + at(i0, k0 + 1) * fp) * (1.0 - fa) + (at(i0 + 1, k0) * (1.0 - fp) + at(i0 + 1, k0 + 1) * fp) * fa;
        return Some(Hit { cls: 1, side: (l as f64).signum(), l: l as f64, n: nat(psi_f) });
    }
    if psi_f < pinf {
        let r = b / (pinf - psi_f).sin();
        let l = side * (r - rout + lsh);
        return Some(Hit { cls: 1, side: side as f64, l: l as f64, n: nat(psi_f) });
    }
    Some(Hit { cls: 0, side: side as f64, l: 0.0, n: nat(pinf) })
}

/// the 2D difference between two hits of the same kind: floor (dl, r dphi), sky (tangent plane at a)
fn diff(g: &Geo, a: &Hit, b: &Hit) -> [f64; 2] {
    if a.cls == 1 {
        let dphi = (a.n.x * b.n.y - a.n.y * b.n.x).atan2(a.n.x * b.n.x + a.n.y * b.n.y);
        [b.l - a.l, g.r(0.5 * (a.l + b.l)) * dphi]
    } else {
        let t1 = if a.n.z.abs() < 0.9 { V3::new(0.0, 0.0, 1.0).cross(a.n).norm() } else { V3::new(1.0, 0.0, 0.0).cross(a.n).norm() };
        let t2 = a.n.cross(t1);
        let d = b.n.sub(a.n);
        [d.dot(t1), d.dot(t2)]
    }
}

/// the error as a shift in pixels: solve J p = err, J's columns the neighbours' differences
fn px_err(j1: [f64; 2], j2: [f64; 2], e: [f64; 2]) -> f64 {
    let det = j1[0] * j2[1] - j1[1] * j2[0];
    if det.abs() < 1e-30 { return f64::NAN; }
    let p0 = (e[0] * j2[1] - e[1] * j2[0]) / det;
    let p1 = (j1[0] * e[1] - j1[1] * e[0]) / det;
    (p0 * p0 + p1 * p1).sqrt()
}

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> f64 { self.0 ^= self.0 << 13; self.0 ^= self.0 >> 7; self.0 ^= self.0 << 17; (self.0 >> 11) as f64 / (1u64 << 53) as f64 }
}

fn pct(v: &mut Vec<f64>, p: f64) -> f64 {
    if v.is_empty() { return f64::NAN; }
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[((v.len() - 1) as f64 * p) as usize]
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let na: usize = args.get(1).map(|s| s.parse().unwrap()).unwrap_or(2048);
    let npsi: usize = args.get(2).map(|s| s.parse().unwrap()).unwrap_or(256);
    let nsamp: usize = args.get(3).map(|s| s.parse().unwrap()).unwrap_or(20000);
    let q: u32 = args.get(4).map(|s| s.parse().unwrap()).unwrap_or(0);
    let only: Option<usize> = args.get(5).map(|s| s.parse().unwrap());
    let g = Geo::new(3.0, 5.0, 1.0);
    let ds = 2e-3;
    if std::env::var("SWEEP").is_ok() {
        for &b in &[0.5, 1.5, 2.5, 2.9, 2.99, 3.01, 3.2, 3.6, 3.95] {
            let s = trace(&g, g.l, -(1.0 - (b / g.rout) * (b / g.rout) as f64).sqrt(), b / g.rout, &[], PI + 50.0, ds, &mut |_, _, _| {});
            println!("{} {:.12} {}", b, s.psi_exit, s.side);
        }
        return;
    }
    let lsh = g.l;
    // eyes 1.6 m above the floor: in a flat universe the chart point (x, 0, 1.6); in the shell
    // n tilted up by 1.6 / r
    let up = |l: f64| { let r = g.r(l); let a = (1.6 / r).asin(); V3::new(a.cos(), 0.0, a.sin()) };
    let at_x = |x: f64, side: f64| { let r = (x * x + 1.6 * 1.6).sqrt(); (side * (r - g.rout + lsh), V3::new(x / r, 0.0, 1.6 / r)) };
    let mut poses: Vec<(&str, f64, V3, f64, f64)> = vec![];
    let (l, n) = at_x(10.0, 1.0); poses.push(("start, at the throat", l, n, 0.0, -10.0));
    let (l, n) = at_x(6.2, 1.0); poses.push(("outside the edge, at the throat", l, n, 0.0, -15.0));
    let (l, n) = at_x(6.2, 1.0); poses.push(("outside the edge, 60 deg aside", l, n, 60.0, -15.0));
    poses.push(("on the fillet l=5, at the throat", 5.0, up(5.0), 0.0, -15.0));
    poses.push(("on the fillet l=5, sideways", 5.0, up(5.0), 90.0, -10.0));
    poses.push(("on the fillet l=5, away", 5.0, up(5.0), 180.0, -10.0));
    poses.push(("throat middle, along", 0.0, up(0.0), 0.0, 0.0));
    poses.push(("throat middle, sideways", 0.0, up(0.0), 90.0, 0.0));
    poses.push(("throat l=2, sideways down", 2.0, up(2.0), 80.0, -20.0));
    let (l, n) = at_x(6.2, -1.0); poses.push(("world B outside the edge, at the throat", l, n, 0.0, -15.0));
    println!("tables: {} alpha rows, {} psi columns; filter fraction bits {}", na, npsi, if q == 0 { "exact".to_string() } else { q.to_string() });
    for (pi, (name, l, n, yaw, pitch)) in poses.iter().enumerate() {
        if let Some(o) = only { if o != pi { continue; } }
        let e = eye(*l, *n, *yaw, *pitch);
        let t0 = std::time::Instant::now();
        let dst: f64 = std::env::var("DS_TAB").ok().map(|s| s.parse().unwrap()).unwrap_or(ds);
    let tab = build(&g, &e, na, npsi, dst);
        let tb = t0.elapsed().as_secs_f64();
        // samples: uniform over the view, and as many near the critical angle (|alpha - ac| < 1 deg)
        let mut rng = Rng(0x9e3779b97f4a7c15 ^ (pi as u64 + 1));
        let mut px = vec![];
        let mut near = 0;
        let mut tries = 0;
        while px.len() < 2 * nsamp && tries < 200 * nsamp {
            tries += 1;
            let (x, y) = (rng.next() * (NPX - 2) as f64, rng.next() * (NPX - 2) as f64);
            let (x, y) = (x.floor() + 0.5, y.floor() + 0.5);
            if px.len() < nsamp { px.push((x, y)); continue; }
            let (vl, w) = pixel_ray(&e, x, y);
            let a = w.len().atan2(vl);
            if (a - tab.ac).abs() < 1f64.to_radians() { px.push((x, y)); near += 1; }
        }
        let res: Vec<(i32, f64, bool)> = std::thread::scope(|sc| {
            let chunks: Vec<_> = px.chunks((px.len() + 3) / 4).collect();
            let hs: Vec<_> = chunks.into_iter().map(|ch| {
                let (g, e, tab) = (&g, &e, &tab);
                sc.spawn(move || {
                    let mut out = vec![];
                    for &(x, y) in ch {
                        let (vl, w) = pixel_ray(e, x, y);
                        let tb = if std::env::var("SELFCHECK").is_ok() { exact(g, e, vl, w, ds * 0.25) } else { table_hit(g, tab, e, vl, w, q) };
                        let Some(tb) = tb else { continue };
                        let Some(ex) = exact(g, e, vl, w, ds) else { continue };
                        let near = (w.len().atan2(vl) - tab.ac).abs() < 1f64.to_radians();
                        if tb.cls != ex.cls || tb.side != ex.side {
                            out.push((-1, 0.0, near));
                            continue;
                        }
                        let (vx, wx) = pixel_ray(e, x + 1.0, y);
                        let (vy, wy) = pixel_ray(e, x, y + 1.0);
                        let (Some(hx), Some(hy)) = (exact(g, e, vx, wx, ds), exact(g, e, vy, wy, ds)) else { continue };
                        if hx.cls != ex.cls || hy.cls != ex.cls || hx.side != ex.side || hy.side != ex.side {
                            out.push((-2, 0.0, near));   // on an edge between kinds: no footprint
                            continue;
                        }
                        let err = px_err(diff(g, &ex, &hx), diff(g, &ex, &hy), diff(g, &ex, &tb));
                        out.push((ex.cls, err, near));
                    }
                    out
                })
            }).collect();
            hs.into_iter().flat_map(|h| h.join().unwrap()).collect()
        });
        let mism = res.iter().filter(|r| r.0 == -1).count();
        let edge = res.iter().filter(|r| r.0 == -2).count();
        let mut fl: Vec<f64> = res.iter().filter(|r| r.0 == 1 && !r.1.is_nan()).map(|r| r.1).collect();
        let mut sk: Vec<f64> = res.iter().filter(|r| r.0 == 0 && !r.1.is_nan()).map(|r| r.1).collect();
        let mut nr: Vec<f64> = res.iter().filter(|r| r.0 >= 0 && r.2 && !r.1.is_nan()).map(|r| r.1).collect();
        println!("{:42} l {:6.2}  build {:5.2} s; curved px {:6} (near ac {:5}); kind mismatch {:4}, edges {:4}", name, l, tb, res.len(), near, mism, edge);
        println!("    floor n {:6}: p50 {:.4} p99 {:.4} p99.9 {:.3} max {:.3} px | sky n {:6}: p50 {:.4} p99 {:.4} max {:.3} px | near ac: p99 {:.3} max {:.3}",
            fl.len(), pct(&mut fl, 0.5), pct(&mut fl, 0.99), pct(&mut fl, 0.999), pct(&mut fl, 1.0),
            sk.len(), pct(&mut sk, 0.5), pct(&mut sk, 0.99), pct(&mut sk, 1.0), pct(&mut nr, 0.99), pct(&mut nr, 1.0));
    }
}
