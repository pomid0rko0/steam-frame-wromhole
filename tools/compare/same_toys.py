"""This build's ray tracer against main's (tests/toys_check.gd's pictures): in every place and eye,
the pixels whose colours differ by more than WRONG (in 1/255: another thing, not the same thing
shaded a little differently), away from the edges of what main's picture shows (a pixel whose
neighbours differ from it by more than WRONG: a silhouette or a grid line a fraction of a pixel
over is no error). Passes when in every picture those pixels are fewer than MAX_WRONG.
   python3 tools/compare/same_toys.py prefix     (where numpy is: tools/box.sh)"""
import sys, glob
import numpy as np
from PIL import Image

WRONG = 60
MAX_WRONG = 20
prefix = sys.argv[1]
ok = True
n = 0
for fn in sorted(glob.glob(prefix + '_*_new_*.png')):
    fm = fn.replace('_new_', '_main_')
    A = np.asarray(Image.open(fm).convert('RGB'), int)
    B = np.asarray(Image.open(fn).convert('RGB'), int)
    d = np.abs(A - B).max(axis=2)
    # main's edges, and a pixel round them
    e = np.zeros(d.shape, bool)
    for dy, dx in [(0, 1), (1, 0), (1, 1), (1, -1)]:
        a = A[max(dy, 0):A.shape[0] + min(dy, 0) or None, max(dx, 0):A.shape[1] + min(dx, 0) or None]
        b = A[max(-dy, 0):A.shape[0] + min(-dy, 0) or None, max(-dx, 0):A.shape[1] + min(-dx, 0) or None]
        g = np.abs(a - b).max(axis=2) > WRONG
        e[max(dy, 0):e.shape[0] + min(dy, 0) or None, max(dx, 0):e.shape[1] + min(dx, 0) or None] |= g
        e[max(-dy, 0):e.shape[0] + min(-dy, 0) or None, max(-dx, 0):e.shape[1] + min(-dx, 0) or None] |= g
    grown = e.copy()
    grown[1:] |= e[:-1]
    grown[:-1] |= e[1:]
    grown[:, 1:] |= e[:, :-1]
    grown[:, :-1] |= e[:, 1:]
    wrong = int(((d > WRONG) & ~grown).sum())
    n += 1
    name = fn[len(prefix) + 1:]
    if wrong >= MAX_WRONG or d.max() > WRONG:
        print(f'{name}: {wrong} px wrong away from edges, {int((d > WRONG).sum())} in all, max {d.max()}/255')
    ok &= wrong < MAX_WRONG
print(f'{n} pictures compared')
print('PASS' if ok and n > 0 else 'FAIL')
