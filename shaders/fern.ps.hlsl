// Fable II ferns and bushes, pixel shader 165EDCD2CB963868. Replaces the
// SDK's translation through the shader_replace_dir cvar (see
// shaders/README.md).
//
// Stage 1: a literal port of the game's Xenos microcode (comments give the
// ucode instruction numbers). What the original does:
//   - UV transforms c8 (albedo tf0), c9 (tf1, a 3-channel mask), c10 (tf2,
//     2-channel normal map); the screen-space shadow buffer tf8 (c0);
//   - a tangent-space normal from v3/v4 and v1 (c255.w / c255.z unpack),
//     bent towards v6 by v6.w; the view vector from c19 - v2;
//   - sun N.L (c80) * c23.w, the half-vector-ish term with c255/c80 (r12),
//     a specular from the mask squared (tf1) with c87 and the shadow;
//     ambient c22 and v7; albedo squared divided by alpha;
//   - optional distance fog (depth > c67.x: 1D lookups tf4/tf5, c66, c68,
//     c28); then a screen-space dither (tf10, c50) fades the whole thing out
//     with distance (c15.y/c15.z) through the alpha, times albedo alpha.
// Xenos reading notes are in xe_common.hlsli.

#ifndef DEBUG_VIEW
#define DEBUG_VIEW 0
#endif
// Improvements (0 = original look):
// VARIATION: low-frequency warm/cool colour variation across the undergrowth
//   from the world position (0 = off, 1 = +-10% tint); VARIATION_SCALE is in
//   metres.
#ifndef VARIATION
#define VARIATION 0.8
#endif
#ifndef VARIATION_SCALE
#define VARIATION_SCALE 2.5
#endif

// --- SDK translator interface (shaders/xe_common.hlsli) -------------------
#define XE_FLOAT_CONSTANTS 17
#define XE_DESCRIPTOR_INDICES 6
#include "xe_common.hlsli"

#define C0 K[0]
#define C8 K[1]
#define C9 K[2]
#define C10 K[3]
#define C15 K[4]
#define C19 K[5]
#define C20 K[6]
#define C22 K[7]
#define C23 K[8]
#define C28 K[9]
#define C50 K[10]
#define C66 K[11]
#define C67 K[12]
#define C68 K[13]
#define C80 K[14]
#define C87 K[15]
#define C255 K[16]

// Texture bindings of this shader, in the translator's order.
#define TF8(uv) Fetch(8, 0, uv, false)
#define TF1(uv) Fetch(1, 1, uv, false)
#define TF2(uv) Fetch(2, 2, uv, false)
#define TF0(uv) Fetch(0, 3, uv, false)
#define TF4(x) Fetch(4, 4, float2(x, 0.0), true)
#define TF5(x) Fetch(5, 5, float2(x, 0.0), true)
#define TF10(uv) Fetch(10, 6, uv, false)

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

float4 main(PSInput8 input, out uint coverage : SV_Coverage) : SV_Target0 {
  float4 r0 = input.v0, r1 = input.v1, r2 = input.v2, r3 = input.v3;
  float4 r4 = input.v4, r5 = input.v5, r6 = input.v6, r7 = input.v7;
  float4 r8 = 0.0, r9 = 0.0, r10 = 0.0, r11 = 0.0, r12 = 0.0;
  float ps = 0.0;
  r8.xy = GuestPixelPosition(input.position, input.front_face);
  float3 world_pos = r2.xyz;

  r9.xy = r0.yx * C8.yx + C8.wz;                                         // 8
  r0.zw = r0.yx * C10.yx + C10.wz;                                       // 9
  r0.xy = r0.yx * C9.yx + C9.wz;                                         // 10
  r8.xy = abs(r8.xy) * C0.zw + C0.xy;                                    // 11
  r1.w = TF8(r8.xy).x;                                                   // 12
  r11.xyz = TF1(r0.yx).xyz;                                              // 13
  r0.yz = TF2(r0.wz).xy;                                                 // 14
  r9 = TF0(r9.yx);                                                       // 15
  r10.xyz = -C22.xyz + C255.y;                                           // 16
  r12 = (C255.xxxy == 0.0) ? C80.zxyy : C255.yyyy;                       // 17
  r0.x = dot(r1.xyz, r1.xyz);                                            // 18
  r2.xyz = -r2.zyx + C19.zyx;                                            // 19
  r7.w = dot(r5.xyz, r5.xyz);                                            // 20
  r8.zw = r0.zy * C255.w + C255.z;                                       // 21
  { float v = dot(r2.xyz, r2.xyz); r7.w = rsqrt(abs(r7.w)); r2.w = v; }  // 22
  r0.yzw = r7.w * r5.zyx;                                                // 23
  r7.w = dot(r8.wz, r8.wz) + C255.x;                                     // 24
  r4.xyz = r8.z * r4.zxy;                                                // 25
  r3.xyz = r8.w * r3.zxy + r4.xyz;                                       // 26
  { float v = -r7.w + C255.y; r0.x = rsqrt(abs(r0.x)); r7.w = v; }       // 27
  { float3 v = r0.x * r1.zyx; r7.w = sqrt(abs(r7.w)); r1.xyz = v; }      // 28
  r3.xyz = r1.xyz * r7.w + r3.xzy;                                       // 29
  { float v = dot(r3.xyz, r3.xyz); r7.w = sqrt(abs(r2.w)); r1.x = v; }   // 30
  { float v = r7.w - C67.x; r1.x = rsqrt(abs(r1.x)); r0.x = v; }         // 31
  r1.xyz = r3.zyx * r1.x;                                                // 32
  { float3 v = -r1.xyz + r6.xyz; r3.x = saturate(r6.w); r3.yzw = v; }    // 33
  r3.xyz = r3.yzw * r3.x + r1.xyz;                                       // 34
  { float v = dot(r3.xyz, r3.xyz); r1.y = rsqrt(abs(r2.w)); r1.x = v; }  // 35
  { float3 v = r2.xyz * r1.y; r1.x = rsqrt(abs(r1.x)); r2.xyz = v; }     // 36
  r4.xyz = r3.xyz * r1.x;                                                // 37
  r1.z = saturate(dot(r0.ywz, r4.zxy));                                  // 38
  r4.w = dot(r4.zxy, C80.zxy);                                           // 39
  r1.x = saturate(dot(r4.zxy, C80.zxy));                                 // 40
  { float v = dot(r4.zxyw, r12); r3.x = r9.x * r9.x; r0.y = v; }         // 41
  r0.yzw = -r4.zyx * r0.y + C80.zyx;                                     // 42
  { float v = saturate(dot(-r2.xzy, r0.ywz)); r3.y = r9.y * r9.y; r11.w = v; }  // 43
  { float4 v = r11 * r11; r3.z = r9.z * r9.z; r5 = v; }                  // 44
  { float v = r5.w * r5.w; r0.z = saturate(C23.w * r1.x); r0.y = v; }    // 45
  { float v = r0.z * r0.y; r3.w = r9.w * r9.w; r1.y = v; }               // 46
  { float3 v = r1.xzy * r1.wzw; r1.x = rcp(r3.w); r0.yzw = v; }          // 47
  { float3 v = r3.xyz * r1.x; r2.w = C87.z * r0.y; r1.xyz = v; }         // 48
  { float4 v = r0.yyww * C87.xyxy; r1.w = C87.z * r0.w; r4 = v; }        // 49
  if (VARIATION > 0.0) {
    // Value noise clusters around 0.5; stretch it so the tint reaches its ends.
    float n = saturate((Noise3(world_pos * (1.0 / VARIATION_SCALE)) - 0.5) * 2.2 + 0.5);
    float3 tint = lerp(float3(1.10, 1.04, 0.88), float3(0.90, 0.99, 1.10), n);
    r1.xyz *= lerp(1.0, tint, VARIATION);
  }
  r0.yzw = r0.z * r10.zyx + C22.zyx;                                     // 50
  r0.yzw = r0.wzy * r7.xyz + C20.xyz;                                    // 51
  r3.z = r1.z * r2.w;                                                    // 52
  { float2 v = r1.xy * r4.xy; ps = r5.z; r3.xy = v; }                    // 53
  { float2 v = r5.xy * r4.zw; r7.z = r1.w * ps; r7.xy = v; }             // 54
  r7.xyz = r3.xyz + r7.xyz;                                              // 55
  r7.xyz = r1.xyz * r0.yzw + r7.xyz;                                     // 56
  if (r0.x > 0.0) {                                                      // 4.1, p0
    { float v = saturate(dot(-r2.xzy, C66.zxy)); r1.x = C67.w * r0.x; r0.y = v; }  // 57
    { float4 t = TF4(r0.y); r0.yzw = t.xyz; }                            // 58
    r1.xyz = TF5(r1.x).xyz;                                              // 59
    r2.xyz = -r1.xyz + C255.y;                                           // 60
    { float3 v = r0.yzw - C68.xyz; r0.x = saturate(C67.z * r0.x); r0.yzw = v; }  // 61
    r0.xyz = r0.x * r0.wzy + C68.zyx;                                    // 62
    r2.xyz = r2.zyx * C28.y;                                             // 63
    r0.xyz = r2.xyz * r0.xyz - r7.zyx;                                   // 64
    r0.xyz = r7.zyx * r1.zyx + r0.xyz;                                   // 65
    r7.xyz = r0.zyx * C28.x + r7.xyz;                                    // 66
  }
  { float2 v = r8.xy * C50.xy; r0.x = -C15.z + r7.w; r0.yz = v; }        // 67
  r7.w = TF10(r0.yz).x;                                                  // 68
  float4 o;
  o.xyz = r7.xyz * C20.w;                                                // 69
  r7.x = saturate(-r0.x * C15.y + C255.y);                               // 70
  r7.x = r7.x + r7.w;                                                    // 71
  r7.x = (r7.x >= C255.y) ? 1.0 : 0.0;                                   // 72
  o.w = r7.x * r9.w;                                                     // 73
#if DEBUG_VIEW == 1
  o.xyz = Noise3(world_pos * (1.0 / VARIATION_SCALE)).xxx;
#endif
  AlphaTest(o.w);
  coverage = AlphaToMask(o.w, input.position.xy);
  return o * xe_color_exp_bias.x;
}
