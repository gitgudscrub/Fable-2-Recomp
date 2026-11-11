// Fable II lit opaque surfaces with a projected shadow map, pixel shader
// 648B965C200A5113: the Wraithmarsh pillars and ruins, dead trees, and other
// props lit by the sun with a 2x2 PCF shadow-map lookup. Replaces the SDK's
// translation through the shader_replace_dir cvar (see shaders/README.md).
//
// Stage 1: a literal port of the game's Xenos microcode (comments give the
// ucode instruction numbers). The layout follows lit.ps.hlsl: tf0 albedo
// (alpha in .x) through c8, tf1 a colour map through c9, tf2 a two-channel
// normal offset through c10, tangent frame v3 / v4 / v1, world position v2,
// view vector c19 - v2, screen-space shadow tf8 at the pixel position, the
// optional lightmap tf13 (b133), the environment cube tf14 (b134), and the
// distance fog beyond c67.x with the tf4 / tf5 ramps. New here:
//   - under b135, the world position goes through a shadow projection
//     (c32..c35, c48) and tf9 is read four times (point, +x, +y, +xy) and
//     compared with sge for a bilinear PCF term, biased by c114;
//   - two directional lights c80 / c81 (position + range in .w) with their
//     own falloffs c96, cones c98 / c99 / c105 / c107 and gains c94, c87, c88.
//
// Modern addition (STRETCH_*): see Wear() below. Some of these props map a
// whole face to a handful of albedo texels (the pillar shafts), so a
// world-space wear pattern is blended in where the albedo is magnified far
// beyond what any texture pack can fill.
// Xenos reading notes are in xe_common.hlsli.

#ifndef DEBUG_VIEW
#define DEBUG_VIEW 0
#endif
#ifndef WEAR
#define WEAR 0.6
#endif
#ifndef STRETCH_START
#define STRETCH_START 12.0  // screen pixels per albedo texel where wear starts
#endif
#ifndef STRETCH_FULL
#define STRETCH_FULL 32.0   // ... and where it is fully on
#endif
#ifndef STRETCH_TEXELS
#define STRETCH_TEXELS 1024.0  // assumed albedo size (the pack's are 1024-2048)
#endif

#define XE_FLOAT_CONSTANTS 36
#define XE_DESCRIPTOR_INDICES 7
#include "xe_common.hlsli"

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
#define C32 K[13]
#define C33 K[14]
#define C34 K[15]
#define C35 K[16]
#define C48 K[17]
#define C49 K[18]
#define C66 K[19]
#define C67 K[20]
#define C68 K[21]
#define C80 K[22]
#define C81 K[23]
#define C87 K[24]
#define C88 K[25]
#define C94 K[26]
#define C96 K[27]
#define C98 K[28]
#define C99 K[29]
#define C105 K[30]
#define C107 K[31]
#define C112 K[32]
#define C114 K[33]
#define C254 K[34]
#define C255 K[35]

// Texture bindings of this shader, in the translator's order.
#define TF2(uv) Fetch(2, 0, uv, false)
#define TF0(uv) Fetch(0, 1, uv, false)
#define TF1(uv) Fetch(1, 2, uv, false)
#define TF8(uv) Fetch(8, 3, uv, false)
#define TF9(uv, o) FetchOffset(9, 4, uv, o)
#define TF13(uv) Fetch(13, 5, uv, false)
#define TF14(stf) FetchCube(14, 6, stf)
#define TF4(x) Fetch(4, 7, float2(x, 0.0), true)
#define TF5(x) Fetch(5, 8, float2(x, 0.0), true)

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
// Multiplier (0..1, mostly near 1) that darkens a stretched surface with
// grime, mottling and cracks, from the world position in metres.
float Wear(float3 p) {
  float grime = Noise3(p * 1.5);                       // ~0.7 m patches
  float mottle = Noise3(p * 12.0) * 0.6 + Noise3(p * 37.0) * 0.4;  // cm detail
  // Cracks: the mid-level contour of a domain-warped noise, so the lines
  // wander like fractures instead of closing into round loops.
  float3 q = p + 0.3 * (float3(Noise3(p * 5.0 + 11.0), Noise3(p * 5.0 + 23.0),
                               Noise3(p * 5.0 + 41.0)) - 0.5);
  float ridge = 1.0 - abs(Noise3(q * 2.5 + 7.3) * 2.0 - 1.0);     // ridged noise
  float crack = smoothstep(0.93, 1.0, ridge)           // thin lines...
              * smoothstep(0.4, 0.7, Noise3(p * 0.7 + 3.1));  // ...only in some areas
  float w = 1.0;
  w -= 0.25 * smoothstep(0.35, 0.8, grime);            // darker grime patches
  w -= 0.18 * (mottle - 0.5);                          // +-9% mottling
  w -= 0.35 * crack;
  return saturate(w);
}

float4 main(PSInput7 input, out uint coverage : SV_Coverage) : SV_Target0 {
  float4 r0 = input.v0, r1 = input.v1, r2 = input.v2, r3 = input.v3;
  float4 r4 = input.v4, r5 = input.v5, r6 = input.v6;
  float4 r7 = 0.0, r8 = 0.0, r9 = 0.0, r10 = 0.0, r11 = 0.0, r12 = 0.0, r13 = 0.0, r14 = 0.0;
  float ps = 0.0;
  r7.xy = GuestPixelPosition(input.position, input.front_face);

  r0.zw = r0.yx * C9.yx + C9.wz;                                         // 14
  r8.xy = r0.yx * C8.yx + C8.wz;                                         // 15
  r8.zw = r0.yx * C10.yx + C10.wz;                                       // 16
  r9.xy = TF2(r8.wz).xy;                                                 // 17
  float2 albedo_uv = r8.yx;  // the uv before the fetch overwrites r8 (Modern: stretch)
  { float4 t = TF0(r8.yx); r8 = t.wxyz; }                                // 18
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
  float wear = wear_mask > 0.0 ? Wear(r2.xyz) : 1.0;  // skip the noise where it is off
  r8.yzw *= lerp(1.0, wear, wear_mask);
  r11.xyz = TF1(r0.wz).xyz;                                              // 19
  r1.w = dot(r1.xyz, r1.xyz);                                            // 20
  r10.xyz = C19.zyx - r2.zyx;                                            // 21
  { float3 v = r8.yzw * r8.yzw; r11.x = r11.x * r11.x; r8.yzw = v; }     // 22
  { float v = dot(r10.xyz, r10.xyz); r11.y = r11.y * r11.y; r0.z = v; }  // 23
  { float2 v = r9.yx * C255.xx + C254.zz; r9.x = v.x; r9.w = v.y; }      // 24
  r0.w = r9.w * r9.w + r9.x * r9.x + C254.x;                             // 25
  { float3 v = r9.x * r4.zxy; r11.z = r11.z * r11.z; r9.xyz = v; }       // 26
  r9.xyz = r9.w * r3.zxy + r9.xyz;                                       // 27
  { float v = C254.y - r0.w; r1.w = rsqrt(abs(r1.w)); r0.w = v; }        // 28
  { float3 v = r1.w * r1.zyx; r0.w = sqrt(abs(r0.w)); r12.xyz = v; }     // 29
  r9.xyz = r12.xyz * r0.w + r9.xzy;                                      // 30
  { float v = dot(r9.xyz, r9.xyz); r1.w = rsqrt(abs(r0.z)); r0.w = v; }  // 31
  { float3 v = r10.zyx * r1.w; r0.w = rsqrt(abs(r0.w)); r10.xyz = v; }   // 32
  { float3 v = r9.xyz * r0.w; r0.z = sqrt(abs(r0.z)); r9.xyz = v; }      // 33
  if (XeBool(128)) {
    r0.w = r8.x * r8.x;                                                  // 34
    r0.w = rcp(r0.w);                                                    // 35
    r8.yzw = r8.yzw * r0.w;                                              // 36
  }
  r7.xy = abs(r7.xy) * C0.zw + C0.xy;                                    // 37
  r6.w = TF8(r7.xy).x;                                                   // 38
  r12.x = log2(abs(r6.x));                                               // 39
  { float3 v = C254.y - C22.xyz; r6.w = C254.y - r6.w; r13.xyz = v; }    // 40
  { float3 v = r8.yzw * C27.w; r12.y = log2(abs(r6.y)); r7.xyz = v; }    // 41
  { float v = dot(r5.xyz, r5.xyz); r12.z = log2(abs(r6.z)); r6.x = v; }  // 42
  { float3 v = r12.xyz * C21.w; r6.x = rsqrt(abs(r6.x)); r12.xyz = v; }  // 43
  { float2 v = r6.w * C112.yx; r12.x = exp2(r12.x); r6.yz = v; }         // 44
  { float3 v = r6.x * r5.zyx; r12.y = exp2(r12.y); r5.xyz = v; }         // 45
  { float v = saturate(dot(r5.xzy, r9.xzy)); r12.z = exp2(r12.z); r6.x = v; }  // 46
  { float3 v = r12.xyz * C21.xyz; r6.x = r6.x * r6.x; r12.xyz = v; }     // 47
  r5.xyz = r6.x * r13.xyz + C22.xyz;                                     // 48
  r5.xyz = r12.xyz * r5.xyz + C20.xyz;                                   // 49
  r5.xyz = r7.xyz * r5.xyz;                                              // 50
  if (XeBool(135)) {
    r14 = float4(C254.x == 0.0 ? r2.z : C254.y, C254.x == 0.0 ? r2.x : C254.y,
                 C254.x == 0.0 ? r2.y : C254.y, C254.y == 0.0 ? r2.y : C254.y);  // 51
    { float v = dot(C32.zxyw, r14); r7.x = rcp(C48.x); r7.z = v; }       // 52
    { float v = dot(C35.zxyw, r14); r7.y = rcp(C48.y); r6.x = v; }       // 53
    { float v = dot(C33.zxyw, r14); r6.x = rcp(r6.x); r7.w = v; }        // 54
    r13 = r7 * r6.x;                                                     // 55
    r12.x = TF9(r13.zw, int2(0, 0)).x;                                   // 56
    r12.y = TF9(r13.zw, int2(0, 1)).x;                                   // 57
    r12.z = TF9(r13.zw, int2(1, 0)).x;                                   // 58
    r12.w = TF9(r13.zw, int2(1, 1)).x;                                   // 59
    r6.w = dot(C34.zxyw, r14);                                           // 60
    r7.xy = r13.xy * r7.zw;                                              // 61
    { float2 v = frac(r7.yx); ps = r6.w; r7.yz = v; }                    // 62
    { float v = C254.y - r7.y; r7.w = r6.x * ps; r7.x = v; }             // 63
    { float2 v = C254.y - r7.wz; r6.x = v.x; r6.w = v.y; }               // 64
    r12 = float4(r6.x >= r12.x ? 1.0 : 0.0, r6.x >= r12.y ? 1.0 : 0.0,
                 r6.x >= r12.z ? 1.0 : 0.0, r6.x >= r12.w ? 1.0 : 0.0);  // 65
    r12.xy = r6.w * r12.xy;                                              // 66
    r12.zw = r12.zw * r7.z;                                              // 67
    r6.x = dot(r12.wyxz, r7.yyxx);                                       // 68
    r6.x = C254.y - r6.x;                                                // 69
    { float2 v = r6.x * C114.xy; r6.x = v.x; r6.w = v.y; }               // 70
    r6.yz = max(r6.yz, r6.wx);                                           // 71
  }
  r7.xyz = -r2.xyz * C81.w + C81.xyz;                                    // 72
  { float3 v = -r2.xyz * C80.w + C80.xyz; r2.x = v.x; r2.y = v.y; r2.w = v.z; }  // 73
  r0.w = dot(r2.wxy, r2.wxy);                                            // 74
  { float v = dot(r7.xyz, r7.xyz); r6.x = sqrt(abs(r0.w)); r6.w = v; }   // 75
  { float v = C254.y - r6.y; r6.y = rsqrt(abs(r6.w)); r2.z = v; }        // 76
  { float3 v = r7.xyz * r6.y; r6.y = rsqrt(abs(r0.w)); r13.xyz = v; }    // 77
  { float3 v = r2.xyw * r6.y; r6.w = sqrt(abs(r6.w)); r7.yzw = v; }      // 78
  r12.xy = saturate(-r6.xw * C96.xy + C254.y);                           // 79
  r6.x = dot(r7.wyz, C98.zxy);                                           // 80
  r12.z = dot(r9.xzy, r7.wyz);                                           // 81
  r2.x = saturate(dot(r9.xzy, r7.wyz));                                  // 82
  r2.y = saturate(dot(r9.xzy, r13.zxy));                                 // 83
  { float v = dot(r9.xzy, r13.zxy); r7.x = saturate(C23.w * r2.x); r12.w = v; }  // 84
  { float v = dot(r13.zxy, C99.zxy); r6.w = r12.z + r12.z; r6.y = v; }   // 85
  { float2 v = r6.yx - C105.yx; r0.w = r12.w + r12.w; r6.xy = v; }       // 86
  r13.xyz = -r9.xyz * r0.w + r13.zyx;                                    // 87
  { float3 v = -r9.xyz * r6.w + r7.wzy; r7.yzw = v; }                    // 88
  { float v = saturate(dot(-r10.zxy, r7.ywz)); r12.z = saturate(C107.x * r6.y); r7.y = v; }  // 89
  { float v = saturate(dot(-r10.zxy, r13.xzy)); r12.w = saturate(C107.y * r6.x); r7.z = v; }  // 90
  r6.xy = r12.zw * r12.xy + C254.z;                                      // 91
  r12.xy = r6.yx * C94.yx + C254.y;                                      // 92
  { float2 v = r7.yz * r7.yz; ps = r12.x; r6.xy = v; }                   // 93
  { float2 v = r6.xy * r6.xy; r6.w = r2.z * ps; r6.xy = v; }             // 94
  { float v = r6.w * r2.y; r7.y = saturate(C23.w * r2.y); r6.w = v; }    // 95
  { float2 v = r7.xy * r6.xy; r12.w = C254.y - r6.z; r7.xy = v; }        // 96
  { float v = r7.x * r12.w; r13.x = C88.x * r6.w; r12.z = v; }           // 97
  { float2 v = r12.yz * r12.wy; r13.y = C88.y * r6.w; r7.zw = v; }       // 98
  { float2 v = r7.yz * r2.zx; r13.z = C88.z * r6.w; r6.xy = v; }         // 99
  r2.xyz = r6.y * C87.xyz + r13.xyz;                                     // 100
  r6.x = r6.x * r12.x;                                                   // 101
  r6.xyz = r6.x * C88.xyz;                                               // 102
  r6.xyz = r7.w * C87.xyz + r6.xyz;                                      // 103
  r6.xyz = r11.xyz * r6.xyz + r5.xyz;                                    // 104
  r2.xyz = r2.xyz * r8.yzw + r6.xyz;                                     // 105
  if (XeBool(133)) {
    r6.xyz = TF13(r0.xy).xyz;                                            // 106
    r6.xyz = r6.xyz * r6.xyz;                                            // 107
    r2.xyz = r6.xyz * C24.z + r2.xyz;                                    // 108
  }
  if (XeBool(134)) {
    r6.x = dot(-r10.zxy, r9.xzy);                                        // 109
    r6.x = r6.x + r6.x;                                                  // 110
    { float3 v = -r9.xzy * r6.x - r10.zxy; r6.x = v.x; r6.y = v.y; r6.w = v.z; }  // 111
    { float3 v = r6.y * r3.zxy; r0.x = v.x; r0.y = v.y; r0.w = v.z; }    // 112
    r6.xyz = r6.x * r1.zxy + float3(r0.x, r0.y, r0.w);                   // 113
    r6.z = -r6.w * r4.y - r6.z;                                          // 114
    r6.xy = r6.w * r4.xz + r6.yx;                                        // 115
    r6 = XeCube(r6.xyz);                                                 // 116
    { float v = r6.w; r0.x = rcp(abs(r6.z)); r0.w = v; }                 // 117
    r0.xy = r6.yx * r0.x + C254.w;                                       // 118
    r6.xyz = TF14(float3(r0.x, r0.y, r0.w)).xyz;                         // 119
    r6.xyz = r6.xyz * r6.xyz;                                            // 120
    r2.xyz = r11.xyz * r6.xyz + r2.xyz;                                  // 121
  }
  r6.x = r0.z - C67.x;                                                   // 122
  r6.yzw = r2.xyz * C49.xyz;                                             // 123
  if (r6.x > 0.0) {                                                      // p0
    { float v = saturate(dot(-r10.zxy, C66.zxy)); r0.w = C67.w * r6.x; r0.x = v; }  // 124
    r0.xyz = TF4(r0.x).xyz;                                              // 125
    r1.xyz = TF5(r0.w).xyz;                                              // 126
    r2.xyz = C254.y - r1.xyz;                                            // 127
    { float3 v = r0.xyz - C68.xyz; r6.x = saturate(C67.z * r6.x); r0.xyz = v; }  // 128
    r0.xyz = r6.x * r0.zyx + C68.zyx;                                    // 129
    r2.xyz = r2.xyz * C28.y;                                             // 130
    r0.xyz = r2.xyz * r0.zyx - r6.yzw;                                   // 131
    r0.xyz = r6.yzw * r1.xyz + r0.xyz;                                   // 132
    r6.yzw = r0.xyz * C28.x + r6.yzw;                                    // 133
  }
  r0.xyz = C20.w * C26.xyz;                                              // 134
  float4 o = float4(r0.xyz * r6.yzw, C26.w * r8.x);                      // 135
#if DEBUG_VIEW == 1
  // R wear mask, G stretch / 32, B the wear pattern.
  o.xyz = float3(wear_mask, stretch / 32.0, wear);
#elif DEBUG_VIEW == 2
  o.xyz = 1.0;  // which surfaces this shader draws
#elif DEBUG_VIEW == 3
  // R/G the albedo uv wrapped 16x (stripes show tiling), B texels per pixel / 8.
  o.xyz = float3(frac(r8.y * 16.0), frac(r8.x * 16.0), saturate(max(duv.x, duv.y) / 8.0));
#endif
  AlphaTest(o.w);
  coverage = AlphaToMask(o.w, input.position.xy);
  return o * xe_color_exp_bias.x;
}
