#![allow(dead_code)]
// The space: optozorax's union_round(planes w = +-h, sphere rho0 extruded along w, R) in R^4.
// Its profile curve in the (r, w) half plane, by arc length l from the throat's middle:
//   cylinder |l| <= Lc: r = rho0, w = l
//   fillet  Lc..L:      a circle of radius R centred at (rho0 + R, h - R): r = rho0 + R (1 - cos th),
//                       w = +-(h - R + R sin th), th = th0 + (|l| - Lc) / R
//   flat    |l| >= L:   r = |l| - L + Rout, w = +-h
// Metric ds^2 = dl^2 + r(l)^2 dOmega^2. A geodesic lies in a plane through the centre; in it,
// with p = dl/ds and psi the polar angle: l'' = b^2 r'(l) / r^3, psi' = b / r^2 (b conserved).
use std::f64::consts::PI;

#[derive(Clone, Copy, Debug)]
pub struct Geo {
    pub rho0: f64,
    pub h: f64,
    pub rf: f64,
    pub lc: f64,
    pub th0: f64,
    pub l: f64,
    pub rout: f64,
    pub rmin: f64,
}

impl Geo {
    pub fn new(rho0: f64, h: f64, rf: f64) -> Geo {
        let lc = (h - rf).max(0.0);
        let th0 = (1.0 - h / rf).max(0.0).asin();
        let l = lc + rf * (0.5 * PI - th0);
        let rmin = rho0 + rf * (1.0 - th0.cos());
        Geo { rho0, h, rf, lc, th0, l, rout: rho0 + rf, rmin }
    }
    /// (r, dr/dl)
    #[inline]
    pub fn prof(&self, l: f64) -> (f64, f64) {
        let al = l.abs();
        let sg = if l >= 0.0 { 1.0 } else { -1.0 };
        if al >= self.l {
            (al - self.l + self.rout, sg)
        } else if al <= self.lc {
            (self.rho0, 0.0)
        } else {
            let th = self.th0 + (al - self.lc) / self.rf;
            (self.rho0 + self.rf * (1.0 - th.cos()), sg * th.sin())
        }
    }
    pub fn r(&self, l: f64) -> f64 {
        self.prof(l).0
    }
    pub fn w4(&self, l: f64) -> f64 {
        let al = l.abs();
        let sg = if l >= 0.0 { 1.0 } else { -1.0 };
        if al >= self.l {
            sg * self.h
        } else if al <= self.lc {
            l
        } else {
            let th = self.th0 + (al - self.lc) / self.rf;
            sg * (self.h - self.rf + self.rf * th.sin())
        }
    }
}

/// What happens to a ray: where it leaves the shell (if it does before psi_max).
#[derive(Clone, Copy, Debug, Default)]
pub struct RaySum {
    pub enters: bool,     // touches the curved region at all
    pub exits: bool,      // leaves it (else: still inside at psi_max)
    pub psi_exit: f64,
    pub s_exit: f64,
    pub side: f64,        // the flat universe it leaves into: +1 A, -1 B
    pub psi_inf: f64,     // polar angle of its direction at infinity (exits only)
}

#[derive(Clone, Copy)]
struct St {
    l: f64,
    p: f64,
    psi: f64,
    s: f64,
}

#[inline]
fn deriv(g: &Geo, b: f64, y: St) -> St {
    let (r, dr) = g.prof(y.l);
    St { l: y.p, p: b * b * dr / (r * r * r), psi: b / (r * r), s: 1.0 }
}

#[inline]
fn rk4(g: &Geo, b: f64, y: St, h: f64) -> St {
    let a = |y: St, k: St, f: f64| St { l: y.l + f * k.l, p: y.p + f * k.p, psi: y.psi + f * k.psi, s: y.s + f * k.s };
    let k1 = deriv(g, b, y);
    let k2 = deriv(g, b, a(y, k1, 0.5 * h));
    let k3 = deriv(g, b, a(y, k2, 0.5 * h));
    let k4 = deriv(g, b, a(y, k3, h));
    St {
        l: y.l + h / 6.0 * (k1.l + 2.0 * k2.l + 2.0 * k3.l + k4.l),
        p: y.p + h / 6.0 * (k1.p + 2.0 * k2.p + 2.0 * k3.p + k4.p),
        psi: y.psi + h / 6.0 * (k1.psi + 2.0 * k2.psi + 2.0 * k3.psi + k4.psi),
        s: y.s + h,
    }
}

/// Trace the ray from the eye at l0 with direction (v_l, |w|) (unit), b = r(l0) |w|.
/// Calls `at(target_index, l, s)` for each target psi (ascending) the ray reaches before psi_max,
/// including the flat parts before the shell and after it (the latter only up to psi_inf).
/// ds: RK4 step on the fillets (the cylinder and the flat parts are closed form).
pub fn trace(g: &Geo, l0: f64, vl: f64, wn: f64, targets: &[f64], psi_max: f64, ds: f64,
             at: &mut dyn FnMut(usize, f64, f64)) -> RaySum {
    let r0 = g.r(l0);
    let b = r0 * wn;
    let mut ti = 0usize;
    let mut sum = RaySum::default();
    let sg0 = if l0 >= 0.0 { 1.0 } else { -1.0 };
    // a straight piece in a flat universe: chi is the polar angle from the closest approach,
    // r = b / cos chi, s = b tan chi (+ const)
    let mut y;
    if l0.abs() >= g.l {
        let inward = vl * sg0 < 0.0;
        let chi0 = if inward { -(b / r0).min(1.0).acos() } else { (b / r0).min(1.0).acos() };
        if !inward || b >= g.rout {
            let psi_inf = 0.5 * PI - chi0;
            while ti < targets.len() && targets[ti] < psi_inf.min(psi_max) {
                let chi = chi0 + targets[ti];
                at(ti, sg0 * (b / chi.cos() - g.rout + g.l), b * (chi.tan() - chi0.tan()));
                ti += 1;
            }
            sum.side = sg0;
            sum.psi_inf = psi_inf;
            sum.exits = true;
            return sum;
        }
        let psi_in = (b / r0).acos() - (b / g.rout).acos();
        let s_in = (r0 * r0 - b * b).sqrt() - (g.rout * g.rout - b * b).sqrt();
        while ti < targets.len() && targets[ti] < psi_in {
            let chi = chi0 + targets[ti];
            at(ti, sg0 * (b / chi.cos() - g.rout + g.l), b * (chi.tan() - chi0.tan()));
            ti += 1;
        }
        y = St { l: sg0 * g.l, p: -sg0 * (1.0 - (b / g.rout).powi(2)).max(0.0).sqrt(), psi: psi_in, s: s_in };
    } else {
        y = St { l: l0, p: vl, psi: 0.0, s: 0.0 };
    }
    sum.enters = true;
    let kc = b / (g.rho0 * g.rho0);
    loop {
        if y.psi >= psi_max {
            break;
        }
        let al = y.l.abs();
        let outward = y.p * y.l.signum() > 0.0;
        if al >= g.l && outward {
            sum.exits = true;
            sum.psi_exit = y.psi;
            sum.s_exit = y.s;
            sum.side = y.l.signum();
            let chix = (b / g.rout).min(1.0).acos();
            sum.psi_inf = y.psi + (b / g.rout).min(1.0).asin();
            while ti < targets.len() && targets[ti] < sum.psi_inf {
                let chi = chix + (targets[ti] - y.psi);
                at(ti, sum.side * (b / chi.cos() - g.rout + g.l), y.s + b * (chi.tan() - chix.tan()));
                ti += 1;
            }
            return sum;
        }
        if g.lc > 0.0 && (al < g.lc || (al <= g.lc && !outward)) {
            // the cylinder: p constant, psi linear
            let send = if y.p > 0.0 { (g.lc - y.l) / y.p } else if y.p < 0.0 { (-g.lc - y.l) / y.p } else { f64::INFINITY };
            let spsi = if kc > 0.0 { (psi_max - y.psi) / kc } else { f64::INFINITY };
            let s_go = send.min(spsi);
            while ti < targets.len() && kc > 0.0 && (targets[ti] - y.psi) / kc <= s_go {
                let d = (targets[ti] - y.psi) / kc;
                at(ti, y.l + y.p * d, y.s + d);
                ti += 1;
            }
            if !(s_go < send) && send.is_finite() {
                y = St { l: y.p.signum() * g.lc, p: y.p, psi: y.psi + kc * send, s: y.s + send };
                continue;
            }
            break;   // psi_max on the cylinder
        }
        // a fillet: RK4; events: into the cylinder, out of the shell, the next target, psi_max
        let y1 = rk4(g, b, y, ds);
        let a1 = y1.l.abs();
        let e_cyl = g.lc > 0.0 && a1 < g.lc;
        let e_out = a1 >= g.l;
        let e_t = ti < targets.len() && y1.psi >= targets[ti];
        let e_m = y1.psi >= psi_max;
        if !(e_cyl || e_out || e_t || e_m) {
            y = y1;
            continue;
        }
        let happened = |yy: &St| -> [bool; 4] {
            [e_cyl && yy.l.abs() < g.lc, e_out && yy.l.abs() >= g.l,
             e_t && yy.psi >= targets[ti], e_m && yy.psi >= psi_max]
        };
        let (mut lo, mut hi) = (0.0, ds);
        for _ in 0..45 {
            let mid = 0.5 * (lo + hi);
            if happened(&rk4(g, b, y, mid)).iter().any(|&x| x) { hi = mid } else { lo = mid }
        }
        let ym = rk4(g, b, y, hi);
        let hp = happened(&ym);
        y = ym;
        if hp[2] {
            at(ti, y.l, y.s);
            ti += 1;
        } else if hp[3] {
            break;
        } else if hp[0] {
            y.l = y.l.signum() * g.lc;
        } else if hp[1] {
            y.l = y.l.signum() * g.l;
        }
    }
    sum.exits = false;
    sum
}
