// Fable II sky cloud layer, pixel shader 61976295517D7015. Replaces the
// SDK's translation through the shader_replace_dir cvar (see
// shaders/README.md).
//
// Stage 1: a literal port of the game's Xenos microcode (comments give the
// ucode instruction numbers). What the original does:
//   - samples the cloud texture (tf13; alpha is a height map) at the dome
//     UV (v1 * c31 + c46);
//   - a radial falloff around the sun's dome position (c79) times the
//     height (c69) gates the pixel: below c254.y it is black;
//   - otherwise builds a normal from the four neighbouring height texels
//     (c70.x = height scale), lights it against the sun direction (-c78)
//     with a diffuse term, a view-dependent term and a (1 - N.L)^c255.x
//     rim, tints with c47 / c71 / c51 and multiplies by the texture colour
//     and c20.w.
// Xenos reading notes are in xe_common.hlsli.

#ifndef DEBUG_VIEW
#define DEBUG_VIEW 0
#endif
// Improvements (0 = original look):
// CLOUD_DETAIL: a finer octave of the same height map (CLOUD_DETAIL_SCALE
//   times the tiling) folded into the cloud normal, so the sun shading shows
//   the small billows of the clouds and not only the broad ones.
// CLARITY: local contrast of the cloud height (which sets the layer's
//   coverage) and colour against their own blurred copy (mip CLARITY_LEVEL),
//   which firms up the painted cloud shapes.
// BUMP: scale on the height gradient the normal is built from (1 = original),
//   so the view-dependent shading shows the billows as rounded forms.
#ifndef CLOUD_DETAIL
#define CLOUD_DETAIL 0.6
#endif
#ifndef CLOUD_DETAIL_SCALE
#define CLOUD_DETAIL_SCALE 3.0
#endif
#ifndef CLARITY
#define CLARITY 0.35
#endif
#ifndef CLARITY_LEVEL
#define CLARITY_LEVEL 3.0
#endif
#ifndef BUMP
#define BUMP 2.5
#endif
// COVERAGE: gain on the layer's blend weight (height * sun falloff), so the
//   clouds sit more firmly on the dome instead of washing into it.
#ifndef COVERAGE
#define COVERAGE 1.6
#endif

// --- SDK translator interface (shaders/xe_common.hlsli) -------------------
#define XE_FLOAT_CONSTANTS 13
#define XE_DESCRIPTOR_INDICES 1
#include "xe_common.hlsli"

#define C20 K[0]
#define C31 K[1]
#define C46 K[2]
#define C47 K[3]
#define C51 K[4]
#define C69 K[5]
#define C70 K[6]
#define C71 K[7]
#define C77 K[8]
#define C78 K[9]
#define C79 K[10]
#define C254 K[11]
#define C255 K[12]

// Texture bindings of this shader, in the translator's order.
#define TF13(uv) Fetch(13, 0, uv, false)
#define TF13_OFF(uv, ox, oy) FetchOffset(13, 0, uv, int2(ox, oy))
#define TF13_LEVEL(uv, l) FetchLevel(13, 0, uv, false, l)

float4 main(PSInput2 input) : SV_Target0 {
  float4 r0 = input.v0, r1 = input.v1;
  float4 r2 = 0.0, r3 = 0.0;
  float dbg_lit = 0.0, dbg_ndotl = 0.0, dbg_fine = 0.0;

  r1.yz = r1.xy * C31.xy + C46.xy;                                       // 6
  { float4 t = TF13(r1.yz); r2 = t.wxyz; }                               // 7
  if (CLARITY != 0.0) {
    float4 soft = TF13_LEVEL(r1.yz, CLARITY_LEVEL).wxyz;
    r2 += (r2 - soft) * CLARITY;
    r2.x = saturate(r2.x);
  }
  r1.xw = r0.yx - C79.yx;                                                // 8
  r0.w = dot(r1.wx, r1.wx) + C254.x;                                     // 9
  { float v = r2.x * C69.x; r0.w = sqrt(abs(r0.w)); r1.w = v; }          // 10
  r0.w = r0.w - C254.z;                                                  // 11
  r1.x = saturate(C254.y * r0.w);                                        // 12
  r0.w = C254.w - r1.x;                                                  // 13
  r0.w = r1.w * r0.w;                                                    // 14
  r0.w = saturate(r0.w * COVERAGE);
  r1.x = (r0.w > C254.y) ? 1.0 : 0.0;                                    // 15
  if (r1.x == 0.0) {                                                     // 16, p0
    r0.xyz = (-abs(r0.x) > C254.x) ? 1.0 : 0.0;                          // 17
  } else {
    r3.z = TF13_OFF(r1.yz, 1, 0).w;                                      // 18
    r3.w = TF13_OFF(r1.yz, 0, 1).w;                                      // 19
    r3.x = TF13_OFF(r1.yz, -1, 0).w;                                     // 20
    r3.y = TF13_OFF(r1.yz, 0, -1).w;                                     // 21
    r1.yzw = r0.zyx - C77.zyx;                                           // 22
    r0.y = dot(r1.ywz, r1.ywz);                                          // 23
    { float2 v = r3.zw - r3.xy; r1.x = rsqrt(abs(r0.y)); r0.xz = v; }    // 24
    if (CLOUD_DETAIL != 0.0) {
      float2 fuv = r1.yz * CLOUD_DETAIL_SCALE;
      float2 fine = float2(TF13_OFF(fuv, 1, 0).w - TF13_OFF(fuv, -1, 0).w,
                           TF13_OFF(fuv, 0, 1).w - TF13_OFF(fuv, 0, -1).w);
      r0.xz += fine * CLOUD_DETAIL;
      dbg_fine = length(fine);
    }
    r0.xz *= BUMP;
    dbg_lit = 1.0;
    r0.y = dot(r0.xz, r0.xz) + C254.x;                                   // 25
    r0.y = C70.x * C70.x + r0.y;                                         // 26
    { float3 v = r1.yzw * r1.x; r0.y = rsqrt(abs(r0.y)); r3.xyz = v; }   // 27
    { float2 v = r0.xz * r0.y; r1.y = C70.x * r0.y; r1.zw = v; }         // 28
    r0.x = saturate(dot(r1.yzw, -C78.zxy));                              // 29
    dbg_ndotl = r0.x;
    r0.x = C254.w - r0.x;                                                // 30
    { float v = saturate(dot(r3.xzy, -r1.yzw)); r0.y = log2(abs(r0.x)); r1.x = v; }  // 31
    r0.x = C255.x * r0.y;                                                // 32
    { float v = saturate(dot(r3.xzy, r1.yzw)); r1.z = exp2(r0.x); r1.y = v; }  // 33
    r0.xz = r1.yx * r1.zx;                                               // 34
    { float v = r1.y + r0.x; r0.y = C254.w - r2.x; r0.x = v; }           // 35
    r0.x = r0.z * r0.y + r0.x;                                           // 36
    r0.xyz = r0.x * C47.zyx + C71.x;                                     // 37
    r0.xyz = r0.xyz * C51.x;                                             // 38
    r0.xyz = r0.zyx * r2.yzw;                                            // 39
  }
  r0.xyz = r0.xyz * C20.w;                                               // 40
#if DEBUG_VIEW == 1
  r0.xyz = r2.x;   // cloud height
#elif DEBUG_VIEW == 2
  // R lit branch, G N.L, B fine-octave gradient x20; alpha 1 so it shows
  // whatever the blend state is.
  r0 = float4(dbg_lit, dbg_ndotl, saturate(dbg_fine * 20.0), 1.0);
#elif DEBUG_VIEW == 3
  // Height map (R) and the base-octave gradient x20 (G), lit branch only.
  r0 = float4(r2.x, saturate(length(r3.zw - r3.xy) * 20.0), dbg_lit, 1.0);
#endif
  AlphaTest(r0.w);
  return r0 * xe_color_exp_bias.x;                                       // 41
}
