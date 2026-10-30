"""Foveation by rays (ray_pass.gd): does each cell of a foveated picture show what the picture
without foveation shows at that cell's size? The ray tracer traces a ray through each cell's middle
and takes the grid's derivatives from the cell's quad; a picture without foveation, rendered at the
cell's size (each eye's pixels over the cell's width and height), has a pixel there with the same
ray and the same neighbours. Cells by the rings in <fov>_ray_fov.json, as trace_kernels.gdshaderinc's
fr_cells lays them: blocks of 64 x 32 pixels, each in the cells of the ring its middle is in (the
radius from the eye's gaze pixel over half the picture). Passes when in each eye fewer than
MAX_SHARE of the cells differ by more than ROUNDING (in 1/255; a cube's edge lines and the arrows
are a pixel's angle wide, wh_pix, which a picture of another size has bigger).
   python3 tools/compare/foveated.py fov_prefix ref_prefix     (ref_prefix_WxH_ray_<eye>.png: the
                                                                 pictures without foveation)"""
import sys, json, os
import numpy as np
from PIL import Image

ROUNDING = 3
MAX_SHARE = 0.003
fov, ref = sys.argv[1], sys.argv[2]
meta = json.load(open(f'{fov}_ray_fov.json'))
ok = True
for v, eye in enumerate(('left', 'right')):
    F = np.asarray(Image.open(f'{fov}_ray_{eye}.png').convert('RGB'), int)
    H, W = F.shape[:2]
    gx, gy = meta['gaze'][v]
    refs = {}
    cells = bad = 0
    worst = 0
    for by in range((H + 31) // 32):
        for bx in range((W + 63) // 64):
            mx, my = (bx + 0.5) * 64, (by + 0.5) * 32
            r = np.hypot((mx - gx) / (0.5 * W), (my - gy) / (0.5 * H))
            cw, ch = 1, 1
            for ring in meta['rings']:
                if r < ring[0]:
                    cw, ch = int(ring[1]), int(ring[2])
                    break
            key = (W // cw, H // ch)
            if key not in refs:
                path = f'{ref}_{key[0]}x{key[1]}_ray_{eye}.png'
                if not os.path.exists(path):
                    sys.exit(f'no picture without foveation at {key[0]} x {key[1]}: {path}')
                refs[key] = np.asarray(Image.open(path).convert('RGB'), int)
            R = refs[key]
            x0, y0 = bx * 64, by * 32
            xs = np.arange(x0, min(x0 + 64, W), cw)
            ys = np.arange(y0, min(y0 + 32, H), ch)
            if xs.size == 0 or ys.size == 0:
                continue
            f = F[np.ix_(ys, xs)]
            g = R[np.ix_(np.minimum(ys // ch, R.shape[0] - 1), np.minimum(xs // cw, R.shape[1] - 1))]
            d = np.abs(f - g).max(axis=2)
            cells += d.size
            bad += int((d > ROUNDING).sum())
            worst = max(worst, int(d.max()))
    share = bad / max(cells, 1)
    print(f'{eye}: {cells} cells, {bad} differ by more than {ROUNDING}/255 ({100 * share:.3f}%), max {worst}/255, '
          f'sizes {sorted(refs)}')
    ok &= cells > 0 and share < MAX_SHARE and len(refs) > 1
print('PASS' if ok else 'FAIL')
