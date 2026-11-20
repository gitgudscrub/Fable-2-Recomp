// mp_looks.h - multiplayer (f36): puppets wear what each player wears.
//
// Every game sends the record ids of what its hero wears (LOOKS, mp_net.h):
// when it changes and every 2 s. Each puppet body is then made to wear exactly
// that list, natively on the game thread (no Lua):
//   * items it should not wear come off (sub_8256FE20, AppearanceModifierManager
//     RemoveItem);
//   * missing items are made in the puppet's inventory (sub_8261A058, what
//     Inventory.AddItemOfType does for a record) and put on (sub_8256FC80,
//     AddAndReplaceItemOfRecordID, which only takes items from the inventory).
// Received records are checked against our own game data first: the record
// must be in the game's record table and be a wearable inventory item (its def
// has AppearanceModifierComponent and InventoryItemComponent, and is not a
// RandomlyGeneratedItem table). Anything else is ignored, so a peer can only
// ever make a puppet wear real clothing, hair or tattoos.
//
// Layout (found with tools/image_dis.py):
//   AppearanceModifierManager = component 15: worn entries at +0x10/+0x14,
//     24 B each, word 0 = item. Item: +4 record id, +8 def.
//   Inventory = component 13: item list sentinel at +0x10, nodes {next, prev, item}.
//   Record table: global 0x83496BD0 -> manager -> table {+0x10 pairs, +0x14 size},
//     open addressing, {record, def} pairs.
#pragma once

#include "mp_enemies.h"

#include <rex/cvar.h>
#include <rex/logging.h>
#include <rex/ppc/context.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

REXCVAR_DEFINE_BOOL(mp_looks, true, "Multiplayer", "Puppets wear what each player's hero wears.");
REXCVAR_DEFINE_INT32(mp_looks_diag, 0, "Multiplayer",
                     "Log what puppets are made to wear (1) and what our hero sends (2).");

DECLARE_REX_FUNC(sub_822A97A8);  // def part by name (r3 def, r4 C string) -> part or 0
DECLARE_REX_FUNC(sub_8261A058);  // inventory: make an item of a record (r3 &out ref, r4 inventory, r5 record)
DECLARE_REX_FUNC(sub_8256FC80);  // appearance: wear the inventory's item of a record (r3 comp, r4 record)
DECLARE_REX_FUNC(sub_8256FE20);  // appearance: take off a worn item (r3 comp, r4 &worn entry)
DECLARE_REX_FUNC(sub_82741BD8);  // release an item ref (r3 item, r4 &ref)

namespace fable2::net::looks {
namespace pz = fable2::net::puppets;
using enemies::component;
using enemies::guest_call;
using enemies::load_u32;
using Clock = std::chrono::steady_clock;

constexpr uint32_t kInventoryType = 13;
constexpr uint32_t kAppearanceType = 15;
constexpr uint32_t kDefManager = 0x83496BD0;  // global: the game's record (def) manager
// The game's own strings, passed to the part lookup (checked once before use).
constexpr uint32_t kStrAppearancePart = 0x820A94F0;  // "AppearanceModifierComponent"
constexpr uint32_t kStrInventoryPart = 0x820A9080;   // "InventoryItemComponent"
constexpr uint32_t kStrRandomPart = 0x820C7390;      // "RandomlyGeneratedItem"
constexpr auto kLocalEvery = std::chrono::seconds(1);  // read our hero's worn items
constexpr auto kCheckEvery = std::chrono::seconds(2);  // compare each puppet with its player
constexpr int kTries = 5;                              // per list and body, then leave it

struct Slot {
  uint32_t peer = 0;   // player the list belongs to
  uint32_t thing = 0;  // body it was applied to
  uint32_t ver = 0;    // LOOKS version (0 = none yet: leave the body alone)
  std::vector<uint32_t> want;  // checked records, sorted
  int tries = 0;
  bool matched = false;
};

struct State {
  int strings = -1;  // -1 = not checked, 0 = this game build differs (off), 1 = ok
  uint32_t scratch = 0;
  Clock::time_point next_local{}, next_check{};
  std::array<Slot, kMaxPeers> slot;
};
inline State& S() {
  static State s;
  return s;
}

inline bool image_string_is(uint8_t* base, uint32_t a, const char* want) {
  return std::memcmp(base + a, want, std::strlen(want) + 1) == 0;
}

// Record id -> def, read straight from the record table (what sub_821E3E10
// does). 0 when the record is unknown.
inline uint32_t def_of(uint8_t* base, uint32_t rec) {
  if (!rec) return 0;
  const uint32_t mgr = load_u32(base, kDefManager);
  if (!pz::heap(base, mgr, 4)) return 0;
  const uint32_t tbl = load_u32(base, mgr);
  if (!pz::heap(base, tbl, 0x18)) return 0;
  const uint32_t pairs = load_u32(base, tbl + 0x10), cap = load_u32(base, tbl + 0x14);
  if (!cap || (cap & (cap - 1)) || cap > (1u << 20) || !pz::heap(base, pairs, cap * 8)) return 0;
  for (uint32_t i = rec & (cap - 1), n = 0; n < cap; ++n, i = (i + 1) & (cap - 1)) {
    const uint32_t key = load_u32(base, pairs + i * 8);
    if (key == rec) return load_u32(base, pairs + i * 8 + 4);
    if (key == 0) return 0;
  }
  return 0;
}

inline bool has_part(PPCContext& ctx, uint8_t* base, uint32_t def, uint32_t name) {
  return def && pz::heap(base, def, 16) && guest_call(ctx, base, sub_822A97A8, def, name) != 0;
}

// A record our game knows as a wearable inventory item.
inline bool wearable(PPCContext& ctx, uint8_t* base, uint32_t rec) {
  const uint32_t def = def_of(base, rec);
  return def && has_part(ctx, base, def, kStrAppearancePart) && has_part(ctx, base, def, kStrInventoryPart) &&
         !has_part(ctx, base, def, kStrRandomPart);
}

// Worn entries of a thing: (entry address, record).
inline std::vector<std::pair<uint32_t, uint32_t>> worn(uint8_t* base, uint32_t thing) {
  std::vector<std::pair<uint32_t, uint32_t>> out;
  const uint32_t amm = component(base, thing, kAppearanceType);
  if (!amm || !pz::heap(base, amm, 0x18)) return out;
  const uint32_t b = load_u32(base, amm + 0x10), e = load_u32(base, amm + 0x14);
  if (e <= b || (e - b) % 24 || e - b > 64 * 24 || !pz::heap(base, b, e - b)) return out;
  for (uint32_t a = b; a < e; a += 24) {
    const uint32_t item = load_u32(base, a);
    const uint32_t rec = pz::heap(base, item, 16) ? load_u32(base, item + 4) : 0;
    if (rec) out.push_back({a, rec});
  }
  return out;
}

inline std::vector<uint32_t> worn_records(uint8_t* base, uint32_t thing) {
  std::vector<uint32_t> v;
  for (const auto& [a, rec] : worn(base, thing)) v.push_back(rec);
  std::sort(v.begin(), v.end());
  v.erase(std::unique(v.begin(), v.end()), v.end());
  return v;
}

inline bool in_inventory(uint8_t* base, uint32_t inv, uint32_t rec) {
  if (!pz::heap(base, inv, 0x14)) return false;
  const uint32_t sentinel = load_u32(base, inv + 0x10);
  if (!pz::heap(base, sentinel, 12)) return false;
  uint32_t node = load_u32(base, sentinel);
  for (int n = 0; n < 512 && node != sentinel && pz::heap(base, node, 12); ++n) {
    const uint32_t item = load_u32(base, node + 8);
    if (pz::heap(base, item, 8) && load_u32(base, item + 4) == rec) return true;
    node = load_u32(base, node);
  }
  return false;
}

inline std::string list_str(const std::vector<uint32_t>& v) {
  std::string out;
  char buf[12];
  for (uint32_t r : v) {
    std::snprintf(buf, sizeof(buf), "%08X ", r);
    out += buf;
  }
  return out.empty() ? "nothing" : out;
}

// Makes `thing` wear exactly `want` (checked records). True when it matches.
inline bool apply(PPCContext& ctx, uint8_t* base, uint32_t thing, const std::vector<uint32_t>& want) {
  State& s = S();
  const uint32_t amm = component(base, thing, kAppearanceType);
  const uint32_t inv = component(base, thing, kInventoryType);
  if (!amm || !inv) return false;
  // Take off what it should not wear (one at a time: the list moves).
  for (int n = 0; n < 32; ++n) {
    uint32_t entry = 0;
    for (const auto& [a, rec] : worn(base, thing))
      if (!std::binary_search(want.begin(), want.end(), rec)) entry = a;
    if (!entry) break;
    guest_call(ctx, base, sub_8256FE20, amm, entry);
  }
  // Put on what it lacks, making the item first when the inventory has none.
  for (uint32_t rec : want) {
    const std::vector<uint32_t> now = worn_records(base, thing);
    if (std::binary_search(now.begin(), now.end(), rec)) continue;
    if (!in_inventory(base, inv, rec)) {
      for (uint32_t k = 0; k < 16; k += 4) pz::store_u32(base, s.scratch + k, 0);
      guest_call(ctx, base, sub_8261A058, s.scratch, inv, rec);
      if (const uint32_t item = load_u32(base, s.scratch)) guest_call(ctx, base, sub_82741BD8, item, s.scratch);
    }
    guest_call(ctx, base, sub_8256FC80, amm, rec);
  }
  return worn_records(base, thing) == want;
}

// Game thread, after enemies::tick.
inline void tick(PPCContext& ctx, uint8_t* base) {
  if (!REXCVAR_GET(mp_enable) || !REXCVAR_GET(mp_looks)) return;
  State& s = S();
  if (s.strings < 0) {
    s.strings = image_string_is(base, kStrAppearancePart, "AppearanceModifierComponent") &&
                image_string_is(base, kStrInventoryPart, "InventoryItemComponent") &&
                image_string_is(base, kStrRandomPart, "RandomlyGeneratedItem");
    if (!s.strings) REXLOG_WARN("[mplooks] this game build is not the one the looks code knows: looks are off");
  }
  if (!s.strings) return;
  if (!s.scratch) s.scratch = fable2::textappend::guest_alloc(ctx, base, 16);
  if (!s.scratch) return;
  const auto now = Clock::now();

  // What our hero wears (only wearables, so the list we send is clean).
  if (now >= s.next_local) {
    s.next_local = now + kLocalEvery;
    const uint32_t hero = enemies::player_hero(ctx, base);
    if (hero && pz::transform_of(base, hero)) {
      std::vector<uint32_t> mine;
      for (uint32_t rec : worn_records(base, hero))
        if (wearable(ctx, base, rec)) mine.push_back(rec);
      if (mine.size() > kMaxLooks) mine.resize(kMaxLooks);
      static std::vector<uint32_t> logged;
      if (REXCVAR_GET(mp_looks_diag) >= 2 && mine != logged) {
        logged = mine;
        REXLOG_INFO("[mplooks] our hero wears {}", list_str(mine));
      }
      Net::Get().set_local_looks(std::move(mine));
    }
  }

  // Each puppet: take its player's newest list (checked), then match it.
  const bool check = now >= s.next_check;
  if (check) s.next_check = now + kCheckEvery;
  for (int i = 0; i < kMaxPeers; ++i) {
    Slot& sl = s.slot[i];
    uint32_t thing = 0, peer = 0;
    {
      std::lock_guard<std::mutex> l(pz::S().m);
      thing = pz::S().pup[i].thing;
      peer = pz::S().pup[i].peer_id;
    }
    if (peer != sl.peer) {  // another player in this slot
      sl = Slot{};
      sl.peer = peer;
    }
    std::vector<uint32_t> list;
    if (Net::Get().peer_looks(i, sl.ver, list)) {
      std::vector<uint32_t> want;
      for (uint32_t rec : list)
        if (wearable(ctx, base, rec)) want.push_back(rec);
      if (REXCVAR_GET(mp_looks_diag) && want.size() != list.size())
        REXLOG_INFO("[mplooks] slot {}: ignored {} record(s) that are not wearable here", i, list.size() - want.size());
      sl.want.swap(want);
      sl.tries = 0;
      sl.matched = false;
    }
    if (!thing || !sl.ver || !pz::transform_of(base, thing)) continue;
    if (thing != sl.thing) {  // a new body
      sl.thing = thing;
      sl.tries = 0;
      sl.matched = false;
    }
    if (!check) continue;
    // Matched bodies are compared again now and then (the game can dress a
    // body itself, e.g. right after it is made).
    if (sl.matched && worn_records(base, thing) == sl.want) continue;
    if (sl.tries >= kTries) continue;
    ++sl.tries;
    const std::vector<uint32_t> before = worn_records(base, thing);
    sl.matched = apply(ctx, base, thing, sl.want);
    if (sl.matched) sl.tries = 0;
    if (REXCVAR_GET(mp_looks_diag))
      REXLOG_INFO("[mplooks] slot {} body 0x{:08X}: wore {}, player wears {}, now {}{}", i, thing, list_str(before),
                  list_str(sl.want), list_str(worn_records(base, thing)),
                  sl.matched ? "" : (sl.tries >= kTries ? " (giving up on this list)" : " (will try again)"));
  }
}

}  // namespace fable2::net::looks
