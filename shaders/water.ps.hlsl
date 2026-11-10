// Fable II water, pixel shaders A17D8AEC3A817D45 (open water) and
// F6D98C7B4D98438B (shore edge; compile with /D EDGE=1). Replaces the SDK's
// translation through the shader_replace_dir cvar (see shaders/README.md).
//
// Stage 1: a literal port of the game's Xenos microcode (comments give the
// ucode instruction numbers) against the SDK translator's interface, so the
// result should match the original exactly. Improvements build on this.
//
// Xenos notes for reading the port: swizzles map to destination components
// by position (r0.xy_w <- src.xyzz writes x<-x, y<-y, w<-z); co-issued
// vector and scalar ops read their sources before either writes; "ps" is
// the previous scalar result.

#ifndef EDGE
#define EDGE 0
#endif
#ifndef RES_SCALE
#define RES_SCALE 3.0
#endif
// Improvements (0 = original look):
// DETAIL: a third, finer and faster ripple layer from the same normal map.
// GLINT: a tight sun glint on top of the game's own specular.
#ifndef DETAIL
#define DETAIL 0.5
#endif
#ifndef DETAIL_SCALE
#define DETAIL_SCALE 2.7
#endif
#ifndef GLINT
#define GLINT 2.0
#endif
// FRESNEL: power on the view-angle term (1 = original, linear). Higher
// shows more of the water itself looking down and keeps the mirror-like
// sky reflection for low angles, like real water.
#ifndef FRESNEL
#define FRESNEL 2.5
#endif

// --- SDK translator interface (must match the translated shader) -----------
cbuffer xe_system_cbuffer : register(b0) {
  uint xe_flags;
  float2 xe_tessellation_factor_range;
  uint xe_line_loop_closing_index;
  uint xe_vertex_index_endian;
  uint xe_vertex_index_offset;
  uint2 xe_vertex_index_min_max;
  float4 xe_user_clip_planes[6];
  float3 xe_ndc_scale;
  float xe_point_vertex_diameter_min;
  float3 xe_ndc_offset;
  float xe_point_vertex_diameter_max;
  float2 xe_point_constant_diameter;
  float2 xe_point_screen_diameter_to_ndc_radius;
  uint4 xe_texture_swizzled_signs[2];
  uint xe_textures_resolution_scaled;
  uint2 xe_sample_count_log2;
  float xe_alpha_test_reference;
  uint xe_alpha_to_mask;
  uint xe_edram_32bpp_tile_pitch_dwords_scaled;
  uint xe_edram_depth_base_dwords_scaled;
  float4 xe_color_exp_bias;
};
// Only the float constants the shader uses, packed in ascending order.
cbuffer xe_float_cbuffer : register(b1) { float4 K[26]; };
cbuffer xe_bool_loop_cbuffer : register(b2) {
  uint4 xe_bool_constants[2];
  uint4 xe_loop_constants[8];
};
cbuffer xe_fetch_cbuffer : register(b3) { uint4 xe_fetch_constants[48]; };
cbuffer xe_descriptor_indices_cbuffer : register(b4) { uint4 xe_descriptor_indices[6]; };
SamplerState xe_samplers[] : register(s0, space0);
Texture2DArray<float4> xe_textures_2d[] : register(t0, space1);

#define C0 K[0]
#define C19 K[1]
#define C20 K[2]
#define C28 K[3]
#define C31 K[4]
#define C66 K[5]
#define C67 K[6]
#define C68 K[7]
#define C116 K[8]
#define C117 K[9]
#define C126 K[10]
#define C127 K[11]
#define C128 K[12]
#define C129 K[13]
#define C130 K[14]
#define C131 K[15]
#define C136 K[16]
#define C137 K[17]
#define C138 K[18]
#define C139 K[19]
#define C140 K[20]
#define C141 K[21]
#define C142 K[22]
#define C143 K[23]
#define C254 K[24]
#define C255 K[25]

bool B136() { return (xe_bool_constants[1].x & 256u) != 0; }
bool B137() { return (xe_bool_constants[1].x & 512u) != 0; }

uint DescriptorIndex(uint i) { return xe_descriptor_indices[i >> 2][i & 3]; }
uint FetchDword(uint i) { return xe_fetch_constants[i >> 2][i & 3]; }

// Guest gamma (PWL) to linear, as the translator does for signed mode 3.
float GammaToLinear(float v) {
  float scale, bias;
  if (v >= 0.376471) {
    bool hi = v >= 0.752941;
    scale = hi ? 0.007812 : 0.003906;
    bias = hi ? -1024.0 : -256.0;
  } else {
    bool hi = v >= 0.250980;
    scale = hi ? 0.001953 : 0.000977;
    bias = hi ? -64.0 : 0.0;
  }
  float x = saturate(v) * 261120.0 * scale + bias;
  return (x + trunc(x * scale)) * 0.000978;
}

// Texture fetch as the translator emits it. `binding` is this shader's
// texture binding number (sampler, unsigned and signed views are the
// descriptor indices 1 + 3 * binding ...).
float4 Fetch(uint tf, uint binding, float2 uv, bool is_1d) {
  uint base = tf * 6;
  float2 size;
  if (is_1d) {
    size = float2(float((FetchDword(base + 2) & 0xFFFFFF) + 1), 1.0);
  } else {
    uint d = FetchDword(base + 2);
    size = float2(float((d & 0x1FFF) + 1), float(((d >> 13) & 0x1FFF) + 1));
  }
  float2 offset = 0.001465 / size;
  if (is_1d) offset.y = 0.0;
  bool scaled = ((xe_textures_resolution_scaled >> tf) & 1) != 0;
  uv = scaled ? offset * (1.0 / 3.0) + uv : uv + offset;
  if (is_1d) uv.y = 0.0;
  float lod_scale = exp2(float(int(FetchDword(base + 4) << 10) >> 22) * 0.03125);
  float2 dx = ddx_coarse(uv) * lod_scale, dy = ddy_coarse(uv) * lod_scale;
  if (is_1d) { dx.y = 0.0; dy.y = 0.0; }
  uint signs_word = xe_texture_swizzled_signs[tf >> 4][(tf >> 2) & 3];
  uint signs = (signs_word >> ((tf & 3) * 8)) & 0xFF;
  uint sampler_index = DescriptorIndex(1 + 3 * binding);
  float4 unsigned_value = xe_textures_2d[NonUniformResourceIndex(DescriptorIndex(2 + 3 * binding))]
      .SampleGrad(xe_samplers[NonUniformResourceIndex(sampler_index)], float3(uv, 0.0), dx, dy);
  float4 signed_value = unsigned_value;
  bool any_signed = false;
  [unroll] for (uint c = 0; c < 4; ++c) any_signed = any_signed || ((signs >> (2 * c)) & 3) == 1;
  if (any_signed) {
    signed_value = xe_textures_2d[NonUniformResourceIndex(DescriptorIndex(3 + 3 * binding))]
        .SampleGrad(xe_samplers[NonUniformResourceIndex(sampler_index)], float3(uv, 0.0), dx, dy);
  }
  float4 v;
  [unroll] for (uint i = 0; i < 4; ++i) {
    uint s = (signs >> (2 * i)) & 3;
    float x = s == 1 ? signed_value[i] : unsigned_value[i];
    if (s == 2) x = x * 2.0 - 1.0;
    if (s == 3) x = GammaToLinear(x);
    v[i] = x;
  }
  int exp_adjust = int(FetchDword(base + 3) << 13) >> 26;
  return v * asfloat(exp_adjust * 0x00800000 + 0x3F800000);
}

// Texture bindings of these shaders, in the translator's order.
#define TF1(uv) Fetch(1, 0, uv, false)
#define TF2(uv) Fetch(2, 1, uv, false)
#define TF13(uv) Fetch(13, 2, uv, false)
#define TF14(uv) Fetch(14, 3, uv, false)
#define TF8(uv) Fetch(8, 4, uv, false)
#define TF4(u) Fetch(4, 5, float2(u, 0.0), true)
#define TF5(u) Fetch(5, 6, float2(u, 0.0), true)

struct PSInput {
  float4 v0 : TEXCOORD0;
  float4 v1 : TEXCOORD1;
  float4 v2 : TEXCOORD2;
  float4 v3 : TEXCOORD3;
  float4 position : SV_Position;
  bool front_face : SV_IsFrontFace;
};

float4 main(PSInput input) : SV_Target0 {
  float4 r0 = input.v0, r1 = input.v1, r2 = input.v2, r3 = input.v3;
  float4 r4 = 0.0, r5 = 0.0, r6 = 0.0, r7 = 0.0;
  // Guest pixel position (resolution scale undone), as the translator sets r4.
  r4.xy = abs(floor(input.position.xy) * (1.0 / RES_SCALE));
  if (xe_flags & 16u) r4.x = input.front_face ? r4.x : -r4.x;

  r0.w = TF1(r3.xy).x;                                    // 10
  r0.w = C255.z - r0.w;                                   // 11
  r0.w = saturate(-r0.w * C141.y + C141.x);               // 12
  r4.w = C255.z - r0.w;                                   // 13
#if EDGE
  r2.w = (C255.z > r4.w) ? 1.0 : 0.0;                     // 14
#else
  r2.w = (r4.w == C255.z) ? 1.0 : 0.0;                    // 14
#endif
  r3.w = saturate(C131.x);
  r2.xyz = (-abs(r0.x) > C254.x) ? 1.0 : 0.0;             // 15
  bool p0 = r2.w != 0.0;
  if (p0) {                                               // 16
    if (C254.x > C255.y) discard;
    r4.w = (-abs(r0.x) > 0.0) ? 1.0 : 0.0;
  }
  r2.w = (r4.w > C141.w) ? 1.0 : 0.0;                     // 17
  p0 = (C254.x == 0.0) && (r2.w != 0.0);                  // 18
  r2.w = p0 ? 0.0 : C254.x + 1.0;

  if (p0) {
    r5.xy = TF2(r1.xy).xy;                                // 19
    r5.zw = TF2(r1.zw).xy;                                // 20
    // Detail layer: both scrolling layers' coordinates combined, scaled up,
    // so it moves faster and finer than either (decorrelated from them).
    float2 detail = 0.0;
    float detail_z = 0.0;
    if (DETAIL > 0.0) {
      detail = TF2((r1.xy + r1.zw) * DETAIL_SCALE + 0.37).xy * 2.0 - 1.0;
      detail_z = sqrt(saturate(1.0 - dot(detail, detail)));
    }
    r3.xy = C129.yx * C255.x;                             // 21
    float ps = C0.x;
    r1.xy = abs(r4.xy) * C0.zw;                           // 22
    r0.w = ps - C255.x;
    r1.w = r0.w + r1.x;                                   // 23
    r2.xy = r5.zw * C254.y + C255.w;                      // 24
    r2.xy = r5.xy * C254.y + r2.xy;                       // 25
    r2.xy += detail * DETAIL;
    r7.xy = r3.xy * r2.yx;                                // 26
    r0.w = r1.y - C255.x;
    r6.yz = r2.yx * C255.x;                               // 27
    r1.z = C0.y + r0.w;
    r1.zw = r1.zw * C31.yx + C255.x;                      // 28
    r7.zw = r6.zy * C130.xy;                              // 29
    r7 = r1.zwzw + r7.xywz;                               // 30
    r3.xyz = TF13(r7.yx).xyz;                             // 31
    r4.xyz = TF14(r7.wz).xyz;                             // 32
    r5 = r5.yxwz * C254.y + C255.y;                       // 33
    r5 = r5.xzyw * r5.xzyw;                               // 34
    r1.w = C255.z;
    r2.xy = r5.zw + r5.xy;                                // 35
    ps = C128.x;
    r2.xy = -r2.xy + C255.z;                              // 36
    r0.w = C255.x * ps;
    {                                                     // 37
      float3 v = -r0.xyz + C19.xyz;
      r0.y = sqrt(abs(r2.x));
      r5.xyz = v;
    }
    r1.z = dot(r5.zxy, r5.zxy);                           // 38
    r0.x = sqrt(abs(r2.y));
    r0.x = r0.y + r0.x;                                   // 39
    r0.x += detail_z * DETAIL;
    ps = C126.z;
    r6.x = r0.w * r0.x;                                   // 40
    r2.x = ps - C127.z;
    {                                                     // 41
      float d = dot(r6.xzy, r6.xzy);
      r0.y = rsqrt(abs(r1.z));
      r0.x = d;
    }
    {                                                     // 42
      float3 v = r5.xyz * r0.y;
      r0.x = rsqrt(abs(r0.x));
      r5.xyz = v;
    }
    r0.xyw = r6.yxz * r0.x;                               // 43
    ps = C126.y;
    r0.z = dot(r5.zxy, r0.ywx);                           // 44
    r2.y = ps - C127.y;
    r0.z = -r0.z + C255.z;                                // 45
    if (FRESNEL != 1.0) r0.z = pow(saturate(r0.z), FRESNEL);
    ps = C126.x;
    r0.z = saturate(r0.z + C116.x);                       // 46
    r2.z = ps - C127.x;
    r2.xyz = r2.zyx * r0.z + C127.xyz;                    // 47
    if (B137()) {
      r1.xy = r1.xy + C0.xy;                              // 48
      r1.x = TF8(r1.xy).x;                                // 49
      r1.w = r1.x * C139.x + C139.y;                      // 50
    }
    {                                                     // 51
      float v = saturate(r0.z + C117.x);
      r0.z = sqrt(abs(r1.z));
      r5.w = v;
    }
    r1.xyz = -r2.xyz + r4.xyz;                            // 52
    r4.xyz = r3.xyz * r1.w - r4.xyz;                      // 53
    r3.xyz = r3.xyz * r1.w - r2.xyz;                      // 54
    r3.xyz = r3.xyz * r3.w + r2.xyz;                      // 55
    r1.xyz = r4.xyz * r5.w + r1.xyz;                      // 56
    r1.xyz = r1.zyx * r3.w + r2.zyx;                      // 57
    {                                                     // 58
      float3 v = r3.zyx - r1.xyz;
      r1.w = saturate(C140.x * r0.z);
      r2.xyz = v;
    }
    r2.xyz = r1.w * r2.zyx + r1.zyx;                      // 59
    if (B136()) {
      r1.x = C136.x * r0.y;                               // 60
      r0.y = dot(r0.wx, r0.wx) + C254.x;                  // 61
      r0.y = r1.x * r1.x + r0.y;                          // 62
      r0.y = rsqrt(abs(r0.y));                            // 63
      r1.x = r1.x * r0.y;                                 // 64
      r1.yz = r0.xw * r0.y;                               // 65
      r0.x = dot(r1.xzy, -C142.zxy);                      // 66
      r0.x = r0.x + r0.x;                                 // 67
      r0.xyw = -r1.xyz * r0.x - C142.zyx;                 // 68
      r0.x = saturate(dot(-r5.zxy, r0.xwy));              // 69
      float r_dot_v = r0.x;
      r0.y = log2(r0.x);                                  // 70
      r0.y = C138.x * r0.y;                               // 71
      {                                                   // 72
        float v = C143.x * C137.x;
        r0.y = exp2(r0.y);
        r0.x = v;
      }
      {                                                   // 73
        float v = r0.x * r0.y;
        r0.x = C137.x * r0.y;
        r1.z = v;
      }
      r1.xy = r0.x * C143.zy;                             // 74
      r2.xyz = r2.xyz + r1.zyx;                           // 75
      if (GLINT > 0.0) {
        float glint = pow(r_dot_v, max(C138.x, 1.0) * 8.0) * GLINT;
        r2.xyz += glint * C137.x * C143.xyz;
      }
    }
    r0.x = r0.z - C67.x;                                  // 76
  }
  bool fog = (r2.w == 0.0) && (r0.x > 0.0);               // 77
  if (fog) {
    r0.y = saturate(dot(-r5.zxy, C66.zxy));               // 78
    r1.x = C67.w * r0.x;
    r0.yzw = TF4(r0.y).xyz;                               // 79
    r1.xyz = TF5(r1.x).xyz;                               // 80
    r3.xyz = -r1.xyz + C255.z;                            // 81
    r0.yzw = r0.yzw - C68.xyz;                            // 82
    r0.x = saturate(C67.z * r0.x);
    r0.xyz = r0.x * r0.wzy + C68.zyx;                     // 83
    r3.xyz = r3.xyz * C28.y;                              // 84
    r0.xyz = r3.xyz * r0.zyx - r2.xyz;                    // 85
    r0.xyz = r1.xyz * r2.xyz + r0.xyz;                    // 86
    r2.xyz = r0.xyz * C28.x + r2.xyz;                     // 87
  }
  r4.xyz = r2.xyz * C20.w;                                // 88
  return r4 * xe_color_exp_bias.x;                        // 89
}
