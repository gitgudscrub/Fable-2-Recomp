#!/usr/bin/env python3
"""Re-imagine chosen rectangles inside a texture atlas (tier 4, atlas-aware).

Most prop textures in Fable II are atlases: one 1024x1024 sheet holding a
coffin, a window, a flag, a slab of pillar stone. tools/reimagine_textures.py
skips those, since a single material prompt would redraw the coffin as rock.
This tool redraws only the tiles you name, each with its own material, and
pastes them back into the atlas with a short feathered edge so the seams do
not show. Everything outside the named tiles is left exactly as it was.

Tiles are given in the DUMP's pixel coordinates (the size in the dump file
name), so the same rectangles work whether the source is the original dump,
the upscaled pack entry (2x) or anything else: they are scaled to the source.

Usage:
  python tools/reimagine_tiles.py <pack_root> <hash> \
      --tile stone:x,y,w,h [--tile bark:x,y,w,h ...] [--strength 0.7]

The result goes to <pack_root>/packs/reimagine/<hash>.dds (and a .tiles
marker listing the rectangles); install it into replace/ as usual, keeping
the upscaled original in packs/pre-reimagine.
"""
import argparse
import glob
import os
import shutil
import sys
import tempfile
import time

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reimagine_textures as rt  # noqa: E402
import upscale_textures as up  # noqa: E402


def parse_tile(spec):
    label, _, rect = spec.partition(':')
    x, y, w, h = (int(v) for v in rect.split(','))
    if label not in rt.PROMPTS:
        raise SystemExit(f'unknown material {label!r}; one of {sorted(rt.PROMPTS)}')
    return label, (x, y, w, h)


def main():
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('pack_root')
    ap.add_argument('hash')
    ap.add_argument('--tile', action='append', required=True, metavar='LABEL:X,Y,W,H',
                    help='rectangle in dump pixels to redraw with that material prompt')
    ap.add_argument('--tools', default=os.path.join(repo, 'out', 'tooling', 'upscale'))
    ap.add_argument('--models', default=os.path.join(repo, 'out', 'tooling', 'reimagine', 'models'))
    ap.add_argument('--strength', type=float, default=0.65)
    ap.add_argument('--control', type=float, default=0.6)
    ap.add_argument('--grain', type=float, default=0.5)
    ap.add_argument('--detail', type=float, default=1.0)
    ap.add_argument('--steps', type=int, default=24)
    ap.add_argument('--guidance', type=float, default=5.0)
    ap.add_argument('--size', type=int, default=1024)
    ap.add_argument('--pad', type=int, default=0,
                    help='wrap padding; 0 for atlas tiles, which do not tile with themselves')
    ap.add_argument('--feather', type=int, default=6, help='blend width at each tile edge, in dump pixels')
    ap.add_argument('--seed', type=int, default=1234)
    ap.add_argument('--keep-png', help='folder for before/after PNGs of each tile')
    args = ap.parse_args()
    h = args.hash.upper()
    tiles = [parse_tile(t) for t in args.tile]

    dumps = glob.glob(os.path.join(args.pack_root, 'dump', h + '_*.dds'))
    if not dumps:
        raise SystemExit(f'no dump for {h}')
    _, dw, dh, fmt = up.parse_dump_name(os.path.basename(dumps[0]))
    backup = os.path.join(args.pack_root, 'packs', 'pre-reimagine', h + '.dds')
    replaced = os.path.join(args.pack_root, 'replace', h + '.dds')
    if os.path.exists(backup):
        src = backup
    elif os.path.exists(replaced) and not os.path.exists(replaced[:-4] + '.reimagined'):
        src = replaced
    else:
        src = dumps[0]
    out_dir = os.path.join(args.pack_root, 'packs', 'reimagine')
    os.makedirs(out_dir, exist_ok=True)

    work = tempfile.mkdtemp(prefix='fable2_tiles_')
    t0 = time.time()
    try:
        img = rt.decode_to(args.tools, [{'hash': h, 'src': src}], work, key='src')[h]
        W, H = img.size
        s = W / dw
        print(f'{h}: source {os.path.basename(src)} {W}x{H} (dump {dw}x{dh}, scale {s:g}), {len(tiles)} tiles')
        pipe = rt.load_pipeline(args)
        canvas = np.asarray(img.convert('RGBA'), np.float32)
        for n, (label, (x, y, w, hh)) in enumerate(tiles, 1):
            box = tuple(int(round(v * s)) for v in (x, y, x + w, y + hh))
            crop = img.crop(box)
            seed = args.seed + int(h[:6], 16) + n
            res = rt.generate_one(pipe, crop, label, args, seed, (w, hh))
            if args.keep_png:
                os.makedirs(args.keep_png, exist_ok=True)
                crop.save(os.path.join(args.keep_png, f'{h}_{n}_{label}_before.png'))
                res.save(os.path.join(args.keep_png, f'{h}_{n}_{label}_after.png'))
            # Feathered paste: full weight inside, fading to zero over --feather
            # dump pixels at each edge so the tile sits in the sheet seamlessly.
            cw, ch = crop.size
            f = max(1, int(round(args.feather * s)))
            ramp_x = np.minimum(np.arange(cw) + 1, cw - np.arange(cw)) / f
            ramp_y = np.minimum(np.arange(ch) + 1, ch - np.arange(ch)) / f
            wgt = np.clip(np.minimum(ramp_y[:, None], ramp_x[None, :]), 0, 1)[..., None]
            region = canvas[box[1]:box[3], box[0]:box[2]]
            canvas[box[1]:box[3], box[0]:box[2]] = region * (1 - wgt) + np.asarray(res, np.float32) * wgt
            print(f'  {n}/{len(tiles)} {label} {w}x{hh} at ({x},{y})  ({time.time() - t0:.0f} s)')
        result = Image.fromarray(canvas.round().clip(0, 255).astype(np.uint8), 'RGBA')
        staged = os.path.join(work, 'staged'); encoded = os.path.join(work, 'encoded')
        os.makedirs(staged); os.makedirs(encoded)
        it = {'fmt': fmt}
        if rt.alpha_kind(it, img) == 'cutout':
            p = os.path.join(staged, h + '.dds')
            up.write_rgba_dds(p, up.cutout_mips(result))
            jobs = [(p, 'BC7_UNORM', True)]
        else:
            p = os.path.join(staged, h + '.png')
            result.save(p)
            jobs = [(p, 'BC7_UNORM', False)]
        print('  compressing')
        up.encode_all(args.tools, jobs, encoded)
        shutil.move(os.path.join(encoded, h + '.dds'), os.path.join(out_dir, h + '.dds'))
        with open(os.path.join(out_dir, h + '.reimagined'), 'w') as fh:
            fh.write(f'tiles strength {args.strength} control {args.control} steps {args.steps}\n')
            for label, rect in tiles:
                fh.write(f'  {label} {",".join(map(str, rect))}\n')
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f'done in {time.time() - t0:.0f} s -> {os.path.join(out_dir, h + ".dds")}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
