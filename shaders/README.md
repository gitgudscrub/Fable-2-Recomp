# Shader rewrites (Modern graphics, tier 3)

Hand-written HLSL that replaces the game's own shaders at the point where the
SDK would use its translation of the Xbox 360 microcode. Built by
`python tools/shaders/build_replace.py` into `shaders/replace/<UCODE
HASH>.dxbc` (checked in, so builds don't need fxc); CMake stages that folder
next to the exe, and the SDK cvar `shader_replace_dir` (seeded from
`[graphics] shader_rewrites`) points there. A replacement is picked up when
the shader is translated, which happens at every startup (the shader cache
stores microcode, not the result), so a rebuilt `.dxbc` needs only a restart.

## Finding the shader for a surface

1. Run with `--dump_shaders=<dir>` once. For every shader this writes
   `shader_<HASH>.ucode.frag` (microcode disassembly) and
   `shader_<HASH>_<mods>.d3d12_rtv.bin.frag` (the translated DXBC;
   `fxc /dumpbin` disassembles it).
2. In the console, `cvar log_frame_shaders 1` logs every vertex/pixel shader
   pair drawn in the next frame, with draw counts, in draw order.
3. `--shader_highlight=HASH1,HASH2,...` (up to 8) draws each listed pixel
   shader's surfaces in a solid colour (magenta, red, green, blue, yellow,
   cyan, white, orange) so you can see which is which.

## Writing a replacement

The replacement is a complete DXBC pixel (or vertex) shader for the SDK's
root signature, so it must declare the same resources the translated shader
does: see the `Buffer Definitions` and `Resource Bindings` blocks at the top
of the `fxc /dumpbin` output. `xe_common.hlsli` holds that interface
(constant buffers, the unbounded sampler/texture tables, `Fetch()` /
`FetchLevel()`, `AlphaTest()`, `PSInput`); a rewrite defines
`XE_FLOAT_CONSTANTS` and `XE_DESCRIPTOR_INDICES` from the dumpbin output and
includes it, as `water.ps.hlsl` does. In particular:

- `xe_float_cbuffer` holds only the float constants the shader uses, packed in
  ascending register order (`K[0]` = lowest `c` register used).
- Textures are fetched through `xe_descriptor_indices`: each texture binding
  takes three indices (sampler, unsigned view, signed view) in the order the
  translator lists them; `Fetch()` in `water.ps.hlsl` reproduces the
  translator's fetch, including guest-gamma decoding and the `exp_adjust`
  scale from the fetch constants.
- The output is multiplied by `xe_color_exp_bias.x`; alpha test and
  alpha-to-coverage are in the translated shader's tail and need porting
  only if the game enables them for that shader.

Start with a literal port of the microcode (one HLSL line per ucode
instruction, as in `water.ps.hlsl`), check it against the original with
screenshots, then add the improvements behind defines so the original look
stays reachable.

Two lessons from the sky attempt: confirm the hash with `--shader_highlight`
*before* porting (a frame's draw counts are not enough; `4B1D3E6E8E58D3AC`
is the distant tree impostor/haze cards, not the sky, and a highlight colour
close to the surface's own colour, such as white on sky, is invisible), and
remember that debug colours written by a shader go through the game's own
tonemapping and the Modern colour grade before a screenshot, so read them
back as threshold steps across the screen, not as absolute values.

## Current rewrites

| Shader | Hashes | Changes |
|---|---|---|
| Water (`water.ps.hlsl`) | `A17D8AEC3A817D45` open water, `F6D98C7B4D98438B` shore edge | finer third ripple layer, tighter sun glint, Fresnel curve on the reflection |
| Tree leaves (`foliage.ps.hlsl`) | `7CD57B81550F19E3` | stronger, soft-gated translucency when the sun is behind the leaves; low-frequency warm/cool variation across the canopy from the world position |
| Sky clouds (`sky.ps.hlsl`) | `61976295517D7015` (the sun-lit, bump-mapped cloud layer over the dome) | finer octave of the cloud height map in the lighting normal; clarity on the cloud colour |
| Tree trunks (`trunk.ps.hlsl`) | `00E09D1BC5295D52` (trunks, branches and the second foliage layer) | low-frequency warm/cool variation of the bark colour from the world position (6 m scale, so each trunk keeps one colour) |
| Ferns and bushes (`fern.ps.hlsl`) | `165EDCD2CB963868` | the same variation across the undergrowth (2.5 m scale) |
| Lit opaque / skin (`lit.ps.hlsl`) | `8D900846800943C8` (rocks, stone, buildings, and the characters' skin and cloth) | on character draws whose albedo is a skin tone: wrapped diffuse, a reddened scattering edge where the light fades, and a tighter, weaker sheen than the stone's. Scenery is byte-for-byte the literal port |

### Skin without a skin shader

Fable II has no skin shader: the hero's face, hands and shirt draw with the
same pixel shader as the rocks (`8D900846800943C8`), the same vertex shader
(`ECD66A10092E6562`; characters are skinned on the CPU and re-uploaded every
frame), and the same lighting constants (`c87`, `c21.w`, `c26` are global
per frame, not per material). Nothing in a draw tells the shader it is a
character. So the SDK fork adds `kSysFlag_DynamicMesh` (`xe_flags` bit 31,
set in the D3D12 command processor): the draw reads a vertex buffer the CPU
rewrote since its last upload, after having been seen in an earlier frame
(scenery buffers upload once and never change; the first sighting is
ignored so freshly streamed scenery is not flagged). The flag is held for
120 frames so a character that stops moving keeps its look.
`lit.ps.hlsl` applies the skin terms where the flag is set *and*
`SkinWeight()` says the albedo is a skin tone (red over green over blue,
moderate saturation), which keeps them off the clothes. Debug view 6 shows
the flag in red and the weight in green.

Port gotchas for this shader: the albedo register (`r8`) is reused for the
env-mask square at instructions 18-22, so anything that wants the albedo
later must copy it right after the fetch; and the diffuse takes the clamped
N.L from `r2.x` (instruction 39), while the `C23.w`-scaled copy in `r0.w`
only gates the specular, so a change to the diffuse falloff has to go into
`r2.x`.

Confirmed hashes for the next ports (Bower Lake, `--shader_highlight`): grass
`2F8A0341E8C09698`, terrain `7DDAD5C29B3F56EE`,
horizon haze band `F7601FBE485936FD`, distant tree impostor cards `4B1D3E6E8E58D3AC`.
