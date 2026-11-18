// mp_pose_codec.h - multiplayer: pose number formats (no game or SDK headers,
// so tests/native/test_mp_pose_codec.cpp can check it on its own).
//   * half floats (16-bit) for every pose value on the wire;
//   * a 3x4 bone matrix as rotation quaternion + translation (POSEQ), used when
//     the 3x3 part is a rotation in one of two memory layouts.
#pragma once

#include <cmath>
#include <cstdint>
#include <cstring>

namespace fable2::net {

// --- half floats ----------------------------------------------------------
inline uint16_t to_half(float f) {
  uint32_t x;
  std::memcpy(&x, &f, 4);
  const uint32_t sign = (x >> 16) & 0x8000;
  int32_t e = int32_t((x >> 23) & 0xFF) - 127 + 15;
  uint32_t m = x & 0x7FFFFF;
  if (e <= 0) return uint16_t(sign);                  // tiny -> signed zero
  if (e >= 31) return uint16_t(sign | 0x7BFF);        // clamp to max finite
  m += 0x1000;                                        // round to nearest
  if (m & 0x800000) { m = 0; if (++e >= 31) return uint16_t(sign | 0x7BFF); }
  return uint16_t(sign | (uint32_t(e) << 10) | (m >> 13));
}
inline float from_half(uint16_t h) {
  const uint32_t sign = uint32_t(h & 0x8000) << 16;
  const uint32_t e = (h >> 10) & 0x1F, m = h & 0x3FF;
  uint32_t x;
  if (e == 0) {
    if (m == 0) x = sign;
    else {  // subnormal
      float f = std::ldexp(float(m), -24);
      std::memcpy(&x, &f, 4);
      x |= sign;
    }
  } else if (e == 31) {
    x = sign | 0x7F800000 | (m << 13);  // inf / nan (rejected by the checks)
  } else {
    x = sign | ((e - 15 + 127) << 23) | (m << 13);
  }
  float f;
  std::memcpy(&f, &x, 4);
  return f;
}

// Rotation/translation indices of a 3x4 bone matrix in each layout.
inline constexpr uint8_t kRot[3][9] = {{}, {0, 1, 2, 4, 5, 6, 8, 9, 10}, {0, 1, 2, 3, 4, 5, 6, 7, 8}};
inline constexpr uint8_t kPos[3][3] = {{}, {3, 7, 11}, {9, 10, 11}};

// True if the 3x3 at these indices is a rotation (orthonormal, det +1).
inline bool is_rotation(const float* m, int layout) {
  float r[9];
  for (int k = 0; k < 9; ++k) r[k] = m[kRot[layout][k]];
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j) {
      const float d = r[i * 3] * r[j * 3] + r[i * 3 + 1] * r[j * 3 + 1] + r[i * 3 + 2] * r[j * 3 + 2];
      if (std::fabs(d - (i == j ? 1.0f : 0.0f)) > 0.01f) return false;
    }
  const float det = r[0] * (r[4] * r[8] - r[5] * r[7]) - r[1] * (r[3] * r[8] - r[5] * r[6]) +
                    r[2] * (r[3] * r[7] - r[4] * r[6]);
  return det > 0.0f;
}
inline void to_quat(const float* m, int layout, float q[4]) {
  const uint8_t* i = kRot[layout];
  const float m00 = m[i[0]], m01 = m[i[1]], m02 = m[i[2]], m10 = m[i[3]], m11 = m[i[4]],
              m12 = m[i[5]], m20 = m[i[6]], m21 = m[i[7]], m22 = m[i[8]];
  const float tr = m00 + m11 + m22;
  if (tr > 0) {
    const float s = std::sqrt(tr + 1.0f) * 2;
    q[3] = 0.25f * s, q[0] = (m21 - m12) / s, q[1] = (m02 - m20) / s, q[2] = (m10 - m01) / s;
  } else if (m00 > m11 && m00 > m22) {
    const float s = std::sqrt(1.0f + m00 - m11 - m22) * 2;
    q[3] = (m21 - m12) / s, q[0] = 0.25f * s, q[1] = (m01 + m10) / s, q[2] = (m02 + m20) / s;
  } else if (m11 > m22) {
    const float s = std::sqrt(1.0f + m11 - m00 - m22) * 2;
    q[3] = (m02 - m20) / s, q[0] = (m01 + m10) / s, q[1] = 0.25f * s, q[2] = (m12 + m21) / s;
  } else {
    const float s = std::sqrt(1.0f + m22 - m00 - m11) * 2;
    q[3] = (m10 - m01) / s, q[0] = (m02 + m20) / s, q[1] = (m12 + m21) / s, q[2] = 0.25f * s;
  }
  if (q[3] < 0) for (int k = 0; k < 4; ++k) q[k] = -q[k];
}
inline void from_quat(const float q[4], const float t[3], int layout, float* m) {
  const float x = q[0], y = q[1], z = q[2], w = q[3];
  const float r[9] = {1 - 2 * (y * y + z * z), 2 * (x * y - z * w),     2 * (x * z + y * w),
                      2 * (x * y + z * w),     1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
                      2 * (x * z - y * w),     2 * (y * z + x * w),     1 - 2 * (x * x + y * y)};
  for (int k = 0; k < 9; ++k) m[kRot[layout][k]] = r[k];
  for (int k = 0; k < 3; ++k) m[kPos[layout][k]] = t[k];
}

}  // namespace fable2::net
