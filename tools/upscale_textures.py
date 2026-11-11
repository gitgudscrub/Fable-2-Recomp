"""Build a texture pack from texture dumps with an AI upscaler.

Input:  <pack root>/dump/<hash>_<w>x<h>_<format>.dds   (written by the game with
        [graphics] texture_dump = true)
Output: <pack root>/replace/<hash>.dds                  (shown by the game when
        [graphics] texture_pack = true; switch live with the toggle key)

Runs entirely on the player's machine: the game's art is never distributed.

Tools (download once, see --tools):
  realesrgan-ncnn-vulkan.exe + models/  (any Vulkan GPU)
  texconv.exe                           (DDS decode and BC encode)

Per dump format:
  DXT1/DXT3/DXT5/RGBA8 (colour + alpha)
      colour: wrap-pad, light de-block blur, AI 4x, Lanczos down to --scale,
              then the fine grain the AI painted out (stone, sand, dirt)
              is added back from the original (--detail).
      alpha:  Lanczos; DXT1 cut-out alpha re-thresholded.
      -> BC7 with mips (cut-out alpha keeps its coverage in the mips).
  DXN (two-channel normal map)
      Nearest-neighbour to --scale (every texel keeps its exact normal, so
      the per-texel shading noise that gives Fable's rock its dusty look
      survives; a Lanczos reconstruction smooths it into wax), plus finer
      noise at the new texel size sized by the original's own texel noise
      (--normal-mode grain, the default; nearest / lanczos also available)
      -> BC5 with a mip chain that keeps that noise at every level.
  DXT5A (single channel)  Lanczos -> BC4 with mips.
  R8                      skipped (mostly video planes).
Skipped: textures smaller than --min-size, and screen-sized buffers.

Already converted textures are skipped unless --force, so the tool can be
re-run as more dumps arrive.
"""

import argparse
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time

import numpy as np
from PIL import Image, ImageFilter

PACK_VERSION = 4  # 3: grain restored after the AI pass; 4: normal maps keep their texel noise
# Screen-sized render targets that sometimes get dumped. Not art.
SCREEN_SIZES = {(1280, 720), (640, 360), (320, 180), (160, 90), (560, 360), (280, 180),
                (1280, 704), (1024, 576), (960, 540)}


def parse_dump_name(name):
    """<hash16>_<w>x<h>_<fmt>.dds -> (hash, w, h, fmt) or None."""
    if not name.lower().endswith('.dds'):
        return None
    parts = name[:-4].split('_')
    if len(parts) != 3 or len(parts[0]) != 16:
        return None
    try:
        w, h = (int(v) for v in parts[1].split('x'))
    except ValueError:
        return None
    return parts[0].upper(), w, h, parts[2]


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f'{os.path.basename(cmd[0])} failed ({r.returncode}): '
                           f'{(r.stderr or r.stdout).strip()[-500:]}')
    return r


def texconv(tools, args):
    return run([os.path.join(tools, 'texconv', 'texconv.exe'), '-nologo', '-y'] + args)


def decode_dumps(tools, items, out_dir):
    """Decode DDS dumps to RGBA PNGs (texconv names them <stem>.png)."""
    batch = 64
    for i in range(0, len(items), batch):
        texconv(tools, ['-ft', 'png', '-f', 'R8G8B8A8_UNORM', '-o', out_dir] +
                [it['path'] for it in items[i:i + batch]])


def wrap_pad(img, pad):
    a = np.asarray(img)
    return Image.fromarray(np.pad(a, ((pad, pad), (pad, pad), (0, 0)), mode='wrap'))


def _box(a, r, axis):
    """Box filter of radius r along an axis, edges clamped."""
    n = a.shape[axis]
    pad = [(0, 0)] * a.ndim
    pad[axis] = (r + 1, r)
    c = np.cumsum(np.pad(a, pad, mode='edge'), axis=axis, dtype=np.float64)
    hi = np.take(c, np.arange(2 * r + 1, 2 * r + 1 + n), axis=axis)
    lo = np.take(c, np.arange(0, n), axis=axis)
    return ((hi - lo) / (2 * r + 1)).astype(np.float32)


def blur(a, radius):
    """Approximate Gaussian blur of a 2D float array (three box passes)."""
    r = max(1, int(round(radius)))
    for _ in range(3):
        a = _box(_box(a, r, 0), r, 1)
    return a


def alpha_bleed(img):
    """RGB with fully transparent pixels filled from nearby visible colour.

    Transparent texels are usually black; scaling and the AI would smear that
    black into visible edges as a dark fringe (leaves, hair, sparks)."""
    a = np.asarray(img.getchannel('A'), np.float32) / 255.0
    rgb = np.asarray(img.convert('RGB'), np.float32)
    if a.min() >= 1.0:
        return img.convert('RGB')
    filled = rgb.copy()
    known = a > 0.0
    weight = a.copy()
    premult = rgb * a[..., None]
    # Wider and wider blurs of the premultiplied colour fill holes from the
    # edges inwards; the first blur that reaches a pixel wins.
    for radius in (1, 2, 4, 8, 16, 32, 64):
        wb = blur(weight, radius)
        cb = np.stack([blur(premult[..., c], radius) for c in range(3)], axis=2)
        reach = (~known) & (wb > 1e-3)
        filled[reach] = cb[reach] / wb[reach][:, None]
        known = known | reach
        if known.all():
            break
    return Image.fromarray(filled.round().clip(0, 255).astype(np.uint8))


def upscale_ai(tools, model, items, work, deblock, pad):
    """AI 4x on the colour channels of every item; returns {hash: 4x RGB Image (unpadded)}."""
    src = os.path.join(work, 'ai_in')
    dst = os.path.join(work, 'ai_out')
    for d in (src, dst):
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
    for it in items:
        rgb = alpha_bleed(it['image'])
        if deblock > 0:
            rgb = rgb.filter(ImageFilter.GaussianBlur(deblock))
        wrap_pad(rgb, pad).save(os.path.join(src, it['hash'] + '.png'))
    run([os.path.join(tools, 'realesrgan', 'realesrgan-ncnn-vulkan.exe'), '-i', src, '-o', dst,
         '-n', model, '-s', '4', '-m', os.path.join(tools, 'realesrgan', 'models'), '-f', 'png'])
    out = {}
    for it in items:
        up = Image.open(os.path.join(dst, it['hash'] + '.png')).convert('RGB')
        w, h = it['image'].size
        p = pad * 4
        out[it['hash']] = up.crop((p, p, p + w * 4, p + h * 4))
    return out


def lanczos(img, size):
    return img.resize(size, Image.LANCZOS)


def grain(arr, orig_size):
    """Fine-detail energy of an image in the band the original texture can
    hold: std of a 1-texel high-pass after shrinking back to the original size."""
    small = Image.fromarray(arr.round().clip(0, 255).astype(np.uint8)).convert('L')
    small = small.resize(orig_size, Image.BOX)
    g = np.asarray(small, np.float32)
    b = np.asarray(small.filter(ImageFilter.GaussianBlur(1.0)), np.float32)
    return float((g - b).std())


def blockiness(img):
    """Mean gradient across 4x4 DXT block edges over the mean gradient inside
    blocks. Natural grain gives ~1.5 for DXT1; smooth textures whose only
    fine detail is the compression grid give 2 and more."""
    g = np.asarray(img.convert('L'), np.float32)
    dx, dy = np.abs(np.diff(g, axis=1)), np.abs(np.diff(g, axis=0))
    edge = dx[:, 3::4].mean() + dy[3::4, :].mean()
    inner = np.delete(dx, np.s_[3::4], axis=1).mean() + np.delete(dy, np.s_[3::4], axis=0).mean()
    return float(edge / max(inner, 1e-3))


def reinject_detail(ai, plain, orig, scale, target):
    """Put back the grain the AI smoothed away.

    Real-ESRGAN treats the speckle of stone, sand and dirt textures as noise
    and paints it out, leaving waxy rock. Measure what share r of the
    original's fine detail survived and add the original's own high-pass
    back on top, scaled so the result has about `target` of the original's
    grain (the two add in quadrature, so k = sqrt(target² - r²)). Flat
    textures and ones the AI kept sharp get nothing; textures whose fine
    detail is mostly the DXT block grid get less, so the grid stays gone.
    Returns (rgb, k)."""
    if target <= 0.0:
        return ai, 0.0
    hf_plain = grain(plain, orig.size)
    if hf_plain < 0.5:
        return ai, 0.0
    r = grain(ai, orig.size) / hf_plain
    k = float(np.sqrt(max(0.0, target * target - r * r)))
    k *= float(np.clip((2.2 - blockiness(orig)) / 0.6, 0.0, 1.0))
    if k < 0.02:
        return ai, 0.0
    base = Image.fromarray(plain.round().clip(0, 255).astype(np.uint8))
    low = np.asarray(base.filter(ImageFilter.GaussianBlur(scale)), np.float32)
    return ai + k * (plain - low), k


def build_colour(it, up4, scale, detail=0.9):
    w, h = it['image'].size
    size = (w * scale, h * scale)
    rgb = lanczos(up4, size) if up4.size != size else up4
    # Keep near-black near-black. The models lift pure black to dark grey,
    # which shows as boxes around additive sprites (snow, sparks, glows)
    # where black means "nothing". Fade from the AI result to plain resizing
    # as the original gets darker.
    plain = np.asarray(lanczos(alpha_bleed(it['image']), size), np.float32)
    ai = np.asarray(rgb, np.float32)
    ai, it['detail_k'] = reinject_detail(ai, plain, it['image'], scale, detail)
    level = plain.max(axis=2, keepdims=True)
    mask = np.clip((level - 4.0) / 20.0, 0.0, 1.0)
    rgb = Image.fromarray((ai * mask + plain * (1 - mask)).round().clip(0, 255).astype(np.uint8))
    alpha = it['image'].getchannel('A')
    amin, amax = alpha.getextrema()
    if amin == 255:
        kind = 'opaque'
        alpha = Image.new('L', size, 255)
    else:
        a = np.asarray(alpha)
        # DXT1 alpha is 1-bit; DXT5 foliage often is too in practice.
        binary = it['fmt'] == 'DXT1' or ((a > 8) & (a < 247)).mean() < 0.01
        kind = 'cutout' if binary else 'soft'
        alpha = lanczos(alpha, size)
        if binary:
            alpha = alpha.point(lambda v: 255 if v >= 128 else 0)
    r, g, b = rgb.split()
    return Image.merge('RGBA', (r, g, b, alpha)), kind


def cutout_mips(img):
    """Mip chain for a cut-out texture with 1-bit alpha on every level.

    The game draws foliage with alpha-to-coverage. Ordinary mips blur the
    alpha, which turns distant grass and leaves into a see-through stipple
    (the originals are DXT1, so their mips are 1-bit too). Each level here is
    thresholded so it keeps the top level's coverage, and its colour is the
    alpha-weighted average so transparent texels don't bleed in."""
    a = np.asarray(img, np.float32) / 255.0
    rgb, soft = a[..., :3], a[..., 3]
    coverage = (soft >= 0.5).mean()
    levels = [np.asarray(img, np.uint8)]
    w, h = img.size

    def down(x, size):
        return np.asarray(Image.fromarray(np.ascontiguousarray(x, np.float32), 'F').resize(size, Image.BOX))

    while w > 1 or h > 1:
        w, h = max(1, w // 2), max(1, h // 2)
        weight = down(soft, (w, h))
        prem = np.stack([down(rgb[..., c] * soft, (w, h)) for c in range(3)], axis=2)
        plain = np.stack([down(rgb[..., c], (w, h)) for c in range(3)], axis=2)
        rgb = np.where(weight[..., None] > 1e-4, prem / np.maximum(weight, 1e-4)[..., None], plain)
        soft = weight
        if coverage <= 0.0:
            cut = np.zeros_like(soft)
        elif coverage >= 1.0:
            cut = np.ones_like(soft)
        else:
            t = np.quantile(soft, 1.0 - coverage)
            cut = (soft >= max(t, 1e-4)).astype(np.float32)
        lv = np.concatenate([rgb, cut[..., None]], axis=2)
        levels.append((lv * 255 + 0.5).clip(0, 255).astype(np.uint8))
    return levels


def write_rgba_dds(path, levels):
    """Uncompressed RGBA8 DDS with the given mip levels (texconv keeps them)."""
    h, w = levels[0].shape[:2]
    pf = struct.pack('<II4sIIIII', 32, 0x41, bytes(4), 32, 0xff, 0xff00, 0xff0000, 0xff000000)
    hdr = (struct.pack('<IIIIIII', 124, 0x1 | 0x2 | 0x4 | 0x8 | 0x1000 | 0x20000, h, w, w * 4, 0,
                       len(levels)) + bytes(44) + pf + struct.pack('<IIIII', 0x1000 | 0x400000 | 0x8, 0, 0, 0, 0))
    with open(path, 'wb') as f:
        f.write(b'DDS ' + hdr)
        for lv in levels:
            f.write(np.ascontiguousarray(lv).tobytes())


def build_normal(it, scale, mode='grain', grain=0.7):
    """Resample a two-channel normal map.

    Fable's rock, sand and plaster get their dusty look from per-texel noise
    in small normal maps magnified many times: each texel tilts the lighting
    its own way. A Lanczos reconstruction (mode 'lanczos') interpolates that
    noise away and the surface turns waxy, so the default keeps every texel
    exactly ('nearest') and adds finer noise at the new texel size, sized by
    the original's own texel-to-texel variation so flat maps stay flat
    ('grain')."""
    w, h = it['image'].size
    a = np.asarray(it['image'].convert('RGBA'), np.float32) / 255.0
    x, y = a[..., 0] * 2 - 1, a[..., 1] * 2 - 1
    if mode == 'lanczos':
        z = np.sqrt(np.clip(1 - x * x - y * y, 0, 1))
        # Lanczos per component with wrap padding, then renormalise.
        pad = 8
        comps = []
        for c in (x, y, z):
            cp = np.pad(c, pad, mode='wrap')
            im = Image.fromarray(cp.astype(np.float32)).resize(((w + 2 * pad) * scale, (h + 2 * pad) * scale),
                                                      Image.LANCZOS)
            arr = np.asarray(im)[pad * scale:(pad + h) * scale, pad * scale:(pad + w) * scale]
            comps.append(arr)
        x, y, z = comps
    else:
        up = lambda c: np.repeat(np.repeat(c, scale, axis=0), scale, axis=1)
        if mode == 'grain' and grain > 0:
            # Local RMS of the texel noise (the part a 1-texel blur removes).
            hx, hy = x - blur(x, 1), y - blur(y, 1)
            amp = np.sqrt(np.maximum(blur(hx * hx + hy * hy, 2), 0.0) * 0.5)
            rng = np.random.default_rng(int(it['hash'][:8], 16))
            noise = rng.standard_normal((h * scale, w * scale, 2)).astype(np.float32) * (up(amp) * grain)[..., None]
            x, y = up(x) + noise[..., 0], up(y) + noise[..., 1]
        else:
            x, y = up(x), up(y)
        z = np.sqrt(np.clip(1 - x * x - y * y, 1e-4, 1))
    n = np.sqrt(x * x + y * y + z * z) + 1e-6
    return x / n, y / n


def pack_normal(x, y):
    """Two unit-normal components -> RGBA8 array (B, A unused)."""
    out = np.zeros(x.shape + (4,), np.uint8)
    out[..., 0] = np.clip((x * 0.5 + 0.5) * 255 + 0.5, 0, 255)
    out[..., 1] = np.clip((y * 0.5 + 0.5) * 255 + 0.5, 0, 255)
    out[..., 3] = 255
    return out


def normal_mips(x, y, seed, grain=1.0):
    """Mip chain for a normal map that keeps its texel noise at every level.

    Box-filtered mips average the per-texel tilt away, so a surface that is
    dusty up close goes waxy a few metres back. The game's own small maps
    stay dusty at any distance, so each level here is the box average plus
    fresh noise of the amplitude the base level had there (the local RMS of
    its texel-to-texel variation, box-reduced alongside)."""
    hx, hy = x - blur(x, 1), y - blur(y, 1)
    amp = np.sqrt(np.maximum(blur(hx * hx + hy * hy, 2), 0.0) * 0.5)
    rng = np.random.default_rng(seed)
    levels = [pack_normal(x, y)]
    h, w = x.shape

    def down(a, size):
        return np.asarray(Image.fromarray(np.ascontiguousarray(a, np.float32), 'F').resize(size, Image.BOX))

    while w > 1 or h > 1:
        w, h = max(1, w // 2), max(1, h // 2)
        x, y, amp = down(x, (w, h)), down(y, (w, h)), down(amp, (w, h))
        if grain > 0:
            x = x + rng.standard_normal(x.shape).astype(np.float32) * amp * grain
            y = y + rng.standard_normal(y.shape).astype(np.float32) * amp * grain
        z = np.sqrt(np.clip(1 - x * x - y * y, 1e-4, 1))
        n = np.sqrt(x * x + y * y + z * z) + 1e-6
        x, y = x / n, y / n
        levels.append(pack_normal(x, y))
    return levels


def build_single(it, scale):
    w, h = it['image'].size
    return lanczos(it['image'].getchannel('R'), (w * scale, h * scale))


def encode_all(tools, jobs, out_dir):
    """jobs: list of (source_path, dxgi_format, has_mips); batched per settings.
    Sources with their own mip chain (cut-outs) keep it."""
    groups = {}
    for png, fmt, has_mips in jobs:
        groups.setdefault((fmt, has_mips), []).append(png)
    for (fmt, has_mips), pngs in groups.items():
        args = ['-f', fmt, '-o', out_dir] + ([] if has_mips else ['-m', '0'])
        for i in range(0, len(pngs), 64):
            texconv(tools, args + pngs[i:i + 64])


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(here)
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('pack_root', help='folder holding dump/ (the game\'s textures folder)')
    ap.add_argument('--out', help='output folder (default <pack_root>/replace)')
    ap.add_argument('--tools', default=os.path.join(repo, 'out', 'tooling', 'upscale'),
                    help='folder with realesrgan/ and texconv/')
    ap.add_argument('--model', default='realesrgan-x4plus', help='ncnn model name in realesrgan/models')
    ap.add_argument('--scale', type=int, default=2, choices=(2, 4), help='final size multiplier')
    ap.add_argument('--deblock', type=float, default=0.7,
                    help='Gaussian blur radius before the AI, removes DXT block edges (0 = off)')
    ap.add_argument('--detail', type=float, default=0.9,
                    help='fine grain to keep, as a share of the original\'s, by adding back what the AI '
                         'smoothed away (0 = off)')
    ap.add_argument('--min-size', type=int, default=32, help='skip textures smaller than this')
    ap.add_argument('--only', default='', help='comma-separated hash prefixes to process')
    ap.add_argument('--normal-mode', default='grain', choices=('grain', 'nearest', 'lanczos'),
                    help='how normal maps (DXN) are resampled; see build_normal')
    ap.add_argument('--normal-grain', type=float, default=0.7,
                    help='finer noise added to normal maps in grain mode, as a share of their own texel noise')
    ap.add_argument('--normals-only', action='store_true',
                    help='rebuild just the normal maps (implies --force for them)')
    ap.add_argument('--batch', type=int, default=48, help='textures per AI batch')
    ap.add_argument('--force', action='store_true', help='redo textures already in the output')
    args = ap.parse_args()

    dump = os.path.join(args.pack_root, 'dump')
    out = args.out or os.path.join(args.pack_root, 'replace')
    os.makedirs(out, exist_ok=True)
    only = [p.upper() for p in args.only.split(',') if p]

    items, skipped = [], {}
    for name in sorted(os.listdir(dump)):
        parsed = parse_dump_name(name)
        if not parsed:
            continue
        h, w, hgt, fmt = parsed
        if only and not any(h.startswith(p) for p in only):
            continue
        reason = None
        if fmt == 'R8':
            reason = 'R8 (video planes)'
        elif min(w, hgt) < args.min_size:
            reason = 'small'
        elif (w, hgt) in SCREEN_SIZES:
            reason = 'screen-sized'
        elif ((w * args.scale) % 4 or (hgt * args.scale) % 4):
            reason = 'size not block-aligned'
        elif args.normals_only and fmt != 'DXN':
            reason = 'not a normal map'
        elif not (args.force or args.normals_only) and os.path.exists(os.path.join(out, h + '.dds')):
            reason = 'done'
        if reason:
            skipped[reason] = skipped.get(reason, 0) + 1
            continue
        items.append({'hash': h, 'fmt': fmt, 'path': os.path.join(dump, name)})
    print(f'{len(items)} to convert; skipped: {skipped or "none"}')
    if not items:
        return 0

    work = tempfile.mkdtemp(prefix='fable2_upscale_')
    t0 = time.time()
    try:
        decoded = os.path.join(work, 'decoded')
        os.makedirs(decoded)
        decode_dumps(args.tools, items, decoded)
        for it in items:
            stem = os.path.splitext(os.path.basename(it['path']))[0]
            it['image'] = Image.open(os.path.join(decoded, stem + '.png')).convert('RGBA')

        colour = [it for it in items if it['fmt'] in ('DXT1', 'DXT3', 'DXT5', 'RGBA8')]
        staged = os.path.join(work, 'staged')
        encoded = os.path.join(work, 'encoded')
        os.makedirs(staged)
        os.makedirs(encoded)
        done = 0
        jobs = []
        for i in range(0, len(colour), args.batch):
            chunk = colour[i:i + args.batch]
            up = upscale_ai(args.tools, args.model, chunk, work, args.deblock, pad=16)
            for it in chunk:
                img, kind = build_colour(it, up[it['hash']], args.scale, args.detail)
                if kind == 'cutout':
                    src = os.path.join(staged, it['hash'] + '.dds')
                    write_rgba_dds(src, cutout_mips(img))
                    jobs.append((src, 'BC7_UNORM', True))
                else:
                    src = os.path.join(staged, it['hash'] + '.png')
                    img.save(src)
                    jobs.append((src, 'BC7_UNORM', False))
                done += 1
            ks = [it['detail_k'] for it in chunk]
            print(f'  upscaled {done}/{len(colour)}  grain restored on {sum(k > 0 for k in ks)}/{len(ks)}'
                  f' (mean {sum(ks) / len(ks):.2f})  ({time.time() - t0:.0f} s)')

        for it in items:
            if it['fmt'] == 'DXN':
                x, y = build_normal(it, args.scale, args.normal_mode, args.normal_grain)
                src = os.path.join(staged, it['hash'] + '.dds')
                write_rgba_dds(src, normal_mips(x, y, int(it['hash'][8:16], 16),
                                                args.normal_grain if args.normal_mode == 'grain' else 0.0))
                jobs.append((src, 'BC5_UNORM', True))
            elif it['fmt'] == 'DXT5A':
                png = os.path.join(staged, it['hash'] + '.png')
                build_single(it, args.scale).save(png)
                jobs.append((png, 'BC4_UNORM', False))
            else:
                continue
            done += 1
        print(f'  resized {done}/{len(items)}; compressing  ({time.time() - t0:.0f} s)')
        encode_all(args.tools, jobs, encoded)
        print(f'  compressed  ({time.time() - t0:.0f} s)')

        for name in os.listdir(encoded):
            shutil.move(os.path.join(encoded, name),
                        os.path.join(out, os.path.splitext(name)[0].upper() + '.dds'))
    finally:
        shutil.rmtree(work, ignore_errors=True)

    info_path = os.path.join(out, 'pack.json')
    info = {'version': PACK_VERSION, 'model': args.model, 'scale': args.scale,
            'deblock': args.deblock, 'detail': args.detail, 'normal_mode': args.normal_mode, 'updated': time.strftime('%Y-%m-%d %H:%M:%S')}
    with open(info_path, 'w', encoding='utf-8') as f:
        json.dump(info, f, indent=2)
    print(f'done in {time.time() - t0:.0f} s -> {out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
