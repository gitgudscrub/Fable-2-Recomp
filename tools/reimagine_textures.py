"""Re-imagine textures of chosen materials with a diffusion model (tier 4 of
the Modern graphics work).

Where the AI upscaler (tools/upscale_textures.py) only sharpens what is
there, this pass redraws the surface detail: an img2img pass with SDXL,
held to the original's layout and colours by a ControlNet-tile model and a
low denoising strength, so the result is still recognisably the same
texture in the same palette, with real stone grain, bark ridges or soil
instead of the painted blur of a 2008 asset.

Input:  <pack root>/dump/<hash>_<w>x<h>_<format>.dds    (the game's dumps)
        <pack root>/replace/<hash>.dds                  (the upscaled pack,
        used as the source when present: it is already 2x and de-blocked)
Output: <out>/<hash>.dds  (BC7 with mips, same alpha handling as the pack)

Steps:
  1. classify  CLIP zero-shot over every colour dump -> <pack root>/
               classify.json (material label + confidence per hash). Cached.
  2. generate  for the hashes in --categories: decode the source, pad with
               a wrapped border (so tiling edges stay continuous), run the
               img2img + tile ControlNet at --strength, crop, put the
               original alpha back, encode.

Runs on the player's machine, like the upscaler: no game art is shipped.
Needs the venv from tools/reimagine_setup.cmd (Python 3.12, torch with
CUDA, diffusers) and about 9 GB of model downloads on first use (cached in
--models).
"""

import argparse
import json
import os
import shutil
import sys
import tempfile
import time

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import upscale_textures as up  # noqa: E402  (decode, alpha, mips, encode)

# Zero-shot labels. The prompt text is what CLIP scores; the key is the
# category name used on the command line.
LABELS = {
    'stone': 'a photo of a rough stone wall or rock surface',
    'ground': 'a photo of dirt ground, soil, gravel or a mud path',
    'bark': 'a photo of tree bark',
    'wood': 'a photo of old wooden planks or timber',
    'grass': 'a photo of grass or a lawn from above',
    'foliage': 'a photo of leaves or plants on a transparent background',
    'cloth': 'a photo of fabric, cloth or leather clothing',
    'metal': 'a photo of a metal surface or armour',
    'skin': 'a photo of human skin or a face',
    'brick': 'a photo of a brick wall or paved cobblestones',
    'roof': 'a photo of roof tiles or thatch',
    'ui': 'a user interface icon, symbol or text on a flat background',
    'sky': 'a photo of sky and clouds',
    'water': 'a photo of water or ripples',
    'other': 'an abstract pattern',
}

# What to ask for per category. Kept to surface detail; the colours come
# from the source through the low strength and the tile ControlNet.
PROMPTS = {
    'stone': 'weathered natural stone, fine mineral grain, small cracks, traces of lichen, '
             'flat even lighting, seamless albedo texture, highly detailed',
    'brick': 'old brick and cobblestone, worn edges, mortar, flat even lighting, '
             'seamless albedo texture, highly detailed',
    'ground': 'earth and soil with small pebbles, roots and dry leaves, flat even lighting, '
              'seamless albedo texture, highly detailed',
    'bark': 'deep ridged tree bark with moss in the grooves, flat even lighting, '
            'seamless albedo texture, highly detailed',
    'wood': 'aged wooden planks with clear grain and knots, flat even lighting, '
            'seamless albedo texture, highly detailed',
    'roof': 'old roof tiles with moss and chips, flat even lighting, seamless albedo texture, '
            'highly detailed',
}
NEGATIVE = ('blurry, smooth, flat colour, painting, cartoon, text, watermark, strong shadows, '
            'specular highlights, people, objects, frame, border')

SDXL = 'stabilityai/stable-diffusion-xl-base-1.0'
VAE = 'madebyollin/sdxl-vae-fp16-fix'
CONTROLNET = 'xinsir/controlnet-tile-sdxl-1.0'
CLIP = 'openai/clip-vit-base-patch32'


def colour_dumps(pack_root, min_size):
    dump = os.path.join(pack_root, 'dump')
    items = []
    for name in sorted(os.listdir(dump)):
        parsed = up.parse_dump_name(name)
        if not parsed:
            continue
        h, w, hgt, fmt = parsed
        if fmt not in ('DXT1', 'DXT3', 'DXT5', 'RGBA8') or min(w, hgt) < min_size:
            continue
        if (w, hgt) in up.SCREEN_SIZES:
            continue
        items.append({'hash': h, 'fmt': fmt, 'w': w, 'h': hgt, 'path': os.path.join(dump, name)})
    return items


def decode_to(tools, items, out_dir, key='path'):
    """Decode DDS files to PNG in out_dir; returns {hash: Image RGBA}."""
    batch = 64
    paths = [it[key] for it in items]
    for i in range(0, len(paths), batch):
        up.texconv(tools, ['-ft', 'png', '-f', 'R8G8B8A8_UNORM', '-o', out_dir] + paths[i:i + batch])
    out = {}
    for it in items:
        stem = os.path.splitext(os.path.basename(it[key]))[0]
        out[it['hash']] = Image.open(os.path.join(out_dir, stem + '.png')).convert('RGBA')
    return out


def classify(args, items):
    """CLIP zero-shot over the colour dumps; cached in classify.json."""
    import torch
    from transformers import CLIPModel, CLIPProcessor
    cache_path = os.path.join(args.pack_root, 'classify.json')
    cache = {}
    if os.path.exists(cache_path):
        with open(cache_path, encoding='utf-8') as f:
            cache = json.load(f)
    todo = [it for it in items if it['hash'] not in cache or args.reclassify]
    if not todo:
        return cache
    print(f'classifying {len(todo)} textures with CLIP')
    model = CLIPModel.from_pretrained(CLIP, cache_dir=args.models).to('cuda').eval()
    proc = CLIPProcessor.from_pretrained(CLIP, cache_dir=args.models)
    keys = list(LABELS)
    texts = [LABELS[k] for k in keys]
    with torch.no_grad():
        work = tempfile.mkdtemp(prefix='fable2_classify_')
        try:
            for i in range(0, len(todo), 64):
                chunk = todo[i:i + 64]
                images = decode_to(args.tools, chunk, work)
                # Alpha-bleed so cut-outs are judged by their texels, not the
                # black behind them; composite onto mid grey for the rest.
                batch = []
                for it in chunk:
                    img = images[it['hash']]
                    rgb = up.alpha_bleed(img)
                    a = np.asarray(img.getchannel('A'), np.float32)[..., None] / 255.0
                    arr = np.asarray(rgb, np.float32) * a + 128.0 * (1 - a)
                    batch.append(Image.fromarray(arr.astype(np.uint8)))
                inp = proc(text=texts, images=batch, return_tensors='pt', padding=True).to('cuda')
                probs = model(**inp).logits_per_image.softmax(dim=-1).cpu().numpy()
                for it, p in zip(chunk, probs):
                    order = np.argsort(-p)
                    cache[it['hash']] = {'label': keys[order[0]], 'score': float(p[order[0]]),
                                         'second': keys[order[1]], 'w': it['w'], 'h': it['h'],
                                         'fmt': it['fmt']}
                print(f'  {min(i + 64, len(todo))}/{len(todo)}')
        finally:
            shutil.rmtree(work, ignore_errors=True)
    with open(cache_path, 'w', encoding='utf-8') as f:
        json.dump(cache, f, indent=1, sort_keys=True)
    return cache


def summarize(cache):
    counts = {}
    for v in cache.values():
        counts[v['label']] = counts.get(v['label'], 0) + 1
    for k, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f'  {k:8} {n}')


def load_pipeline(args):
    import torch
    from diffusers import (AutoencoderKL, ControlNetModel, DPMSolverMultistepScheduler,
                           StableDiffusionXLControlNetImg2ImgPipeline)
    kw = {'torch_dtype': torch.float16, 'cache_dir': args.models}
    controlnet = ControlNetModel.from_pretrained(CONTROLNET, **kw)
    vae = AutoencoderKL.from_pretrained(VAE, **kw)
    pipe = StableDiffusionXLControlNetImg2ImgPipeline.from_pretrained(
        SDXL, controlnet=controlnet, vae=vae, variant='fp16', use_safetensors=True, **kw)
    pipe.scheduler = DPMSolverMultistepScheduler.from_config(pipe.scheduler.config,
                                                             use_karras_sigmas=True)
    pipe.to('cuda')
    pipe.set_progress_bar_config(disable=True)
    return pipe


def work_size(w, h, max_side):
    """Generation size: scale so the long side is max_side, multiples of 8."""
    s = min(1.0, max_side / max(w, h))
    return max(64, int(w * s) // 8 * 8), max(64, int(h * s) // 8 * 8)


def generate_one(pipe, src_rgba, prompt, args, seed, native):
    """src_rgba: the source (the upscaled pack entry when present); native:
    the dump's own size. Generation always runs with the long side at --size
    (see below); where the source is finer than that, its finer detail (the
    upscaler's grain) is added back afterwards."""
    import torch
    w, h = src_rgba.size
    rgb = up.alpha_bleed(src_rgba)
    pad = args.pad
    # SDXL only draws well near its training size, so the long side is always
    # --size: small textures are upsampled for generation (the model then
    # invents the detail they never had) and large ones downsampled.
    nw, nh = native
    s = args.size / max(nw, nh)
    gw, gh = max(64, int((nw + 2 * pad) * s) // 8 * 8), max(64, int((nh + 2 * pad) * s) // 8 * 8)
    padded = up.wrap_pad(rgb, pad * w // nw)
    cond = padded.resize((gw, gh), Image.LANCZOS)
    gen = torch.Generator('cuda').manual_seed(seed)
    out = pipe(prompt=prompt, negative_prompt=NEGATIVE, image=cond, control_image=cond,
               strength=args.strength, num_inference_steps=args.steps,
               guidance_scale=args.guidance, controlnet_conditioning_scale=args.control,
               generator=gen, width=gw, height=gh).images[0]
    p = pad * w // nw
    out = out.resize(padded.size, Image.LANCZOS).crop((p, p, p + w, p + h))
    arr = np.asarray(out, np.float32)
    plain = np.asarray(rgb, np.float32)
    if args.grain > 0:
        from PIL import ImageFilter
        soft1 = np.asarray(rgb.filter(ImageFilter.GaussianBlur(1.2)), np.float32)
        arr = arr + (plain - soft1) * args.grain
    if (gw - 2 * pad * s) < w - 1:
        # Fine detail the generation size could not hold: the source minus
        # its own copy passed through the same size.
        small = rgb.resize((max(1, int(w * (gw - 2 * pad * s) / (w + 2 * p) + 0.5)),
                            max(1, int(h * (gh - 2 * pad * s) / (h + 2 * p) + 0.5))), Image.LANCZOS)
        soft = np.asarray(small.resize((w, h), Image.LANCZOS), np.float32)
        arr = arr + (plain - soft) * args.detail
    # As in the upscaler: keep near-black near-black (additive sprites).
    level = plain.max(axis=2, keepdims=True)
    mask = np.clip((level - 4.0) / 20.0, 0.0, 1.0)
    # Hold the overall colour: match the mean of the result to the source
    # per channel so the palette does not drift with the prompt.
    arr = arr - arr.mean(axis=(0, 1)) + plain.mean(axis=(0, 1))
    arr = arr * mask + plain * (1 - mask)
    rgb = Image.fromarray(arr.round().clip(0, 255).astype(np.uint8))
    r, g, b = rgb.split()
    return Image.merge('RGBA', (r, g, b, src_rgba.getchannel('A')))


def alpha_kind(it, img):
    alpha = img.getchannel('A')
    amin, _ = alpha.getextrema()
    if amin == 255:
        return 'opaque'
    a = np.asarray(alpha)
    binary = it['fmt'] == 'DXT1' or ((a > 8) & (a < 247)).mean() < 0.01
    return 'cutout' if binary else 'soft'


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(here)
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('pack_root', help="folder holding dump/ and replace/ (the game's textures folder)")
    ap.add_argument('--out', help='output folder (default <pack_root>/replace, overwriting the upscaled pack)')
    ap.add_argument('--tools', default=os.path.join(repo, 'out', 'tooling', 'upscale'))
    ap.add_argument('--models', default=os.path.join(repo, 'out', 'tooling', 'reimagine', 'models'),
                    help='Hugging Face cache folder for the models')
    ap.add_argument('--categories', default='stone,brick,wood,roof',
                    help='comma-separated categories to re-imagine (see LABELS). bark and ground '
                         'exist too but CLIP mixes painted trees and terrain atlases into them')
    ap.add_argument('--min-score', type=float, default=0.5, help='CLIP confidence needed')
    ap.add_argument('--min-size', type=int, default=128, help='skip textures smaller than this')
    ap.add_argument('--strength', type=float, default=0.65,
                    help='img2img denoising strength (0.65 redraws the surface; 0.35 barely changes it)')
    ap.add_argument('--control', type=float, default=0.6,
                    help='tile ControlNet weight (1.0 pins the result to the source; 0.3 invents a new wall)')
    ap.add_argument('--grain', type=float, default=0.5,
                    help="how much of the source's own fine speckle to add back (the model smooths it)")
    ap.add_argument('--detail', type=float, default=1.0,
                    help="how much of the source's detail above the generation size to add back")
    ap.add_argument('--steps', type=int, default=24)
    ap.add_argument('--guidance', type=float, default=5.0)
    ap.add_argument('--size', type=int, default=1024, help='long side at generation')
    ap.add_argument('--pad', type=int, default=32, help='wrapped border for tiling, in source texels')
    ap.add_argument('--seed', type=int, default=1234)
    ap.add_argument('--only', default='', help='comma-separated hash prefixes to process')
    ap.add_argument('--limit', type=int, default=0, help='stop after this many (trials)')
    ap.add_argument('--classify-only', action='store_true')
    ap.add_argument('--reclassify', action='store_true')
    ap.add_argument('--force', action='store_true', help='redo textures already in the output')
    ap.add_argument('--keep-png', help='also write the before/after PNGs here (for judging)')
    args = ap.parse_args()

    out = args.out or os.path.join(args.pack_root, 'replace')
    os.makedirs(out, exist_ok=True)
    os.makedirs(args.models, exist_ok=True)
    items = colour_dumps(args.pack_root, 32)
    cache = classify(args, items)
    print('materials:')
    summarize(cache)
    if args.classify_only:
        return 0

    cats = [c for c in args.categories.split(',') if c]
    only = [p.upper() for p in args.only.split(',') if p]
    todo = []
    for it in items:
        c = cache.get(it['hash'])
        if not c or c['label'] not in cats or c['score'] < args.min_score:
            continue
        if min(it['w'], it['h']) < args.min_size:
            continue
        if only and not any(it['hash'].startswith(p) for p in only):
            continue
        if not args.force and os.path.exists(os.path.join(out, it['hash'] + '.dds')) \
                and os.path.exists(os.path.join(out, it['hash'] + '.reimagined')):
            continue
        it['label'] = c['label']
        replaced = os.path.join(args.pack_root, 'replace', it['hash'] + '.dds')
        it['src'] = replaced if os.path.exists(replaced) else it['path']
        todo.append(it)
    if args.limit:
        todo = todo[:args.limit]
    print(f'{len(todo)} textures to re-imagine in {cats}')
    if not todo:
        return 0

    pipe = load_pipeline(args)
    work = tempfile.mkdtemp(prefix='fable2_reimagine_')
    t0 = time.time()
    try:
        staged = os.path.join(work, 'staged')
        encoded = os.path.join(work, 'encoded')
        decoded = os.path.join(work, 'decoded')
        for d in (staged, encoded, decoded):
            os.makedirs(d)
        if args.keep_png:
            os.makedirs(args.keep_png, exist_ok=True)
        jobs = []
        for n, it in enumerate(todo, 1):
            img = decode_to(args.tools, [it], decoded, key='src')[it['hash']]
            seed = args.seed + int(it['hash'][:6], 16)
            res = generate_one(pipe, img, PROMPTS[it['label']], args, seed, (it['w'], it['h']))
            if args.keep_png:
                img.save(os.path.join(args.keep_png, f"{it['hash']}_{it['label']}_before.png"))
                res.save(os.path.join(args.keep_png,
                                      f"{it['hash']}_{it['label']}_after_s{args.strength}_c{args.control}.png"))
            if alpha_kind(it, img) == 'cutout':
                src = os.path.join(staged, it['hash'] + '.dds')
                up.write_rgba_dds(src, up.cutout_mips(res))
                jobs.append((src, 'BC7_UNORM', True))
            else:
                src = os.path.join(staged, it['hash'] + '.png')
                res.save(src)
                jobs.append((src, 'BC7_UNORM', False))
            print(f"  {n}/{len(todo)} {it['hash']} {it['label']} {img.size[0]}x{img.size[1]}"
                  f'  ({time.time() - t0:.0f} s)')
        print('  compressing')
        up.encode_all(args.tools, jobs, encoded)
        for name in os.listdir(encoded):
            h = os.path.splitext(name)[0].upper()
            shutil.move(os.path.join(encoded, name), os.path.join(out, h + '.dds'))
            with open(os.path.join(out, h + '.reimagined'), 'w') as f:
                f.write(f'strength {args.strength} control {args.control} steps {args.steps}\n')
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f'done in {time.time() - t0:.0f} s -> {out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
