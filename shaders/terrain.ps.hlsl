// Fable II terrain, pixel shader 9C2144E42E95A76F: the ground of the outdoor
// regions (grass, paths, earth) and, on steep slopes, a two-projection rock
// blend for the cliff faces. Replaces the SDK's translation through the
// shader_replace_dir cvar (see shaders/README.md).
//
// Stage 1: a literal port of the game's Xenos microcode (comments give the
// ucode instruction numbers). What the original does:
//   - tf0 ground colour and tf2 two-channel tangent-space normal at v2.xy;
//   - a slope weight from |v3.z| (c45): where it is below c254.y the cliff
//     path blends in tf13 rock colour and tf14 rock normals sampled in two
//     projections (v0.xy, v1.xy), weighted by the normal's x / y and their
//     signs;
//   - the normal in world space from v7 (tangent), v6 (bitangent) and v3;
//   - sun diffuse (c80) times the screen-space shadow buffer tf8, a
//     specular term from c109 (c254.z), per-vertex light v9 raised to c21.w
//     (through tf3 at v5.xy), ambient c22 / c20, specular colour c87;
//   - distance fog beyond c67.x (tf4 sun-angle and tf5 distance ramps, c66,
//     c68, c28), the same block as the lit shaders;
//   - alpha = (1 - saturate(dist * c31.x + c31.y)) * v9.w.
// Xenos reading notes are in xe_common.hlsli.

#ifndef DEBUG_VIEW
#define DEBUG_VIEW 0
#endif
// Improvements (0 / 1 = original look):
// ALBEDO_BUMP: relief from the ground colour's brightness slope (one texel
//   either side, following the mip level), as in lit.ps.hlsl: pebbles, ruts
//   and grass clumps catch the sun instead of reading as paint.
// FOG: distance fog strength (1 = original).
// SMOOTH_LIGHT: the baked light map (tf3) read with a 16-tap cubic B-spline
//   on its texel grid; as the game reads it, each texel shows as a square
//   of light and colour on the ground (ground.ps.hlsl has the same).
#ifndef SMOOTH_LIGHT
#define SMOOTH_LIGHT 1
#endif
// SMOOTH_COLOR: where the ground colour map (tf0) is magnified (one texel
//   covers more than a pixel), read it with the same cubic B-spline at texel
//   centres. The game samples it point-filtered, so close up each texel is
//   a hard square of colour.
#ifndef SMOOTH_COLOR
#define SMOOTH_COLOR 1
#endif
#ifndef ALBEDO_BUMP
#define ALBEDO_BUMP 5.0
#endif
#ifndef FOG
#define FOG 0.6
#endif

// --- SDK translator interface (shaders/xe_common.hlsli) -------------------
#define XE_FLOAT_CONSTANTS 17
#define XE_DESCRIPTOR_INDICES 7
#include "xe_common.hlsli"
#include "modern_common.hlsli"
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
#define C45 K[8]
#define C66 K[9]
#define C67 K[10]
#define C68 K[11]
#define C80 K[12]
#define C87 K[13]
#define C109 K[14]
#define C254 K[15]
#define C255 K[16]

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
#define TF0_OFF(uv, ox, oy) FetchOffset(0, 0, uv, int2(ox, oy))
#define TF2(uv) Fetch(2, 1, uv, false)
#define TF13(uv) Fetch(13, 2, uv, false)
#define TF14(uv) Fetch(14, 3, uv, false)
#define TF8(uv) Fetch(8, 4, uv, false)
#define TF3(uv) Fetch(3, 5, uv, false)
#define TF3_TEXEL(uv) FetchLevel(3, 5, uv, false, 0.0)




#define TF4(x) Fetch(4, 6, float2(x, 0.0), true)
#define TF5(x) Fetch(5, 7, float2(x, 0.0), true)

float4 main(PSInput10 input) : SV_Target0 {
  float4 r0 = input.v0, r1 = input.v1, r2 = input.v2, r3 = input.v3, r4 = input.v4;
  float4 r5 = input.v5, r6 = input.v6, r7 = input.v7, r8 = input.v8, r9 = input.v9;
  float4 r10 = 0.0, r11 = 0.0, r12 = 0.0, r13 = 0.0, r14 = 0.0, r15 = 0.0;
  r10.xy = GuestPixelPosition(input.position, input.front_face);
  float2 ground_uv = r2.xy;

  r11.xyz = TF0(r2.xy).xyz;
  float magnify = 0.0;
  if (SMOOTH_COLOR) {
    // Texels per pixel of the guest-size map; below 1 it is magnified.
    magnify = Magnification(0, ground_uv);
    if (magnify > 0.0) r11.xyz = lerp(r11.xyz, SmoothFetch(0, 0, ground_uv).xyz, magnify);
  }                                              // 10
  float2 relief = 0.0;
  if (ALBEDO_BUMP != 0.0) {
    // The fetched colour is still gamma (it is squared at 17).
    float3 lw = float3(0.299, 0.587, 0.114);
    float he = dot(TF0_OFF(ground_uv, 1, 0).xyz, lw), hw = dot(TF0_OFF(ground_uv, -1, 0).xyz, lw);
    float hn = dot(TF0_OFF(ground_uv, 0, 1).xyz, lw), hs = dot(TF0_OFF(ground_uv, 0, -1).xyz, lw);
    relief = float2(he - hw, hn - hs) * (0.5 * ALBEDO_BUMP);
  }
  r2.xy = TF2(r2.xy).xy;                                                 // 11
  r9.y = saturate(abs(r3.z) * C45.y + C45.x);                            // 12
  r2.w = (C254.y > r9.y) ? 1.0 : 0.0;                                    // 13
  r2.xy = r2.yx * C254.x + C255.y;                                       // 14
  r2.z = dot(r2.yx, r2.yx) + C255.x;                                     // 15
  r2.z = -r2.z + C255.z;                                                 // 16
  bool p0 = r2.w == 0.0;
  { float s = sqrt(abs(r2.z)); r11.xyz = r11.zxy * r11.zxy; r2.z = s; }  // 17
  if (!p0) {
    r14.xyz = TF13(r1.xy).xyz;                                           // 18
    r13.xyz = TF13(r0.xy).xyz;                                           // 19
    r12.xy = TF14(r0.xy).xy;                                             // 20
    r12.zw = TF14(r1.xy).xy;                                             // 21
    r0.y = abs(r3.x) + C255.w;                                           // 22
    r0.x = (r3.y > -r3.y) ? 1.0 : 0.0;                                   // 23
    r9.x = (-r3.y > r3.y) ? 1.0 : 0.0;                                   // 24
    { float s = r0.y + abs(r3.y); r0.x = r0.x - r9.x; r9.x = s; }        // 25 (ps = max(r0.y, r0.y))
    r12 = r12.yxwz * C254.x + C255.y;                                    // 26
    { float s = rcp(r9.x); r0.z = r12.z * -r0.x; r0.w = s; }             // 27
    r0.y = r0.w * abs(r3.y);                                             // 28
    { float s = C255.z - r9.y; r15 = r12.xwyz * r12.xwyz; r0.x = s; }    // 29
    { float2 v = float2(r0.x * r0.w, r0.y * r0.x); r1.x = v.x; r1.w = v.y; }  // 30
    { float s = r15.z + r15.x; r0.y = r1.w * r12.w; r0.x = s; }          // 31
    { float s = r15.y + r15.w; r13.xyz = r13.xyz * r13.xyz; r9.x = s; }  // 32
    { float s = C255.z - r0.x; r14.xyz = r14.xyz * r14.xyz; r1.y = s; }  // 33
    { float s = C255.z - r9.x; r11.xyz = r11.xyz * r9.y; r0.x = s; }     // 34
    r11.xyz = r14.zxy * r1.w + r11.xyz;                                  // 35
    { float s = sqrt(abs(r1.y)); r0.w = r1.x * abs(r3.x); r1.y = s; }    // 36
    r11.xyz = r13.zxy * r0.w + r11.xyz;                                  // 37
    r1.x = r0.w * r1.y;                                                  // 38
    { float s = sqrt(abs(r0.x)); r1.yz = r0.w * -r12.xy; r0.w = s; }     // 39
    r0.zw = r1.w * r0.zw;                                                // 40
    r0.xyz = r1.xyz + r0.wyz;                                            // 41
    r2.xyz = r9.y * r2.xyz + r0.zyx;                                     // 42
    relief *= r9.y;  // the cliff blend has its own rock normals
  }
  if (ALBEDO_BUMP != 0.0) {
    // Tilt only: the normal is normalised at 58.
    r2.xy -= relief;
  }
  r9.xy = abs(r10.xy) * C0.zw + C0.xy;                                   // 43
  r0.w = TF8(r9.xy).x;                                                   // 44
#if SPARROW
  {
    // Sparrow: the real sun shadow map (v4 world position, v3 normal).
    float3 n = normalize(input.v3.xyz);
    r0.w = SparrowSunOr(r0.w, input.v4.xyz, n.z < 0.0 ? -n : n);
  }
#endif
  r9.xyz = (SMOOTH_LIGHT ? SmoothFetch(3, 5, r5.xy) : TF3(r5.xy)).xyz;                                               // 45
  { float s = log2(abs(r9.x)); r1.yzw = -r4.xyz + C19.xyz; r0.x = s; }   // 46
  { float s = log2(abs(r9.y)); r9.x = dot(r8.zxy, r8.zxy); r0.y = s; }   // 47
  { float s = log2(abs(r9.z)); r4.xyz = r2.x * r7.xzy; r0.z = s; }       // 48
  { float3 v = r2.y * r6.zxy + r4.yxz; r2.x = v.x; r2.y = v.y; r2.w = v.z; }  // 49
  { float s = rsqrt(abs(r9.x)); r9.z = dot(r1.wyz, r1.wyz); r9.y = s; }  // 50
  { float s = rsqrt(abs(r9.z)); r4.xyz = r11.yzx * C11.x; r1.x = s; }    // 51
  r3.xyz = r2.z * r3.zyx + float3(r2.x, r2.w, r2.y);                     // 52
  { float s = sqrt(abs(r9.z)); r0.xyz = r0.zxy * C21.w; r9.x = s; }      // 53
  { float s = exp2(r0.y); r2.xyz = r9.y * r8.zyx; r0.y = s; }            // 54
  { float s = exp2(r0.z); r9.x = r9.x - C67.x; r0.z = s; }               // 55
  { float s = exp2(r0.x); r9.y = dot(r3.xzy, r3.xzy); r0.x = s; }        // 56
  { float s = rsqrt(abs(r9.y)); r1.xyz = r1.yzw * r1.x; r9.y = s; }      // 57
  r3.xyz = r3.xyz * r9.y;                                                // 58
  float3 n_shade = r3.zyx;  // Sparrow: the shading normal in world order
  r2.y = saturate(dot(r2.xzy, r3.xzy));                                  // 59
  r2.z = saturate(dot(r3.xzy, C80.zxy));                                 // 60
  r9.y = dot(r3.xzy, C109.zxy);                                          // 61
  { float s = saturate(C254.z * r9.y); r5.xyz = -C22.xyz + C255.z; r1.w = s; }  // 62
  { float s = C21.x * r0.y; r2.x = r1.w * r0.w; r3.x = s; }              // 63
  { float s = C21.y * r0.z; float2 v = float2(r2.y * r2.y, r2.x * r2.z); r2.x = v.x; r2.w = v.y; r3.y = s; }  // 64
  r2.xyz = r2.x * r5.xyz + C22.xyz;                                      // 65
  { float s = C21.z * r0.x; r5.xyz = r2.w * C87.xyz; r3.z = s; }         // 66
  r0.xyz = r5.xyz * r11.yzx;                                             // 67
  bool fog = r9.x > 0.0;
  r2.xyz = r3.xyz * r2.xyz + C20.xyz;                                    // 68
  float sky_vis = -1.0;
#if SPARROW
  // Sparrow: sky light and bounce from the ground ambient grid.
  if (SparrowActive()) {
    float3 a = SparrowGroundAmbientLight(r2.xyz, input.v4.xyz, normalize(input.v3.xyz) * (input.v3.z < 0.0 ? -1.0 : 1.0), C87.xyz / max(C11.x, 1e-3), sky_vis);
    r2.xyz = a;
  }
  float3 ambient = r2.xyz;  // the ambient light, before the albedo
#endif
  r0.xyz = r4.xyz * r2.xyz + r0.xyz;                                     // 69
#if SPARROW
  SparrowWet sp_wet = (SparrowWet)0;
  if (SparrowActive()) {
    // the cobbles' faint sky sheen; wet in the rain
    float3 sheen = SparrowGroundWetSheen(r0.xyz, ambient * C11.x, input.v4.xyz, input.position.xy,
                                         n_shade, r1.xyz, C20.w * xe_color_exp_bias.x, sp_wet);
    r0.xyz += sheen;
    if (SparrowDebug() == 2) r0.xyz = sheen;
  }
#endif
  if (fog) {
    { float s = C67.w * r9.x; r1.x = saturate(dot(-r1.zxy, C66.zxy)); r0.w = s; }  // 70
    r1.xyz = TF4(r1.x).xyz;                                              // 71
    r2.xyz = TF5(r0.w).xyz;                                              // 72
    r3.xyz = C255.z - r2.xyz;                                            // 73
    { float s = saturate(C67.z * r9.x); r1.xyz = r1.xyz - C68.xyz; r0.w = s; }  // 74
    r1.xyz = r0.w * r1.zyx + C68.zyx;                                    // 75
    r3.xyz = r3.xyz * C28.y;                                             // 76
    r1.xyz = r3.xyz * r1.zyx - r0.xyz;                                   // 77
    r1.xyz = r0.xyz * r2.xyz + r1.xyz;                                   // 78
    r0.xyz = r1.xyz * (C28.x * FOG) + r0.xyz;                            // 79
  }
  r9.x = saturate(r9.z * C31.x + C31.y);                                 // 80
  r9.x = C255.z - r9.x;                                                  // 81
  float4 o = float4(r0.xyz * C20.w, r9.x * r9.w);                        // 82-83
#if DEBUG_VIEW == 2
  o.xyz = float3(magnify, 0.0, 0.0);
#elif DEBUG_VIEW == 1
  o.xyz = float3(saturate(relief * 4.0 + 0.5), p0 ? 0.0 : 1.0);
#endif
#if SPARROW
  // red open sky, green closed in (sparrow_debug 3)
  if (SparrowDebug() == 3) o.xyz = SparrowVisDebug(sky_vis);
  if (SparrowDebug() == 10) o.xyz = SparrowWetDebug(sp_wet);
#endif
  return o * xe_color_exp_bias.x;
}
