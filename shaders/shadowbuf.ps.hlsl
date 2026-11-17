// Fable II screen-space sun shadow buffer, pixel shader 0F99810F072BF0FC:
// the full-screen pass, after the depth pre-pass and the game's own shadow
// map passes, that writes the buffer every lit material then reads at its
// pixel position (tf8 in lit.ps.hlsl, terrain.ps.hlsl and the rest). Built
// only for Project Sparrow (tools/shaders/build_replace.py --sparrow), where
// the buffer also takes the real sun shadow map wherever that covers the
// pixel (the darker of the two), so every material, ported or not, is
// shadowed by it.
//
// Stage 1: a literal port of the game's Xenos microcode (comments give the
// ucode instruction numbers). What the original does:
//   - the scene depth tf13 at the pixel (through c46 / c248) gives the
//     normalised device position; c116..c119 take it to the world, c31 is
//     the camera, r0.w the distance;
//   - near the camera (distance < c12.x + c12.z) a 13-tap rotated-disc PCF
//     in the near cascade tf6: offsets c250..c255 rotated by a noise texture
//     tf14 at the pixel (c47), cascade matrix c36..c39, scale c77.x;
//   - between c12.x and c12.y + c248.x, a bilinear 2x2 PCF in the far
//     cascade tf7 (matrix c40..c43);
//   - the two blended over c12.x .. c12.x + c12.z, then faded towards c12.w
//     past c12.y (c249.w scales the fade); 1 = lit.
// Xenos reading notes are in xe_common.hlsli.

// --- SDK translator interface (shaders/xe_common.hlsli) -------------------
#define XE_FLOAT_CONSTANTS 25
#define XE_DESCRIPTOR_INDICES 4
#include "xe_common.hlsli"
#if SPARROW
#include "sparrow_common.hlsli"
#endif

#define C12 K[0]
#define C31 K[1]
#define C36 K[2]
#define C37 K[3]
#define C38 K[4]
#define C39 K[5]
#define C40 K[6]
#define C41 K[7]
#define C42 K[8]
#define C43 K[9]
#define C46 K[10]
#define C47 K[11]
#define C77 K[12]
#define C116 K[13]
#define C117 K[14]
#define C118 K[15]
#define C119 K[16]
#define C248 K[17]
#define C249 K[18]
#define C250 K[19]
#define C251 K[20]
#define C252 K[21]
#define C253 K[22]
#define C254 K[23]
#define C255 K[24]

// Texture bindings of this shader, in the translator's order.
#define TF13(uv) Fetch(13, 0, uv, false)
#define TF14(uv) Fetch(14, 1, uv, false)
#define TF6(uv) Fetch(6, 2, uv, false)
#define TF7(uv) Fetch(7, 3, uv, false)
#define TF7_OFF(uv, ox, oy) FetchOffset(7, 3, uv, int2(ox, oy))

struct PSInput0 {
  noperspective float4 position : SV_Position;
  bool front_face : SV_IsFrontFace;
};

float Gt(float a, float b) { return a > b ? 1.0 : 0.0; }
float4 Gt4(float a, float4 b) { return float4(a > b.x, a > b.y, a > b.z, a > b.w); }
float4 Ge4(float a, float4 b) { return float4(a >= b.x, a >= b.y, a >= b.z, a >= b.w); }

float4 main(PSInput0 input) : SV_Target0 {
  float4 r0 = 0.0, r1 = 0.0, r2 = 0.0, r3 = 0.0, r4 = 0.0, r5 = 0.0;
  float4 r6 = 0.0, r7 = 0.0, r8 = 0.0, r9 = 0.0;
  r0.xy = GuestPixelPosition(input.position, input.front_face);

  r1 = C46.zwzw + C249.zzyy; r3.w = C249.y;                              // 11
  r1.zw = r1.zw + C46.zw;                                                // 12
  r1.xy = r1.xy + abs(r0.xy);                                            // 13
  r1.zw = abs(r0.xy) * C248.w + r1.zw;                                   // 14
  r1 = r1.xywz * C46.xyyx;                                               // 15
  r0.z = TF13(r1.xy).x;                                                  // 16
  r2.x = r1.w + C248.z; r2.z = r1.z + C248.z; r2.y = C249.y - r0.z;      // 17
  r3.xyz = float3(C249.x == 0.0 ? -r2.z : r2.y,                          // 18
                  C249.y == 0.0 ? -r2.z : r2.y,
                  C249.y == 0.0 ? -r2.z : r2.x);
  r1.x = dot(C116.zxyw, r3.yzxw);                                        // 19
  r1.y = dot(C117.zxyw, r3.yzxw);                                        // 20
  r0.w = dot(C119.zxyw, r3.yzxw);                                        // 21
  r1.z = dot(C118.zxyw, r3.yzxw); r0.w = rcp(r0.w);                      // 22
  float3 world = r1.xyz * r0.w;  // world position (Sparrow)
  r1.xyz = r1.zyx * r0.w - C31.zyx;                                      // 23
  r0.w = dot(r1.xzy, r1.xzy);                                            // 24
  r1.x = C12.x + C12.z; r0.w = sqrt(abs(r0.w));                          // 25
  r1.x = Gt(r1.x, r0.w);                                                 // 26
  r3.xy = Gt(-abs(r0.x), C249.x);                                        // 27
  if (r1.x != 0.0) {
    r0.xy = abs(r0.xy) + C47.xy;                                         // 28
    r0.xy = r0.yx * C47.wz;                                              // 29
    r0.xy = TF14(r0.yx).xy;                                              // 30
    r9.xyz = float3(C249.x == 0.0 ? r2.y : -r2.z,                        // 31
                    C249.x == 0.0 ? r2.x : -r2.z,
                    C249.y == 0.0 ? r2.x : -r2.z);
    r0.xy = r0.xy * C248.w + C248.z;                                     // 32
    r1.xz = r0.x * C254.xy;                                              // 33
    r5.xz = r0.x * C251.xy; r9.w = C249.y;                               // 34
    r8.xz = r0.x * C255.xy;                                              // 35
    r6.xz = r0.x * C253.zw; r7.x = r0.x * C252.z;                        // 36
    r1.yw = -r0.y * C254.xy;                                             // 37
    r5.yw = -r0.y * C251.xy; r7.z = r0.x * C252.w;                       // 38
    r8.yw = -r0.y * C255.xy; r4.x = C251.z * r0.x;                       // 39
    r7.yw = -r0.y * C252.zw; r4.z = C251.w * r0.x;                       // 40
    r6.yw = -r0.y * C253.zw;                                             // 41
    r3.y = dot(C36.zxyw, r9); r4.y = -r0.y * C251.z;                     // 42
    r3.z = dot(C37.zxyw, r9);                                            // 43
    r3.w = dot(C38.zxyw, r9); r4.w = -r0.y * C251.w;                     // 44
    r4 = r0.yxyx * C254.zzww + r4;                                       // 45
    r6 = r0.yxyx * C250.zzww + r6;                                       // 46
    r7 = r0.yxyx * C255.zzww + r7;                                       // 47
    r8 = r0.yxyx * C252.xxyy + r8;                                       // 48
    r5 = r0.yxyx * C250.xxyy + r5;                                       // 49
    r1 = r0.yxyx * C253.xxyy + r1;                                       // 50
    { float v = dot(C39.zxyw, r9); r0.y = r1.x; r0.x = v; }              // 51
    r5 *= C77.x; r9.x = C77.x * r0.y;                                    // 52
    r8 *= C77.x; r9.y = C77.x * r1.y;                                    // 53
    r7 *= C77.x; r9.z = C77.x * r1.z;                                    // 54
    r6 *= C77.x; r9.w = C77.x * r1.w;                                    // 55
    r1 = r4 * C77.x; r0.x = rcp(r0.x);                                   // 56
    r4 = r3.yzyz * r0.x + r1;                                            // 57
    r6 = r3.yzyz * r0.x + r6;                                            // 58
    r7 = r3.yzyz * r0.x + r7;                                            // 59
    r8 = r3.yzyz * r0.x + r8;                                            // 60
    r5 = r3.yyzz * r0.x + r5.zxyw;                                       // 61
    r1 = r3.yzyz * r0.x + r9;                                            // 62
    r1.x = TF6(r1.xy).x;                                                 // 63
    r1.y = TF6(r5.xw).x;                                                 // 64
    r1.z = TF6(r1.zw).x;                                                 // 65
    r1.w = TF6(r8.zw).x;                                                 // 66
    r5.x = TF6(r7.xy).x;                                                 // 67
    r5.y = TF6(r5.yz).x;                                                 // 68
    r5.z = TF6(r6.xy).x;                                                 // 69
    r5.w = TF6(r4.xy).x;                                                 // 70
    r4.x = TF6(r8.xy).x;                                                 // 71
    r4.y = TF6(r7.zw).x;                                                 // 72
    r4.z = TF6(r4.zw).x;                                                 // 73
    r4.w = TF6(r6.zw).x;                                                 // 74
    r0.x = -r3.w * r0.x + C249.y;                                        // 75
    r4 = Gt4(r0.x, r4);                                                  // 76
    r5 = Gt4(r0.x, r5);                                                  // 77
    r1 = Gt4(r0.x, r1);                                                  // 78
    r0.x = dot(r1.yzw, C249.yyy);                                        // 79
    r0.z = dot(r5.yzwx, C249.yyyy);                                      // 80
    r0.y = dot(r4.yzw, C249.yyy);                                        // 81
    r0.y = r0.z + r0.y;                                                  // 82
    r0.y = r0.y + r4.x;                                                  // 83
    r0.x = r0.y + r0.x;                                                  // 84
    r0.x = r0.x + r1.x;                                                  // 85
    r3.y = C248.y * r0.x;                                                // 86
  }
  r0.x = C12.y + C248.x;                                                 // 87
  r0.y = Gt(r0.w, C12.x);                                                // 88
  r0.x = Gt(r0.x, r0.w);                                                 // 89
  r0.x = r0.y * r0.x;                                                    // 90
  if (r0.x != 0.0) {                                                     // 91
    r4.w = C249.y;                                                       // 92
    r4.xyz = float3(C249.x == 0.0 ? r2.y : -r2.z,                        // 93
                    C249.x == 0.0 ? r2.x : -r2.z,
                    C249.y == 0.0 ? r2.x : -r2.z);
    r1.x = dot(C40.zxyw, r4);                                            // 94
    r1.y = dot(C41.zxyw, r4);                                            // 95
    r0.x = dot(C43.zxyw, r4);                                            // 96
    r1.z = dot(C42.zxyw, r4); r0.x = rcp(r0.x);                          // 97
    r0.xyz = r1.zxy * r0.x;                                              // 98
    r1.x = TF7_OFF(r0.yz, -1, -1).x;                                     // 99
    r1.y = TF7_OFF(r0.yz, 0, -1).x;                                      // 100
    r1.z = TF7_OFF(r0.yz, -1, 0).x;                                      // 101
    r1.w = TF7(r0.yz).x;                                                 // 102
    r2.zw = frac(r0.yz * TextureSize(7) - 0.5);                          // 103
    r2.xy = -r2.zw + C249.y;                                             // 104
    r2 = r2.xyxz * r2.yzww; r0.x = C249.y - r0.x;                        // 105
    r1 = Ge4(r0.x, r1);                                                  // 106
    r3.x = dot(r2.wzxy, r1.wzxy);                                        // 107
  }
  r0.z = r3.x - r3.y;                                                    // 108
  { float2 v = r0.w - C12.yx; r0.w = rcp(C12.z); r0.xy = v; }            // 109
  r0.w = saturate(r0.y * r0.w);                                          // 110
  r0.z = r0.w * r0.z + r3.y;                                             // 111
  r0.w = -r0.z + C12.w; r0.x = saturate(C249.w * r0.x);                  // 112
  float4 o = float4(r0.x * r0.w + r0.z, r0.x * r0.w + r0.z, r0.x * r0.w + r0.z, 1.0);  // 113
#if SPARROW
  // The real sun shadow map wherever it covers the pixel; the normal from
  // the world position's screen derivatives (a flat-shaded estimate, only
  // used for the normal offset and to leave back faces to the game).
  float3 n = cross(ddy(world), ddx(world));
  n = dot(n, n) > 1e-12 ? normalize(n) : float3(0.0, 0.0, 0.0);
  if (dot(n, C31.xyz - world) < 0.0) n = -n;  // toward the camera
  float s = SparrowSunShadow(world, n);
  // Shadowed if either map says so: the game's cascade also holds casters
  // off screen (trees behind the camera), which ours, replayed from the
  // camera's depth pre-pass, does not.
  if (s >= 0.0) o.xyz = min(o.xyz, lerp(SPARROW_MAP_LEAK, 1.0, s));  // canopy leak (SparrowSunOr)
#endif
  return o * xe_color_exp_bias.x;
}
