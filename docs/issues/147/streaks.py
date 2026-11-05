"""#147: thin streaks inside a cube's face, in pictures drawn with faces.patch (each face of a cube
in the zone flat in its own pure colour): a pixel of another class (another face, or not a face:
what shows through a crack) with the same face on both sides of it 2 to 8 pixels off, in one of
eight directions, inside a face's broad region (three quarters of the 25 x 25 pixels about it that
face: not the thin far images between the background's). Prints the pictures with any, most first:
the count, the picture, the streaks' bounding box (x0 y0 x1 y1).
  python3 streaks.py out_dir [how_many]"""
import sys
import glob
import os
import numpy as np
from PIL import Image
from scipy.ndimage import uniform_filter

PURE = np.array([[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0], [255, 0, 255], [0, 255, 255]])


def classes(f):
    a = np.asarray(Image.open(f).convert('RGB')).astype(int)
    c = np.full(a.shape[:2], -1)
    for k, p in enumerate(PURE):
        c[np.all(a == p, -1)] = k
    return c


def streaks(c, ds=(2, 3, 5, 8)):
    H, W = c.shape
    flag = np.zeros_like(c, bool)
    for d in ds:
        for vy, vx in ((0, 1), (1, 0), (1, 1), (1, -1), (1, 2), (2, 1), (1, -2), (2, -1)):
            dy, dx = vy * d, vx * d
            m = max(abs(dy), abs(dx))
            a = c[m:H - m, m:W - m]
            p = c[m + dy:H - m + dy, m + dx:W - m + dx]
            q = c[m - dy:H - m - dy, m - dx:W - m - dx]
            flag[m:H - m, m:W - m] |= (p >= 0) & (p == q) & (a != p)
    best = np.zeros(c.shape)
    for k in range(len(PURE)):
        best = np.maximum(best, np.where(c != k, uniform_filter((c == k).astype(float), 25), 0.0))
    return flag & (best >= 0.75)


res = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], '*_app_*.png'))):
    fl = streaks(classes(f))
    if fl.sum():
        ys, xs = np.nonzero(fl)
        res.append((int(fl.sum()), os.path.basename(f), xs.min(), ys.min(), xs.max(), ys.max()))
res.sort(reverse=True)
for r in res[:int(sys.argv[2]) if len(sys.argv) > 2 else 40]:
    print(*r)
print(len(res), 'pictures with any')
