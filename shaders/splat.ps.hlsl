// Fable II ground splats, pixel shader 4755A2E4A05BA678: the dirt, path and
// forest-floor patches blended over the near terrain (alpha = vertex alpha
// v7.w times a distance fade). Replaces the SDK's translation through the
// shader_replace_dir cvar (see shaders/README.md).
//
// Stage 1: a literal port of the game's Xenos microcode (comments give the
// ucode instruction numbers). What the original does:
//   - tf0 colour and tf2 two-channel normal at v0.xy; tangent frame v5 / v4,
//     normal v1; world position v2;
//   - tf3 baked light at v3.xy, raised to c21.w (log / exp) and tinted by
//     c21.xyz; the screen-space sun shadow tf8;
//   - sun diffuse (c80), a sky term (c109, c255.x), ambient c22 / c20,
//     specular colour c87, overall c11.x;
//   - distance fog beyond c67.x, the same block as the lit shaders;
//   - alpha = (1 - saturate(dist * c31.x + c31.y)) * v7.w.
// Xenos reading notes are in xe_common.hlsli.

#ifndef DEBUG_VIEW
#define DEBUG_VIEW 0
#endif
// Improvements (0 / 1 = original look):
// SMOOTH_COLOR / SMOOTH_LIGHT: the colour map (where magnified) and the
//   baked light map read with a cubic B-spline at texel centres instead of
//   the guest's point filter, which shows every texel as a hard square on
//   the ground at the higher render resolution.
// ALBEDO_BUMP / FOG: as in lit.ps.hlsl.
#ifndef SMOOTH_COLOR
#define SMOOTH_COLOR 1
#endif
#ifndef SMOOTH_LIGHT
#define SMOOTH_LIGHT 1
#endif
#ifndef ALBEDO_BUMP
#define ALBEDO_BUMP 5.0
#endif
#ifndef FOG
#define FOG 0.6
#endif

// --- SDK translator interface (shaders/xe_common.hlsli) -------------------
#define XE_FLOAT_CONSTANTS 16
#define XE_DESCRIPTOR_INDICES 5
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
#define C66 K[8]
#define C67 K[9]
#define C68 K[10]
#define C80 K[11]
#define C87 K[12]
#define C109 K[13]
#define C254 K[14]
#define C255 K[15]

struct PSInput8c {
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
#define TF0(uv) Fetch(0, 2, uv, false)
#define TF0_OFF(uv, ox, oy) FetchOffset(0, 2, uv, int2(ox, oy))
#define TF3(uv) Fetch(3, 3, uv, false)
#define TF4(x) Fetch(4, 4, float2(x, 0.0), true)
#define TF5(x) Fetch(5, 5, float2(x, 0.0), true)


// 16 texel-centre reads of fetch constant `tf` / `binding` at level 0,
// blended with B-spline weights.


float4 main(PSInput8c input) : SV_Target0 {
  float4 r0 = input.v0, r1 = input.v1, r2 = input.v2, r3 = input.v3;
  float4 r4 = input.v4, r5 = input.v5, r6 = input.v6, r7 = input.v7;
  float4 r8 = 0.0, r9 = 0.0, r10 = 0.0;
  float ps;
  r8.xy = GuestPixelPosition(input.position, input.front_face);
  float2 color_uv = r0.xy;

  r7.xy = abs(r8.xy) * C0.zw + C0.xy;                                    // 6
  r1.w = TF8(r7.xy).x;                                                   // 7
#if SPARROW
  // Sparrow: the sun shadow map (sparrow_common.hlsli).
  r1.w = SparrowSunOr(r1.w, input.v2.xyz, normalize(input.v1.xyz));
#endif
  r9.xy = TF2(r0.xy).xy;                                                 // 8
  r10.xyz = TF0(r0.xy).xyz;                                              // 9
  float magnify = 0.0;
  if (SMOOTH_COLOR) {
    magnify = Magnification(2, color_uv);
    if (magnify > 0.0) r10.xyz = lerp(r10.xyz, SmoothFetch(0, 2, color_uv).xyz, magnify);
  }
  { float4 t = SMOOTH_LIGHT ? SmoothFetch(3, 3, r3.xy) : TF3(r3.xy);     // 10
    r0.x = t.x; r0.y = t.y; r0.w = t.z; }
  r8.xyz = -r2.zyx + C19.zyx;                                            // 11
  { float s = log2(abs(r0.x)); r7.x = dot(r6.zxy, r6.zxy); r2.x = s; }   // 12
  { float s = log2(abs(r0.y)); r3.xyz = r10.xyz * r10.xyz; r2.y = s; }   // 13
  r9.xy = r9.yx * C254.x + C254.z;                                       // 14
  if (ALBEDO_BUMP != 0.0) {
    float3 lw = float3(0.299, 0.587, 0.114);
    float he = dot(TF0_OFF(color_uv, 1, 0).xyz, lw), hw = dot(TF0_OFF(color_uv, -1, 0).xyz, lw);
    float hn = dot(TF0_OFF(color_uv, 0, 1).xyz, lw), hs = dot(TF0_OFF(color_uv, 0, -1).xyz, lw);
    r9.xy -= float2(he - hw, hn - hs) * (0.5 * ALBEDO_BUMP * (1.0 - 0.7 * magnify));
  }
  { float s = rsqrt(abs(r7.x)); r7.y = dot(r8.xzy, r8.xzy); r7.x = s; }  // 15
  { float s = log2(abs(r0.w)); r0.xyz = r7.x * r6.zyx; r2.w = s; }       // 16
  r0.w = dot(r9.yx, r9.yx) + C254.y;                                     // 17
  { float s = rsqrt(abs(r7.y)); r5.xyz = r9.x * r5.zxy; r2.z = s; }      // 18
  r5.xyz = r9.y * r4.zxy + r5.xyz;                                       // 19
  { float s = sqrt(abs(r7.y)); r2.xyw = r2.xyw * C21.w; r7.x = s; }      // 20
  { float s = exp2(r2.x); r7.x = r7.x - C67.x; r4.x = s; }               // 21
  { float s = exp2(r2.y); r0.w = -r0.w + C254.w; r4.y = s; }             // 22
  { float s = sqrt(abs(r0.w)); r2.xyz = r8.xyz * r2.z; r0.w = s; }       // 23
  r1.xyz = r0.w * r1.zyx + r5.xzy;                                       // 24
  { float s = exp2(r2.w); r0.w = dot(r1.xzy, r1.xzy); r4.z = s; }        // 25
  { float s = rsqrt(abs(r0.w)); r4.xyz = r4.xyz * C21.xyz; r0.w = s; }   // 26
  float3 light = r4.xyz;
  r5.xyz = r1.zyx * r0.w;                                                // 27
  r0.y = saturate(dot(r0.xzy, r5.zxy)); ps = -C22.x;                     // 28
  { float s = ps + C254.w; r0.z = saturate(dot(r5.zxy, C80.zxy)); r1.x = s; }  // 29
  r0.x = dot(r5.zxy, C109.zxy); ps = -C22.y;                             // 30
  { float s = ps + C254.w; r0.x = saturate(r0.x * C255.x); r1.y = s; }   // 31
  r0.x = r0.x * r1.w; ps = -C22.z;                                       // 32
  { float s = ps + C254.w; r0.xy = r0.xy * r0.zy; r1.z = s; }            // 33
  r1.xyz = r0.y * r1.xyz + C22.xyz;                                      // 34
  r0.xyz = r0.x * C87.xyz;                                               // 35
  r0.xyz = r3.xyz * r0.xyz;                                              // 36
  r1.xyz = r4.xyz * r1.xyz + C20.xyz;                                    // 37
  float sky_vis = -1.0;
#if SPARROW
  // Sparrow: sky light and bounce from the ground ambient grid.
  if (SparrowActive()) {
    float3 a = SparrowGroundAmbientLight(r1.xyz, input.v2.xyz, normalize(input.v1.xyz), C87.xyz / max(C11.x, 1e-3), sky_vis);
    r1.xyz = a;
  }
  float3 ambient = r1.xyz;  // the ambient light, before the albedo
#endif
  r1.xyz = r3.xyz * r1.xyz;                                              // 38
  bool fog = r7.x > 0.0;
  r0.xyz = r1.xyz * C11.x + r0.xyz;                                      // 39
#if SPARROW
  SparrowWet sp_wet = (SparrowWet)0;
  if (SparrowActive()) {
    // the cobbles' faint sky sheen; wet in the rain
    float3 sheen = SparrowGroundWetSheen(r0.xyz, ambient * C11.x, input.v2.xyz, input.position.xy,
                                         r5.xyz, r2.zyx, C20.w * xe_color_exp_bias.x, sp_wet);
    r0.xyz += sheen;
    if (SparrowDebug() == 2) r0.xyz = sheen;
  }
#endif
  if (fog) {
    { float s = C67.w * r7.x; r1.x = saturate(dot(-r2.xzy, C66.zxy)); r0.w = s; }  // 40
    r1.xyz = TF4(r1.x).xyz;                                              // 41
    r2.xyz = TF5(r0.w).xyz;                                              // 42
    r3.xyz = C254.w - r2.xyz;                                            // 43
    { float s = saturate(C67.z * r7.x); r1.xyz = r1.xyz - C68.xyz; r0.w = s; }  // 44
    r1.xyz = r0.w * r1.zyx + C68.zyx;                                    // 45
    r3.xyz = r3.zyx * C28.y;                                             // 46
    r1.xyz = r3.xyz * r1.xyz - r0.zyx;                                   // 47
    r1.xyz = r0.zyx * r2.zyx + r1.xyz;                                   // 48
    r0.xyz = r1.zyx * (C28.x * FOG) + r0.xyz;                            // 49
  }
  r7.x = saturate(r7.y * C31.x + C31.y);                                 // 50
  r7.x = C254.w - r7.x;                                                  // 51
  float4 o = float4(r0.xyz * C20.w, r7.x * r7.w);                        // 52-53
#if DEBUG_VIEW == 1
  o.xyz = sqrt(r3.xyz);  // colour map alone
#elif DEBUG_VIEW == 2
  o.xyz = light * 0.5;   // baked light alone
#endif
#if SPARROW
  // red open sky, green closed in (sparrow_debug 3)
  if (SparrowDebug() == 3) o.xyz = SparrowVisDebug(sky_vis);
  if (SparrowDebug() == 10) o.xyz = SparrowWetDebug(sp_wet);
#endif
  return o * xe_color_exp_bias.x;
}
