// Fable II lit opaque surfaces with four lights, pixel shader
// 789266C3E42D7E59: the town's walls and stonework near lanterns
// (Bowerstone Market's castle wall), the four-light version of lit.ps.hlsl.
// Built only for Project Sparrow (tools/shaders/build_replace.py --sparrow).
//
// Stage 1: a literal port of the game's Xenos microcode (comments give the
// ucode instruction numbers). What the original does:
//   - UV transforms c8 / c9 / c10 on v0: tf0 albedo (alpha in .x), tf1 the
//     specular colour map (squared), tf2 two-channel normal map; tangent
//     frame v3 / v4 / v1; world position v2, camera c19;
//   - ambient: per-vertex light v6 raised to c21.w and tinted by c21.xyz, a
//     sky term from v5 and c22, plus c20; albedo scale c27.w;
//   - four lights c80..c83 (colours c87..c90, range c96, spot c98..c101 /
//     c105 / c107 / c94); c112 picks the sun's slot, dimmed by the screen
//     shadow tf8; under b135 the projected shadow tf9 dims slot c114;
//     diffuse N.L and a Phong specular (V.R)^4 * saturate(c23.w * N.L)
//     times the specular map;
//   - optional lightmap tf13 (b133, c24.z), environment cube tf14 (b134)
//     times the specular map; fog beyond c67.x; output * c20.w * c26,
//     alpha c26.w * albedo alpha (alpha test and alpha to coverage).
// Sparrow (Command Hub f20, option 1): the game's specular map stays the
// specular colour, but the lobe is GGX with Fresnel (sparrow_common.hlsli),
// plus a damped sky reflection.
// Xenos reading notes are in xe_common.hlsli.

#ifndef SPARROW_SKY_REFLECT
#define SPARROW_SKY_REFLECT 1.0
#endif

// --- SDK translator interface (shaders/xe_common.hlsli) -------------------
#define XE_FLOAT_CONSTANTS 42
#define XE_DESCRIPTOR_INDICES 7
#include "xe_common.hlsli"
#if SPARROW
#include "sparrow_common.hlsli"
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
#define C82 K[24]
#define C83 K[25]
#define C87 K[26]
#define C88 K[27]
#define C89 K[28]
#define C90 K[29]
#define C94 K[30]
#define C96 K[31]
#define C98 K[32]
#define C99 K[33]
#define C100 K[34]
#define C101 K[35]
#define C105 K[36]
#define C107 K[37]
#define C112 K[38]
#define C114 K[39]
#define C254 K[40]
#define C255 K[41]

// Texture bindings of this shader, in the translator's order.
#define TF2(uv) Fetch(2, 0, uv, false)
#define TF0(uv) Fetch(0, 1, uv, false)
#define TF1(uv) Fetch(1, 2, uv, false)
#define TF8(uv) Fetch(8, 3, uv, false)
#define TF9_OFF(uv, ox, oy) FetchOffset(9, 4, uv, int2(ox, oy))
#define TF13(uv) Fetch(13, 5, uv, false)
#define TF14(stf) FetchCube(14, 6, stf)
#define TF4(x) Fetch(4, 7, float2(x, 0.0), true)
#define TF5(x) Fetch(5, 8, float2(x, 0.0), true)

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


float4 Ge4(float a, float4 b) { return float4(a >= b.x, a >= b.y, a >= b.z, a >= b.w); }

float4 main(PSInput7 input, out uint coverage : SV_Coverage) : SV_Target0 {
  float4 r0 = input.v0, r1 = input.v1, r2 = input.v2, r3 = input.v3;
  float4 r4 = input.v4, r5 = input.v5, r6 = input.v6;
  float4 r7 = 0.0, r8 = 0.0, r9 = 0.0, r10 = 0.0, r11 = 0.0, r12 = 0.0, r13 = 0.0;
  float4 r14 = 0.0, r15 = 0.0, r16 = 0.0, r17 = 0.0;
  r7.xy = GuestPixelPosition(input.position, input.front_face);
#if SPARROW
  // Sparrow: surface relief (the textures read where the view ray meets the
  // colour's height field; not on characters).
  SPARROW_RELIEF_APPLY(Lit, input.v0.xy, C8.xy, input.v2.xyz, C19.xyz, LIT_RELIEF_DEPTH)
#endif

  r0.zw = r0.yx * C9.yx + C9.wz;                                         // 16
  r8.xy = r0.yx * C8.yx + C8.wz;                                         // 17
  r8.zw = r0.yx * C10.yx + C10.wz;                                       // 18
  r10.xy = TF2R(r8.wz).xy;                                                // 19
  { float4 t = TF0R(r8.yx); r8 = t.wxyz; }                                // 20
  float3 sp_albedo = r8.yzw * r8.yzw;  // Sparrow: colour map, linear (character material)
  r12.xyz = TF1R(r0.wz).xyz;                                              // 21
  r1.w = dot(r1.zxy, r1.zxy);                                            // 22
  r9.xyz = -r2.zyx + C19.zyx;                                            // 23
  { float3 v = r8.yzw * r8.yzw; r8.y = r12.x * r12.x; r11.xyz = v; }     // 24
  { float v = dot(r9.xzy, r9.xzy); r8.z = r12.y * r12.y; r0.z = v; }     // 25
  { float2 v = r10.yx * C255.x + C254.z; r10.x = v.x; r10.w = v.y; }     // 26
  r0.w = dot(r10.wx, r10.wx) + C254.x;                                   // 27
  r10.xyz = r10.x * r4.zxy; r8.w = r12.z * r12.z;                        // 28
  r10.xyz = r10.w * r3.zxy + r10.xyz;                                    // 29
  r0.w = -r0.w + C254.y; r1.w = rsqrt(abs(r1.w));                        // 30
  r12.xyz = r1.w * r1.zyx; r0.w = sqrt(abs(r0.w));                       // 31
  r10.xyz = r12.xyz * r0.w + r10.xzy;                                    // 32
  { float v = dot(r10.xzy, r10.xzy); r1.w = rsqrt(abs(r0.z)); r0.w = v; }  // 33
  { float3 v = r9.zyx * r1.w; r0.w = rsqrt(abs(r0.w)); r9.xyz = v; }     // 34
  r10.xyz = r10.xyz * r0.w; r0.z = sqrt(abs(r0.z));                      // 35
  if (XeBool(128)) {
    r0.w = r8.x * r8.x;                                                  // 36
    r0.w = rcp(r0.w);                                                    // 37
    r11.xyz = r11.xyz * r0.w;                                            // 38
  }
  r7.xy = abs(r7.xy) * C0.zw + C0.xy;                                    // 39
  r6.w = TF8(r7.xy).x;                                                   // 40
  r7.x = log2(abs(r6.x));                                                // 41
  r13.xyz = -C22.xyz + C254.y; r0.w = C254.y - r6.w;                     // 42
  r12.xyz = r11.xyz * C27.w; r7.y = log2(abs(r6.y));                     // 43
  r1.w = dot(r5.zxy, r5.zxy); r7.z = log2(abs(r6.z));                    // 44
  { float3 v = float3(r7.y, r7.x, r7.z) * C21.w; r6.z = rsqrt(abs(r1.w)); r6.x = v.x; r6.y = v.y; r6.w = v.z; }  // 45
  r7 = r0.w * C112; r6.y = exp2(r6.y);                                   // 46
  { float3 v = r6.z * r5.zyx; r6.z = exp2(r6.x); r5.xyz = v; }           // 47
  r6.x = saturate(dot(r5.xzy, r10.xzy)); r6.w = exp2(r6.w);              // 48
  r5.xyz = r6.yzw * C21.xyz; r6.x = r6.x * r6.x;                         // 49
  r6.xyz = r6.x * r13.xyz + C22.xyz;                                     // 50
  r6.xyz = r5.xyz * r6.xyz + C20.xyz;                                    // 51
  float sky_vis = -1.0;
#if SPARROW
  if (SparrowActive()) {
    float3 sun = C87.xyz * C112.x + C88.xyz * C112.y + C89.xyz * C112.z + C90.xyz * C112.w;
    r6.xyz = SparrowAmbient(r6.xyz, input.v2.xyz, r10.zyx, sun, sky_vis);
  }
#endif
  float3 ambient = r6.xyz;  // Sparrow: the ambient light
  r6.yzw = r12.xyz * r6.xyz;                                             // 52
  if (XeBool(135)) {
    r14 = float4(C254.x == 0.0 ? r2.z : C254.y, C254.x == 0.0 ? r2.x : C254.y,  // 53
                 C254.x == 0.0 ? r2.y : C254.y, C254.y == 0.0 ? r2.y : C254.y);
    r5.z = dot(C32.zxyw, r14); r5.x = rcp(C48.x);                        // 54
    r6.x = dot(C35.zxyw, r14); r5.y = rcp(C48.y);                        // 55
    { float v = dot(C33.zxyw, r14); r6.x = rcp(r6.x); r5.w = v; }        // 56
    r13 = r5 * r6.x;                                                     // 57
    r12.x = TF9_OFF(r13.zw, 0, 0).x;                                     // 58
    r12.y = TF9_OFF(r13.zw, 0, 1).x;                                     // 59
    r12.z = TF9_OFF(r13.zw, 1, 0).x;                                     // 60
    r12.w = TF9_OFF(r13.zw, 1, 1).x;                                     // 61
    r0.w = dot(C34.zxyw, r14);                                           // 62
    r5.xy = r13.xy * r5.zw;                                              // 63
    { float2 v = frac(float2(r5.y, r5.x)); r5.y = v.x; r5.z = v.y; }     // 64
    r5.x = -r5.y + C254.y; r5.w = r0.w * r6.x;                           // 65
    r13.xy = -r5.wz + C254.y;                                            // 66
    r12 = Ge4(r13.x, r12);                                               // 67
    r12.xy = r13.y * r12.xy;                                             // 68
    r12.zw = r12.zw * r5.z;                                              // 69
    r6.x = dot(r12.wyxz, r5.yyxx);                                       // 70
    r6.x = C254.y - r6.x;                                                // 71
    r5 = r6.x * C114;                                                    // 72
    r7 = max(r7, r5);                                                    // 73
  }
#if SPARROW
  // Sparrow: lamp shadows (screen space) dim the lights' shadow factor
  // before the game lights with it.
  float4 lamp_vis = 1.0;
  if (SparrowActive()) {
    lamp_vis = SparrowLampShadows4(input.v2.xyz, input.position.xy, C80, C81, C82, C83, C96);
    r7 = 1.0 - (1.0 - r7) * lamp_vis;
  }
#endif
  float4 light_mask = 1.0 - r7;  // Sparrow: per light 0..3, the shadow factor
  r15.xyz = -r2.xyz * C83.w + C83.xyz;                                   // 74
  r14.xyz = -r2.xyz * C82.w + C82.xyz;                                   // 75
  r13.xyz = -r2.xyz * C81.w + C81.xyz;                                   // 76
  r5.xyz = -r2.xyz * C80.w + C80.xyz;                                    // 77
  r0.w = dot(r5.zxy, r5.zxy);                                            // 78
  { float v = dot(r13.zxy, r13.zxy); r2.x = sqrt(abs(r0.w)); r1.w = v; } // 79
  { float v = dot(r14.zxy, r14.zxy); r2.y = sqrt(abs(r1.w)); r2.w = v; } // 80
  { float v = dot(r15.zxy, r15.zxy); r2.z = sqrt(abs(r2.w)); r6.x = v; } // 81
  r12 = -r7.xzyw + C254.y; r3.w = rsqrt(abs(r6.x));                      // 82
  { float3 v = r15.xyz * r3.w; r2.w = rsqrt(abs(r2.w)); r17.xyz = v; }   // 83
  { float3 v = r14.xyz * r2.w; r1.w = rsqrt(abs(r1.w)); r14.xyz = v; }   // 84
  { float3 v = r13.xyz * r1.w; r0.w = rsqrt(abs(r0.w)); r15.xyz = v; }   // 85
  r16.xyz = r5.xyz * r0.w; r2.w = sqrt(abs(r6.x));                       // 86
  float3 l0 = r16.xyz, l1 = r15.xyz, l2 = r14.xyz, l3 = r17.xyz;  // Sparrow
  r5 = saturate(-float4(r2.w, r2.y, r2.x, r2.z) * C96.wyxz + C254.y);   // 87
  r13.x = dot(r16.zxy, C98.zxy);                                         // 88
  r13.y = dot(r15.zxy, C99.zxy);                                         // 89
  r13.z = dot(r14.zxy, C100.zxy);                                        // 90
  r13.w = dot(r17.zxy, C101.zxy);                                        // 91
  r2.w = saturate(dot(r10.xzy, r16.zxy));                                // 92
  r2.x = saturate(dot(r10.xzy, r15.zxy));                                // 93
  r2.y = saturate(dot(r10.xzy, r14.zxy));                                // 94
  r2.z = saturate(dot(r10.xzy, r17.zxy));                                // 95
  r7.x = dot(r10.xzy, r16.zxy);                                          // 96
  r7.y = dot(r10.xzy, r15.zxy);                                          // 97
  r7.z = dot(r10.xzy, r14.zxy);                                          // 98
  r7.w = dot(r10.xzy, r17.zxy);                                          // 99
  r7 = r7 + r7;                                                          // 100
  r13 = r13 - C105;                                                      // 101
  r13 = saturate(r13.xwzy * C107.xwzy);                                  // 102
  r14.xyz = -r10.xyz * r7.z + r14.zyx;                                   // 103
  r15.xyz = -r10.xyz * r7.y + r15.zyx;                                   // 104
  { float3 v = -r10.xyz * r7.w + r17.zyx; r7.y = v.x; r7.z = v.y; r7.w = v.z; }  // 105
  r16.xyz = -r10.xyz * r7.x + r16.zyx;                                   // 106
  r7.x = saturate(dot(-r9.zxy, r16.xzy));                                // 107
  r7.y = saturate(dot(-r9.zxy, float3(r7.y, r7.w, r7.z)));               // 108
  r7.z = saturate(dot(-r9.zxy, r15.xzy));                                // 109
  r7.w = saturate(dot(-r9.zxy, r14.xzy));                                // 110
  r5 = r13.yxzw * r5.xzwy + C254.z;                                      // 111
  r5 = r5.xzwy * C94.wzyx + C254.y;                                      // 112
  float4 light_atten = r5;  // Sparrow: (light 3, 2, 1, 0) range * spot
  r13 = r7 * r7; r6.x = r2.w;                                            // 113
  r7 = r5.wyzx * r12; r15.x = saturate(C23.w * r6.x);                    // 114
  r13 = r13 * r13; r15.y = saturate(C23.w * r2.x);                       // 115
  r7 = r7 * r2.wyxz; r15.z = saturate(C23.w * r2.y);                     // 116
  r14.xyz = r7.w * C90.xyz; r15.w = saturate(C23.w * r2.z);              // 117
  r13 = r15.xwyz * r13;                                                  // 118
  r2.xyz = r7.y * C89.xzy + r14.xzy;                                     // 119
  r12 = r13.xwyz * r12.xywz;                                             // 120
  r5 = r12.zywx * r5;                                                    // 121
  r2.xyz = r7.z * C88.xyz + r2.xzy;                                      // 122
  r2.xyz = r7.x * C87.xzy + r2.xzy;                                      // 123
  r7.xyz = r5.x * C90.xyz;                                               // 124
  r7.xyz = r5.y * C89.xzy + r7.xzy;                                      // 125
  r5.xyz = r5.z * C88.xyz + r7.xzy;                                      // 126
  r5.xyz = r5.w * C87.xzy + r5.xzy;                                      // 127
  float3 sparrow_grazing = 0.0;
#if SPARROW
  if (SparrowActive()) {
    // GGX for the four lights with the specular map as F0; the grazing part
    // of the Fresnel is white. Shinier maps
    // read as smoother surfaces.
    float3 n = r10.zyx, v = r9.xyz;
    float spec_lum = dot(r8.yzw, float3(0.2126, 0.7152, 0.0722));
    float rough = lerp(0.75, 0.35, saturate(spec_lum * 4.0));
    float3 base = 0.0;
    SparrowSpecularSplit(n, v, l0, rough, C87.xyz * (light_mask.x * light_atten.w), base, sparrow_grazing);
    SparrowSpecularSplit(n, v, l1, rough, C88.xyz * (light_mask.y * light_atten.z), base, sparrow_grazing);
    SparrowSpecularSplit(n, v, l2, rough, C89.xyz * (light_mask.z * light_atten.y), base, sparrow_grazing);
    SparrowSpecularSplit(n, v, l3, rough, C90.xyz * (light_mask.w * light_atten.x), base, sparrow_grazing);
    // F0 = the map with a floor of the dielectric 4%: the map adds shine,
    // never takes stone below what stone reflects. Applied here, so the
    // map product at 128 gets nothing.
    sparrow_grazing += base * max(r8.yzw, SPARROW_F0);
    r5.xyz = 0.0;
    sparrow_grazing += ambient * C27.w * SparrowEnvSpecular(n, v, rough, max(spec_lum, SPARROW_F0)) * SPARROW_SKY_REFLECT;
    if (xe_flags & 0x80000000u) {
      // Characters: the soft universal lobe and fabric sheen instead, as
      // lit.ps.hlsl / lit_shadow.ps.hlsl (their specular maps are near zero).
      SparrowCharMat cm = SparrowCharMaterial(sp_albedo);
      sparrow_grazing = SparrowCharacterSpecular(n, v, l0, C87.xyz * (light_mask.x * light_atten.w), cm) +
                        SparrowCharacterSpecular(n, v, l1, C88.xyz * (light_mask.y * light_atten.z), cm) +
                        SparrowCharacterSpecular(n, v, l2, C89.xyz * (light_mask.z * light_atten.y), cm) +
                        SparrowCharacterSpecular(n, v, l3, C90.xyz * (light_mask.w * light_atten.x), cm) +
                        SparrowCharacterSheen(ambient * C27.w, n, v, cm);
    }
    if (SparrowDebug() == 2) { r11.xyz = 0.0; r6.yzw = 0.0; }
  }
#endif
  r6.xyz = r8.yzw * r5.xzy + r6.yzw;                                     // 128
  r6.xyz += sparrow_grazing;
  r2.xyz = r2.xzy * r11.xyz + r6.xyz;                                    // 129
  if (XeBool(133)) {
    r6.xyz = TF13(r0.xy).xyz;                                            // 130
    r6.xyz = r6.xyz * r6.xyz;                                            // 131
    r2.xyz = r6.xyz * C24.z + r2.xyz;                                    // 132
  }
  if (XeBool(134)) {
    r6.x = dot(-r9.zxy, r10.xzy);                                        // 133
    r6.x = r6.x + r6.x;                                                  // 134
    { float3 v = -r10.xzy * r6.x - r9.zxy; r6.x = v.x; r6.y = v.y; r6.w = v.z; }  // 135
    { float3 v = r6.y * r3.zxy; r0.x = v.x; r0.y = v.y; r0.w = v.z; }    // 136
    r6.xyz = r6.x * r1.zxy + float3(r0.x, r0.y, r0.w);                   // 137
    r6.z = -r6.w * r4.y - r6.z;                                          // 138
    r6.xy = r6.w * r4.xz + r6.yx;                                        // 139
    r6 = XeCube(r6.xyz);                                                 // 140
    { float v = r6.w; r0.x = rcp(abs(r6.z)); r0.w = v; }                 // 141
    r0.xy = r6.yx * r0.x + C254.w;                                       // 142
    r6.xyz = TF14(float3(r0.x, r0.y, r0.w)).xyz;                         // 143
    r6.xyz = r6.xyz * r6.xyz;                                            // 144
    r2.xyz = r8.yzw * r6.xyz + r2.xyz;                                   // 145
  }
  r6.x = -C67.x - (-r0.z);                                               // 146
  { float3 v = r2.xyz * C49.xyz; r6.y = v.x; r6.z = v.y; r6.w = v.z; }   // 147
  if (r6.x > 0.0) {
    { float s = C67.w * r6.x; r0.x = saturate(dot(-r9.zxy, C66.zxy)); r0.w = s; }  // 148
    r0.xyz = TF4(r0.x).xyz;                                              // 149
    r1.xyz = TF5(r0.w).xyz;                                              // 150
    r2.xyz = -r1.xyz + C254.y;                                           // 151
    r0.xyz = r0.xyz - C68.xyz; r6.x = saturate(C67.z * r6.x);            // 152
    r0.xyz = r6.x * r0.zyx + C68.zyx;                                    // 153
    r2.xyz = r2.xyz * C28.y;                                             // 154
    r0.xyz = r2.xyz * r0.zyx - r6.yzw;                                   // 155
    r0.xyz = r6.yzw * r1.xyz + r0.xyz;                                   // 156
    r6.yzw = r0.xyz * C28.x + r6.yzw;                                    // 157
  }
  r0.xyz = C20.w * C26.xyz;                                              // 158
  float4 o = float4(r0.xyz * r6.yzw, C26.w * r8.x);                      // 159
#if SPARROW
  if (SparrowDebug() == 3) o.xyz = SparrowVisDebug(sky_vis);  // red open, green closed
#endif
  AlphaTest(o.w);
  coverage = AlphaToMask(o.w, input.position.xy);
#if SPARROW
  if (SparrowDebug() == 5) o.xyz = SparrowLampDebug(lamp_vis);
  if (SparrowDebug() == 7) o.xyz = SparrowDepthCheck(input.v2.xyz, input.position.xy);
#endif
  return o * xe_color_exp_bias.x;
}
