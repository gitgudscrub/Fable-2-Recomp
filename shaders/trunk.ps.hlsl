// Fable II tree trunks (and the second foliage layer), pixel shader
// 00E09D1BC5295D52. Replaces the SDK's translation through the
// shader_replace_dir cvar (see shaders/README.md).
//
// Stage 1: a literal port of the game's Xenos microcode (comments give the
// ucode instruction numbers). What the original does:
//   - UV transforms c8 (bark albedo, tf0) and c10 (2-channel normal map,
//     tf2); the screen-space shadow buffer tf8 at the pixel position (c0);
//   - albedo squared (guest gamma) divided by its alpha; a tangent-space
//     normal from v3/v4 and the vertex normal v1 (c255.x / c254 unpack);
//   - v5 is a per-vertex direction whose N.V^2 blends the sky colour c22
//     towards white (a hemisphere term); v8 holds per-vertex light terms
//     raised to c21.w and scaled by c21, the same as the lit opaque shader;
//   - sun: N.L (c80) * shadow * c87, plus the ambient (c27.w, c49 tint);
//   - optional fog (b132: v6 scale, v7 offset) and the cloud-plane shadow
//     (b129; the same code as in the leaves shader), c26 tint, c15.w alpha.
// Xenos reading notes are in xe_common.hlsli.

#ifndef DEBUG_VIEW
#define DEBUG_VIEW 0
#endif
// Improvements (0 = original look):
// VARIATION: low-frequency warm/cool variation of the bark colour from the
//   world position, so a stand of trees is not one repeated colour (0 =
//   off, 1 = +-8% tint); VARIATION_SCALE is in metres, larger than the
//   leaves' so one trunk stays one colour.
#ifndef VARIATION
#define VARIATION 0.8
#endif
#ifndef VARIATION_SCALE
#define VARIATION_SCALE 6.0
#endif

// --- SDK translator interface (shaders/xe_common.hlsli) -------------------
#define XE_FLOAT_CONSTANTS 21
#define XE_DESCRIPTOR_INDICES 4
#include "xe_common.hlsli"

#define C0 K[0]
#define C8 K[1]
#define C10 K[2]
#define C15 K[3]
#define C19 K[4]
#define C20 K[5]
#define C21 K[6]
#define C22 K[7]
#define C26 K[8]
#define C27 K[9]
#define C28 K[10]
#define C49 K[11]
#define C72 K[12]
#define C73 K[13]
#define C74 K[14]
#define C75 K[15]
#define C76 K[16]
#define C80 K[17]
#define C87 K[18]
#define C254 K[19]
#define C255 K[20]

// Texture bindings of this shader, in the translator's order.
#define TF8(uv) Fetch(8, 0, uv, false)
#define TF0(uv) Fetch(0, 1, uv, false)
#define TF2(uv) Fetch(2, 2, uv, false)
#define TF12(uv) Fetch(12, 3, uv, false)
#define TF11(uv) Fetch(11, 4, uv, false)

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

float4 main(PSInput9 input, out uint coverage : SV_Coverage) : SV_Target0 {
  float4 r0 = input.v0, r1 = input.v1, r2 = input.v2, r3 = input.v3, r4 = input.v4;
  float4 r5 = input.v5, r6 = input.v6, r7 = input.v7, r8 = input.v8;
  float4 r9 = 0.0, r10 = 0.0, r11 = 0.0, r12 = 0.0;
  float ps = 0.0;
  r9.xy = GuestPixelPosition(input.position, input.front_face);
  float3 world_pos = r2.xyz;

  r10.yz = r0.yx * C10.yx + C10.wz;                                      // 10
  r0.xy = r0.yx * C8.yx + C8.wz;                                         // 11
  r0.zw = abs(r9.xy) * C0.zw + C0.xy;                                    // 12
  r10.x = TF8(r0.zw).x;                                                  // 13
  { float4 t = TF0(r0.yx); r0 = t.wxyz; }                                // 14
  r9.xy = TF2(r10.zy).xy;                                                // 15
  r6.xyz = r6.zyx * C49.zyx;                                             // 16
  r11.xyz = -C22.xyz + C254.x;                                           // 17
  { float v = dot(r1.xyz, r1.xyz); r12.x = log2(abs(r8.x)); r1.w = v; }  // 18
  { float v = dot(r5.xyz, r5.xyz); r12.y = log2(abs(r8.y)); r2.w = v; }  // 19
  r10.yz = r9.yx * C255.x + C254.z;                                      // 20
  { float4 v = r0.yzwx * r0.yzwx; r0.y = rsqrt(abs(r2.w)); r9 = v; }     // 21
  { float3 v = r0.y * r5.zyx; r12.z = log2(abs(r8.z)); r5.xyz = v; }     // 22
  r8.w = dot(r10.zy, r10.zy) + C254.y;                                   // 23
  { float3 v = r12.xyz * C21.w; r1.w = rsqrt(abs(r1.w)); r0.yzw = v; }   // 24
  { float3 v = r10.y * r4.zxy; r0.y = exp2(r0.y); r8.xyz = v; }          // 25
  r8.xyz = r10.z * r3.zxy + r8.xyz;                                      // 26
  { float v = -r8.w + C254.x; r0.z = exp2(r0.z); r8.w = v; }             // 27
  { float3 v = r1.w * r1.zyx; r8.w = sqrt(abs(r8.w)); r1.xyz = v; }      // 28
  r8.yzw = r1.xyz * r8.w + r8.xzy;                                       // 29
  { float v = dot(r8.yzw, r8.yzw); r0.w = exp2(r0.w); r8.x = v; }        // 30
  { float3 v = r0.yzw * C21.xyz; r8.x = rsqrt(abs(r8.x)); r0.yzw = v; }  // 31
  r8.yzw = r8.wzy * r8.x;                                                // 32
  r8.x = saturate(dot(r8.wyz, C80.zxy));                                 // 33
  r8.y = saturate(dot(r5.xzy, r8.wyz));                                  // 34
  { float v = r8.x * r10.x; r8.y = r8.y * r8.y; r10.y = v; }             // 35
  r8.yzw = r8.y * r11.xyz + C22.xyz;                                     // 36
  r0.yzw = r0.yzw * r8.yzw + C20.xyz;                                    // 37
  { float3 v = r10.yyx * C87.yzx; r1.x = rcp(r9.w); r8.yzw = v; }        // 38
  { float3 v = r9.xyz * r1.x; ps = r8.w; r1.xyz = v; }                   // 39
  if (VARIATION > 0.0) {
    // Value noise clusters around 0.5; stretch it so the tint reaches its ends.
    float n = saturate((Noise3(world_pos * (1.0 / VARIATION_SCALE)) - 0.5) * 2.2 + 0.5);
    float3 tint = lerp(float3(1.10, 1.03, 0.90), float3(0.90, 0.98, 1.10), n);
    r1.xyz *= lerp(1.0, tint, VARIATION);
  }
  { float3 v = r1.zyx * r0.wzy; r8.x = r8.x * ps; r0.yzw = v; }          // 40
  r8.xyz = r1.xyz * r8.xyz;                                              // 41
  r8.xyz = r0.yzw * C27.w + r8.zyx;                                      // 42
  r0.yzw = r8.zyx * C49.xyz;                                             // 43
  if (XeBool(132)) {                                                     // 3.1
    r0.yzw = r6.zyx * r8.zyx + r7.xyz;                                   // 44
    if (XeBool(129)) {                                                   // 4.1
      r1.xyz = r2.xyz - C19.xyz;                                         // 45
      r3.x = (r1.z >= 0.0) ? C254.y : C254.x;                            // 46
      r3.w = (r1.z >= 0.0) ? C254.x : C254.y;
      r8.xy = (-abs(r3.w) >= 0.0) ? r2.xy : C19.xy;                      // 47
      r8.xy = r8.xy * C74.xy + C74.zw;                                   // 48
      r8.y = TF12(r8.xy).x;                                              // 49
      { float v = -C19.z + C76.y; r8.x = C76.x * r8.y; r8.z = v; }       // 50
      { float v = r8.z + r8.x; r8.y = rcp(r1.z); r8.z = v; }             // 51
      r8.y = r8.z * r8.y;                                                // 52
      r3.y = (C254.x > r8.y) ? 1.0 : 0.0;                                // 53
      { float v = r3.y + abs(r3.w); r3.z = (r8.y >= 0.0) ? 1.0 : 0.0; r8.z = v; }  // 54
      r8.w = abs(r3.x) + r3.z;                                           // 55
      r8.zw = (r8.zw != C254.yy) ? 1.0 : 0.0;                            // 56
      r8.z = r8.w * r8.z;                                                // 57
      { float v = r8.x + C76.y; r8.x = v; }                              // 58
      if (r8.z != 0.0) {                                                 // 6.1 (!p0)
        r3.xy = r3.xy * r3.zw;                                           // 59
        r8.yzw = r8.y * r1.xyz + C19.xyz;                                // 60
        r1.xyz = (r3.y == 0.0) ? r2.xyz : r8.yzw;                        // 61
        r3.xyz = (r3.x == 0.0) ? C19.xyz : r8.yzw;                       // 62
        r2.xy = r3.xy * C73.xy;                                          // 63
        r2.zw = r1.yx * C73.yx;                                          // 64
        r2 = r2 + C73.zwwz;                                              // 65
        r8.yz = r2.yx + r2.zw;                                           // 66
        r8.yz = r8.zy * C254.w;                                          // 67
        r2.z = TF11(r2.xy).x;                                            // 68
        r2.w = TF11(r8.yz).x;                                            // 69
        r8.w = C75.x * C254.w;                                           // 70
        r1.w = -C75.y + C254.x;                                          // 71
        r8.y = r8.x - r3.z;                                              // 72
        { float3 v = r1.xyz - r3.xyz; ps = r8.x; r3.xyz = v; }           // 73
        { float v = dot(r3.xyz, r3.xyz); r8.z = ps - r1.z; r8.x = v; }   // 74
        r2.xy = saturate(r8.yz * C76.w);                                 // 75
        { float2 v = r2.xz + r2.yw; r1.x = sqrt(abs(r8.x)); r1.yz = v; } // 76
        r8.yz = r1.xz * C254.w;                                          // 77
        r8.xyz = r8.zyw * r1.wyz;                                        // 78
        { float v = r8.x + C75.y; r8.y = r8.y - r8.z; r8.x = v; }        // 79
        r8.x = r8.y * r8.x;                                              // 80
        r8.x = max(r8.x, C254.y);                                        // 81
        r8.x = C76.z * r8.x;                                             // 82
        r8.y = exp2(r8.x);                                               // 83
        r8.x = C254.x - r8.y;                                            // 84
        r8.xzw = r8.x * C72.zyx;                                         // 85
        r8.xzw = r8.wzx * C28.y;                                         // 86
        r0.yzw = r0.yzw * r8.y + r8.xzw;                                 // 87
      }
    }
  }
  { float3 v = C20.w * C26.xyz; r8.x = C26.w * r0.x; r8.yzw = v; }       // 88
  float4 o = float4(r8.yzw * r0.yzw, C15.w * r8.x);                      // 89
#if DEBUG_VIEW == 1
  o.xyz = Noise3(world_pos * (1.0 / VARIATION_SCALE)).xxx;
#endif
  AlphaTest(o.w);
  coverage = AlphaToMask(o.w, input.position.xy);
  return o * xe_color_exp_bias.x;
}
