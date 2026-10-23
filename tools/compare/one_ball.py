"""Ray-traced ball vs Godot's rasterized ball, one image pair per eye (or one pair on desktop).
Arguments: ray.png mesh.png [ray2.png mesh2.png ...]. PASS: in every pair the red silhouettes
overlap (IoU > 0.99) and their centroids differ by less than 0.5 px."""
import sys
import numpy as np
from PIL import Image


def mask(p):
    a = np.asarray(Image.open(p).convert('RGB'), int)
    return (a[..., 0] - np.maximum(a[..., 1], a[..., 2])) > 60     # red, lit or in shade


ok = True
for a, b in zip(sys.argv[1::2], sys.argv[2::2]):
    A, B = mask(a), mask(b)
    if A.sum() == 0 or B.sum() == 0:
        print(f'{a}: no ball in one of the images')
        ok = False
        continue
    ay, ax = [v.mean() for v in np.nonzero(A)]
    by, bx = [v.mean() for v in np.nonzero(B)]
    iou = (A & B).sum() / (A | B).sum()
    d = np.hypot(ax - bx, ay - by)
    print(f'{a.split("/")[-1]} vs {b.split("/")[-1]}: centroid offset {d:.2f} px, IoU {iou:.4f}')
    ok &= iou > 0.99 and d < 0.5
print('PASS' if ok else 'FAIL')
