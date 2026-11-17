// Fable II near terrain with point lights, pixel shader 45243B758F9272AB:
// the ground layers around the player (grass, earth, paths blended on the
// tessellated terrain patches, vertex shader C30A97D9) and, on steep slopes,
// the two-projection cliff rock. The sibling of 9C2144E42E95A76F
// (terrain.ps.hlsl) with two lights instead of the plain sun. Built only for
// Project Sparrow (tools/shaders/build_replace.py --sparrow).
//
// Stage 1: a literal port of the game's Xenos microcode (comments give the
// ucode instruction numbers). What the original does:
//   - tf0 ground colour and tf2 two-channel normal at v2.xy; below the slope
//     threshold (c45, c254.z) the cliff blend of tf13 rock colour and tf14
//     rock normals in two projections (v0.xy, v1.xy), as terrain.ps.hlsl;
//   - normal from v7 (tangent), v6 (bitangent) and v3; world position v4,
//     camera c19;
//   - tf3 baked light at v5.xy raised to c21.w and tinted by c21.xyz, a sky
//     term from v8 / c109, ambient c22 / c20, scale c11.x;
//   - two lights c80 / c81 (position, w = 1 point / 0 directional), colours
//     c87 / c88, range c96, spot axes c98 / c99, cone c105 / c107 / c94; c112
//     picks the sun's slot, which the screen-space shadow tf8 dims; under
//     b135 a projected shadow map tf9 (c32..c35, c48) dims the slot c114
//     picks;
//   - distance fog beyond c67.x (tf4 / tf5 ramps, c66 / c68 / c28) and an
//     alpha fade with distance (c31) times v9.w.
// Sparrow shapes the ambient light with the sky visibility and adds the
// sun's bounce from the ground ambient grid (sparrow_common.hlsli).
// Xenos reading notes are in xe_common.hlsli.

// --- SDK translator interface (shaders/xe_common.hlsli) -------------------
#define XE_FLOAT_CONSTANTS 32
#define XE_DESCRIPTOR_INDICES 7
#include "xe_common.hlsli"
#if SPARROW
#include "sparrow_common.hlsli"
#endif

#define C0 K[0]
#define C11 K[1]
#define C19 K[2]
#define C20 K[3]
#define C21 K[4]
#define C22 K[5]
#define C28 K[6]
#define C31 K[7]
#define C32 K[8]
#define C33 K[9]
#define C34 K[10]
#define C35 K[11]
#define C45 K[12]
#define C48 K[13]
#define C66 K[14]
#define C67 K[15]
#define C68 K[16]
#define C80 K[17]
#define C81 K[18]
#define C87 K[19]
#define C88 K[20]
#define C94 K[21]
#define C96 K[22]
#define C98 K[23]
#define C99 K[24]
#define C105 K[25]
#define C107 K[26]
#define C109 K[27]
#define C112 K[28]
#define C114 K[29]
#define C254 K[30]
#define C255 K[31]

struct PSInput10 {
  float4 v0 : TEXCOORD0;
  float4 v1 : TEXCOORD1;
  float4 v2 : TEXCOORD2;
  float4 v3 : TEXCOORD3;
  float4 v4 : TEXCOORD4;
  float4 v5 : TEXCOORD5;
  float4 v6 : TEXCOORD6;
  float4 v7 : TEXCOORD7;
  float4 v8 : TEXCOORD8;
  centroid float4 v9 : TEXCOORD9;
  float4 position : SV_Position;
  bool front_face : SV_IsFrontFace;
};

// Texture bindings of this shader, in the translator's order.
#define TF0(uv) Fetch(0, 0, uv, false)
#define TF2(uv) Fetch(2, 1, uv, false)
#define TF13(uv) Fetch(13, 2, uv, false)
#define TF14(uv) Fetch(14, 3, uv, false)
#define TF8(uv) Fetch(8, 4, uv, false)
#define TF3(uv) Fetch(3, 5, uv, false)
#define TF9_OFF(uv, ox, oy) FetchOffset(9, 6, uv, int2(ox, oy))
#define TF4(x) Fetch(4, 7, float2(x, 0.0), true)
#define TF5(x) Fetch(5, 8, float2(x, 0.0), true)

float4 Ge4(float a, float4 b) { return float4(a >= b.x, a >= b.y, a >= b.z, a >= b.w); }

float4 main(PSInput10 input) : SV_Target0 {
  float4 r0 = input.v0, r1 = input.v1, r2 = input.v2, r3 = input.v3, r4 = input.v4;
  float4 r5 = input.v5, r6 = input.v6, r7 = input.v7, r8 = input.v8, r9 = input.v9;
  float4 r10 = 0.0, r11 = 0.0, r12 = 0.0, r13 = 0.0, r14 = 0.0, r15 = 0.0;
  r10.xy = GuestPixelPosition(input.position, input.front_face);
  float3 world = input.v4.xyz;

  r11.xyz = TF0(r2.xy).xyz;                                              // 13
  r2.xy = TF2(r2.xy).xy;                                                 // 14
  r9.x = saturate(abs(r3.z) * C45.y + C45.x);                            // 15
  r2.w = (C254.z > r9.x) ? 1.0 : 0.0;                                    // 16
  r2.xy = r2.yx * C254.y + C255.z;                                       // 17
  r2.z = dot(r2.yx, r2.yx) + C255.x;                                     // 18
  r2.z = -r2.z + C255.y;                                                 // 19
  bool p0 = r2.w == 0.0;
  { float s = sqrt(abs(r2.z)); r11.xyz = r11.xyz * r11.xyz; r2.z = s; }  // 20
  if (!p0) {
    r14.xyz = TF13(r1.xy).xyz;                                           // 21
    r13.xyz = TF13(r0.xy).xyz;                                           // 22
    r12.xy = TF14(r0.xy).xy;                                             // 23
    r12.zw = TF14(r1.xy).xy;                                             // 24
    r0.y = abs(r3.x) + C255.w;                                           // 25
    r0.x = (r3.y > -r3.y) ? 1.0 : 0.0;                                   // 26
    float ps = r0.y;
    r9.z = (-r3.y > r3.y) ? 1.0 : 0.0;                                   // 27 (ps = max(r0.y, r0.y))
    { float s = ps + abs(r3.y); r0.x = r0.x - r9.z; r9.z = s; }          // 28
    r12 = r12.yxwz * C254.y + C255.z;                                    // 29
    { float s = rcp(r9.z); r0.z = r12.z * -r0.x; r0.w = s; }             // 30
    r0.y = r0.w * abs(r3.y);                                             // 31
    { float s = C255.y - r9.x; r15 = r12.xwyz * r12.xwyz; r0.x = s; }    // 32
    { float2 v = float2(r0.x * r0.w, r0.y * r0.x); r1.x = v.x; r1.w = v.y; }  // 33
    { float s = r15.z + r15.x; r0.y = r1.w * r12.w; r0.x = s; }          // 34
    { float s = r15.y + r15.w; r13.xyz = r13.xyz * r13.xyz; r9.z = s; }  // 35
    { float s = C255.y - r0.x; r14.xyz = r14.xyz * r14.xyz; r1.y = s; }  // 36
    { float s = C255.y - r9.z; r11.xyz = r11.zxy * r9.x; r0.x = s; }     // 37
    r11.xyz = r14.zxy * r1.w + r11.xyz;                                  // 38
    { float s = sqrt(abs(r1.y)); r0.w = r1.x * abs(r3.x); r1.y = s; }    // 39
    r11.xyz = r13.xyz * r0.w + r11.yzx;                                  // 40
    r1.x = r0.w * r1.y;                                                  // 41
    { float s = sqrt(abs(r0.x)); r1.yz = r0.w * -r12.xy; r0.w = s; }     // 42
    r0.zw = r1.w * r0.zw;                                                // 43
    r0.xyz = r1.xyz + r0.wyz;                                            // 44
    r2.xyz = r9.x * r2.xyz + r0.zyx;                                     // 45
  }
  r9.xy = abs(r10.xy) * C0.zw + C0.xy;                                   // 46
  r10.z = TF8(r9.xy).x;                                                  // 47
  r9.xyz = TF3(r5.xy).xyz;                                               // 48
  { float s = log2(abs(r9.x)); r5.xyz = -r4.xyz + C19.xyz; r9.x = s; }   // 49
  { float s = log2(abs(r9.y)); r1.xyz = r2.x * r7.xzy; r9.y = s; }       // 50
  { float s = log2(abs(r9.z)); r0.x = dot(r8.zxy, r8.zxy); r9.z = s; }   // 51
  { float s = rsqrt(abs(r0.x)); r0.z = dot(r5.zxy, r5.zxy); r0.x = s; }  // 52
  r1.xyz = r2.y * r6.zxy + r1.yxz;                                       // 53
  r3.xyz = r2.z * r3.zyx + r1.xzy;                                       // 54
  { float s = rsqrt(abs(r0.z)); r9.xyz = r9.yzx * C21.w; r2.x = s; }     // 55
  { float s = exp2(r9.z); r1.xyz = r11.xyz * C11.x; r9.z = s; }          // 56
  { float s = exp2(r9.x); float3 v = r0.x * r8.zyx; r0.x = v.x; r0.y = v.y; r0.w = v.z; r9.x = s; }  // 57
  { float s = exp2(r9.y); r1.w = dot(r3.xzy, r3.xzy); r9.y = s; }        // 58
  { float s = rsqrt(abs(r1.w)); r2.xyz = r5.xyz * r2.x; r1.w = s; }      // 59
  r3.xyz = r3.xyz * r1.w;                                                // 60
  float3 n_world = r3.zyx;  // Sparrow: the shading normal in world order
  r10.x = saturate(dot(float3(r0.x, r0.w, r0.y), r3.xzy));               // 61
  r0.y = dot(r3.xzy, C109.zxy);                                          // 62
  { float s = saturate(C254.x * r0.y); r6.xyz = -C22.xyz + C255.y; r10.y = s; }  // 63
  { float s = C21.x * r9.z; float2 v = float2(r10.x * r10.x, r10.y * r10.z); r5.y = v.x; r5.z = v.y; r5.x = s; }  // 64
  { float3 v = r5.y * r6.xyz + C22.xyz; r0.x = v.x; r0.y = v.y; r0.w = v.z; }  // 65
  { float s = C21.y * r9.x; r1.w = -r5.z + C255.y; r5.y = s; }           // 66
  { float s = C21.z * r9.y; r9.x = r1.w * C112.x; r9.z = r1.w * C112.y; r5.z = s; }  // 67
  { float3 v = r5.xyz * float3(r0.x, r0.y, r0.w) + C20.xyz; r0.x = v.x; r0.y = v.y; r0.w = v.z; }  // 68
  float sky_vis = -1.0;
#if SPARROW
  if (SparrowActive()) {
    // Sky light and bounce from the ground ambient grid; the ambient is
    // scaled by c11.x below, the lights are not.
    float3 sun = (C87.xyz * C112.x + C88.xyz * C112.y) / max(C11.x, 1e-3);
    float3 a = SparrowGroundAmbientLight(float3(r0.x, r0.y, r0.w), world, n_world, sun, sky_vis);
    r0.x = a.x; r0.y = a.y; r0.w = a.z;
  }
#endif
  float3 ambient = float3(r0.x, r0.y, r0.w);  // Sparrow: the ambient light, before the albedo
  { float s = sqrt(abs(r0.z)); r1.xyz = r1.xyz * float3(r0.x, r0.y, r0.w); r9.y = s; }  // 69
  if (XeBool(135)) {
    r8 = float4(C255.x == 0.0 ? r4.z : C255.y, C255.x == 0.0 ? r4.x : C255.y,  // 70
                C255.x == 0.0 ? r4.y : C255.y, C255.y == 0.0 ? r4.y : C255.y);
    { float s = rcp(C48.x); r5.z = dot(C32.zxyw, r8); r5.x = s; }        // 71
    { float s = rcp(C48.y); r0.x = dot(C35.zxyw, r8); r5.y = s; }        // 72
    { float s = rcp(r0.x); r5.w = dot(C33.zxyw, r8); r0.x = s; }         // 73
    r7 = r5 * r0.x;                                                      // 74
    r6.x = TF9_OFF(r7.zw, 0, 0).x;                                       // 75
    r6.y = TF9_OFF(r7.zw, 0, 1).x;                                       // 76
    r6.z = TF9_OFF(r7.zw, 1, 0).x;                                       // 77
    r6.w = TF9_OFF(r7.zw, 1, 1).x;                                       // 78
    r0.y = dot(C34.zxyw, r8);                                            // 79
    r5.xy = r7.xy * r5.zw;                                               // 80
    float ps = r0.y;                                                     // 81 (ps = max(r0.y, r0.y))
    { float2 v = frac(float2(r5.y, r5.x)); r5.y = v.x; r5.z = v.y; }
    { float s = ps * r0.x; r5.x = -r5.y + C255.y; r5.w = s; }            // 82
    r0.xy = -r5.wz + C255.y;                                             // 83
    r6 = Ge4(r0.x, r6);                                                  // 84
    r6.xy = r0.y * r6.xy;                                                // 85
    r6.zw = r6.zw * r5.z;                                                // 86
    r0.x = dot(r6.wyxz, r5.yyxx);                                        // 87
    r0.x = C255.y - r0.x;                                                // 88
    r0.xy = r0.x * C114.xy;                                              // 89
    r9.xz = max(r9.xz, r0.xy);                                           // 90
  }
  r6.xyz = -r4.xyz * C80.w + C80.xyz;                                    // 91
  r4.xyz = -r4.xyz * C81.w + C81.xyz;                                    // 92
  r1.w = dot(r4.zxy, r4.zxy);                                            // 93
  { float s = rsqrt(abs(r1.w)); r2.w = dot(r6.zxy, r6.zxy); r0.x = s; }  // 94
  { float s = rsqrt(abs(r2.w)); r5.xyz = r4.xyz * r0.x; r0.x = s; }      // 95
  { float3 v = r6.xyz * r0.x; r0.x = v.x; r0.y = v.y; r0.w = v.z; }      // 96
  { float s = sqrt(abs(r2.w)); r4.x = saturate(dot(r3.xzy, float3(r0.w, r0.x, r0.y))); r4.z = s; }  // 97
  { float s = sqrt(abs(r1.w)); r4.y = saturate(dot(r3.xzy, r5.zxy)); r4.w = s; }  // 98
  r4.zw = saturate(-r4.wz * C96.yx + C255.y);                            // 99
  r0.x = dot(float3(r0.w, r0.x, r0.y), C98.zxy);                         // 100
  r0.y = dot(r5.zxy, C99.zxy);                                           // 101
  { float s = C255.y - r9.x; r0.xy = r0.xy - C105.xy; r3.x = s; }        // 102
  { float s = C255.y - r9.z; r3.zw = saturate(r0.xy * C107.xy); r3.y = s; }  // 103
  r3 = r3.xywz * r4;                                                     // 104
  r0.xy = r3.zw + C255.z;                                                // 105
  r0.xy = r0.xy * C94.yx + C255.y;                                       // 106
  { float s = r9.y - C67.x; r3.xy = r3.xy * r0.yx; r9.x = s; }           // 107
  bool fog = r9.x > 0.0;
  { float3 v = r3.y * C88.xyz; r0.x = v.x; r0.y = v.y; r0.w = v.z; }     // 108
  { float3 v = r3.x * C87.xyz + float3(r0.x, r0.y, r0.w); r0.x = v.x; r0.y = v.y; r0.w = v.z; }  // 109
  { float3 v = float3(r0.x, r0.y, r0.w) * r11.xyz + r1.xyz; r0.x = v.x; r0.y = v.y; r0.w = v.z; }  // 110
#if SPARROW
  SparrowWet sp_wet = (SparrowWet)0;
  if (SparrowActive()) {
    // the cobbles' faint sky sheen; wet in the rain
    float3 lit = r0.xyw;
    float3 sheen = SparrowGroundWetSheen(lit, ambient * C11.x, world, input.position.xy,
                                         n_world, r2.xyz, C20.w * xe_color_exp_bias.x, sp_wet);
    r0.xyw = lit + sheen;
    if (SparrowDebug() == 2) r0.xyw = sheen;
  }
#endif
  if (fog) {
    { float s = C67.w * r9.x; r1.x = saturate(dot(-r2.zxy, C66.zxy)); r1.w = s; }  // 111
    r1.xyz = TF4(r1.x).xyz;                                              // 112
    r2.xyz = TF5(r1.w).xyz;                                              // 113
    r3.xyz = -r2.xyz + C255.y;                                           // 114
    { float s = saturate(C67.z * r9.x); r1.xyz = r1.xyz - C68.xyz; r1.w = s; }  // 115
    r1.xyz = r1.w * r1.zyx + C68.zyx;                                    // 116
    r3.xyz = r3.xyz * C28.y;                                             // 117
    r1.xyz = r3.xyz * r1.zyx - float3(r0.x, r0.y, r0.w);                 // 118
    r1.xyz = float3(r0.x, r0.y, r0.w) * r2.xyz + r1.xyz;                 // 119
    { float3 v = r1.xyz * C28.x + float3(r0.x, r0.y, r0.w); r0.x = v.x; r0.y = v.y; r0.w = v.z; }  // 120
  }
  r9.x = saturate(r0.z * C31.x + C31.y);                                 // 121
  r9.x = C255.y - r9.x;                                                  // 122
  float4 o = float4(float3(r0.x, r0.y, r0.w) * C20.w, r9.x * r9.w);      // 123-124
#if SPARROW
  // red open sky, green closed in (sparrow_debug 3)
  if (SparrowDebug() == 3) o.xyz = SparrowVisDebug(sky_vis);
  if (SparrowDebug() == 10) o.xyz = SparrowWetDebug(sp_wet);
#endif
  return o * xe_color_exp_bias.x;
}
