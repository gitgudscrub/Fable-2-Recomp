// Fable II tree leaves, pixel shader 7CD57B81550F19E3. Replaces the SDK's
// translation through the shader_replace_dir cvar (see shaders/README.md).
//
// Stage 1: a literal port of the game's Xenos microcode (comments give the
// ucode instruction numbers). What the original does:
//   - the vertex shader does the lighting: v1 ambient, v2 direct sun (both
//     with the UV in .w), v3 back light for translucency, v4/v5 fog scale
//     and offset, v0 world position;
//   - the pixel shader reads the screen-space shadow buffer (tf8) and the
//     leaf atlas (tf0, colour squared), lights it as albedo * (ambient +
//     shadow * sun) plus a translucency term shadow * backlight * albedo
//     that only the green-dominant texels get (sge on g >= r);
//   - optional fog (b129... b132) and the cloud-plane shadow (b129, the same
//     code as the sky-card shader), then the c26 tint and c15.w alpha scale.
// Xenos reading notes are in xe_common.hlsli.

#ifndef DEBUG_VIEW
#define DEBUG_VIEW 0
#endif
// Improvements (0 = original look):
// TRANSLUCENCY: strength of the back-light term (1 = original); the gate on
//   green-dominant texels becomes a soft ramp of width TRANSLUCENCY_SOFT.
// VARIATION: low-frequency warm/cool colour variation across the canopy from
//   the world position, so neighbouring trees and branches stop being the
//   same green (0 = off, 1 = +-8% tint); VARIATION_SCALE is in metres.
#ifndef TRANSLUCENCY
#define TRANSLUCENCY 1.6
#endif
#ifndef TRANSLUCENCY_SOFT
#define TRANSLUCENCY_SOFT 0.08
#endif
#ifndef VARIATION
#define VARIATION 0.8
#endif
#ifndef VARIATION_SCALE
#define VARIATION_SCALE 3.5
#endif

// --- SDK translator interface (shaders/xe_common.hlsli) -------------------
#define XE_FLOAT_CONSTANTS 16
#define XE_DESCRIPTOR_INDICES 4
#include "xe_common.hlsli"

#define C0 K[0]
#define C8 K[1]
#define C15 K[2]
#define C19 K[3]
#define C20 K[4]
#define C26 K[5]
#define C27 K[6]
#define C28 K[7]
#define C49 K[8]
#define C72 K[9]
#define C73 K[10]
#define C74 K[11]
#define C75 K[12]
#define C76 K[13]
#define C254 K[14]
#define C255 K[15]

// Texture bindings of this shader, in the translator's order.
#define TF8(uv) Fetch(8, 0, uv, false)
#define TF0(uv) Fetch(0, 1, uv, false)
#define TF12(uv) Fetch(12, 2, uv, false)
#define TF11(uv) Fetch(11, 3, uv, false)

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

float4 main(PSInput6 input, out uint coverage : SV_Coverage) : SV_Target0 {
  float4 r0 = input.v0, r1 = input.v1, r2 = input.v2, r3 = input.v3, r4 = input.v4, r5 = input.v5;
  float4 r6 = 0.0, r7 = 0.0;
  float ps = 0.0;
  r6.xy = GuestPixelPosition(input.position, input.front_face);
  float3 world_pos = r0.xyz;

  r6.zw = abs(r6.xy) * C0.zw + C0.xy;                                    // 8
  { float3 v = r1.zyx * C27.w; r6.x = C8.y * r2.w; r7.xyz = v; }         // 9
  { float3 v = r4.xyz * C49.xyz; r6.y = C8.x * r1.w; r4.xyz = v; }       // 10
  r6.xy = r6.xy + C8.wz;                                                 // 11
  r0.w = TF8(r6.zw).x;                                                   // 12
  { float4 t = TF0(r6.yx); r6 = t.wxyz; }                                // 13
  r1 = r6.yzwx * r6.yzwx;                                                // 14
  r0.w = r0.w * C255.w + C255.z;                                         // 15
  r2.xyz = r0.w * r2.zyx + r7.xyz;                                       // 16
  r0.w = r0.w * C255.w + C255.z;                                         // 17
  { float3 v = r0.w * r3.zyx; r0.w = 1.0 / r1.w; r7.xyz = v; }           // 18
  r3.xyz = r1.xyz * r0.w;                                                // 19
  r0.w = (r3.y >= r3.x) ? 1.0 : 0.0;                                     // 20
  if (TRANSLUCENCY_SOFT > 0.0) {
    r0.w = smoothstep(-TRANSLUCENCY_SOFT, TRANSLUCENCY_SOFT, r3.y - r3.x);
  }
  r1.xyz = r3.zyx * r0.w;                                                // 21
  r1.xyz = r7.zyx * r1.zyx;                                              // 22
  r1.xyz *= TRANSLUCENCY;
  r1.xyz = r3.xyz * r2.zyx + r1.xyz;                                     // 23
  if (VARIATION > 0.0) {
    float n = Noise3(world_pos * (1.0 / VARIATION_SCALE));
    float3 tint = lerp(float3(1.08, 1.03, 0.90), float3(0.92, 0.99, 1.08), n);
    r1.xyz *= lerp(1.0, tint, VARIATION);
  }
  r2.xyz = r1.xyz * C49.xyz;                                             // 24
  if (XeBool(132)) {                                                     // 2.0
    r2.xyz = r4.xyz * r1.xyz + r5.xyz;                                   // 25
    if (XeBool(129)) {                                                   // 3.0
      r1.xyz = r0.xyz - C19.xyz;                                         // 26
      r3.xy = (-r1.z > 0.0) ? r0.xy : C19.xy;                            // 27
      r3.xy = r3.xy * C74.xy + C74.zw;                                   // 28
      r0.w = TF12(r3.xy).x;                                              // 29
      { float v = -C19.z + C76.y; r0.w = C76.x * r0.w; r1.w = v; }       // 30
      { float v = r1.w + r0.w; r1.w = 1.0 / r1.z; r2.w = v; }            // 31
      r1.w = r2.w * r1.w;                                                // 32
      r3.y = (C255.x > r1.w) ? 1.0 : 0.0;                                // 33
      r3.x = (r1.z >= 0.0) ? C255.y : C255.x;                            // 34
      r3.z = (r1.w >= 0.0) ? C255.x : C255.y;
      r3.w = (r1.z >= 0.0) ? C255.x : C255.y;
      r4.xy = abs(r3.xy) + abs(r3.zw);                                   // 35
      r4.xy = (r4.xy != C255.yy) ? 1.0 : 0.0;                            // 36
      r2.w = r4.x * r4.y;                                                // 37
      r0.w = r0.w + C76.y;                                               // 38
      if (r2.w != 0.0) {                                                 // 5.0 (!p0)
        r3.xy = r3.xy * r3.zw;                                           // 39
        r1.xyz = r1.w * r1.xyz + C19.xyz;                                // 40
        r4.xyz = (r3.y == 0.0) ? r0.xyz : r1.xyz;                        // 41
        r5.xyz = (r3.x == 0.0) ? C19.xyz : r1.xyz;                       // 42
        r1.xy = r5.xy * C73.xy;                                          // 43
        r1.zw = r4.yx * C73.yx;                                          // 44
        r1 = r1 + C73.zwwz;                                              // 45
        r0.xy = r1.yx + r1.zw;                                           // 46
        r0.xy = r0.yx * C254.x;                                          // 47
        r3.z = TF11(r1.xy).x;                                            // 48
        r3.w = TF11(r0.xy).x;                                            // 49
        r0.z = C75.x * C254.x;                                           // 50
        r1.w = -C75.y + C255.x;                                          // 51
        r1.x = r0.w - r5.z;                                              // 52
        { float3 v = r4.xyz - r5.xyz; ps = r0.w; r5.xyz = v; }           // 53
        { float v = dot(r5.zxy, r5.zxy); r1.y = ps - r4.z; r0.x = v; }   // 54
        r3.xy = saturate(r1.xy * C76.w);                                 // 55
        { float2 v = r3.xz + r3.yw; r1.x = sqrt(abs(r0.x)); r1.yz = v; } // 56
        r0.xy = r1.xz * C254.x;                                          // 57
        r0.xyz = r0.yxz * r1.wyz;                                        // 58
        { float v = r0.x + C75.y; r0.y = r0.y - r0.z; r0.x = v; }        // 59
        r0.x = r0.y * r0.x;                                              // 60
        r0.x = max(r0.x, C255.y);                                        // 61
        r0.x = C76.z * r0.x;                                             // 62
        r0.y = exp2(r0.x);                                               // 63
        r0.x = C255.x - r0.y;                                            // 64
        r0.xzw = r0.x * C72.zyx;                                         // 65
        r0.xzw = r0.wzx * C28.y;                                         // 66
        r2.xyz = r2.xyz * r0.y + r0.xzw;                                 // 67
      }
    }
  }
  { float3 v = C20.w * C26.xyz; r0.x = C26.w * r6.x; r0.yzw = v; }       // 68
  float4 o = float4(r0.yzw * r2.xyz, C15.w * r0.x);                      // 69
#if DEBUG_VIEW == 1
  o.xyz = Noise3(world_pos * (1.0 / VARIATION_SCALE)).xxx;
#endif
  AlphaTest(o.w);
  coverage = AlphaToMask(o.w, input.position.xy);
  return o * xe_color_exp_bias.x;
}
