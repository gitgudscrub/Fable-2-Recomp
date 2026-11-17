// Fable II near ground splats with point lights, pixel shader
// AF1E16EE57E4BB06: the dirt, path and forest-floor patches blended over
// the near terrain layers (vertex shader FB68A7F2, as 4755A2E4A05BA678 /
// splat.ps.hlsl, which has the plain sun instead of two lights). Built only
// for Project Sparrow (tools/shaders/build_replace.py --sparrow).
//
// Stage 1: a literal port of the game's Xenos microcode (comments give the
// ucode instruction numbers). What the original does:
//   - tf0 colour and tf2 two-channel normal at v0.xy; tangent frame v5 / v4,
//     normal v1; world position v2, camera c19;
//   - tf3 baked light at v3.xy raised to c21.w and tinted by c21.xyz, a sky
//     term from v6 / c109, ambient c22 / c20, scale c11.x;
//   - two lights c80 / c81 (position, w = 1 point / 0 directional), colours
//     c87 / c88, range c96, spot axes c98 / c99, cone c105 / c107 / c94; c112
//     picks the sun's slot, which the screen-space shadow tf8 dims; under
//     b135 a projected shadow map tf9 (c32..c35, c48) dims the slot c114
//     picks;
//   - distance fog beyond c67.x (tf4 / tf5 ramps, c66 / c68 / c28) and an
//     alpha fade with distance (c31) times v7.w.
// Sparrow shapes the ambient light with the sky visibility and adds the
// sun's bounce from the ground ambient grid (sparrow_common.hlsli).
// Xenos reading notes are in xe_common.hlsli.

// --- SDK translator interface (shaders/xe_common.hlsli) -------------------
#define XE_FLOAT_CONSTANTS 31
#define XE_DESCRIPTOR_INDICES 6
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
#define C48 K[12]
#define C66 K[13]
#define C67 K[14]
#define C68 K[15]
#define C80 K[16]
#define C81 K[17]
#define C87 K[18]
#define C88 K[19]
#define C94 K[20]
#define C96 K[21]
#define C98 K[22]
#define C99 K[23]
#define C105 K[24]
#define C107 K[25]
#define C109 K[26]
#define C112 K[27]
#define C114 K[28]
#define C254 K[29]
#define C255 K[30]

struct PSInputSplatNear {
  float4 v0 : TEXCOORD0;
  float4 v1 : TEXCOORD1;
  float4 v2 : TEXCOORD2;
  float4 v3 : TEXCOORD3;
  float4 v4 : TEXCOORD4;
  float4 v5 : TEXCOORD5;
  float4 v6 : TEXCOORD6;
  centroid float4 v7 : TEXCOORD7;
  float4 position : SV_Position;
  bool front_face : SV_IsFrontFace;
};

// Texture bindings of this shader, in the translator's order.
#define TF8(uv) Fetch(8, 0, uv, false)
#define TF2(uv) Fetch(2, 1, uv, false)
#define TF3(uv) Fetch(3, 2, uv, false)
#define TF0(uv) Fetch(0, 3, uv, false)
#define TF9_OFF(uv, ox, oy) FetchOffset(9, 4, uv, int2(ox, oy))
#define TF4(x) Fetch(4, 5, float2(x, 0.0), true)
#define TF5(x) Fetch(5, 6, float2(x, 0.0), true)

float4 Ge4(float a, float4 b) { return float4(a >= b.x, a >= b.y, a >= b.z, a >= b.w); }

float4 main(PSInputSplatNear input) : SV_Target0 {
  float4 r0 = input.v0, r1 = input.v1, r2 = input.v2, r3 = input.v3;
  float4 r4 = input.v4, r5 = input.v5, r6 = input.v6, r7 = input.v7;
  float4 r8 = 0.0, r9 = 0.0, r10 = 0.0;
  r8.xy = GuestPixelPosition(input.position, input.front_face);
  float3 world = input.v2.xyz;

  r7.xy = abs(r8.xy) * C0.zw + C0.xy;                                    // 9
  r10.z = TF8(r7.xy).x;                                                  // 10
  { float2 t = TF2(r0.xy).xy; r7.y = t.x; r7.z = t.y; }                  // 11
  { float4 t = TF3(r3.xy); r3.x = t.x; r3.y = t.y; r3.w = t.z; }         // 12
  r8.xyz = TF0(r0.xy).xyz;                                               // 13
  r0.xyz = -C22.xyz + C254.y;                                            // 14
  r7.x = dot(r6.zxy, r6.zxy);                                            // 15
  r9.xyz = -r2.zyx + C19.zyx;                                            // 16
  r8.xyz = r8.xyz * r8.xyz;                                              // 17
  { float s = log2(abs(r3.x)); r1.w = dot(r9.xzy, r9.xzy); r10.x = s; }  // 18
  { float2 v = float2(r7.z, r7.y) * C255.x + C254.z; r10.y = v.x; r10.w = v.y; }  // 19
  r7.y = dot(float2(r10.w, r10.y), float2(r10.w, r10.y)) + C254.x;       // 20
  { float s = log2(abs(r3.y)); r5.xyz = r10.y * r5.zxy; r10.y = s; }     // 21
  r4.xyz = r10.w * r4.zxy + r5.xyz;                                      // 22
  { float s = rsqrt(abs(r7.x)); r0.w = -r7.y + C254.y; r7.x = s; }       // 23
  { float s = sqrt(abs(r0.w)); r7.xyz = r7.x * r6.zyx; r0.w = s; }       // 24
  r3.xyz = r0.w * r1.zyx + r4.xzy;                                       // 25
  { float s = log2(abs(r3.w)); r0.w = dot(r3.xzy, r3.xzy); r10.w = s; }  // 26
  { float s = rsqrt(abs(r0.w)); r1.xyz = float3(r10.x, r10.y, r10.w) * C21.w; r0.w = s; }  // 27
  r3.xyz = r3.xyz * r0.w;                                                // 28
  float3 n_world = r3.zyx;  // Sparrow: the shading normal in world order
  { float s = rsqrt(abs(r1.w)); r10.y = saturate(dot(r7.xzy, r3.xzy)); r7.z = s; }  // 29
  { float s = exp2(r1.x); r7.x = dot(r3.xzy, C109.zxy); r4.x = s; }      // 30
  { float s = exp2(r1.y); r10.x = saturate(r7.x * C254.w); r4.y = s; }   // 31
  { float s = exp2(r1.z); r7.xy = r10.xy * r10.zy; r4.z = s; }           // 32
  r0.xyz = r7.y * r0.xyz + C22.xyz;                                      // 33
  { float s = C254.y - r7.x; r1.xyz = r9.xyz * r7.z; r7.z = s; }         // 34
  { float s = C112.x * r7.z; r4.xyz = r4.xyz * C21.xyz; r7.x = s; }      // 35
  r0.xyz = r4.xyz * r0.xyz + C20.xyz;                                    // 36
  float sky_vis = -1.0;
#if SPARROW
  if (SparrowActive()) {
    // Sky light and bounce from the ground ambient grid; the ambient is
    // scaled by c11.x below, the lights are not.
    float3 sun = (C87.xyz * C112.x + C88.xyz * C112.y) / max(C11.x, 1e-3);
    r0.xyz = SparrowGroundAmbientLight(r0.xyz, world, n_world, sun, sky_vis);
  }
#endif
  float3 ambient = r0.xyz;  // Sparrow: the ambient light, before the albedo
  { float s = C112.y * r7.z; r0.xyz = r8.xyz * r0.xyz; r7.z = s; }       // 37
  { float s = sqrt(abs(r1.w)); r0.yzw = r0.xyz * C11.x; r7.y = s; }      // 38 (r0.yzw = r0.xxyz.yzw)
  if (XeBool(135)) {
    r9 = float4(C254.x == 0.0 ? r2.z : C254.y, C254.x == 0.0 ? r2.x : C254.y,  // 39
                C254.x == 0.0 ? r2.y : C254.y, C254.y == 0.0 ? r2.y : C254.y);
    { float s = rcp(C48.x); r4.z = dot(C32.zxyw, r9); r4.x = s; }        // 40
    { float s = rcp(C48.y); r0.x = dot(C35.zxyw, r9); r4.y = s; }        // 41
    { float s = rcp(r0.x); r4.w = dot(C33.zxyw, r9); r0.x = s; }         // 42
    r6 = r4 * r0.x;                                                      // 43
    r5.x = TF9_OFF(r6.zw, 0, 0).x;                                       // 44
    r5.y = TF9_OFF(r6.zw, 0, 1).x;                                       // 45
    r5.z = TF9_OFF(r6.zw, 1, 0).x;                                       // 46
    r5.w = TF9_OFF(r6.zw, 1, 1).x;                                       // 47
    r2.w = dot(C34.zxyw, r9);                                            // 48
    r4.xy = r6.xy * r4.zw;                                               // 49
    float ps = r2.w;                                                     // 50 (ps = max(r2.w, r2.w))
    { float2 v = frac(float2(r4.y, r4.x)); r4.y = v.x; r4.z = v.y; }
    { float s = ps * r0.x; r4.x = -r4.y + C254.y; r4.w = s; }            // 51
    r6.xy = -r4.wz + C254.y;                                             // 52
    r5 = Ge4(r6.x, r5);                                                  // 53
    r5.xy = r6.y * r5.xy;                                                // 54
    r5.zw = r5.zw * r4.z;                                                // 55
    r0.x = dot(r5.wyxz, r4.yyxx);                                        // 56
    r0.x = C254.y - r0.x;                                                // 57
    r4.xy = r0.x * C114.xy;                                              // 58
    r7.xz = max(r7.xz, r4.xy);                                           // 59
  }
  r5.xyz = -r2.xyz * C80.w + C80.xyz;                                    // 60
  r4.xyz = -r2.xyz * C81.w + C81.xyz;                                    // 61
  r0.x = dot(r4.zxy, r4.zxy);                                            // 62
  { float s = rsqrt(abs(r0.x)); r2.y = dot(r5.zxy, r5.zxy); r2.x = s; }  // 63
  { float s = rsqrt(abs(r2.y)); r4.xyz = r4.xyz * r2.x; r2.x = s; }      // 64
  r5.xyz = r5.xyz * r2.x;                                                // 65
  { float s = sqrt(abs(r2.y)); r2.x = saturate(dot(r3.xzy, r5.zxy)); r2.z = s; }  // 66
  { float s = sqrt(abs(r0.x)); r2.y = saturate(dot(r3.xzy, r4.zxy)); r2.w = s; }  // 67
  r2.zw = saturate(-r2.wz * C96.yx + C254.y);                            // 68
  r3.x = dot(r5.zxy, C98.zxy);                                           // 69
  r3.y = dot(r4.zxy, C99.zxy);                                           // 70
  { float s = C254.y - r7.x; r3.yz = r3.xy - C105.xy; r3.x = s; }        // 71
  { float s = C254.y - r7.z; r3.zw = saturate(r3.yz * C107.xy); r3.y = s; }  // 72
  r2 = r3.wzxy * r2.zwxy;                                                // 73
  r3.xy = r2.xy + C254.z;                                                // 74
  r2.xy = r3.xy * C94.yx + C254.y;                                       // 75
  { float s = r7.y - C67.x; float2 v = float2(r2.w * r2.x, r2.z * r2.y); r2.x = v.x; r2.w = v.y; r7.x = s; }  // 76
  bool fog = r7.x > 0.0;
  r2.xyz = r2.x * C88.xyz;                                               // 77
  r2.xyz = r2.w * C87.xyz + r2.xyz;                                      // 78
  r0.xyz = r8.xyz * r2.xyz + r0.yzw;                                     // 79
#if SPARROW
  SparrowWet sp_wet = (SparrowWet)0;
  if (SparrowActive()) {
    // the cobbles' faint sky sheen; wet in the rain
    float3 sheen = SparrowGroundWetSheen(r0.xyz, ambient * C11.x, world, input.position.xy,
                                         n_world, r1.zyx, C20.w * xe_color_exp_bias.x, sp_wet);
    r0.xyz += sheen;
    if (SparrowDebug() == 2) r0.xyz = sheen;
  }
#endif
  if (fog) {
    { float s = C67.w * r7.x; r1.x = saturate(dot(-r1.xzy, C66.zxy)); r0.w = s; }  // 80
    r1.xyz = TF4(r1.x).xyz;                                              // 81
    r2.xyz = TF5(r0.w).xyz;                                              // 82
    r3.xyz = -r2.xyz + C254.y;                                           // 83
    { float s = saturate(C67.z * r7.x); r1.xyz = r1.xyz - C68.xyz; r0.w = s; }  // 84
    r1.xyz = r0.w * r1.zyx + C68.zyx;                                    // 85
    r3.xyz = r3.zyx * C28.y;                                             // 86
    r1.xyz = r3.xyz * r1.xyz - r0.zyx;                                   // 87
    r1.xyz = r0.zyx * r2.zyx + r1.xyz;                                   // 88
    r0.xyz = r1.zyx * C28.x + r0.xyz;                                    // 89
  }
  r7.x = saturate(r1.w * C31.x + C31.y);                                 // 90
  r7.x = C254.y - r7.x;                                                  // 91
  float4 o = float4(r0.xyz * C20.w, r7.x * r7.w);                        // 92-93
#if SPARROW
  // red open sky, green closed in (sparrow_debug 3)
  if (SparrowDebug() == 3) o.xyz = SparrowVisDebug(sky_vis);
  if (SparrowDebug() == 10) o.xyz = SparrowWetDebug(sp_wet);
#endif
  return o * xe_color_exp_bias.x;
}
