// mp_puppets.h - multiplayer (f4): remote players drawn as puppet heroes.
//
// Game side of the network layer (mp_net.h). Every game tick (game thread):
//   * publishes our hero's position and facing to Net::local();
//   * gives every active peer a puppet body (a spawned hero), spawned by a
//     fixed Lua file (mp_puppet_child.lua / mp_puppet_adult.lua, chosen by the
//     peer's bone count; no network data ever goes into Lua), and moves it to
//     the peer's position (smoothed by real time) with the peer's facing.
// In the bone palette packer (sub_82207A90, render side):
//   * our hero's palettes are copied into Net::local() (sent by the net thread);
//   * a puppet's palettes are overwritten with the peer's latest pose.
//
// Skeleton -> entity: a skeleton belongs to the entity standing where its
// world position (skel+112) is (horizontal distance; the origin sits above the
// feet). Ownership is sticky: once matched, a skeleton stays with its owner
// while it stays near it, so bodies that walk through each other keep theirs.
//
// Loopback test (one game): --mp_enable=true --mp_port=27960
//   --mp_peers=127.0.0.1:27960 --mp_puppet_offset=1.5
// Our own packets come back and a puppet copies our hero 1.5 m to its right.
//
// Limits (first cut): a puppet whose peer leaves stays where it stood; a peer
// whose body changes (child -> adult) keeps the old body; puppet bodies are
// checked (transform vtable + owner) before every use but a freed body's
// memory could in theory be reused by another entity.
#pragma once

#include "mp_net.h"

#include <rex/cvar.h>
#include <rex/logging.h>
#include <rex/ppc/context.h>

#include <algorithm>
#include <cmath>
#include <deque>
#include <mutex>
#include <unordered_map>
#include <vector>

REXCVAR_DEFINE_DOUBLE(mp_puppet_offset, 0.0, "Multiplayer",
                      "Test: draw each puppet this many metres to its player's right "
                      "(1.5 for the loopback test, where the puppet is ourselves).");

DECLARE_REX_FUNC(sub_82207A90);  // bone palette packer (r3 skel, r4 palette vector)
DECLARE_REX_FUNC(sub_8222F1B0);  // GetPlayerHero native -> CThing*
DECLARE_REX_FUNC(sub_825BC498);  // Lua entity:SetPosition binding (r3 handle, v1 pos)
DECLARE_REX_FUNC(CheckValidPointer_825575C8);  // Lua entity handle -> CThing*

namespace fable2::net::puppets {
namespace ta = fable2::textappend;

constexpr float kMarkX = -7777.0f;           // SetPosition x that marks a new puppet
constexpr uint32_t kTransformVtbl = 0x820071C0;
constexpr int kHero = -1;                    // skeleton owner id for our hero
constexpr auto kSpawnRetry = std::chrono::seconds(5);
constexpr auto kSeenKeep = std::chrono::milliseconds(200);

struct Seen {
  float x, y, z;
  Clock::time_point t;
};

struct Puppet {
  uint32_t thing = 0;      // CThing* of the body (0 = none)
  uint32_t peer_id = 0;    // peer the body was made for
  uint16_t body_bones = 0; // main bone count of the body we asked for
  Clock::time_point spawn_req{};
  bool spawning = false;
  bool have_pos = false;
  float pos[3] = {};       // smoothed position
  std::array<std::vector<float>, kMaxParts> pose;  // host floats per part
  std::array<uint32_t, kMaxParts> pose_ver{};
  bool warned_body = false;
};

struct State {
  std::mutex m;  // guards everything below (packer hook + game thread)
  std::unordered_map<uint32_t, Seen> seen;    // skel -> last world position
  std::unordered_map<uint32_t, int> owner;    // skel -> kHero or puppet slot
  std::vector<uint32_t> hero_parts;           // our hero's skeletons, largest first
  std::unordered_map<uint32_t, std::pair<int, int>> puppet_skel;  // skel -> (slot, part)
  std::array<Puppet, kMaxPeers> pup;
  std::deque<int> pending;                    // slots waiting for their spawned body
  Clock::time_point last_tick{};
  bool logged_hero = false;
  uint32_t pose_writes = 0, pose_skips = 0;   // puppet palettes written / size mismatch
  Clock::time_point next_log{};
};
inline State& S() {
  static State s;
  return s;
}

inline bool heap(uint8_t* base, uint32_t a, size_t n) {
  return a >= 0x40000000u && a < 0x80000000u && ta::rdable2(base, a, n);
}
inline void store_f32(uint8_t* base, uint32_t a, float v) {
  uint32_t w;
  std::memcpy(&w, &v, 4);
  w = __builtin_bswap32(w);
  std::memcpy(base + a, &w, 4);
}
// A live entity: its transform component has the transform vtable and points back.
inline uint32_t transform_of(uint8_t* base, uint32_t thing) {
  if (!heap(base, thing, 128)) return 0;
  const uint32_t c = ta::load_be(base, thing + 124);
  if (!heap(base, c, 0x100)) return 0;
  if (ta::load_be(base, c) != kTransformVtbl || ta::load_be(base, c + 4) != thing) return 0;
  return c;
}
inline uint32_t vec_bones(uint8_t* base, uint32_t vec, uint32_t* begin) {
  if (!heap(base, vec, 12)) return 0;
  const uint32_t b = ta::load_be(base, vec + 4), e = ta::load_be(base, vec + 8);
  *begin = b;
  return (e > b && e - b < 48 * kMaxBones && (e - b) % 48 == 0) ? (e - b) / 48 : 0;
}
inline uint32_t skel_bones(uint8_t* base, uint32_t skel) {
  uint32_t b;
  return vec_bones(base, skel + 624, &b);
}

// Calls the transform component's own SetPosition (vtable +100, vector in v1;
// lanes are byte-reversed: f32[3] = x).
inline void set_position(PPCContext& ctx, uint8_t* base, uint32_t tc, float x, float y, float z) {
  const uint32_t vt = ta::load_be(base, tc);
  const uint32_t fn = ta::load_be(base, vt + 100);
  if (fn < 0x82000000u || fn >= 0x84000000u) return;
  const auto save_v1 = ctx.v1;
  const uint64_t r3 = ctx.r3.u64;
  ctx.v1.f32[3] = x;
  ctx.v1.f32[2] = y;
  ctx.v1.f32[1] = z;
  ctx.v1.f32[0] = 0.0f;
  ctx.r3.u32 = tc;
  REX_CALL_INDIRECT_FUNC(fn);
  ctx.r3.u64 = r3;
  ctx.v1 = save_v1;
}

// Packer hook (render side): record the skeleton; send our hero's pose; draw
// puppets with their peer's pose.
inline void on_pack(uint8_t* base, uint32_t skel, uint32_t vec) {
  if (!REXCVAR_GET(mp_enable)) return;
  State& s = S();
  std::lock_guard<std::mutex> l(s.m);
  if (s.seen.size() < 1024 || s.seen.count(skel))
    s.seen[skel] = {ta::load_f32(base, skel + 112), ta::load_f32(base, skel + 116),
                    ta::load_f32(base, skel + 120), Clock::now()};
  uint32_t b = 0;
  const uint32_t n = vec_bones(base, vec, &b);
  if (!n || !heap(base, b, n * 48)) return;

  const auto h = std::find(s.hero_parts.begin(), s.hero_parts.end(), skel);
  if (h != s.hero_parts.end()) {
    const uint32_t part = uint32_t(h - s.hero_parts.begin());
    if (part >= kMaxParts) return;
    std::vector<float> pose(n * 12);
    for (uint32_t k = 0; k < n * 12; ++k) pose[k] = ta::load_f32(base, b + k * 4);
    Local& L = Net::Get().local();
    std::lock_guard<std::mutex> ll(L.m);
    L.parts[part].swap(pose);
    L.part_count = uint32_t(std::min<size_t>(s.hero_parts.size(), kMaxParts));
    if (part == 0) ++L.pose_frame;
    return;
  }
  const auto p = s.puppet_skel.find(skel);
  if (p == s.puppet_skel.end()) return;
  const auto& src = s.pup[p->second.first].pose[p->second.second];
  if (src.size() != size_t(n) * 12 || !ta::wr2(base, b, n * 48)) {
    ++s.pose_skips;
    return;
  }
  for (uint32_t k = 0; k < n * 12; ++k) store_f32(base, b + k * 4, src[k]);
  ++s.pose_writes;
}

// Re-match skeletons to owners. Caller holds s.m.
inline void match_skeletons(uint8_t* base, const float hero_pos[3],
                            const std::array<uint32_t, kMaxPeers>& pup_tc, Clock::time_point now) {
  State& s = S();
  for (auto it = s.seen.begin(); it != s.seen.end();)
    it = (now - it->second.t > kSeenKeep) ? s.seen.erase(it) : std::next(it);

  float opos[kMaxPeers][3];
  for (int i = 0; i < kMaxPeers; ++i)
    if (pup_tc[i])
      for (int k = 0; k < 3; ++k) opos[i][k] = ta::load_f32(base, pup_tc[i] + 0x70 + 4 * k);
  auto owner_pos = [&](int o) -> const float* {
    if (o == kHero) return hero_pos;
    return (o >= 0 && o < kMaxPeers && pup_tc[o]) ? opos[o] : nullptr;
  };
  auto is_near = [](const Seen& k, const float* p) {
    const float dx = k.x - p[0], dy = k.y - p[1], dz = k.z - p[2];
    return dx * dx + dy * dy < 0.35f * 0.35f && dz > -0.5f && dz < 2.0f;
  };
  // keep owned skeletons that are still seen near their owner
  for (auto it = s.owner.begin(); it != s.owner.end();) {
    const auto sk = s.seen.find(it->first);
    const float* op = owner_pos(it->second);
    it = (sk == s.seen.end() || !op || !is_near(sk->second, op)) ? s.owner.erase(it) : std::next(it);
  }
  // give unowned skeletons to whoever stands there (our hero first). A body has
  // at most one skeleton of each size, so a puppet standing on our hero (same
  // start point) cannot lose its skeleton to the hero.
  std::vector<std::pair<int, uint32_t>> have;  // (owner, bones)
  for (const auto& [skel, o] : s.owner) have.push_back({o, skel_bones(base, skel)});
  auto takes = [&](int o, uint32_t bones) {
    return std::find(have.begin(), have.end(), std::make_pair(o, bones)) == have.end();
  };
  for (const auto& [skel, k] : s.seen) {
    if (s.owner.count(skel)) continue;
    const uint32_t bones = skel_bones(base, skel);
    int o = -2;
    if (is_near(k, hero_pos) && takes(kHero, bones)) o = kHero;
    for (int i = 0; o == -2 && i < kMaxPeers; ++i)
      if (pup_tc[i] && is_near(k, opos[i]) && takes(i, bones)) o = i;
    if (o == -2) continue;
    s.owner[skel] = o;
    have.push_back({o, bones});
  }
  // parts: per owner, largest bone count first (ties: address)
  std::vector<std::pair<uint32_t, uint32_t>> by[kMaxPeers + 1];  // (bones, skel); [0] = hero
  for (const auto& [skel, o] : s.owner) by[o + 1].push_back({skel_bones(base, skel), skel});
  for (auto& v : by)
    std::sort(v.begin(), v.end(), [](auto& a, auto& b) { return a.first != b.first ? a.first > b.first : a.second < b.second; });
  s.hero_parts.clear();
  for (auto& [bones, skel] : by[0]) s.hero_parts.push_back(skel);
  s.puppet_skel.clear();
  for (int i = 0; i < kMaxPeers; ++i)
    for (size_t k = 0; k < by[i + 1].size() && k < kMaxParts; ++k)
      s.puppet_skel[by[i + 1][k].second] = {i, int(k)};
}

// Game thread, from the frame-loop idle point (runs many times per frame).
inline void tick(PPCContext& ctx, uint8_t* base) {
  if (!REXCVAR_GET(mp_enable)) return;
  Net& net = Net::Get();
  net.ensure_started();
  State& s = S();
  const auto now = Clock::now();
  if (now - s.last_tick < std::chrono::milliseconds(8)) return;
  const float dt = std::min(0.1f, std::chrono::duration<float>(now - s.last_tick).count());
  s.last_tick = now;

  const uint64_t save_r3 = ctx.r3.u64;
  sub_8222F1B0(ctx, base);
  const uint32_t hero = ctx.r3.u32;
  ctx.r3.u64 = save_r3;
  const uint32_t ht = hero ? transform_of(base, hero) : 0;
  if (!ht) {
    if (hero && !s.logged_hero) {
      s.logged_hero = true;
      REXLOG_WARN("[mppup] hero 0x{:08X} failed the transform check; multiplayer idle", hero);
    }
    std::lock_guard<std::mutex> ll(net.local().m);
    net.local().valid = false;
    return;
  }
  float hp[3];
  for (int k = 0; k < 3; ++k) hp[k] = ta::load_f32(base, ht + 0x70 + 4 * k);
  const float hqz = ta::load_f32(base, ht + 0xE8), hqw = ta::load_f32(base, ht + 0xEC);
  {
    Local& L = net.local();
    std::lock_guard<std::mutex> ll(L.m);
    L.valid = true;
    std::memcpy(L.pos, hp, sizeof(hp));
    L.qz = hqz;
    L.qw = hqw;
  }

  std::array<uint32_t, kMaxPeers> tc{};
  for (int i = 0; i < kMaxPeers; ++i) {
    Puppet& p = s.pup[i];
    Net::PeerView v;
    const bool active = net.peer_view(i, v);
    uint32_t thing;
    {
      std::lock_guard<std::mutex> l(s.m);
      thing = p.thing;
    }
    tc[i] = thing ? transform_of(base, thing) : 0;
    if (thing && !tc[i]) {  // body gone (level change, killed...)
      std::lock_guard<std::mutex> l(s.m);
      REXLOG_INFO("[mppup] slot {}: puppet body 0x{:08X} is gone", i, thing);
      p.thing = 0;
      p.have_pos = false;
    }
    if (!active || v.bone_count == 0) continue;
    if (p.peer_id != v.id) {  // new player in this slot
      p.peer_id = v.id;
      p.pose_ver.fill(0);
      p.warned_body = false;
    }
    if (!tc[i]) {
      if (!p.spawning || now - p.spawn_req > kSpawnRetry) {
        std::lock_guard<std::mutex> l(s.m);
        p.spawning = true;
        p.spawn_req = now;
        p.body_bones = v.bone_count;
        s.pending.erase(std::remove(s.pending.begin(), s.pending.end(), i), s.pending.end());
        s.pending.push_back(i);
        const char* script = v.bone_count == 143 ? "scripts/recomp/mp_puppet_child.lua"
                                                 : "scripts/recomp/mp_puppet_adult.lua";
        REXLOG_INFO("[mppup] slot {}: spawning a body for peer {:08X} ({} bones) via {}", i, v.id,
                    v.bone_count, script);
        fable2::f5lua::request_run(script);
      }
      continue;
    }
    if (p.body_bones != v.bone_count && !p.warned_body) {
      p.warned_body = true;
      REXLOG_WARN("[mppup] slot {}: peer now has {} bones, body has {} (pose not shown)", i,
                  v.bone_count, p.body_bones);
    }
    // transform: smoothed toward the peer's latest state
    if (v.have_state) {
      const float yaw = 2.0f * std::atan2(v.qz, v.qw);  // forward = (cos, sin)
      const float off = float(REXCVAR_GET(mp_puppet_offset));
      const float tx = v.pos[0] + std::sin(yaw) * off, ty = v.pos[1] - std::cos(yaw) * off,
                  tz = v.pos[2];
      const float dx = tx - p.pos[0], dy = ty - p.pos[1], dz = tz - p.pos[2];
      if (!p.have_pos || dx * dx + dy * dy + dz * dz > 25.0f) {  // first or > 5 m: snap
        p.pos[0] = tx, p.pos[1] = ty, p.pos[2] = tz;
        p.have_pos = true;
      } else {
        const float a = 1.0f - std::exp(-dt * 20.0f);
        p.pos[0] += dx * a, p.pos[1] += dy * a, p.pos[2] += dz * a;
      }
      set_position(ctx, base, tc[i], p.pos[0], p.pos[1], p.pos[2]);
      if (ta::wr2(base, tc[i] + 0xE0, 16)) {
        store_f32(base, tc[i] + 0xE0, 0.0f);
        store_f32(base, tc[i] + 0xE4, 0.0f);
        store_f32(base, tc[i] + 0xE8, v.qz);
        store_f32(base, tc[i] + 0xEC, v.qw);
      }
    }
    // pose: take any newer complete part
    for (uint32_t part = 0; part < v.part_count && part < kMaxParts; ++part) {
      std::vector<float> pose;
      uint32_t ver = 0;
      if (net.peer_pose(i, part, p.pose_ver[part], pose, &ver)) {
        std::lock_guard<std::mutex> l(s.m);
        p.pose[part].swap(pose);
        p.pose_ver[part] = ver;
      }
    }
  }

  std::lock_guard<std::mutex> l(s.m);
  match_skeletons(base, hp, tc, now);
  if (now >= s.next_log) {
    s.next_log = now + std::chrono::seconds(10);
    std::string hero_b, pup_b;
    for (uint32_t k : s.hero_parts) hero_b += std::to_string(skel_bones(base, k)) + " ";
    for (const auto& [skel, sp] : s.puppet_skel)
      pup_b += "s" + std::to_string(sp.first) + "p" + std::to_string(sp.second) + ":" +
               std::to_string(skel_bones(base, skel)) + " ";
    REXLOG_INFO("[mppup] hero parts [{}] puppet parts [{}] pose writes {} skips {}; {} skeletons seen",
                hero_b, pup_b, s.pose_writes, s.pose_skips, s.seen.size());
  }
}

// SetPosition hook: x == kMarkX hands the entity to the oldest waiting slot.
inline bool on_mark(PPCContext& ctx, uint8_t* base) {
  if (ctx.v1.f32[3] != kMarkX) return false;
  const uint64_t r3 = ctx.r3.u64;
  CheckValidPointer_825575C8(ctx, base);
  const uint32_t thing = ctx.r3.u32;
  ctx.r3.u64 = r3;
  State& s = S();
  std::lock_guard<std::mutex> l(s.m);
  if (s.pending.empty()) {
    REXLOG_WARN("[mppup] marked entity 0x{:08X} but no puppet was waiting", thing);
    return true;
  }
  const int slot = s.pending.front();
  s.pending.pop_front();
  Puppet& p = s.pup[slot];
  p.thing = thing;
  p.spawning = false;
  p.have_pos = false;
  REXLOG_INFO("[mppup] slot {}: puppet body 0x{:08X}", slot, thing);
  return true;
}

}  // namespace fable2::net::puppets

// Bone palette packer: research log + multiplayer pose send/apply, then the original.
extern "C" void sub_82207A90(PPCContext& ctx, uint8_t* base) {
  fable2::net::skeldiag::on_pack(base, ctx.r3.u32, ctx.r4.u32);
  fable2::net::puppets::on_pack(base, ctx.r3.u32, ctx.r4.u32);
  __imp__sub_82207A90(ctx, base);
}

// entity:SetPosition binding: x == -7777 marks a freshly spawned puppet body.
extern "C" void sub_825BC498(PPCContext& ctx, uint8_t* base) {
  if (fable2::net::puppets::on_mark(ctx, base)) return;
  __imp__sub_825BC498(ctx, base);
}
