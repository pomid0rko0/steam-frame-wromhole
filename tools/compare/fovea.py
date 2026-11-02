"""Is the fovea the picture without foveation? For each pair of prefixes a:b, each eye's
<dir>/<b>_app_<eye>.png (foveation on) against <dir>/<a>_app_<eye>.png (off) inside the fovea:
the pixels whose centres are nearer than r0 - MARGIN to the pixel g the eye looks at, both from
<dir>/<b>_fovea.json (Foveation.fovea: g's x, y and r0 per eye, x from the left, y from the top
row as the images are saved). There a pixel takes the centre of a texel worked out at its own
centre (foveation.gd's top), so only the GPU's rounding tells them apart: the largest difference of
any colour channel, in 1/255, and how many pixels differ by more than ROUNDING (in 1/255). Passes
when in every eye those pixels are fewer than MAX_SHARE of the fovea's (a pixel right on a sharp
edge, the sky's against what the curved zone shows, may fall either way) and the fovea is there.
   python3 tools/compare/fovea.py dir a:b [a:b ...]     (where numpy is: tools/box.sh)"""
import sys, os, json
import numpy as np
from PIL import Image

ROUNDING = 1
MAX_SHARE = 5e-4
MARGIN = 2
d = sys.argv[1]
ok = True
n = 0
for pair in sys.argv[2:]:
    a, b = pair.split(':')
    fovea = json.load(open(os.path.join(d, b + '_fovea.json')))
    for i, eye in enumerate(('left', 'right')):
        A = np.asarray(Image.open(os.path.join(d, f'{a}_app_{eye}.png')).convert('RGB'), int)
        B = np.asarray(Image.open(os.path.join(d, f'{b}_app_{eye}.png')).convert('RGB'), int)
        gx, gy, r0 = fovea[3 * i:3 * i + 3]
        ys, xs = np.mgrid[0:A.shape[0], 0:A.shape[1]] + 0.5
        inside = np.hypot(xs - gx, ys - gy) < r0 - MARGIN
        diff = np.abs(A - B).max(axis=2)[inside]
        big = int((diff > ROUNDING).sum())
        n += 1
        print(f'{b} {eye}: fovea at ({gx:.0f}, {gy:.0f}), r0 {r0:.0f} px, {inside.sum()} px; '
              f'max {diff.max() if diff.size else 0}/255, {big} off by more than {ROUNDING}')
        ok &= inside.sum() > 1000 and big <= MAX_SHARE * inside.sum()
print(f'{n} foveae compared')
print('PASS' if ok and n > 0 else 'FAIL')
