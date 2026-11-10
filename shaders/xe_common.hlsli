// Shared interface for the Modern-graphics shader rewrites: the SDK
// translator's root signature and its texture fetch, so a replacement shader
// binds exactly what the translated shader it stands in for would bind.
//
// Before including, define:
//   XE_FLOAT_CONSTANTS      number of float4 constants the original shader
//                           uses (the translator packs only those, in
//                           ascending register order, into K[]).
//   XE_DESCRIPTOR_INDICES   number of uint4s in xe_descriptor_indices
//                           (ceil((1 + 3 * texture bindings) / 4)).
// Both come from the `Buffer Definitions` block of `fxc /dumpbin` on the
// translated shader (shaders/README.md).
//
// Xenos notes for reading the ports: swizzles map to destination components
// by position (r0.xy_w <- src.xyzz writes x<-x, y<-y, w<-z); co-issued
// vector and scalar ops read their sources before either writes; "ps" is
// the previous scalar result.

#ifndef XE_COMMON_HLSLI
#define XE_COMMON_HLSLI

#ifndef RES_SCALE
#define RES_SCALE 3.0
#endif

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
cbuffer xe_float_cbuffer : register(b1) { float4 K[XE_FLOAT_CONSTANTS]; };
cbuffer xe_bool_loop_cbuffer : register(b2) {
  uint4 xe_bool_constants[2];
  uint4 xe_loop_constants[8];
};
cbuffer xe_fetch_cbuffer : register(b3) { uint4 xe_fetch_constants[48]; };
cbuffer xe_descriptor_indices_cbuffer : register(b4) {
  uint4 xe_descriptor_indices[XE_DESCRIPTOR_INDICES];
};
SamplerState xe_samplers[] : register(s0, space0);
Texture2DArray<float4> xe_textures_2d[] : register(t0, space1);
TextureCube<float4> xe_textures_cube[] : register(t0, space3);

// Boolean constant b<n> (n in 0..255).
bool XeBool(uint n) { return (xe_bool_constants[n >> 7][(n >> 5) & 3] & (1u << (n & 31))) != 0; }

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
// descriptor indices 1 + 3 * binding ...). Rewrites use Fetch/FetchLevel;
// FetchCore is the shared body (`level` < 0 samples with derivatives).
float4 FetchCore(uint tf, uint binding, float2 uv, bool is_1d, float grad_scale, float level, bool use_offset, int2 texel_offset) {
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
  float lod_scale = exp2(float(int(FetchDword(base + 4) << 10) >> 22) * 0.03125) * grad_scale;
  float2 dx = ddx_coarse(uv) * lod_scale, dy = ddy_coarse(uv) * lod_scale;
  if (is_1d) { dx.y = 0.0; dy.y = 0.0; }
  uint signs_word = xe_texture_swizzled_signs[tf >> 4][(tf >> 2) & 3];
  uint signs = (signs_word >> ((tf & 3) * 8)) & 0xFF;
  uint sampler_index = DescriptorIndex(1 + 3 * binding);
  Texture2DArray<float4> tex_u = xe_textures_2d[NonUniformResourceIndex(DescriptorIndex(2 + 3 * binding))];
  SamplerState smp = xe_samplers[NonUniformResourceIndex(sampler_index)];
  // The offset overloads emit sample_*_aoffimmi; keep the plain overloads
  // when there is no offset so offset-free ports stay byte-identical.
  float4 unsigned_value = use_offset
      ? (level >= 0.0 ? tex_u.SampleLevel(smp, float3(uv, 0.0), level, texel_offset)
                      : tex_u.SampleGrad(smp, float3(uv, 0.0), dx, dy, texel_offset))
      : (level >= 0.0 ? tex_u.SampleLevel(smp, float3(uv, 0.0), level)
                      : tex_u.SampleGrad(smp, float3(uv, 0.0), dx, dy));
  float4 signed_value = unsigned_value;
  bool any_signed = false;
  [unroll] for (uint c = 0; c < 4; ++c) any_signed = any_signed || ((signs >> (2 * c)) & 3) == 1;
  if (any_signed) {
    Texture2DArray<float4> tex_s = xe_textures_2d[NonUniformResourceIndex(DescriptorIndex(3 + 3 * binding))];
    signed_value = use_offset
        ? (level >= 0.0 ? tex_s.SampleLevel(smp, float3(uv, 0.0), level, texel_offset)
                        : tex_s.SampleGrad(smp, float3(uv, 0.0), dx, dy, texel_offset))
        : (level >= 0.0 ? tex_s.SampleLevel(smp, float3(uv, 0.0), level)
                        : tex_s.SampleGrad(smp, float3(uv, 0.0), dx, dy));
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
float4 Fetch(uint tf, uint binding, float2 uv, bool is_1d) {
  return FetchCore(tf, binding, uv, is_1d, 1.0, -1.0, false, int2(0, 0));
}
// The same fetch with a texel offset (the ucode's OffsetX/OffsetY).
float4 FetchOffset(uint tf, uint binding, float2 uv, int2 offset) {
  return FetchCore(tf, binding, uv, false, 1.0, -1.0, true, offset);
}
// The same fetch at an explicit mip level, for rewrites that want a blurred
// copy of a texture.
float4 FetchLevel(uint tf, uint binding, float2 uv, bool is_1d, float level) {
  return FetchCore(tf, binding, uv, is_1d, 1.0, level, false, int2(0, 0));
}

// Decode of a fetched value by the fetch constant's per-component signs
// (0 unsigned, 1 signed view, 2 biased, 3 guest gamma) and exp_adjust.
float4 DecodeFetch(uint tf, uint binding, float4 unsigned_value, float4 signed_value) {
  uint signs_word = xe_texture_swizzled_signs[tf >> 4][(tf >> 2) & 3];
  uint signs = (signs_word >> ((tf & 3) * 8)) & 0xFF;
  float4 v;
  [unroll] for (uint i = 0; i < 4; ++i) {
    uint s = (signs >> (2 * i)) & 3;
    float x = s == 1 ? signed_value[i] : unsigned_value[i];
    if (s == 2) x = x * 2.0 - 1.0;
    if (s == 3) x = GammaToLinear(x);
    v[i] = x;
  }
  int exp_adjust = int(FetchDword(tf * 6 + 3) << 13) >> 26;
  return v * asfloat(exp_adjust * 0x00800000 + 0x3F800000);
}

// The Xenos `cube` ALU op as the translator emulates it: from a direction
// returns (s-ish, t-ish, 2 * major axis, face id).
float4 XeCube(float3 v) {
  float4 r;
  if (abs(v.z) >= abs(v.x) && abs(v.z) >= abs(v.y)) {
    bool w = v.z < 0.0;
    r = float4(-v.y, w ? -v.x : v.x, 2.0 * v.z, w ? 5.0 : 4.0);
  } else if (abs(v.y) >= abs(v.x)) {
    bool w = v.y < 0.0;
    r = float4(w ? -v.z : v.z, v.x, 2.0 * v.y, w ? 3.0 : 2.0);
  } else {
    bool w = v.x < 0.0;
    r = float4(-v.y, w ? v.z : -v.z, 2.0 * v.x, w ? 1.0 : 0.0);
  }
  return r;
}

// tfetchCube as the translator emits it: `stf` is the ucode's (s, t, face)
// coordinate (s and t in 1..2 after the usual +1.5), rebuilt into a
// direction for the host cube map.
float4 FetchCube(uint tf, uint binding, float3 stf) {
  uint base = tf * 6;
  uint d = FetchDword(base + 2);
  float2 size = float2(float((d & 0x1FFF) + 1), float(((d >> 13) & 0x1FFF) + 1));
  float2 offset = 0.001465 / size;
  bool scaled = ((xe_textures_resolution_scaled >> tf) & 1) != 0;
  float2 st = scaled ? offset * (1.0 / 3.0) + stf.xy : stf.xy + offset;
  st = st * 2.0 - 3.0;
  uint face = min(uint(stf.z), 5u);
  bool neg = (face & 1u) != 0;
  float3 dir;
  switch (face >> 1) {
    case 0u: dir = float3(neg ? -1.0 : 1.0, -st.y, neg ? st.x : -st.x); break;
    case 1u: dir = float3(st.x, neg ? -1.0 : 1.0, neg ? -st.y : st.y); break;
    default: dir = float3(neg ? -st.x : st.x, -st.y, neg ? -1.0 : 1.0); break;
  }
  float lod_scale = exp2(float(int(FetchDword(base + 4) << 10) >> 22) * 0.03125);
  float3 dx = ddx_coarse(dir) * lod_scale, dy = ddy_coarse(dir) * lod_scale;
  uint signs_word = xe_texture_swizzled_signs[tf >> 4][(tf >> 2) & 3];
  uint signs = (signs_word >> ((tf & 3) * 8)) & 0xFF;
  SamplerState smp = xe_samplers[NonUniformResourceIndex(DescriptorIndex(1 + 3 * binding))];
  TextureCube<float4> tex_u = xe_textures_cube[NonUniformResourceIndex(DescriptorIndex(2 + 3 * binding))];
  float4 unsigned_value = tex_u.SampleGrad(smp, dir, dx, dy);
  float4 signed_value = unsigned_value;
  bool any_signed = false;
  [unroll] for (uint c = 0; c < 4; ++c) any_signed = any_signed || ((signs >> (2 * c)) & 3) == 1;
  if (any_signed) {
    TextureCube<float4> tex_s = xe_textures_cube[NonUniformResourceIndex(DescriptorIndex(3 + 3 * binding))];
    signed_value = tex_s.SampleGrad(smp, dir, dx, dy);
  }
  return DecodeFetch(tf, binding, unsigned_value, signed_value);
}

// Width and height of a 2D texture from its fetch constant.
float2 TextureSize(uint tf) {
  uint d = FetchDword(tf * 6 + 2);
  return float2(float((d & 0x1FFF) + 1), float(((d >> 13) & 0x1FFF) + 1));
}

// The guest's alpha test, from the tail of every translated pixel shader
// (xe_flags bits 7..9 hold the compare function; 7 = always).
void AlphaTest(float alpha) {
  uint func = (xe_flags >> 7) & 7u;
  if (func == 7u) return;
  bool keep = ((func & 1u) && alpha < xe_alpha_test_reference) ||
              ((func & 2u) && alpha == xe_alpha_test_reference) ||
              ((func & 4u) && alpha > xe_alpha_test_reference);
  if (!keep) discard;
}

// The guest's alpha-to-coverage, from the tail of the translated pixel
// shaders (xe_alpha_to_mask holds four 2-bit dither offsets, one per pixel
// of a 2x2 block). `position` is the host pixel position. Returns the
// sample mask; discards the pixel when no sample passes.
uint AlphaToMask(float alpha, float2 position) {
  if (xe_alpha_to_mask == 0u) return 0xFFFFFFFFu;
  uint2 p = uint2(position);
  uint shift = (((p.x & 1u) << 1) | (p.y & 1u)) << 1;
  float d = float((xe_alpha_to_mask >> shift) & 3u);
  uint mask = 0u;
  if (xe_sample_count_log2.y != 0u) {
    if (xe_sample_count_log2.x != 0u) {
      mask = (alpha >= d * -0.0625 + 0.75 ? 1u : 0u) | (alpha >= d * -0.0625 + 0.25 ? 2u : 0u) |
             (alpha >= d * -0.0625 + 0.5 ? 4u : 0u) | (alpha >= d * -0.0625 + 1.0 ? 8u : 0u);
    } else {
      mask = (alpha >= d * -0.125 + 0.5 ? 2u : 0u) | (alpha >= d * -0.125 + 1.0 ? 1u : 0u);
    }
  } else {
    mask = alpha >= d * -0.25 + 1.0 ? 1u : 0u;
  }
  if (mask == 0u) discard;
  return mask;
}

// Guest pixel position as the translator puts it in the register after the
// last interpolator (resolution scale undone, x negated for back faces when
// xe_flags bit 4 is set).
float2 GuestPixelPosition(float4 position, bool front_face) {
  float2 p = abs(floor(position.xy) * (1.0 / RES_SCALE));
  if (xe_flags & 16u) p.x = front_face ? p.x : -p.x;
  return p;
}

struct PSInput {
  float4 v0 : TEXCOORD0;
  float4 v1 : TEXCOORD1;
  float4 v2 : TEXCOORD2;
  float4 v3 : TEXCOORD3;
  float4 position : SV_Position;
  bool front_face : SV_IsFrontFace;
};
struct PSInput2 {
  float4 v0 : TEXCOORD0;
  float4 v1 : TEXCOORD1;
  float4 position : SV_Position;
  bool front_face : SV_IsFrontFace;
};
// Seven interpolators, the last centroid-sampled (as the translator declares
// it for shaders whose vertex shader marks it so).
struct PSInput7 {
  float4 v0 : TEXCOORD0;
  float4 v1 : TEXCOORD1;
  float4 v2 : TEXCOORD2;
  float4 v3 : TEXCOORD3;
  float4 v4 : TEXCOORD4;
  float4 v5 : TEXCOORD5;
  centroid float4 v6 : TEXCOORD6;
  float4 position : SV_Position;
  bool front_face : SV_IsFrontFace;
};
struct PSInput6 {
  float4 v0 : TEXCOORD0;
  float4 v1 : TEXCOORD1;
  float4 v2 : TEXCOORD2;
  float4 v3 : TEXCOORD3;
  float4 v4 : TEXCOORD4;
  float4 v5 : TEXCOORD5;
  float4 position : SV_Position;
  bool front_face : SV_IsFrontFace;
};
// Eight interpolators, the last centroid-sampled (ferns).
struct PSInput8 {
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
// Nine interpolators, all linear (tree trunks).
struct PSInput9 {
  float4 v0 : TEXCOORD0;
  float4 v1 : TEXCOORD1;
  float4 v2 : TEXCOORD2;
  float4 v3 : TEXCOORD3;
  float4 v4 : TEXCOORD4;
  float4 v5 : TEXCOORD5;
  float4 v6 : TEXCOORD6;
  float4 v7 : TEXCOORD7;
  float4 v8 : TEXCOORD8;
  float4 position : SV_Position;
  bool front_face : SV_IsFrontFace;
};

#endif  // XE_COMMON_HLSLI
