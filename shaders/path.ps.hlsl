// Fable II lit ground decals with point lights, pixel shader
// 578342593A37DD35: the cobbles, flagstones and paths of the towns
// (Bowerstone Market's streets), drawn over the terrain. Built only for
// Project Sparrow (tools/shaders/build_replace.py --sparrow).
//
// Stage 1: a literal port of the game's Xenos microcode (comments give the
// ucode instruction numbers). What the original does:
//   - tf0 colour at v0.xy (squared to linear), tf2 two-channel normal map,
//     tangent frame v4 / v5 / v1; world position v2, camera c19;
//   - tf3 baked light at v3.xy raised to c21.w and tinted by c21.xyz, a sky
//     term from c109 / c255.x and v6, ambient c22 / c20, scale c11.x;
//   - four lights c80..c83 (position, w = 1 point / 0 directional) with
//     colours c87..c90, range c96, spot axes c98..c101 and cone c105 / c107
//     / c94; c112 picks the sun's slot, which the screen-space shadow tf8
//     dims; under b135 a projected shadow map tf9 (c32..c35, c48) dims the
//     slot c114 picks;
//   - distance fog beyond c67.x (tf4 / tf5 ramps, c66 / c68 / c28) and an
//     alpha fade with distance (c31) times v7.w.
// Sparrow adds a physically based specular for the four lights and a sky
// reflection at grazing angles (sparrow_common.hlsli).
// Xenos reading notes are in xe_common.hlsli.

#ifndef SPARROW_ROUGHNESS
#define SPARROW_ROUGHNESS 0.55  // worn stone; the gloss rises in the gaps' wet dirt
#endif
#ifndef SPARROW_REFLECT
#define SPARROW_REFLECT 1.0 // screen-space reflection strength (x Fresnel, roughness)
#endif
#ifndef SPARROW_SKY_REFLECT
#define SPARROW_SKY_REFLECT 0.25  // a faint sheen: the ground beside the cobbles has none, and more draws a seam at their edge
#endif

// --- SDK translator interface (shaders/xe_common.hlsli) -------------------
#define XE_FLOAT_CONSTANTS 37
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
#define C82 K[18]
#define C83 K[19]
#define C87 K[20]
#define C88 K[21]
#define C89 K[22]
#define C90 K[23]
#define C94 K[24]
#define C96 K[25]
#define C98 K[26]
#define C99 K[27]
#define C100 K[28]
#define C101 K[29]
#define C105 K[30]
#define C107 K[31]
#define C109 K[32]
#define C112 K[33]
#define C114 K[34]
#define C254 K[35]
#define C255 K[36]

// Texture bindings of this shader, in the translator's order.
#define TF8(uv) Fetch(8, 0, uv, false)
#define TF2(uv) Fetch(2, 1, uv, false)
#define TF3(uv) Fetch(3, 2, uv, false)
#define TF0(uv) Fetch(0, 3, uv, false)
#define TF9_OFF(uv, ox, oy) FetchOffset(9, 4, uv, int2(ox, oy))
#define TF4(x) Fetch(4, 5, float2(x, 0.0), true)
#define TF5(x) Fetch(5, 6, float2(x, 0.0), true)

float4 Ge4(float a, float4 b) { return float4(a >= b.x, a >= b.y, a >= b.z, a >= b.w); }

#if SPARROW
float3 PathRGB(float2 b) { return TF0(b).xyz; }
SPARROW_RELIEF_FUNCS(Path, PathRGB)
float4 TF0R(float2 uv) { SparrowReliefGrads(1.0); float4 t = TF0(uv); xe_grad_override = false; return t; }
float4 TF2R(float2 uv) { SparrowReliefGrads(1.0); float4 t = TF2(uv); xe_grad_override = false; return t; }
#else
#define TF0R(uv) TF0(uv)
#define TF2R(uv) TF2(uv)
#endif

float4 main(PSInput8 input) : SV_Target0 {
  float4 r0 = input.v0, r1 = input.v1, r2 = input.v2, r3 = input.v3;
  float4 r4 = input.v4, r5 = input.v5, r6 = input.v6, r7 = input.v7;
  float4 r8 = 0.0, r9 = 0.0, r10 = 0.0, r11 = 0.0, r12 = 0.0;
  r8.xy = GuestPixelPosition(input.position, input.front_face);
  float3 world = input.v2.xyz;
#if SPARROW
  // Sparrow: surface relief, the colour and normal map read where the view
  // ray meets the height field.
  float relief_h = 1.0, relief_shadow = 1.0;
  if (SparrowActive()) {
    SparrowReliefFrame rf = SparrowReliefBegin(world, C19.xyz, input.v0.xy, SPARROW_RELIEF_DEPTH);
    [branch] if (rf.fade > 0.0) {
      r0.xy = PathRelief(input.v0.xy, input.position.xy, rf, 1.0, true, relief_h, relief_shadow);
      sp_relief_on = true;
      sp_relief_dx = rf.dx;
      sp_relief_dy = rf.dy;
    }
  }
#endif

  r7.xy = abs(r8.xy) * C0.zw + C0.xy;                                    // 11
  r8.z = TF8(r7.xy).x;                                                   // 12
  r3.zw = TF2R(r0.xy).xy;                                                // 13
  { float4 t = TF3(r3.xy); r7.x = t.y; r7.y = t.z; r7.z = t.x; }         // 14
  r0.xyz = TF0R(r0.xy).xyz;                                              // 15
#if SPARROW
  r8.z *= relief_shadow;  // Sparrow: the stones shade the gaps from the sun
#endif
  r0.w = dot(r6.zxy, r6.zxy);                                            // 16
  r9.xyz = -r2.zyx + C19.zyx; r0.w = rsqrt(abs(r0.w));                   // 17
  r0.xyz = r0.xyz * r0.xyz; r3.x = log2(abs(r7.z));                      // 18
  float3 albedo = r0.xyz;  // Sparrow: linear albedo
  { float v = dot(r9.xzy, r9.xzy); r3.y = log2(abs(r7.x)); r7.z = v; }   // 19
  { float2 v = r3.wz * C254.w + C254.z; r3.z = v.x; r3.w = v.y; }        // 20
  r7.x = dot(r3.wz, r3.wz) + C254.x;                                     // 21
  { float3 v = r3.z * r5.zxy; r3.z = log2(abs(r7.y)); r5.xyz = v; }      // 22
  { float3 v = r3.w * r4.zxy + r5.xyz; r8.x = v.x; r8.y = v.y; r8.w = v.z; }  // 23
  { float3 v = r3.xyz * C21.w; r7.y = rsqrt(abs(r7.z)); r3.x = v.x; r3.y = v.y; r3.w = v.z; }  // 24
  r4.xyz = r0.w * r6.zyx; r5.x = exp2(r3.x);                             // 25
  r7.x = -r7.x + C254.y; r5.y = exp2(r3.y);                              // 26
  r3.xyz = r9.xyz * r7.y; r7.x = sqrt(abs(r7.x));                        // 27
  r1.xyz = r7.x * r1.zyx + r8.xwy;                                       // 28
  r7.x = dot(r1.xzy, r1.xzy); r5.z = exp2(r3.w);                         // 29
  r6.xyz = r5.xyz * C21.xyz; r7.x = rsqrt(abs(r7.x));                    // 30
  r5.xyz = r1.xyz * r7.x;                                                // 31
  float3 n_world = r5.zyx;  // Sparrow: the shading normal in world order
  r8.y = saturate(dot(r4.xzy, r5.xzy));                                  // 32
  r7.y = dot(r5.xzy, C109.zxy);                                          // 33
  r1.xyz = -C22.xyz + C254.y; r8.x = saturate(C255.x * r7.y);            // 34
  r7.xy = r8.xy * r8.zy;                                                 // 35
  r4.xyz = r7.y * r1.xyz + C22.xyz;                                      // 36
  r7.y = C254.y - r7.x;                                                  // 37
  r1 = r7.y * C112;                                                      // 38
  r4.xyz = r6.xyz * r4.xyz + C20.xyz;                                    // 39
  float sky_vis = -1.0;
#if SPARROW
  if (SparrowActive()) {
    float3 sun = C87.xyz * C112.x + C88.xyz * C112.y + C89.xyz * C112.z + C90.xyz * C112.w;
    r4.xyz = SparrowGroundAmbientLight(r4.xyz, world, n_world, sun, sky_vis);
  }
#endif
  float3 ambient = r4.xyz;  // Sparrow: the ambient light, before the albedo
  r4.xyz = r0.xyz * r4.xyz;                                              // 40
  r4.xyz = r4.xzy * C11.x; r7.y = sqrt(abs(r7.z));                       // 41
  if (XeBool(135)) {
    r10 = float4(C254.x == 0.0 ? r2.z : C254.y, C254.x == 0.0 ? r2.x : C254.y,  // 42
                 C254.x == 0.0 ? r2.y : C254.y, C254.y == 0.0 ? r2.y : C254.y);
    r6.z = dot(C32.zxyw, r10); r6.x = rcp(C48.x);                        // 43
    r7.x = dot(C35.zxyw, r10); r6.y = rcp(C48.y);                        // 44
    { float v = dot(C33.zxyw, r10); r7.x = rcp(r7.x); r6.w = v; }        // 45
    r9 = r6 * r7.x;                                                      // 46
    r8.x = TF9_OFF(r9.zw, 0, 0).x;                                       // 47
    r8.y = TF9_OFF(r9.zw, 0, 1).x;                                       // 48
    r8.z = TF9_OFF(r9.zw, 1, 0).x;                                       // 49
    r8.w = TF9_OFF(r9.zw, 1, 1).x;                                       // 50
    r0.w = dot(C34.zxyw, r10);                                           // 51
    r6.xy = r9.xy * r6.zw;                                               // 52
    { float2 v = frac(float2(r6.y, r6.x)); r6.y = v.x; r6.z = v.y; }     // 53
    r6.x = -r6.y + C254.y; r6.w = r0.w * r7.x;                           // 54
    r9.xy = -r6.wz + C254.y;                                             // 55
    r8 = Ge4(r9.x, r8);                                                  // 56
    r8.xy = r9.y * r8.xy;                                                // 57
    r8.zw = r8.zw * r6.z;                                                // 58
    r7.x = dot(r8.wyxz, r6.yyxx);                                        // 59
    r0.w = C254.y - r7.x;                                                // 60
    r6 = r0.w * C114;                                                    // 61
    r1 = max(r1, r6);                                                    // 62
  }
  r12.xyz = -r2.xyz * C83.w + C83.xyz;                                   // 63
  r9.xyz = -r2.xyz * C82.w + C82.xyz;                                    // 64
  r10.xyz = -r2.xyz * C81.w + C81.xyz;                                   // 65
  r11.xyz = -r2.xyz * C80.w + C80.xyz;                                   // 66
  r0.w = dot(r11.zxy, r11.zxy);                                          // 67
  { float v = dot(r10.zxy, r10.zxy); r6.x = sqrt(abs(r0.w)); r2.x = v; } // 68
  { float v = dot(r9.zxy, r9.zxy); r6.y = sqrt(abs(r2.x)); r3.w = v; }   // 69
  { float v = dot(r12.zxy, r12.zxy); r6.z = sqrt(abs(r3.w)); r7.x = v; } // 70
  { float4 v = -r1 + C254.y; r1.x = rsqrt(abs(r7.x)); r8 = v; }          // 71
  { float3 v = r12.xyz * r1.x; r1.x = rsqrt(abs(r3.w)); r2.y = v.x; r2.z = v.y; r2.w = v.z; }  // 72
  { float3 v = r9.xyz * r1.x; r1.x = rsqrt(abs(r2.x)); r9.xyz = v; }     // 73
  { float3 v = r10.xyz * r1.x; r0.w = rsqrt(abs(r0.w)); r10.xyz = v; }   // 74
  r11.xyz = r11.xyz * r0.w; r6.w = sqrt(abs(r7.x));                      // 75
  float3 l0 = r11.xyz, l1 = r10.xyz, l2 = r9.xyz, l3 = float3(r2.y, r2.z, r2.w);  // Sparrow
#if SPARROW
  // Sparrow: lamp shadows (screen space) dim the lights' shadow factor
  // before the game lights with it.
  float4 lamp_vis = 1.0;
  if (SparrowActive()) {
    lamp_vis = SparrowLampShadows4(input.v2.xyz, input.position.xy, C80, C81, C82, C83, C96);
    r8 *= lamp_vis;
  }
#endif
  r1 = saturate(-r6.wzyx * C96.wzyx + C254.y);                           // 76
  r6.x = dot(r11.zxy, C98.zxy);                                          // 77
  r6.y = dot(r10.zxy, C99.zxy);                                          // 78
  r6.z = dot(r9.zxy, C100.zxy);                                          // 79
  r6.w = dot(float3(r2.w, r2.y, r2.z), C101.zxy);                        // 80
  r2.x = saturate(dot(r5.xzy, r11.zxy));                                 // 81
  r2.y = saturate(dot(r5.xzy, float3(r2.w, r2.y, r2.z)));                // 82
  r2.z = saturate(dot(r5.xzy, r10.zxy));                                 // 83
  r2.w = saturate(dot(r5.xzy, r9.zxy));                                  // 84
  r2 = r8.xwyz * r2;                                                     // 85
  r5 = r6 - C105;                                                        // 86
  r5 = saturate(r5 * C107);                                              // 87
  r1 = r5.wzyx * r1 + C254.z;                                            // 88
  r1 = r1 * C94.wzyx + C254.y;                                           // 89
  float4 light_mask = r8;   // Sparrow: per light 0..3, the shadow factor
  float4 light_atten = r1;  // Sparrow: (light 3, 2, 1, 0) range * spot
  r1 = r2.wyzx * r1.yxzw; r7.x = -C67.x - (-r7.y);                       // 90
  bool fog = r7.x > 0.0;                                                 // 91
  r2.xyz = r1.y * C90.xyz;
  r2.xyz = r1.x * C89.xzy + r2.xzy;                                      // 92
  r1.xyz = r1.z * C88.xyz + r2.xzy;                                      // 93
  r1.xyz = r1.w * C87.xzy + r1.xzy;                                      // 94
  r0.xyz = r0.xyz * r1.xzy + r4.xzy;                                     // 95
#if SPARROW
  float4 refl = 0.0;
  SparrowWet wet = (SparrowWet)0;
  if (SparrowActive()) {
    // Specular for the four lights (shadow and range / spot as the diffuse
    // has them) and the sky's reflection at grazing angles. Crevices (dark
    // albedo: dirt between the stones) are rougher than the worn tops.
    float3 v = r3.zyx;  // toward the camera, normalised at 27
    float lum = sqrt(max(dot(albedo, float3(0.2126, 0.7152, 0.0722)), 0.0));
    float rough = saturate(SPARROW_ROUGHNESS + 0.25 * (0.35 - lum));
    // Rain: the dark gaps between the stones fill first.
    float3 geo_n = normalize(cross(ddy(input.v2.xyz), ddx(input.v2.xyz)));
    wet = SparrowWetGround(input.v2.xyz, saturate((0.4 - lum) * 3.0), abs(geo_n.z));
    SparrowApplyWet(wet, r0.xyz, rough, n_world);
    float3 spec = SparrowSpecular(n_world, v, l0, rough, SPARROW_F0, C87.xyz * (light_mask.x * light_atten.w))
                + SparrowSpecular(n_world, v, l1, rough, SPARROW_F0, C88.xyz * (light_mask.y * light_atten.z))
                + SparrowSpecular(n_world, v, l2, rough, SPARROW_F0, C89.xyz * (light_mask.z * light_atten.y))
                + SparrowSpecular(n_world, v, l3, rough, SPARROW_F0, C90.xyz * (light_mask.w * light_atten.x));
    // Screen-space reflection where the ray finds the scene, else the sky.
    refl = SparrowReflectLight(input.v2.xyz, input.position.xy, n_world, v, rough, SPARROW_F0,
                               C20.w * xe_color_exp_bias.x, SPARROW_REFLECT);
    spec += ambient * C11.x * SparrowEnvSpecular(n_world, v, rough, SPARROW_F0) *
            lerp(SPARROW_SKY_REFLECT, SPARROW_WET_SKY, saturate(wet.film + wet.puddle)) * (1.0 - refl.a);
    spec += refl.rgb;
    r0.xyz += spec;
    if (SparrowDebug() == 2) r0.xyz = spec;
  }
#endif
  if (fog) {
    { float s = C67.w * r7.x; r1.x = saturate(dot(-r3.xzy, C66.zxy)); r0.w = s; }  // 96
    r1.xyz = TF4(r1.x).xyz;                                              // 97
    r2.xyz = TF5(r0.w).xyz;                                              // 98
    r3.xyz = -r2.xyz + C254.y;                                           // 99
    r1.xyz = r1.xyz - C68.xyz; r0.w = saturate(C67.z * r7.x);            // 100
    r1.xyz = r0.w * r1.zyx + C68.zyx;                                    // 101
    r3.xyz = r3.zyx * C28.y;                                             // 102
    r1.xyz = r3.xyz * r1.xyz - r0.zyx;                                   // 103
    r1.xyz = r0.zyx * r2.zyx + r1.xyz;                                   // 104
    r0.xyz = r1.zyx * C28.x + r0.xyz;                                    // 105
  }
  r7.x = saturate(r7.z * C31.x + C31.y);                                 // 106
  r7.x = C254.y - r7.x;                                                  // 107
  float4 o = float4(r0.xyz * C20.w, r7.x * r7.w);                        // 108-109
#if SPARROW
  if (SparrowDebug() == 3) o.xyz = SparrowVisDebug(sky_vis);  // red open, green closed
#endif
#if SPARROW
  if (SparrowDebug() == 5) o.xyz = SparrowLampDebug(lamp_vis);
  if (SparrowDebug() == 8) o.xyz = refl.rgb * C20.w;
  if (SparrowDebug() == 10) o.xyz = SparrowWetDebug(wet);
  if (SparrowDebug() == 12) o.xyz = float3(relief_h, relief_shadow, relief_h);
  if (SparrowDebug() == 7) o.xyz = SparrowDepthCheck(input.v2.xyz, input.position.xy);
#endif
  return o * xe_color_exp_bias.x;
}
