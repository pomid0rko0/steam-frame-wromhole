"""Are two sets of renders the same picture? For each pair of prefixes a:b, every image
<dir>/<b><rest>.png against <dir>/<a><rest>.png: the largest difference of any colour channel
of any pixel, in 1/255, and how many pixels differ by more than ROUNDING (in 1/255: the GPU may
round a colour either way). Passes when in every pair those pixels are fewer than MAX_SHARE of
them.
   python3 tools/compare/same_images.py dir a:b [a:b ...]     (where numpy is: tools/box.sh)"""
import sys, glob, os
import numpy as np
from PIL import Image

ROUNDING = 1
MAX_SHARE = 1e-4
d = sys.argv[1]
ok = True
n = 0
for pair in sys.argv[2:]:
    a, b = pair.split(':')
    for fb in sorted(glob.glob(os.path.join(d, b + '*.png'))):
        fa = os.path.join(d, a + os.path.basename(fb)[len(b):])
        if not os.path.exists(fa):
            print(f'{os.path.basename(fb)}: no {os.path.basename(fa)}')
            ok = False
            continue
        A = np.asarray(Image.open(fa).convert('RGB'), int)
        B = np.asarray(Image.open(fb).convert('RGB'), int)
        if A.shape != B.shape:
            print(f'{os.path.basename(fb)}: size {B.shape} vs {A.shape}')
            ok = False
            continue
        diff = np.abs(A - B).max(axis=2)
        big = int((diff > ROUNDING).sum())
        n += 1
        if diff.max() > ROUNDING:
            print(f'{os.path.basename(fb)} vs {os.path.basename(fa)}: max {diff.max()}/255, {big} px off by more than {ROUNDING}')
        ok &= big < MAX_SHARE * diff.size
print(f'{n} image pairs compared')
print('PASS' if ok and n > 0 else 'FAIL')
