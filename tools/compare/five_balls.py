"""Per-eye comparison of red silhouettes, five balls or cubes: union IoU and per-object centroid
offsets. Argument: the image prefix (<prefix>_ray_left.png, <prefix>_mesh_left.png, ...). PASS:
in each eye at least MIN_CHECKED objects lie wholly in the picture (a turned head can lose one or
two past its edge), each of them has its ray-traced silhouette's centre within 0.5 px of Godot's,
and the union IoU is at least MIN_IOU (no ray-traced object where Godot drew none)."""
import sys, numpy as np
from PIL import Image
from scipy import ndimage
def mask(p):
    a = np.asarray(Image.open(p).convert('RGB'), int)
    return (a[..., 0] - np.maximum(a[..., 1], a[..., 2])) > 60
MIN_CHECKED = 3
MIN_IOU = 0.99
worst = 0.0
ok = True
for eye in ('left', 'right'):
    A = mask(f'{sys.argv[1]}_ray_{eye}.png'); B = mask(f'{sys.argv[1]}_mesh_{eye}.png')
    iou = (A & B).sum() / max((A | B).sum(), 1)
    lb, nb = ndimage.label(B)
    print(f'{eye}: union IoU {iou:.4f}, mesh blobs {nb}')
    checked = 0
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
        checked += 1
        print(f'   mesh ({xs.mean():7.2f},{ys.mean():7.2f}) n={mb.sum():6d} | ray ({rx.mean():7.2f},{ry.mean():7.2f}) n={near.sum():6d} | offset {d:.2f} px')
    if checked < MIN_CHECKED or iou < MIN_IOU:
        print(f'   {checked} objects checked (at least {MIN_CHECKED}), union IoU {iou:.4f} (at least {MIN_IOU})')
        ok = False
print(f'worst centroid offset {worst:.2f} px')
print('PASS' if ok and worst < 0.5 else 'FAIL')
