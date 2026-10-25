"""Are two sets of renders the same picture? For each pair of prefixes a:b, every image
<dir>/<b><rest>.png against <dir>/<a><rest>.png: the largest difference of any colour channel
of any pixel, in 1/255, and how many pixels differ by more than 1/255. Passes when every pair
matches within 1/255 (the GPU may round a colour either way) and pixels off by more are fewer
than 1 in 10 000. Used for foveation on against off (tools/test_stereo.sh): on software Vulkan
there is no density map, so only the split render pass could change anything.
   python3 same_images.py dir a:b [a:b ...]"""
import sys, glob, os
import numpy as np
from PIL import Image

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
        big = int((diff > 1).sum())
        n += 1
        if diff.max() > 1:
            print(f'{os.path.basename(fb)} vs {os.path.basename(fa)}: max {diff.max()}/255, {big} px off by more than 1')
        ok &= big * 10000 < diff.size
print(f'{n} image pairs compared')
print('PASS' if ok and n > 0 else 'FAIL')
