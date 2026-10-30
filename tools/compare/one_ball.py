"""The app's ball vs Godot's standard one, one image pair per eye (or one pair on desktop).
Arguments: app.png mesh.png [app2.png mesh2.png ...]. PASS: in every pair the red silhouettes
overlap (IoU above MIN_IOU) and their centroids differ by less than MAX_OFFSET px."""
import sys
import numpy as np
from PIL import Image

MIN_IOU = 0.99
MAX_OFFSET = 0.5


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
    ok &= iou > MIN_IOU and d < MAX_OFFSET
print('PASS' if ok else 'FAIL')
