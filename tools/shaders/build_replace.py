"""Compile the Modern-graphics shader rewrites (shaders/*.hlsl) to the DXBC
files the SDK swaps in for the game's own shaders (cvar shader_replace_dir,
seeded from [graphics] shader_rewrites).

    python tools/shaders/build_replace.py [--out DIR] [--sparrow]

Default output: shaders/replace in the repo (checked in; CMake stages it next
to the exe as shaders/replace at build time). Each entry in
SHADERS is (source, defines, ucode hash): the SDK replaces the translated
shader whose ucode hash matches the file name. See shaders/README.md for how
hashes are found.

Shaders that read the pixel position (GuestPixelPosition / RES_SCALE) bake
the resolution scale in, so they are built once per scale as
<hash>.x<scale>.dxbc; the SDK picks the one for the running scale.

--sparrow builds the same set with /D SPARROW=1 into shaders/sparrow_replace,
which the Project Sparrow edition loads instead ([graphics] sparrow_renderer;
see shaders/sparrow_common.hlsli). Shaders without SPARROW code come out the
same as the Enhanced ones.
"""
import argparse
import glob
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, 'shaders')
DEFAULT_OUT = os.path.join(SRC, 'replace')
SPARROW_OUT = os.path.join(SRC, 'sparrow_replace')

# (source file, profile, extra defines, ucode hash)
SHADERS = [
    ('water.ps.hlsl', 'ps_5_1', [], 'A17D8AEC3A817D45'),            # open water
    ('water.ps.hlsl', 'ps_5_1', ['EDGE=1'], 'F6D98C7B4D98438B'),    # shore edge
    ('foliage.ps.hlsl', 'ps_5_1', [], '7CD57B81550F19E3'),          # tree leaves
    ('sky.ps.hlsl', 'ps_5_1', [], '61976295517D7015'),              # sun-lit cloud layer
    ('lit.ps.hlsl', 'ps_5_1', [], '8D900846800943C8'),              # lit opaque: rocks, stone, skin, cloth
    ('lit_shadow.ps.hlsl', 'ps_5_1', [], '648B965C200A5113'),  # lit + shadow map: pillars, ruins, dead trees
    ('trunk.ps.hlsl', 'ps_5_1', [], '00E09D1BC5295D52'),            # tree trunks, second foliage layer
    ('fern.ps.hlsl', 'ps_5_1', [], '165EDCD2CB963868'),             # ferns and bushes
    ('tonemap.ps.hlsl', 'ps_5_1', [], '37B186F4BD3288F7'),          # final composite: bloom + tone curve
    ('terrain.ps.hlsl', 'ps_5_1', [], '9C2144E42E95A76F'),          # ground + cliff rock blend
    ('grass.ps.hlsl', 'ps_5_1', [], '2F8A0341E8C09698'),            # near ground (grass, forest floor)
    ('ground.ps.hlsl', 'ps_5_1', [], '7DDAD5C29B3F56EE'),           # far lightmapped terrain
    ('splat.ps.hlsl', 'ps_5_1', [], '4755A2E4A05BA678'),            # dirt / path splats over the ground
]

# Built only with --sparrow (Project Sparrow replaces these; Enhanced keeps
# the game's own).
SPARROW_ONLY = [
    ('shadowbuf.ps.hlsl', 'ps_5_1', [], '0F99810F072BF0FC'),        # screen-space sun shadow buffer
    ('path.ps.hlsl', 'ps_5_1', [], '578342593A37DD35'),             # town cobbles / paths, 4 lights
    ('lit4.ps.hlsl', 'ps_5_1', [], '789266C3E42D7E59'),             # walls / stone near lanterns, 4 lights
    ('terrain_near.ps.hlsl', 'ps_5_1', [], '45243B758F9272AB'),     # near terrain layers + cliffs, 2 lights
    ('splat_near.ps.hlsl', 'ps_5_1', [], 'AF1E16EE57E4BB06'),       # near ground splats, 2 lights
    ('character.ps.hlsl', 'ps_5_1', [], '401A01FD4E5F8757'),        # characters: hair, cloth, robes
    ('character2.ps.hlsl', 'ps_5_1', [], '44B567635EB10620'),       # characters lit by two lights
    ('character4.ps.hlsl', 'ps_5_1', [], 'F2F103F16764043B'),       # characters lit by four lights
    ('char_alpha.ps.hlsl', 'ps_5_1', [], '2FD24989AB04A475'),       # translucent character parts, sun
    ('char_alpha2.ps.hlsl', 'ps_5_1', [], 'F96A4494958BFA12'),      # ... two lights + shadow map (wings)
    ('lit7.ps.hlsl', 'ps_5_1', [], 'FC0922A3A8D8DA7A'),             # interiors, 7 lamps, no sun
    ('lit7b.ps.hlsl', 'ps_5_1', [], '31AE85A9275B4A29'),            # ... glossy (Tattered Spire)
    ('lit4b.ps.hlsl', 'ps_5_1', [], 'A22982E86122DA41'),            # caves, 4 lamps
    ('lit7_fog.ps.hlsl', 'ps_5_1', [], '356E4E7B9E2B36E6'),         # temple interiors, 7 lamps + fog
    ('lit_fog.ps.hlsl', 'ps_5_1', [], '999604E7F8EAE7CC'),          # sunlit walls in fog (Crucible, marsh)
    ('bush.ps.hlsl', 'ps_5_1', [], 'E99F4ACC7A3C78B4'),             # bushes and hedges, 2 lights
    ('bush2.ps.hlsl', 'ps_5_1', [], 'F525E023E08AC9BB'),            # leafy bushes, normal map, 2 lights
    ('grass_clump.ps.hlsl', 'ps_5_1', [], 'A7E45D07F5CF6627'),      # grass clumps, sun only
    ('marsh.ps.hlsl', 'ps_5_1', [], '04F23292B2F44077'),            # marsh reeds and cover, 4 lights
]


# Resolution scales the launcher offers (1x, 2x, 3x).
SCALES = (1, 2, 3)


def find_fxc():
    env = os.environ.get('FXC')
    if env and os.path.isfile(env):
        return env
    pattern = r'C:\Program Files (x86)\Windows Kits\10\bin\10.*\x64\fxc.exe'
    found = sorted(glob.glob(pattern))
    if not found:
        sys.exit('fxc.exe not found (Windows SDK); set FXC=<path>')
    return found[-1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', default=None)
    parser.add_argument('--sparrow', action='store_true')
    args = parser.parse_args()
    if args.out is None:
        args.out = SPARROW_OUT if args.sparrow else DEFAULT_OUT
    sparrow = ['SPARROW=1'] if args.sparrow else []
    fxc = find_fxc()
    os.makedirs(args.out, exist_ok=True)
    for source, profile, defines, hash_ in SHADERS + (SPARROW_ONLY if args.sparrow else []):
        text = open(os.path.join(SRC, source), encoding='utf-8').read()
        scaled = 'GuestPixelPosition' in text or 'RES_SCALE' in text
        variants = [(f'.x{n}', [f'RES_SCALE={n}.0']) for n in SCALES] if scaled else [('', [])]
        stale = os.path.join(args.out, hash_ + '.dxbc')
        if scaled and os.path.exists(stale):
            os.remove(stale)
        for suffix, extra in variants:
            out = os.path.join(args.out, hash_ + suffix + '.dxbc')
            cmd = [fxc, '/nologo', '/T', profile, '/E', 'main', '/O3',
                   '/enable_unbounded_descriptor_tables', '/Fo', out]
            for d in defines + sparrow + extra:
                cmd += ['/D', d]
            cmd.append(os.path.join(SRC, source))
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode:
                print(result.stdout, result.stderr, file=sys.stderr)
                sys.exit(f'{source} ({defines + extra}) failed')
            print(f'{source:20} {",".join(defines + extra) or "-":24} -> {out}')


if __name__ == '__main__':
    main()
