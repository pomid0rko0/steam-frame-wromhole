"""Per-eye comparison of red silhouettes, five balls or cubes: union IoU and per-object centroid
offsets. Argument: the image prefix (<prefix>_ray_left.png, <prefix>_mesh_left.png, ...). PASS:
in both eyes all five objects are there, each one away from the picture's edge has a ray-traced
silhouette, and their centroids differ by less than 0.5 px."""
import sys, numpy as np
from PIL import Image
from scipy import ndimage
def mask(p):
    a = np.asarray(Image.open(p).convert('RGB'), int)
    return (a[..., 0] - np.maximum(a[..., 1], a[..., 2])) > 60
COUNT = 5
worst = 0.0
ok = True
for eye in ('left', 'right'):
    A = mask(f'{sys.argv[1]}_ray_{eye}.png'); B = mask(f'{sys.argv[1]}_mesh_{eye}.png')
    iou = (A & B).sum() / max((A | B).sum(), 1)
    lb, nb = ndimage.label(B)
    print(f'{eye}: union IoU {iou:.4f}, mesh blobs {nb}')
    if nb != COUNT or A.sum() == 0:
        print(f'   expected {COUNT} mesh blobs and a ray-traced picture')
        ok = False
    for k in range(1, nb + 1):
        mb = lb == k
        ys, xs = np.nonzero(mb)
        if xs.min() == 0 or ys.min() == 0 or xs.max() == B.shape[1] - 1 or ys.max() == B.shape[0] - 1:
            print('   blob at edge, skipped'); continue
        # the ray blob is whatever ray pixels lie in this blob's neighbourhood
        near = ndimage.binary_dilation(mb, iterations=25) & A
        if near.sum() == 0:
            print(f'   mesh blob ({xs.mean():.1f},{ys.mean():.1f}) n={mb.sum()}: NO ray blob'); worst = 1e9; continue
        ry, rx = np.nonzero(near)
        d = np.hypot(rx.mean() - xs.mean(), ry.mean() - ys.mean())
        worst = max(worst, d)
        print(f'   mesh ({xs.mean():7.2f},{ys.mean():7.2f}) n={mb.sum():6d} | ray ({rx.mean():7.2f},{ry.mean():7.2f}) n={near.sum():6d} | offset {d:.2f} px')
print(f'worst centroid offset {worst:.2f} px')
print('PASS' if ok and worst < 0.5 else 'FAIL')
