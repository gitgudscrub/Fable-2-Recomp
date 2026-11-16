// mp_puppet_mirror.h - multiplayer spike f35: a puppet hero copies the local hero.
//
// Remote players will appear as puppets: spawned CreatureHero bodies driven by
// our code. This spike proves the driving part without a network: with
// `cvar mp_mirror true`, a marked puppet stands beside the hero, faces the same
// way and shows exactly the hero's pose (attacks, rolls, expressions...).
//
// How:
//  * Pose: the engine evaluates each skinned mesh into a bone palette (3x4 float
//    matrices, MODEL space) at skel+624 and packs it for the GPU in
//    sub_82207A90(skel, vector*). We save the hero's palettes there and write
//    them over the puppet's matching palettes before they are packed.
//  * Skeletons of an entity: the ones whose world position (skel+112) is the
//    entity's position; paired by bone count (the bodies must match).
//  * Transform: thing+124 = transform component; position at +0x70 (set through
//    vtable +100, vector in v1), facing = Z-axis quaternion at +0xE0.
//  * Marking the puppet (test scaffolding, console only). The body must match
//    the hero's (young hero = 143 bones -> CreatureHeroChild; adult -> CreatureHero):
//      spawn CreatureHeroChild 1 pup1
//      lua Debug.GetEntityWithName("pup1"):SetPosition(CVector3(-7777, 0, 0))
//    The SetPosition binding (sub_825BC498) sees the magic x and records that
//    entity as the puppet instead of moving it. Later the network layer spawns
//    puppets itself.
//
// Proven 2026-11-16 (prologue): the puppet follows at the offset, faces the same
// way, and shows the hero's pose even while told to play its own walk loop
// (`cvar mp_mirror_pose false` brings its own animation back).
// Spike limits: the puppet pointer is not cleared when the entity dies or the
// level changes, and the tick sets the position more often than once a frame.
//
// Game thread only for engine calls (tick); the packer hook only copies memory.
#pragma once

#include <rex/cvar.h>
#include <rex/logging.h>
#include <rex/ppc/context.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <vector>

REXCVAR_DEFINE_BOOL(mp_mirror, false, "Multiplayer",
                    "Spike: the marked puppet copies the hero's pose and facing, standing "
                    "mp_mirror_offset metres to the hero's right.");
REXCVAR_DEFINE_BOOL(mp_mirror_pose, true, "Multiplayer",
                    "Spike: copy the hero's bone palettes onto the mirror puppet (off = only "
                    "position and facing follow).");
REXCVAR_DEFINE_DOUBLE(mp_mirror_offset, 1.5, "Multiplayer",
                      "Spike: how far to the hero's right the mirror puppet stands (metres).");

DECLARE_REX_FUNC(sub_82207A90);  // bone palette packer
DECLARE_REX_FUNC(sub_8222F1B0);  // GetPlayerHero native -> CThing*
DECLARE_REX_FUNC(sub_825BC498);  // Lua entity:SetPosition binding (r3 handle, v1 pos)
DECLARE_REX_FUNC(CheckValidPointer_825575C8);  // Lua entity handle -> CThing*

namespace fable2::net::mirror {
namespace ta = fable2::textappend;

constexpr float kMarkX = -7777.0f;

struct State {
  std::mutex m;
  std::atomic<uint32_t> puppet{0};                   // puppet CThing*
  std::unordered_map<uint32_t, int> hero_slot;       // hero skel -> slot
  std::unordered_map<uint32_t, int> puppet_slot;     // puppet skel -> slot
  std::vector<std::vector<uint8_t>> hero_pal;        // per slot, raw guest bytes
  bool logged = false;
  bool logged_vec = false;
  std::atomic<uint32_t> copies{0};  // palettes written onto the puppet (research)
  uint32_t ticks = 0;
};
inline State& S() {
  static State s;
  return s;
}

inline bool readable(uint8_t* base, uint32_t a, size_t n) {
  return a >= 0x40000000u && a < 0x80000000u && ta::rdable2(base, a, n);
}

// Skeletons packed last frame with their world position (skel+112, the
// translation of the skeleton's world matrix at skel+64). An entity's skeletons
// are the ones standing at its position: entity -> skeleton links in memory
// differ from run to run, positions do not.
struct Seen {
  uint32_t skel;
  float x, y, z;
};
// One entry per skeleton (the packer runs several times per frame for each).
inline std::unordered_map<uint32_t, Seen>& seen_frame() {
  static std::unordered_map<uint32_t, Seen> v;
  return v;
}
// The skeleton origin sits above the entity's feet (about 0.7 m on the young
// hero), so match on horizontal distance with a loose height window.
inline std::vector<uint32_t> skeletons_at(float x, float y, float z) {
  constexpr float kR2 = 0.35f * 0.35f;
  std::vector<uint32_t> out;
  for (const auto& [skel, k] : seen_frame()) {
    const float dx = k.x - x, dy = k.y - y, dz = k.z - z;
    if (dx * dx + dy * dy < kR2 && dz > -0.5f && dz < 2.0f) out.push_back(skel);
  }
  std::sort(out.begin(), out.end());
  return out;
}

inline uint32_t bone_count(uint8_t* base, uint32_t skel) {
  const uint32_t b = ta::load_be(base, skel + 628), e = ta::load_be(base, skel + 632);
  return (e > b && e - b < 48 * 512) ? (e - b) / 48 : 0;
}

// The palette vector the packer was handed ({?, begin, end}; normally skel+624).
inline uint32_t vec_bones(uint8_t* base, uint32_t vec, uint32_t* begin) {
  if (!readable(base, vec, 12)) return 0;
  const uint32_t b = ta::load_be(base, vec + 4), e = ta::load_be(base, vec + 8);
  *begin = b;
  return (e > b && e - b < 48 * 512 && (e - b) % 48 == 0) ? (e - b) / 48 : 0;
}

// Packer hook (any thread): save the hero's palettes, overwrite the puppet's.
inline void on_pack(uint8_t* base, uint32_t skel, uint32_t vec) {
  State& s = S();
  if (!s.puppet.load(std::memory_order_relaxed)) return;
  std::lock_guard<std::mutex> l(s.m);
  if (seen_frame().size() < 1024)
    seen_frame()[skel] = {skel, ta::load_f32(base, skel + 112), ta::load_f32(base, skel + 116),
                          ta::load_f32(base, skel + 120)};
  if (vec != skel + 624 && !s.logged_vec) {
    s.logged_vec = true;
    REXLOG_INFO("[mpmirror] note: packer vector 0x{:08X} is not skel+624 (skel 0x{:08X})", vec, skel);
  }
  uint32_t b = 0;
  const uint32_t n = vec_bones(base, vec, &b);
  if (!n || !readable(base, b, n * 48)) return;
  auto h = s.hero_slot.find(skel);
  if (h != s.hero_slot.end()) {
    auto& dst = s.hero_pal[h->second];
    dst.resize(n * 48);
    std::memcpy(dst.data(), base + b, n * 48);
    return;
  }
  auto p = s.puppet_slot.find(skel);
  if (p == s.puppet_slot.end() || !REXCVAR_GET(mp_mirror) || !REXCVAR_GET(mp_mirror_pose)) return;
  const auto& src = s.hero_pal[p->second];
  if (src.size() == size_t(n) * 48 && ta::wr2(base, b, n * 48)) {
    std::memcpy(base + b, src.data(), n * 48);
    s.copies.fetch_add(1, std::memory_order_relaxed);
  }
}

inline void store_f32(uint8_t* base, uint32_t a, float v) {
  uint32_t w;
  std::memcpy(&w, &v, 4);
  w = __builtin_bswap32(w);
  std::memcpy(base + a, &w, 4);
}

// Game thread, once per frame.
inline void tick(PPCContext& ctx, uint8_t* base) {
  State& s = S();
  const uint32_t puppet = s.puppet.load(std::memory_order_relaxed);
  if (!puppet || !REXCVAR_GET(mp_mirror)) return;

  const uint64_t save_r3 = ctx.r3.u64;
  sub_8222F1B0(ctx, base);
  const uint32_t hero = ctx.r3.u32;
  ctx.r3.u64 = save_r3;
  if (!hero || hero == puppet) return;
  if (++s.ticks % 300 == 0)
    REXLOG_INFO("[mpmirror] {} palette copies so far", s.copies.load(std::memory_order_relaxed));

  const uint32_t ht = ta::load_be(base, hero + 124), pt = ta::load_be(base, puppet + 124);
  if (!readable(base, ht, 0x100) || !readable(base, pt, 0x100)) return;

  // Pair skeletons (found by position) by bone count. Render and game frames
  // are not in step, so a tick can come before the hero was packed: then keep
  // the last pairing until the hero's skeletons show up again.
  {
    std::lock_guard<std::mutex> l(s.m);
    const auto hs = skeletons_at(ta::load_f32(base, ht + 0x70), ta::load_f32(base, ht + 0x74),
                                 ta::load_f32(base, ht + 0x78));
    const auto ps = skeletons_at(ta::load_f32(base, pt + 0x70), ta::load_f32(base, pt + 0x74),
                                 ta::load_f32(base, pt + 0x78));
    seen_frame().clear();
    if (!hs.empty()) {
      s.hero_slot.clear();
      s.puppet_slot.clear();
      if (s.hero_pal.size() < hs.size()) s.hero_pal.resize(hs.size());
      std::vector<bool> used(ps.size(), false);
      for (size_t i = 0; i < hs.size(); ++i) {
        const uint32_t hn = bone_count(base, hs[i]);
        s.hero_slot[hs[i]] = int(i);
        for (size_t j = 0; j < ps.size(); ++j) {
          if (!used[j] && hn && bone_count(base, ps[j]) == hn) {
            s.puppet_slot[ps[j]] = int(i);
            used[j] = true;
            break;
          }
        }
      }
      if (!s.logged) {
        s.logged = true;
        REXLOG_INFO("[mpmirror] hero 0x{:08X}: {} skeletons; puppet 0x{:08X}: {} skeletons, {} paired",
                    hero, hs.size(), puppet, ps.size(), s.puppet_slot.size());
        for (uint32_t k : hs) REXLOG_INFO("[mpmirror]   hero skel 0x{:08X} {} bones", k, bone_count(base, k));
        for (uint32_t k : ps) REXLOG_INFO("[mpmirror]   puppet skel 0x{:08X} {} bones", k, bone_count(base, k));
      }
    }
  }

  // Transform: beside the hero (to its right), same facing.
  const float x = ta::load_f32(base, ht + 0x70), y = ta::load_f32(base, ht + 0x74),
              z = ta::load_f32(base, ht + 0x78);
  const float qz = ta::load_f32(base, ht + 0xE8), qw = ta::load_f32(base, ht + 0xEC);
  // Heading about Z from the quaternion: forward = (cos, sin) (seen in game);
  // right = forward rotated by -90 degrees.
  const float yaw = 2.0f * std::atan2(qz, qw);
  const float off = static_cast<float>(REXCVAR_GET(mp_mirror_offset));
  const float px = x + std::sin(yaw) * off, py = y - std::cos(yaw) * off;

  // position through the component's own setter (vtable +100, vector in v1;
  // lanes are byte-reversed: f32[3] = x)
  const uint32_t vt = ta::load_be(base, pt);
  // (vtables live in the image, 0x82000000+, not the heap range readable() accepts)
  const uint32_t set_pos =
      (vt >= 0x82000000u && vt < 0x84000000u) ? ta::load_be(base, vt + 100) : 0;
  if (set_pos >= 0x82000000u && set_pos < 0x84000000u) {
    const auto save_v1 = ctx.v1;
    const uint64_t r3 = ctx.r3.u64;
    ctx.v1.f32[3] = px;
    ctx.v1.f32[2] = py;
    ctx.v1.f32[1] = z;
    ctx.v1.f32[0] = 0.0f;
    ctx.r3.u32 = pt;
    REX_CALL_INDIRECT_FUNC(set_pos);
    ctx.r3.u64 = r3;
    ctx.v1 = save_v1;
  }
  // facing: copy the quaternion
  if (ta::wr2(base, pt + 0xE0, 16))
    for (uint32_t k = 0; k < 16; k += 4) store_f32(base, pt + 0xE0 + k, ta::load_f32(base, ht + 0xE0 + k));
}

}  // namespace fable2::net::mirror

// Bone palette packer: research log + mirror copy, then the original.
extern "C" void sub_82207A90(PPCContext& ctx, uint8_t* base) {
  fable2::net::skeldiag::on_pack(base, ctx.r3.u32, ctx.r4.u32);
  fable2::net::mirror::on_pack(base, ctx.r3.u32, ctx.r4.u32);
  __imp__sub_82207A90(ctx, base);
}

// entity:SetPosition binding: x == -7777 marks that entity as the mirror puppet.
extern "C" void sub_825BC498(PPCContext& ctx, uint8_t* base) {
  const float x = ctx.v1.f32[3];
  if (x == fable2::net::mirror::kMarkX) {
    const uint64_t r3 = ctx.r3.u64;
    CheckValidPointer_825575C8(ctx, base);
    const uint32_t thing = ctx.r3.u32;
    ctx.r3.u64 = r3;
    fable2::net::mirror::S().puppet.store(thing);
    fable2::net::mirror::S().logged = false;
    REXLOG_INFO("[mpmirror] puppet marked: thing 0x{:08X}", thing);
    return;
  }
  __imp__sub_825BC498(ctx, base);
}
