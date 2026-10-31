"""Does Godot's green overlay sit on the app's floor lines and balls, in each eye?
Floor: share of the app's white line pixels (inside the area where green may be drawn,
away from its edges) that green does NOT cover. With green wider than the white lines, this is
~0 when aligned; shifting green by 2 px shows how fast it grows.
Balls: share of green ball-grid pixels outside the app's red silhouette, and the
difference of their outlines (bounding boxes). The cube (when its pictures are there): the same
for Godot's green edges and the app's magenta cube. With
--floor-only (the scene without the app's balls) only the floor is compared."""
import os, sys, numpy as np
from PIL import Image
from scipy import ndimage
pre = sys.argv[1]
floor_only = '--floor-only' in sys.argv[2:]
def img(m, eye): return np.asarray(Image.open(f'{pre}_{m}_{eye}.png').convert('RGB'), int)
def green(a): return (a[..., 1] - np.maximum(a[..., 0], a[..., 2])) > 80
ok = True
for eye in ('left', 'right'):
    R = img('app', eye)
    # the balls' red: green and blue both under 0.45 of red (between the shaded balls and the
    # gravity view's red and orange floor)
    gb = np.maximum(R[..., 1], R[..., 2])
    red = ((R[..., 0] - gb) > 60) & (gb < 0.45 * R[..., 0])
    gray = R.mean(axis=2)
    W = (gray - ndimage.grey_opening(gray, size=(7, 7))) > 10
    dom = ndimage.binary_erosion(green(img('domain', eye)), iterations=6)
    G = green(img('floor', eye))
    wl = W & dom
    unc = lambda g: (wl & ~g).sum() / max(wl.sum(), 1)
    u0 = unc(G)
    u2 = max(unc(np.roll(G, 2, axis=1)), unc(np.roll(G, 2, axis=0)))
    if floor_only:
        print(f'{eye}: floor white px checked {wl.sum()}, uncovered {100*u0:.2f}% '
              f'(if green were 2 px off: {100*u2:.1f}%)')
        ok &= wl.sum() > 1000 and u0 < 0.01
        continue
    def objects(sil, mode):
        """Green of a mode against an app's silhouette: (share outside it, regions, the largest
        difference of their outlines in px)."""
        B = green(img(mode, eye))
        out = (B & ~ndimage.binary_dilation(sil, iterations=1)).sum() / max(B.sum(), 1)
        lab, nb = ndimage.label(ndimage.binary_dilation(sil, iterations=3))
        bbd = 0
        for k in range(1, nb + 1):
            reg = lab == k
            r_ys, r_xs = np.nonzero(sil & reg); g_ys, g_xs = np.nonzero(B & reg)
            if len(g_xs) == 0: bbd = 99; continue
            bbd = max(bbd, abs(r_xs.min() - g_xs.min()), abs(r_xs.max() - g_xs.max()),
                      abs(r_ys.min() - g_ys.min()), abs(r_ys.max() - g_ys.max()))
        return out, nb, bbd
    out, nb, bbd = objects(red, 'balls')
    line = (f'{eye}: floor white px checked {wl.sum()}, uncovered {100*u0:.2f}% '
            f'(if green were 2 px off: {100*u2:.1f}%) | balls {nb}: green outside red {100*out:.2f}%, '
            f'outline difference {bbd} px')
    ok &= wl.sum() > 1000 and u0 < 0.01 and nb >= 1 and out < 0.01 and bbd <= 2
    if os.path.exists(f'{pre}_cube_{eye}.png'):
        # magenta, its dark edges too, near Godot's cube (the gravity view's floor has purple)
        Cg = green(img('cube', eye))
        near = np.zeros_like(Cg)
        if Cg.any():
            ys, xs = np.nonzero(Cg)
            near[max(ys.min() - 12, 0):ys.max() + 13, max(xs.min() - 12, 0):xs.max() + 13] = True
        mag = ((np.minimum(R[..., 0], R[..., 2]) - R[..., 1]) > 25) & near
        cout, cn, cbd = objects(mag, 'cube')
        line += f' | cube: green outside magenta {100*cout:.2f}%, outline difference {cbd} px'
        ok &= cn == 1 and cout < 0.01 and cbd <= 2
    print(line)
print('PASS' if ok else 'FAIL')
