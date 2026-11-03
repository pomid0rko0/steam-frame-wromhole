"""Does foveation leave every pixel where it is? For each pair of prefixes a:b (b foveated, a the
same without), each eye:
- the fovea: <dir>/<b>_app_<eye>.png against <dir>/<a>_app_<eye>.png at the pixels whose centres
  are nearer than r0 - MARGIN to the pixel g the eye looks at, both from <dir>/<b>_fovea.json
  (Foveation.fovea: g's x, y, r0 and m per eye, x from the left, y from the top row as the images
  are saved). There a pixel takes the centre of a texel worked out at its own centre (foveation.gd's
  top), so only the GPU's rounding tells them apart: the largest difference of any colour channel,
  in 1/255, and how many pixels differ by more than ROUNDING. Passes when those are fewer than
  MAX_SHARE of the fovea's pixels (a pixel right on a sharp edge, the sky's against what the curved
  zone shows, may fall either way).
- everywhere, if <dir>/<b>_probe_<eye>.png is there (tests/multiview_check.gd's mode probe: blue
  where the floor's quad draws, red by how far from its own place each pixel took its colour, 0.5 px
  full, linear and stored as sRGB): away from the fovea the floor is softer by design, but a pixel
  must take what was worked out where it is, or the eyes' pictures would part. Passes when no
  pixel is off by more than PROBE_LIMIT px or PROBE_SHARE of its texel (the larger: the filter on a
  curved grid of texels errs by a share of the texel), over enough of the picture.
   python3 tools/compare/fovea.py dir a:b [a:b ...]     (where numpy is: tools/box.sh)"""
import sys, os, json
import numpy as np
from PIL import Image

ROUNDING = 1
MAX_SHARE = 5e-4
MARGIN = 2
PROBE_LIMIT = 0.1
PROBE_SHARE = 0.01
d = sys.argv[1]
ok = True
n = 0
for pair in sys.argv[2:]:
    a, b = pair.split(':')
    fovea = json.load(open(os.path.join(d, b + '_fovea.json')))
    for i, eye in enumerate(('left', 'right')):
        A = np.asarray(Image.open(os.path.join(d, f'{a}_app_{eye}.png')).convert('RGB'), int)
        B = np.asarray(Image.open(os.path.join(d, f'{b}_app_{eye}.png')).convert('RGB'), int)
        gx, gy, r0, m = fovea[4 * i:4 * i + 4]
        ys, xs = np.mgrid[0:A.shape[0], 0:A.shape[1]] + 0.5
        r = np.hypot(xs - gx, ys - gy)
        inside = r < r0 - MARGIN
        diff = np.abs(A - B).max(axis=2)[inside]
        big = int((diff > ROUNDING).sum())
        n += 1
        line = (f'{b} {eye}: fovea at ({gx:.0f}, {gy:.0f}), r0 {r0:.0f} px, {inside.sum()} px; '
                f'max {diff.max() if diff.size else 0}/255, {big} off by more than {ROUNDING}')
        ok &= inside.sum() > 1000 and big <= MAX_SHARE * inside.sum()
        probe = os.path.join(d, f'{b}_probe_{eye}.png')
        if os.path.exists(probe):
            P = np.asarray(Image.open(probe).convert('RGB'), float) / 255.0
            floor = (P[..., 2] > 0.5) & (P[..., 1] < 0.2)
            lin = np.where(P[..., 0] <= 0.04045, P[..., 0] / 12.92, ((P[..., 0] + 0.055) / 1.055) ** 2.4)
            err = 0.5 * lin[floor]
            texel = np.where(r > r0, np.sqrt(1 + (m * (r - r0)) ** 2), 1.0)[floor]
            limit = np.maximum(PROBE_LIMIT, PROBE_SHARE * texel)
            far = floor & ~inside
            line += (f' | probe: {floor.sum()} px ({far.sum()} out of the fovea, texels up to {texel.max():.1f} px), '
                     f'off by up to {err.max() if err.size else 0:.3f} px, {int((err > limit).sum())} over the limit')
            ok &= far.sum() > 0.3 * P.shape[0] * P.shape[1] and err.size > 0 and (err <= limit).all()
        print(line)
print(f'{n} pictures compared')
print('PASS' if ok and n > 0 else 'FAIL')
