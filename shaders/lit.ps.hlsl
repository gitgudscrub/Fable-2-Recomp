// Fable II lit opaque surfaces, pixel shader 8D900846800943C8: rocks, stone,
// buildings, and the characters' skin and cloth (the hero's face and hands
// draw with this shader; there is no separate skin shader). Replaces the
// SDK's translation through the shader_replace_dir cvar (see
// shaders/README.md).
//
// Stage 1: a literal port of the game's Xenos microcode (comments give the
// ucode instruction numbers). What the original does:
//   - UV transforms c8 / c9 / c10 on v0; tf0 albedo (alpha in .x), tf1
//     tangent-space normal, tf2 a two-channel detail/offset map;
//   - the tangent frame is v3 / v4 (tangent, bitangent) and v1 (normal,
//     unnormalised); the view vector is c19 - v2 (world position);
//   - the sun direction is c80: half-vector specular pow(N.H, c21.w) tinted
//     by c87, diffuse scaled by the screen-space shadow buffer tf8 (read at
//     the pixel position through c0) and c23.w; v6 holds per-vertex light
//     terms raised to c21.w; ambient c22 / c20 / c27.w;
//   - optional lightmap tf13 (b133, scaled by c24.z), optional environment
//     cube tf14 (b134, reflection vector) added as albedo * env^2;
//   - distance fog beyond c67.x with the 1D sun-angle (tf4) and distance
//     (tf5) ramps, c66 / c68 / c28;
//   - output * c20.w * c26, alpha = c26.w * albedo alpha.
// Xenos reading notes are in xe_common.hlsli.

#ifndef DEBUG_VIEW
#define DEBUG_VIEW 0
#endif
// Improvements (0 = original look). Skin: the game has no skin shader, so
// the skin terms apply where the SDK flags the draw as a dynamic mesh
// (xe_flags bit 31: its vertex buffer is rewritten by the CPU, which is how
// the game skins its characters; scenery never is) and the albedo is a skin
// tone (SkinWeight below), which keeps them off the clothes and off
// everything that is not a character.
// SKIN_WRAP: wraps the sun's diffuse term past the terminator (0 = original
//   hard N.L), the first-order look of light scattering under the skin.
// SKIN_SCATTER: reddens the diffuse falloff near the terminator, the colour
//   of that scattering; 0 = none.
// SKIN_SPEC_POWER: multiplier on the specular exponent (the original is a
//   broad (V.R)^4 sheen); SKIN_SPEC scales its strength.
#ifndef SKIN_WRAP
#define SKIN_WRAP 0.5
#endif
#ifndef SKIN_SCATTER
#define SKIN_SCATTER 0.8
#endif
#ifndef SKIN_SPEC_POWER
#define SKIN_SPEC_POWER 3.0
#endif
#ifndef SKIN_SPEC
#define SKIN_SPEC 0.7
#endif

// Procedural wear for stretched surfaces. Some props (the Wraithmarsh pillar
// shafts, large plain rocks) map their whole face to a handful of albedo
// texels, so they come out as one flat colour whatever the texture pack
// holds. Where the albedo is magnified past STRETCH_START texels... that is,
// where one texel spans more than STRETCH_START screen pixels, a world-space
// noise is blended into the albedo: broad grime, finer mottling and a sparse
// crack-like ridge pattern. Ordinary surfaces (a few pixels per texel) are
// untouched. WEAR = overall strength (0 = original).
#ifndef WEAR
#define WEAR 1.0
#endif
#ifndef BUMP
#define BUMP 1.0           // normal tilt from the stone relief
#endif
#ifndef STRETCH_START
#define STRETCH_START 12.0  // screen pixels per albedo texel where wear starts
#endif
#ifndef STRETCH_FULL
#define STRETCH_FULL 32.0   // ... and where it is fully on
#endif
// Relief from the albedo: the brightness slope of the albedo texture (one
// texel either side, so it follows the mip level and stays steady at a
// distance) bends the normal, dark crevices reading as low. Most of the
// game's surfaces have faint or no normal maps; this gives stone, wood,
// plaster and cloth real light and shade. Off on skin. 0 = original.
#ifndef ALBEDO_BUMP
#define ALBEDO_BUMP 5.0
#endif
// Distance fog strength (1 = original). The fog washes texture and shape
// out of everything past the middle distance.
#ifndef FOG
#define FOG 0.6
#endif

#ifndef STRETCH_TEXELS
#define STRETCH_TEXELS 1024.0  // assumed albedo size (the pack's are 1024-2048)
#endif

// --- SDK translator interface (shaders/xe_common.hlsli) -------------------
#define XE_FLOAT_CONSTANTS 21
#define XE_DESCRIPTOR_INDICES 7
#include "xe_common.hlsli"
#if SPARROW
#include "sparrow_common.hlsli"
#endif
#ifndef SPARROW_SKY_REFLECT
#define SPARROW_SKY_REFLECT 1.0
#endif

#define C0 K[0]
#define C8 K[1]
#define C9 K[2]
#define C10 K[3]
#define C19 K[4]
#define C20 K[5]
#define C21 K[6]
#define C22 K[7]
#define C23 K[8]
#define C24 K[9]
#define C26 K[10]
#define C27 K[11]
#define C28 K[12]
#define C49 K[13]
#define C66 K[14]
#define C67 K[15]
#define C68 K[16]
#define C80 K[17]
#define C87 K[18]
#define C254 K[19]
#define C255 K[20]

// Texture bindings of this shader, in the translator's order.
#define TF2(uv) Fetch(2, 0, uv, false)
#define TF0(uv) Fetch(0, 1, uv, false)
#define TF0_OFF(uv, ox, oy) FetchOffset(0, 1, uv, int2(ox, oy))
#define TF1(uv) Fetch(1, 2, uv, false)
#define TF8(uv) Fetch(8, 3, uv, false)
#define TF13(uv) Fetch(13, 4, uv, false)
#define TF14(stf) FetchCube(14, 5, stf)
#define TF4(x) Fetch(4, 6, float2(x, 0.0), true)
#define TF5(x) Fetch(5, 7, float2(x, 0.0), true)

#ifndef LIT_RELIEF_DEPTH
#define LIT_RELIEF_DEPTH 0.03  // surface relief depth, world units
#endif
#if SPARROW
float3 ReliefRGB(float2 b) { return TF0(b * C8.xy + C8.zw).xyz; }
SPARROW_RELIEF_FUNCS(Lit, ReliefRGB)
float4 TF0R(float2 uv) { SparrowReliefGrads(C8.xy); float4 t = TF0(uv); xe_grad_override = false; return t; }
float4 TF1R(float2 uv) { SparrowReliefGrads(C9.xy); float4 t = TF1(uv); xe_grad_override = false; return t; }
float4 TF2R(float2 uv) { SparrowReliefGrads(C10.xy); float4 t = TF2(uv); xe_grad_override = false; return t; }
#else
#define TF0R(uv) TF0(uv)
#define TF1R(uv) TF1(uv)
#define TF2R(uv) TF2(uv)
#endif


// How much an albedo (guest gamma space) looks like skin: red over green
// over blue with moderate saturation, not too dark. Soft so that make-up,
// dirt and lighting baked into the texture do not flicker the result.
float SkinWeight(float3 c) {
  float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
  float sat = (mx - mn) / max(mx, 1e-3);
  float order = smoothstep(0.0, 0.04, c.r - c.g) * smoothstep(0.0, 0.04, c.g - c.b);
  float chroma = smoothstep(0.08, 0.22, sat) * (1.0 - smoothstep(0.6, 0.85, sat));
  return order * chroma * smoothstep(0.12, 0.3, mx);
}

float Hash3(float3 p) {
  p = frac(p * 0.1031);
  p += dot(p, p.yzx + 33.33);
  return frac((p.x + p.y) * p.z);
}
// Smooth value noise in 0..1.
float Noise3(float3 p) {
  float3 i = floor(p), f = frac(p);
  f = f * f * (3.0 - 2.0 * f);
  float4 a = float4(Hash3(i), Hash3(i + float3(1, 0, 0)), Hash3(i + float3(0, 1, 0)), Hash3(i + float3(1, 1, 0)));
  float4 b = float4(Hash3(i + float3(0, 0, 1)), Hash3(i + float3(1, 0, 1)), Hash3(i + float3(0, 1, 1)), Hash3(i + float3(1, 1, 1)));
  float4 c = lerp(a, b, f.z);
  float2 d = lerp(c.xy, c.zw, f.y);
  return lerp(d.x, d.y, f.x);
}
// Worn stone for stretched surfaces, from the world position in metres: a
// height field (broad unevenness, fine grain, scattered pits) whose slope
// along the tangent frame bends the normal, and whose features tint the
// albedo. Stains alone read as damp patches; the relief is what makes it stone.
float StoneHeight(float3 p) {
  float undul = Noise3(p * 6.0);                                   // ~15 cm swell
  float grain = Noise3(p * 40.0) * 0.6 + Noise3(p * 95.0) * 0.4;  // 1-2 cm grain
  float pit = smoothstep(0.70, 0.88, Noise3(p * 16.0 + 5.0));     // scattered dents
  return 0.008 * undul + 0.002 * grain - 0.005 * pit;
}
// Albedo multiplier (mostly near 1) and the tangent-space slope dh/dT, dh/dB.
float StoneWear(float3 p, float3 T, float3 B, out float2 slope) {
  const float e = 0.003;
  float h0 = StoneHeight(p);
  slope = float2(StoneHeight(p + T * e) - h0, StoneHeight(p + B * e) - h0) / e;
  float speck = Noise3(p * 40.0) * 0.6 + Noise3(p * 95.0) * 0.4;
  float tone = Noise3(p * 2.5 + 9.0);
  float pit = smoothstep(0.70, 0.88, Noise3(p * 16.0 + 5.0));
  float w = 1.0;
  w += 0.20 * (speck - 0.5);  // granular speckle, +-10%
  w += 0.12 * (tone - 0.5);   // slow tonal drift
  w -= 0.18 * pit;            // dents hold dirt
  return saturate(w);
}

float4 main(PSInput7 input, out uint coverage : SV_Coverage) : SV_Target0 {
  float4 r0 = input.v0, r1 = input.v1, r2 = input.v2, r3 = input.v3;
  float4 r4 = input.v4, r5 = input.v5, r6 = input.v6;
  float4 r7 = 0.0, r8 = 0.0, r9 = 0.0, r10 = 0.0, r11 = 0.0, r12 = 0.0, r13 = 0.0, r14 = 0.0;
  r7.xy = GuestPixelPosition(input.position, input.front_face);
#if SPARROW
  // Sparrow: surface relief (the textures read where the view ray meets the
  // colour's height field; not on characters).
  SPARROW_RELIEF_APPLY(Lit, input.v0.xy, C8.xy, input.v2.xyz, C19.xyz, LIT_RELIEF_DEPTH)
#endif

  r0.zw = r0.yx * C9.yx + C9.wz;                                         // 10
  r8.xy = r0.yx * C8.yx + C8.wz;                                         // 11
  r8.zw = r0.yx * C10.yx + C10.wz;                                       // 12
  r12.xy = TF2R(r8.wz).xy;                                                // 13
  float2 albedo_uv = r8.yx;  // the uv before the fetch overwrites r8 (Modern: stretch)
  { float4 t = TF0R(r8.yx); r8 = t.wxyz; }                                // 14
  float3 sp_albedo = r8.yzw * r8.yzw;  // Sparrow: colour map, linear (character material)
  float3 albedo = r8.yzw;  // kept for SkinWeight: r8.yzw is reused at 18-22
  // Stretch: screen pixels per albedo texel, from the area of the uv
  // footprint of one pixel (the Jacobian, as mip selection uses). A face
  // mapped to a line of texels (the Wraithmarsh pillars keep v fixed and
  // sweep u round each ring) has zero area; a wall seen at a grazing angle
  // or with an unequal texel density keeps a normal area, so it stays off.
  float2 uv_dx = ddx(albedo_uv) * STRETCH_TEXELS, uv_dy = ddy(albedo_uv) * STRETCH_TEXELS;
  float2 duv = float2(abs(uv_dx.x) + abs(uv_dy.x), abs(uv_dx.y) + abs(uv_dy.y));  // for DEBUG_VIEW
  float area = abs(uv_dx.x * uv_dy.y - uv_dy.x * uv_dx.y);
  float stretch = 1.0 / max(sqrt(area), 1e-6);
  float wear_mask = WEAR * smoothstep(STRETCH_START, STRETCH_FULL, stretch)
                    * ((xe_flags & 0x80000000u) ? 0.0 : 1.0);  // never on characters
  float2 wear_slope = 0.0;
  float wear = wear_mask > 0.0 ? StoneWear(r2.xyz, normalize(r4.xyz), normalize(r3.xyz), wear_slope) : 1.0;
  r8.yzw *= lerp(1.0, wear, wear_mask);
  float2 relief = 0.0;
  if (ALBEDO_BUMP != 0.0) {
    // Perceptual brightness of the neighbouring texels (the fetch is linear).
    float3 lw = float3(0.299, 0.587, 0.114);
    float he = sqrt(max(dot(TF0_OFF(albedo_uv, 1, 0).xyz, lw), 0.0));
    float hw = sqrt(max(dot(TF0_OFF(albedo_uv, -1, 0).xyz, lw), 0.0));
    float hn = sqrt(max(dot(TF0_OFF(albedo_uv, 0, 1).xyz, lw), 0.0));
    float hs = sqrt(max(dot(TF0_OFF(albedo_uv, 0, -1).xyz, lw), 0.0));
    float not_skin = (xe_flags & 0x80000000u) ? 1.0 - SkinWeight(albedo) : 1.0;
    relief = float2(he - hw, hn - hs) * (0.5 * ALBEDO_BUMP * not_skin * (1.0 - wear_mask));
  }
  r10.xyz = TF1R(r0.wz).xyz;                                              // 15
  r1.w = dot(r1.xyz, r1.xyz);                                            // 16
  r9.xyz = C19.zyx - r2.zyx;                                             // 17
  { float3 v = r8.wzy * r8.wzy; r8.y = r10.x * r10.x; r11.xyz = v; }     // 18
  { float v = dot(r9.xyz, r9.xyz); r8.z = r10.y * r10.y; r0.z = v; }     // 19
  r2.xw = r12.yx * C254.xx + C254.zz;                                    // 20
  if (ALBEDO_BUMP != 0.0) {
    float2 n = float2(r2.x, r2.w) - relief;
    n *= rsqrt(max(1.0, dot(n, n) * 1.2));
    r2.x = n.x; r2.w = n.y;
  }
  if (wear_mask > 0.0) {  // Modern: the stone relief bends the normal
    float2 n = float2(r2.x, r2.w) - wear_slope * (BUMP * wear_mask);
    n *= rsqrt(max(1.0, dot(n, n) * 1.2));  // keep room for the z component
    r2.x = n.x; r2.w = n.y;
  }
  r0.w = r2.w * r2.w + r2.x * r2.x + C254.y;                             // 21
  { float3 v = r2.x * r4.zxy; r8.w = r10.z * r10.z; r2.xyz = v; }        // 22
  r2.xyz = r2.w * r3.zxy + r2.xyz;                                       // 23
  { float v = C254.w - r0.w; r1.w = rsqrt(abs(r1.w)); r0.w = v; }        // 24
  { float3 v = r1.w * r1.zyx; r0.w = sqrt(abs(r0.w)); r10.xyz = v; }     // 25
  r2.xyz = r10.xyz * r0.w + r2.xzy;                                      // 26
  { float v = dot(r2.xyz, r2.xyz); r1.w = rsqrt(abs(r0.z)); r0.w = v; }  // 27
  { float3 v = r9.zyx * r1.w; r0.w = rsqrt(abs(r0.w)); r10.xyz = v; }    // 28
  { float3 v = r2.xyz * r0.w; r0.z = sqrt(abs(r0.z)); r9.xyz = v; }      // 29
  if (XeBool(128)) {
    r0.w = r8.x * r8.x;                                                  // 30
    r0.w = rcp(r0.w);                                                    // 31
    r11.xyz = r11.xyz * r0.w;                                            // 32
  }
  r2.xy = abs(r7.xy) * C0.zw + C0.xy;                                    // 33
  r2.w = TF8(r2.xy).x;                                                   // 34
#if SPARROW
  // Sparrow: the real sun shadow map instead of the game's short-range
  // screen-space buffer (v2 is the world position, v1 the normal).
  r2.w = SparrowSunOr(r2.w, input.v2.xyz, normalize(input.v1.xyz));
#endif
  float dbg_shadow = r2.w;
  r14.xyz = C254.w - C22.xyz;                                            // 35
  r7.xyz = r11.zyx * C27.w;                                              // 36
  { float v = dot(r5.xyz, r5.xyz); r6.x = log2(abs(r6.x)); r6.w = v; }   // 37
  { float v = dot(r9.xzy, C80.zxy); r6.y = log2(abs(r6.y)); r0.w = v; }  // 38
  { float v = saturate(dot(r9.xzy, C80.zxy)); r6.z = log2(abs(r6.z)); r2.x = v; }  // 39
  { float v = r0.w + r0.w; r6.w = rsqrt(abs(r6.w)); r0.w = v; }          // 40
  float ndotl_raw = r0.w * 0.5;  // unclamped N.L from 38, for the skin wrap
  r12.xyz = -r9.xyz * r0.w + C80.zyx;                                    // 41
  { float3 v = r6.w * r5.zyx; r0.w = saturate(C23.w * r2.x); r5.xyz = v; }  // 42
  float skin = (xe_flags & 0x80000000u) ? SkinWeight(albedo) : 0.0;
  float3 skin_tint = 1.0;
  if (skin > 0.0) {
    float ndotl = ndotl_raw;
    float wrapped = saturate((ndotl + SKIN_WRAP) / (1.0 + SKIN_WRAP));
    float sun = saturate(C23.w * wrapped);
    // Redden where the wrapped light fades: the scattering colour.
    float edge = saturate(1.0 - abs(ndotl) * 2.5) * SKIN_SCATTER;
    skin_tint = lerp(1.0, float3(1.0, 0.62, 0.5), edge * skin);
    // r2.x (clamped N.L from 39) feeds the diffuse at 48; r0.w only gates
    // the specular at 47.
    r2.x = lerp(r2.x, wrapped, skin);
    r0.w = lerp(r0.w, sun, skin);
  }
  { float v = saturate(dot(r5.xzy, r9.xzy)); r1.w = C21.w * r6.x; r2.z = v; }  // 43
  { float v = saturate(dot(-r10.zxy, r12.xzy)); r6.w = C21.w * r6.y; r2.y = v; }  // 44
  { float v = r2.y * r2.y; r6.z = C21.w * r6.z; r2.y = v; }              // 45
  { float v = r2.y * r2.y; r5.x = exp2(r1.w); r6.x = v; }                // 46
  if (skin > 0.0) {
    // Tighter, weaker sheen than the stone's (V.R)^4.
    float tight = pow(r6.x, SKIN_SPEC_POWER) * SKIN_SPEC;
    r6.x = lerp(r6.x, tight, skin);
  }
  { float v = r0.w * r6.x; r5.y = exp2(r6.w); r2.y = v; }                // 47
  { float3 v = r2.zyx * r2.zww; r5.z = exp2(r6.z); r6.x = v.x; r6.y = v.y; r6.w = v.z; }  // 48
  { float3 v = r5.xyz * C21.xyz; r12.x = C87.x * r6.w; r13.xyz = v; }    // 49
  { float3 v = r6.y * C87.xyz; r12.y = C87.y * r6.w; r5.xyz = v; }       // 50
  r2.xyz = r6.x * r14.xyz + C22.xyz;                                     // 51
  r2.xyz = r13.xyz * r2.xyz + C20.xyz;                                   // 52
  float sky_vis = -1.0;
#if SPARROW
  // Sparrow: sky openness and the sun's bounce on the ambient (r9 holds the
  // normal as zyx; c87 is the sun's colour in this one-light shader).
  if (SparrowActive()) r2.xyz = SparrowAmbient(r2.xyz, input.v2.xyz, r9.zyx, C87.xyz, sky_vis);
#endif
  { float3 v = r8.ywz * r5.xzy; r12.z = C87.z * r6.w; r5.xyz = v; }      // 53
  float3 sparrow_spec = 0.0;
  float3 dbg_spec = r8.yzw;  // DEBUG_VIEW 11
#if SPARROW
  if (SparrowActive() && !(xe_flags & 0x80000000u)) {
    // Scenery only (characters keep the game's sheen and the skin terms):
    // the sun's GGX lobe with the game's specular map as F0 (floored at the
    // 4% of stone), shadowed as the diffuse is, in place of (V.R)^4, plus
    // the sky's reflection at grazing angles unless the material has its
    // own reflection cube (b134). As lit4.ps.hlsl (Command Hub f20,
    // option 1).
    float3 n = r9.zyx, v = r10.xyz;
    float spec_lum = dot(r8.yzw, float3(0.2126, 0.7152, 0.0722));
    float rough = lerp(0.75, 0.35, saturate(spec_lum * 4.0));
    float3 base = 0.0, grazing = 0.0;
    SparrowSpecularSplit(n, v, C80.xyz, rough, C87.xyz * dbg_shadow, base, grazing);
    sparrow_spec = base * max(r8.yzw, SPARROW_F0) + grazing;
    r5.xyz = 0.0;
    if (!XeBool(134))
      sparrow_spec += r2.xyz * C27.w * SparrowEnvSpecular(n, v, rough, max(spec_lum, SPARROW_F0)) * SPARROW_SKY_REFLECT;
  } else if (SparrowActive()) {
    // Characters: the soft universal lobe and fabric sheen (their specular
    // maps are near zero), off the skin, which keeps its own terms.
    float3 n = r9.zyx, v = r10.xyz;
    SparrowCharMat cm = SparrowCharMaterial(sp_albedo);
    sparrow_spec = (SparrowCharacterSpecular(n, v, C80.xyz, C87.xyz * dbg_shadow, cm) +
                    SparrowCharacterSheen(r2.xyz * C27.w, n, v, cm)) * (1.0 - skin);
  }
#endif
  r12.xyz *= skin_tint;
  r6.xyz = r12.xyz * r11.zyx + r5.xzy;                                   // 54
  r6.xyz += sparrow_spec;
#if SPARROW
  if (SparrowDebug() == 2 && SparrowActive()) {
    r6.xyz = sparrow_spec;
    r7.xyz = 0.0;
  }
#endif
  r2.xyz = r7.xyz * r2.xyz + r6.xyz;                                     // 55
  if (XeBool(133)) {
    r6.xyz = TF13(r0.xy).xyz;                                            // 56
    r6.xyz = r6.xyz * r6.xyz;                                            // 57
    r2.xyz = r6.xyz * C24.z + r2.xyz;                                    // 58
  }
  if (XeBool(134)) {
    r6.x = dot(-r10.zxy, r9.xzy);                                        // 59
    r6.x = r6.x + r6.x;                                                  // 60
    { float3 v = -r9.xzy * r6.x - r10.zxy; r6.x = v.x; r6.y = v.y; r6.w = v.z; }  // 61
    { float3 v = r6.y * r3.zxy; r0.x = v.x; r0.y = v.y; r0.w = v.z; }    // 62
    r6.xyz = r6.x * r1.zxy + float3(r0.x, r0.y, r0.w);                   // 63
    r6.z = -r6.w * r4.y - r6.z;                                          // 64
    r6.xy = r6.w * r4.xz + r6.yx;                                        // 65
    r6 = XeCube(r6.xyz);                                                 // 66
    { float v = r6.w; r0.x = rcp(abs(r6.z)); r0.w = v; }                 // 67
    r0.xy = r6.yx * r0.x + C255.x;                                       // 68
    r6.xyz = TF14(float3(r0.x, r0.y, r0.w)).xyz;                         // 69
    r6.xyz = r6.xyz * r6.xyz;                                            // 70
    r2.xyz = r8.yzw * r6.xyz + r2.xyz;                                   // 71
  }
  float dbg_fog = 0.0;
  r6.x = r0.z - C67.x;                                                   // 72
  r6.yzw = r2.xyz * C49.xyz;                                             // 73
  if (r6.x > 0.0) {                                                      // p0
    { float v = saturate(dot(-r10.zxy, C66.zxy)); r0.w = C67.w * r6.x; r0.x = v; }  // 74
    r0.xyz = TF4(r0.x).xyz;                                              // 75
    r1.xyz = TF5(r0.w).xyz;                                              // 76
    r2.xyz = C254.w - r1.xyz;                                            // 77
    { float3 v = r0.xyz - C68.xyz; r6.x = saturate(C67.z * r6.x); r0.xyz = v; }  // 78
    dbg_fog = r6.x;
    r0.xyz = r6.x * r0.zyx + C68.zyx;                                    // 79
    r2.xyz = r2.xyz * C28.y;                                             // 80
    r0.xyz = r2.xyz * r0.zyx - r6.yzw;                                   // 81
    r0.xyz = r6.yzw * r1.xyz + r0.xyz;                                   // 82
    r6.yzw = r0.xyz * (C28.x * FOG) + r6.yzw;                                    // 83
  }
  r0.xyz = C20.w * C26.xyz;                                              // 84
  float4 o = float4(r0.xyz * r6.yzw, C26.w * r8.x);                      // 85
#if DEBUG_VIEW == 1
  o.xyz = C87.xyz;        // specular colour
#elif DEBUG_VIEW == 2
  o.xyz = C21.w / 64.0;   // specular power
#elif DEBUG_VIEW == 3
  o.xyz = C26.xyz;        // material tint
#elif DEBUG_VIEW == 4
  // R specular colour (mean), G specular power / 64, B material tint (mean).
  o.xyz = float3(dot(C87.xyz, 1.0 / 3.0), C21.w / 64.0, dot(C26.xyz, 1.0 / 3.0));
#elif DEBUG_VIEW == 5
  // R albedo alpha, G/B the tf2 map.
  o.xyz = float3(r8.x, r12.x, r12.y);
#elif DEBUG_VIEW == 6
  // R dynamic-mesh flag, G skin weight.
  o.xyz = float3((xe_flags & 0x80000000u) ? 1.0 : 0.0, skin, 0.0);
#elif DEBUG_VIEW == 7
  // R wear mask, G stretch / 32, B the wear pattern.
  o.xyz = float3(wear_mask, stretch / 32.0, wear);
#elif DEBUG_VIEW == 8
  o.xyz = r8.yzw;         // albedo
#elif DEBUG_VIEW == 9
  o.xyz = dbg_shadow;     // screen-space shadow buffer (tf8)
#elif DEBUG_VIEW == 11
  // The specular map (x4) on characters; dark blue elsewhere.
  o.xyz = (xe_flags & 0x80000000u) ? dbg_spec * 4.0 : float3(0.0, 0.0, 0.25);
#elif DEBUG_VIEW == 10
  o.xyz = float3(dbg_fog, saturate(r0.z / 4000.0), 0.0);  // R fog amount, G distance
#endif
#if SPARROW
  if (SparrowDebug() == 3) o.xyz = SparrowVisDebug(sky_vis);  // red open, green closed
#endif
  AlphaTest(o.w);
  coverage = AlphaToMask(o.w, input.position.xy);
  return o * xe_color_exp_bias.x;
}
