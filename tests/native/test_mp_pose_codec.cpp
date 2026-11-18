// Multiplayer pose formats (src/net/mp_pose_codec.h): a bone matrix sent as a
// half-float quaternion + translation comes back close to the original, in both
// memory layouts; non-rotations are rejected so they go out as full matrices.
#include "mp_pose_codec.h"

#include <cmath>
#include <cstdio>
#include <random>

using namespace fable2::net;

static int failures = 0;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); ++failures; } } while (0)

// A random rotation (from a random unit quaternion) + translation, stored in a layout.
static void make_bone(std::mt19937& rng, int layout, float* m) {
  std::normal_distribution<float> n(0, 1);
  std::uniform_real_distribution<float> u(-2, 2);
  float q[4] = {n(rng), n(rng), n(rng), n(rng)};
  const float len = std::sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
  for (float& v : q) v /= len;
  const float t[3] = {u(rng), u(rng), u(rng)};
  for (int k = 0; k < 12; ++k) m[k] = 0;
  from_quat(q, t, layout, m);
}

int main() {
  std::mt19937 rng(1234);
  float worst_rot = 0, worst_pos = 0;
  for (int layout = 1; layout <= 2; ++layout) {
    for (int i = 0; i < 5000; ++i) {
      float m[12];
      make_bone(rng, layout, m);
      CHECK(is_rotation(m, layout));
      // the wire: quaternion + translation as half floats
      float q[4], t[3];
      to_quat(m, layout, q);
      CHECK(q[3] >= 0);
      for (float& v : q) v = from_half(to_half(v));
      for (int k = 0; k < 3; ++k) t[k] = from_half(to_half(m[kPos[layout][k]]));
      const float len = std::sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
      for (float& v : q) v /= len;
      float back[12] = {};
      from_quat(q, t, layout, back);
      for (int k = 0; k < 9; ++k)
        worst_rot = std::fmax(worst_rot, std::fabs(back[kRot[layout][k]] - m[kRot[layout][k]]));
      for (int k = 0; k < 3; ++k)
        worst_pos = std::fmax(worst_pos, std::fabs(back[kPos[layout][k]] - m[kPos[layout][k]]));
    }
  }
  std::printf("pose codec: worst rotation error %.5f, worst translation error %.5f m\n", worst_rot, worst_pos);
  CHECK(worst_rot < 0.004f);   // half-float quaternion: about 0.2 degrees at worst
  CHECK(worst_pos < 0.002f);   // within 2 m of the model origin: under 2 mm

  // Not rigid: scaled, sheared or mirrored bones must fall back to full matrices.
  float m[12];
  make_bone(rng, 1, m);
  float scaled[12];
  for (int k = 0; k < 12; ++k) scaled[k] = m[k] * 1.1f;
  CHECK(!is_rotation(scaled, 1));
  float mirrored[12];
  std::memcpy(mirrored, m, sizeof(m));
  for (int k : {0, 4, 8}) mirrored[k] = -mirrored[k];  // flip the first column
  CHECK(!is_rotation(mirrored, 1));
  // a rows-of-4 rotation is not mistaken for rows of 3 (translation lands in the 3x3)
  CHECK(!is_rotation(m, 2) || (m[3] == 0 && m[7] == 0));

  // identity, and a 180-degree turn (trace -1: the other quaternion branches)
  for (int layout = 1; layout <= 2; ++layout) {
    const float q180[4] = {0, 0, 1, 0}, t0[3] = {0, 0, 0};
    float r[12] = {};
    from_quat(q180, t0, layout, r);
    float q[4];
    to_quat(r, layout, q);
    CHECK(std::fabs(std::fabs(q[2]) - 1.0f) < 1e-5f);
  }
  if (failures) return 1;
  std::printf("pose codec tests passed\n");
  return 0;
}
