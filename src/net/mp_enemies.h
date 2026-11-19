// mp_enemies.h - multiplayer combat step 2: the host's enemies in every world.
//
// The host's game is the only one that runs enemies. Ten times a second it
// sends (ENEMIES, mp_net.h) every hostile creature near a player: an id, the
// record id, position, facing, health and whether it is dead. The other games
// do not run their own enemies while the host's list keeps arriving: hostile
// creatures of their own are removed, and copies of the host's are made and
// moved to the host's positions. A copy dies when the host's enemy dies and is
// removed when the host stops listing it. Damage dealt by a copy is dropped
// (the host's enemy deals the real damage, see mp_combat.h); damage to a copy
// is dropped for now (step 3 sends it to the host).
//
// Game internals used (all found from the Lua bindings):
//   entity list: manager = *(*(*(*(*(0x83496920) + 12) + 88) + 4) + 0)
//     node = *(manager + 8), next = *(node + 0), entity = *(node + 8);
//     live entity: byte +144 bit 0x40; next entity UID at manager + 4.
//   entity +28: record id. Record table *(0x83496BD0): a list of sources
//     (node +0 next, +8 source, +12 kind), each a sorted array of
//     {name hash, record id} (source header +16 array, +20 count).
//   sub_82391030: create entity (r3 record id, r4 &{uid, 0}, r5 &name, r6 1,
//     r7 0, v1 position) -> CThing*; sub_82392FF8: destroy entity (r3).
//     Both run from mp_enemy_phase.lua's callback, inside a script, as the
//     Debug.CreateEntityAtPosition / DestroyAllEntitiesOfType bindings do.
//   components (list at +72/+76 of {type, ptr}): 36 health (+20 health,
//     +28 max), 133 faction (+20 faction id). sub_822040D0(faction comp, other
//     entity) == 4: hostile (Faction.IsMyEnemy).
//
// No network data ever goes into Lua: the record id from the host is checked
// against the game's own record table and given to the native create.
#pragma once

#include <rex/cvar.h>
#include <rex/logging.h>
#include <rex/ppc/context.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "mp_combat.h"
#include "mp_puppets.h"

REXCVAR_DEFINE_INT32(mp_enemy_diag, 0, "Multiplayer",
                     "1 = log enemy sync (copies made and removed, own enemies removed).");
REXCVAR_DEFINE_DOUBLE(mp_enemy_range, 50.0, "Multiplayer",
                      "Host: send hostile creatures within this many metres of any player.");

DECLARE_REX_FUNC(sub_82391030);  // create entity from record id
DECLARE_REX_FUNC(sub_82392FF8);  // destroy entity
DECLARE_REX_FUNC(sub_822040D0);  // faction relation (r3 faction comp, r4 other entity) -> 4 = hostile

namespace fable2::net::enemies {

using combat::load_f32;
using combat::load_u32;
using Clock = std::chrono::steady_clock;

constexpr uint32_t kWorldGlobal = 0x83496920;  // lis -31927 + 26912
constexpr uint32_t kRecordTable = 0x83496BD0;  // lis -31927 + 27600
constexpr uint32_t kMaxEntities = 20000;
constexpr uint32_t kHealthType = 36;
constexpr uint32_t kFactionType = 133;
constexpr uint32_t kHostile = 4;
constexpr auto kSendEvery = std::chrono::milliseconds(100);
constexpr auto kHostSilence = std::chrono::seconds(2);   // no list for this long: host gone
constexpr auto kMissingFor = std::chrono::seconds(1);    // copy not listed this long: remove it
constexpr auto kDeadListed = std::chrono::seconds(5);    // host keeps listing a corpse this long
constexpr auto kOwnScanEvery = std::chrono::milliseconds(500);

// --- game access -------------------------------------------------------------

inline uint32_t entity_manager(uint8_t* base) {
  uint32_t a = load_u32(base, kWorldGlobal);
  for (uint32_t off : {12u, 88u, 4u, 0u}) {
    if (!puppets::heap(base, a, off + 4)) return 0;
    a = load_u32(base, a + off);
  }
  return puppets::heap(base, a, 16) ? a : 0;
}

inline bool live(uint8_t* base, uint32_t t) { return puppets::heap(base, t, 160) && (base[t + 144] & 0x40); }

inline uint32_t component(uint8_t* base, uint32_t t, uint32_t type) {
  const uint32_t b = load_u32(base, t + 72), e = load_u32(base, t + 76);
  if (e <= b || e - b > 512 * 8 || (e - b) % 8 || !puppets::heap(base, b, e - b)) return 0;
  for (uint32_t a = b; a < e; a += 8) {
    if (load_u32(base, a) != type) continue;
    const uint32_t c = load_u32(base, a + 4);
    return (puppets::heap(base, c, 32) && load_u32(base, c + 4) == t) ? c : 0;
  }
  return 0;
}

// Transform component of any entity (heroes and creatures use different classes).
inline uint32_t transform(uint8_t* base, uint32_t t) {
  if (!puppets::heap(base, t, 128)) return 0;
  const uint32_t c = load_u32(base, t + 124);
  if (!puppets::heap(base, c, 0x100) || load_u32(base, c + 4) != t) return 0;
  const uint32_t vt = load_u32(base, c);
  return (vt >= 0x82000000u && vt < 0x82100000u) ? c : 0;
}

// Calls a guest function with its own stack frame (callees store into their
// caller's frame) and the whole context put back afterwards. Returns r3.
inline uint32_t guest_call(PPCContext& ctx, uint8_t* base, PPCFunc* fn, uint32_t a3, uint32_t a4 = 0,
                           uint32_t a5 = 0, uint32_t a6 = 0, uint32_t a7 = 0, const float* v1 = nullptr) {
  const PPCContext saved = ctx;
  ctx.r1.u64 = (saved.r1.u64 - 1024) & ~uint64_t(15);
  ctx.r3.u64 = a3;
  ctx.r4.u64 = a4;
  ctx.r5.u64 = a5;
  ctx.r6.u64 = a6;
  ctx.r7.u64 = a7;
  if (v1) {  // lanes are byte-reversed: f32[3] = x
    ctx.v1.f32[3] = v1[0];
    ctx.v1.f32[2] = v1[1];
    ctx.v1.f32[1] = v1[2];
    ctx.v1.f32[0] = 0.0f;
  }
  fn(ctx, base);
  const uint32_t r = ctx.r3.u32;
  ctx = saved;
  return r;
}

inline uint32_t player_hero(PPCContext& ctx, uint8_t* base) {
  const uint64_t r3 = ctx.r3.u64;
  sub_8222F1B0(ctx, base);
  const uint32_t h = ctx.r3.u32;
  ctx.r3.u64 = r3;
  return h;
}

inline bool hostile_to(PPCContext& ctx, uint8_t* base, uint32_t t, uint32_t hero) {
  const uint32_t fc = component(base, t, kFactionType);
  return fc && guest_call(ctx, base, sub_822040D0, fc, hero) == kHostile;
}

// Every record id the game knows (built once).
inline bool valid_record(uint8_t* base, uint32_t id) {
  static std::unordered_set<uint32_t> ids;
  static bool built = false;
  if (!built) {
    const uint32_t table = load_u32(base, kRecordTable);
    if (!puppets::heap(base, table, 4)) return false;
    const uint32_t head = load_u32(base, table);
    const uint32_t sentinel = puppets::heap(base, head, 8) ? load_u32(base, head + 4) : 0;
    uint32_t node = puppets::heap(base, sentinel, 4) ? load_u32(base, sentinel) : 0;
    for (int n = 0; node && node != sentinel && n < 256; ++n) {
      if (!puppets::heap(base, node, 16)) break;
      const uint32_t src = load_u32(base, node + 8);
      const uint32_t h = puppets::heap(base, src, 4) ? load_u32(base, src) : 0;
      if (load_u32(base, node + 12) == 0 && puppets::heap(base, h, 24)) {
        const uint32_t arr = load_u32(base, h + 16), cnt = load_u32(base, h + 20);
        if (cnt < 200000 && puppets::heap(base, arr, cnt * 8))
          for (uint32_t k = 0; k < cnt; ++k) ids.insert(load_u32(base, arr + k * 8 + 4));
      }
      node = load_u32(base, node);
    }
    built = !ids.empty();
    REXLOG_INFO("[mpenemy] {} record ids known", ids.size());
  }
  return ids.count(id) != 0;
}

// --- state ---------------------------------------------------------------------

struct Copy {
  uint32_t thing = 0;      // 0 = being made
  uint32_t record = 0;
  bool have_pos = false;
  float pos[3] = {};
  bool killed = false;     // the host's enemy died and so did the copy
  Clock::time_point last_listed{};
  Clock::time_point create_req{};
};

struct Track {  // host: one of our enemies
  uint16_t id = 0;
  bool dead = false;
  Clock::time_point dead_since{};
};

struct Create {
  uint16_t id;
  uint32_t record;
  float pos[3];
};

struct State {
  std::mutex m;  // guards copy_things (read from the health hook)
  std::unordered_set<uint32_t> copy_things;
  bool applying = false;  // our own health change on a copy (its death)
  // host
  std::unordered_map<uint32_t, Track> tracks;  // thing -> track
  uint16_t next_id = 1;
  Clock::time_point next_send{};
  // the other players
  std::unordered_map<uint16_t, Copy> copies;   // host id -> copy
  std::vector<EnemyState> host_list;
  uint32_t list_ver = 0;
  Clock::time_point list_at{};
  Clock::time_point next_own_scan{};
  Clock::time_point next_diag{};
  // work for the script phase
  std::vector<Create> creates;
  std::vector<std::pair<uint32_t, uint32_t>> destroys;  // (thing, record)
  bool phase_requested = false;
  Clock::time_point phase_req_at{};
};
inline State& S() {
  static State s;
  return s;
}

inline bool is_copy(uint32_t thing) {
  State& s = S();
  std::lock_guard<std::mutex> l(s.m);
  return s.copy_things.count(thing) != 0;
}
inline bool applying_own() { return S().applying; }

inline void forget_copy(State& s, uint32_t thing) {
  std::lock_guard<std::mutex> l(s.m);
  s.copy_things.erase(thing);
}

inline void request_phase(State& s, Clock::time_point now) {
  if (s.creates.empty() && s.destroys.empty()) return;
  if (s.phase_requested && now - s.phase_req_at < std::chrono::seconds(2)) return;
  s.phase_requested = true;
  s.phase_req_at = now;
  f5lua::request_run("scripts/recomp/mp_enemy_phase.lua");
}

// mp_enemy_phase.lua's callback: inside a script, on the game thread.
inline void on_script_phase(PPCContext& ctx, uint8_t* base) {
  State& s = S();
  s.phase_requested = false;
  const int diag = REXCVAR_GET(mp_enemy_diag);
  for (const auto& [t, rec] : s.destroys) {
    if (!live(base, t) || load_u32(base, t + 28) != rec) continue;
    guest_call(ctx, base, sub_82392FF8, t);
    if (diag) REXLOG_INFO("[mpenemy] removed 0x{:08X} (record {:08X})", t, rec);
  }
  s.destroys.clear();
  static uint32_t scratch = 0;  // {uid, 0, name (0 = none)}
  if (!scratch) scratch = fable2::textappend::guest_alloc(ctx, base, 16);
  const uint32_t mgr = entity_manager(base);
  for (const auto& c : s.creates) {
    auto it = s.copies.find(c.id);
    if (it == s.copies.end() || it->second.thing || !scratch || !mgr) continue;
    const uint32_t uid = load_u32(base, mgr + 4);
    puppets::store_u32(base, mgr + 4, uid + 1);
    puppets::store_u32(base, scratch, uid);
    puppets::store_u32(base, scratch + 4, 0);
    puppets::store_u32(base, scratch + 8, 0);
    const uint32_t t = guest_call(ctx, base, sub_82391030, c.record, scratch, scratch + 8, 1, 0, c.pos);
    if (!live(base, t)) {
      REXLOG_WARN("[mpenemy] could not make a copy of record {:08X}", c.record);
      continue;
    }
    it->second.thing = t;
    {
      std::lock_guard<std::mutex> l(s.m);
      s.copy_things.insert(t);
    }
    if (diag) REXLOG_INFO("[mpenemy] copy {} (record {:08X}) made: 0x{:08X}", c.id, c.record, t);
  }
  s.creates.clear();
}

inline std::vector<uint32_t> puppet_bodies() {
  std::vector<uint32_t> v;
  auto& ps = puppets::S();
  std::lock_guard<std::mutex> l(ps.m);
  for (const auto& p : ps.pup)
    if (p.thing) v.push_back(p.thing);
  return v;
}

// --- host ----------------------------------------------------------------------

inline void host_tick(PPCContext& ctx, uint8_t* base, uint32_t hero, Clock::time_point now) {
  State& s = S();
  if (now < s.next_send) return;
  s.next_send = now + kSendEvery;
  const std::vector<uint32_t> bodies = puppet_bodies();
  if (bodies.empty()) {  // nobody to send to
    s.tracks.clear();
    return;
  }
  // players: our hero and every puppet body
  std::vector<std::array<float, 3>> players;
  for (uint32_t t : bodies) {
    const uint32_t tc = transform(base, t);
    if (tc) players.push_back({load_f32(base, tc + 0x70), load_f32(base, tc + 0x74), load_f32(base, tc + 0x78)});
  }
  if (const uint32_t tc = transform(base, hero))
    players.push_back({load_f32(base, tc + 0x70), load_f32(base, tc + 0x74), load_f32(base, tc + 0x78)});
  const float range = float(std::clamp(REXCVAR_GET(mp_enemy_range), 5.0, 200.0));

  struct Cand {
    float d2;
    EnemyState e;
  };
  std::vector<Cand> cands;
  std::unordered_set<uint32_t> seen;
  const uint32_t mgr = entity_manager(base);
  uint32_t node = mgr ? load_u32(base, mgr + 8) : 0;
  for (uint32_t n = 0; node && n < kMaxEntities; ++n) {
    if (!puppets::heap(base, node, 12)) break;
    const uint32_t t = load_u32(base, node + 8);
    node = load_u32(base, node);
    if (t == hero || !live(base, t)) continue;
    if (std::find(bodies.begin(), bodies.end(), t) != bodies.end()) continue;
    const uint32_t hc = component(base, t, kHealthType);
    if (!hc) continue;
    const uint32_t tc = transform(base, t);
    if (!tc) continue;
    const float pos[3] = {load_f32(base, tc + 0x70), load_f32(base, tc + 0x74), load_f32(base, tc + 0x78)};
    float d2 = 1e30f;
    for (const auto& p : players) {
      const float dx = pos[0] - p[0], dy = pos[1] - p[1], dz = pos[2] - p[2];
      d2 = std::min(d2, dx * dx + dy * dy + dz * dz);
    }
    if (d2 > range * range) continue;
    const float health = load_f32(base, hc + 20);
    auto tr = s.tracks.find(t);
    if (tr == s.tracks.end()) {
      if (!(health > 0.0f) || !hostile_to(ctx, base, t, hero)) continue;
      Track k;
      k.id = s.next_id++;
      if (s.next_id == 0) s.next_id = 1;
      tr = s.tracks.emplace(t, k).first;
    }
    Track& k = tr->second;
    if (!(health > 0.0f) && !k.dead) {
      k.dead = true;
      k.dead_since = now;
    }
    seen.insert(t);  // keep the id while the corpse exists
    if (k.dead && now - k.dead_since > kDeadListed) continue;
    EnemyState e;
    e.id = k.id;
    e.flags = k.dead ? 1 : 0;
    e.record = load_u32(base, t + 28);
    std::copy(pos, pos + 3, e.pos);
    e.qz = load_f32(base, tc + 0xE8);
    e.qw = load_f32(base, tc + 0xEC);
    const float len = std::sqrt(e.qz * e.qz + e.qw * e.qw);
    if (!std::isfinite(len) || len < 0.5f) {
      e.qz = 0.0f;
      e.qw = 1.0f;
    }
    e.health = std::isfinite(health) ? health : 0.0f;
    cands.push_back({d2, e});
  }
  for (auto it = s.tracks.begin(); it != s.tracks.end();)
    it = seen.count(it->first) ? std::next(it) : s.tracks.erase(it);
  std::sort(cands.begin(), cands.end(), [](const Cand& a, const Cand& b) { return a.d2 < b.d2; });
  if (cands.size() > kMaxEnemies) cands.resize(kMaxEnemies);
  std::vector<EnemyState> list;
  list.reserve(cands.size());
  for (const auto& c : cands) list.push_back(c.e);
  Net::Get().set_enemies(std::move(list));
}

// --- the other players -----------------------------------------------------------

// The host's enemy died: kill the copy too, so it plays its own death.
inline void kill_copy(PPCContext& ctx, uint8_t* base, uint32_t thing) {
  const uint32_t hc = component(base, thing, kHealthType);
  if (!hc || !(load_f32(base, hc + 20) > 0.0f)) return;
  const double amount = -double(load_f32(base, hc + 20)) - 1.0;
  State& s = S();
  const PPCContext saved = ctx;
  ctx.r1.u64 = (saved.r1.u64 - 1024) & ~uint64_t(15);
  ctx.r3.u64 = hc;
  ctx.r5.u64 = 0;
  ctx.f1.f64 = amount;
  s.applying = true;
  __imp__sub_8268BD90(ctx, base);
  s.applying = false;
  ctx = saved;
}

inline void guest_tick(PPCContext& ctx, uint8_t* base, uint32_t hero, Clock::time_point now, float dt) {
  State& s = S();
  const int diag = REXCVAR_GET(mp_enemy_diag);
  {
    std::vector<EnemyState> list;
    Clock::time_point at;
    if (Net::Get().take_enemies(s.list_ver, list, at)) {
      s.host_list.swap(list);
      s.list_at = at;
    }
  }
  const bool host_here = s.list_ver != 0 && now - s.list_at < kHostSilence;
  if (!host_here) {
    // No host list (alone, or the host left): no copies, our own enemies run.
    if (!s.copies.empty()) {
      for (auto& [id, c] : s.copies)
        if (c.thing) s.destroys.push_back({c.thing, c.record});
      s.copies.clear();
      std::lock_guard<std::mutex> l(s.m);
      s.copy_things.clear();
      REXLOG_INFO("[mpenemy] the host's enemy list stopped; removing the copies");
    }
    s.creates.clear();
    request_phase(s, now);
    return;
  }

  // Our own hostile creatures: removed while the host runs the enemies.
  if (now >= s.next_own_scan) {
    s.next_own_scan = now + kOwnScanEvery;
    const std::vector<uint32_t> bodies = puppet_bodies();
    const uint32_t mgr = entity_manager(base);
    uint32_t node = mgr ? load_u32(base, mgr + 8) : 0;
    int removed = 0;
    for (uint32_t n = 0; node && n < kMaxEntities && removed < 16; ++n) {
      if (!puppets::heap(base, node, 12)) break;
      const uint32_t t = load_u32(base, node + 8);
      node = load_u32(base, node);
      if (t == hero || !live(base, t) || is_copy(t)) continue;
      if (std::find(bodies.begin(), bodies.end(), t) != bodies.end()) continue;
      const uint32_t hc = component(base, t, kHealthType);
      if (!hc || !(load_f32(base, hc + 20) > 0.0f)) continue;
      if (!hostile_to(ctx, base, t, hero)) continue;
      const auto key = std::make_pair(t, load_u32(base, t + 28));
      if (std::find(s.destroys.begin(), s.destroys.end(), key) != s.destroys.end()) continue;
      s.destroys.push_back(key);
      ++removed;
      if (diag) REXLOG_INFO("[mpenemy] removing our own enemy 0x{:08X} (record {:08X})", key.first, key.second);
    }
  }

  // Copies follow the host's list.
  for (const auto& e : s.host_list) {
    auto it = s.copies.find(e.id);
    if (it == s.copies.end()) {
      if (s.copies.size() >= kMaxEnemies || (e.flags & 1)) continue;  // no copies of corpses
      if (!valid_record(base, e.record)) {
        static int warned = 0;
        if (warned++ < 10) REXLOG_WARN("[mpenemy] the host sent an unknown record {:08X}; ignored", e.record);
        continue;
      }
      it = s.copies.emplace(e.id, Copy{}).first;
      it->second.record = e.record;
    }
    Copy& c = it->second;
    if (c.record != e.record) continue;  // the id now means another kind: let the old one expire
    c.last_listed = s.list_at;
    if (!c.thing) {
      if (now - c.create_req > std::chrono::seconds(3)) {
        c.create_req = now;
        s.creates.push_back({e.id, e.record, {e.pos[0], e.pos[1], e.pos[2]}});
      }
      continue;
    }
    const uint32_t tc = transform(base, c.thing);
    if (!live(base, c.thing) || !tc || load_u32(base, c.thing + 28) != c.record) {
      forget_copy(s, c.thing);  // gone: made again next time
      c.thing = 0;
      c.have_pos = false;
      continue;
    }
    // position: smoothed toward the host's (it arrives 10 times a second)
    const float dx = e.pos[0] - c.pos[0], dy = e.pos[1] - c.pos[1], dz = e.pos[2] - c.pos[2];
    if (!c.have_pos || dx * dx + dy * dy + dz * dz > 25.0f) {
      std::copy(e.pos, e.pos + 3, c.pos);
      c.have_pos = true;
    } else {
      const float a = 1.0f - std::exp(-dt * 12.0f);
      c.pos[0] += dx * a, c.pos[1] += dy * a, c.pos[2] += dz * a;
    }
    puppets::set_position(ctx, base, tc, c.pos[0], c.pos[1], c.pos[2]);
    if (fable2::textappend::wr2(base, tc + 0xE0, 16)) {
      puppets::store_f32(base, tc + 0xE0, 0.0f);
      puppets::store_f32(base, tc + 0xE4, 0.0f);
      puppets::store_f32(base, tc + 0xE8, e.qz);
      puppets::store_f32(base, tc + 0xEC, e.qw);
    }
    if ((e.flags & 1) && !c.killed) {
      c.killed = true;
      kill_copy(ctx, base, c.thing);
      if (diag) REXLOG_INFO("[mpenemy] copy {} died with the host's enemy", e.id);
    }
  }
  if (diag && now >= s.next_diag) {
    s.next_diag = now + std::chrono::seconds(3);
    for (const auto& e : s.host_list) {
      const auto it = s.copies.find(e.id);
      const uint32_t tc = (it != s.copies.end() && it->second.thing) ? transform(base, it->second.thing) : 0;
      if (!tc) continue;
      const float x = load_f32(base, tc + 0x70), y = load_f32(base, tc + 0x74), z = load_f32(base, tc + 0x78);
      REXLOG_INFO("[mpenemy] copy {}: host at {:.2f} {:.2f} {:.2f}, copy at {:.2f} {:.2f} {:.2f} (off {:.2f} m)", e.id,
                  e.pos[0], e.pos[1], e.pos[2], x, y, z,
                  std::sqrt((x - e.pos[0]) * (x - e.pos[0]) + (y - e.pos[1]) * (y - e.pos[1]) +
                            (z - e.pos[2]) * (z - e.pos[2])));
    }
  }
  // copies the host no longer lists
  for (auto it = s.copies.begin(); it != s.copies.end();) {
    Copy& c = it->second;
    if (s.list_at - c.last_listed > kMissingFor) {
      if (c.thing) {
        if (!c.killed) s.destroys.push_back({c.thing, c.record});  // corpses stay, as in the host's world
        forget_copy(s, c.thing);
      }
      if (diag) REXLOG_INFO("[mpenemy] copy {} no longer listed by the host", it->first);
      it = s.copies.erase(it);
    } else {
      ++it;
    }
  }
  request_phase(s, now);
}

// Game thread, after combat::tick.
inline void tick(PPCContext& ctx, uint8_t* base) {
  if (!REXCVAR_GET(mp_enable)) return;
  static Clock::time_point last{};
  const auto now = Clock::now();
  if (now - last < std::chrono::milliseconds(8)) return;
  const float dt = std::min(0.1f, std::chrono::duration<float>(now - last).count());
  last = now;
  const uint32_t hero = player_hero(ctx, base);
  if (!hero || !live(base, hero)) return;
  if (REXCVAR_GET(mp_host))
    host_tick(ctx, base, hero, now);
  else
    guest_tick(ctx, base, hero, now, dt);
}

}  // namespace fable2::net::enemies
