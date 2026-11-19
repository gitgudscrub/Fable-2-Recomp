// mp_combat.h - multiplayer combat.
//
// The game's native "modify health" function, sub_8268BD90:
//   r3 = health component (+4 owner CThing*, +20 health float), f1 = amount
//   (negative = damage), r5 = the entity causing it (0 = none).
// Step 1 (done): health changes on a puppet body are never applied to the body.
// Damage is sent (HIT) to the player it stands for, and that player's game
// applies it to their own hero (the hero's health component, type 0x24 in the
// thing's component list at +72/+76).
//
// mp_combat_diag = 1 logs every health change (owner, amount, attacker, health
// before/after) so we can confirm combat damage goes through here.
#pragma once

#include <rex/cvar.h>
#include <rex/logging.h>
#include <rex/ppc/context.h>

#include <atomic>
#include <cstdint>
#include <cstring>

#include "mp_puppets.h"

REXCVAR_DEFINE_INT32(mp_combat_diag, 0, "Multiplayer",
                     "Research: 1 = log every health change (owner, amount, attacker).");

DECLARE_REX_FUNC(sub_8268BD90);  // modify health (r3 health comp, f1 amount, r5 attacker)

namespace fable2::net::enemies {  // mp_enemies.h
inline bool is_copy(uint32_t thing);
inline bool applying_own();
inline uint16_t copy_id(uint32_t thing);
}

namespace fable2::net::combat {

inline float load_f32(uint8_t* base, uint32_t a) {
  uint32_t w;
  std::memcpy(&w, base + a, 4);
  w = __builtin_bswap32(w);
  float f;
  std::memcpy(&f, &w, 4);
  return f;
}
inline uint32_t load_u32(uint8_t* base, uint32_t a) {
  uint32_t w;
  std::memcpy(&w, base + a, 4);
  return __builtin_bswap32(w);
}

constexpr uint32_t kHealthVtable = 0x82003818;
constexpr uint32_t kHealthCompType = 0x24;

// Which puppet slot owns this thing (-1 = none); `peer` gets its player id.
inline int puppet_slot_of(uint32_t thing, uint32_t* peer = nullptr) {
  if (!thing) return -1;
  auto& s = puppets::S();
  std::lock_guard<std::mutex> l(s.m);
  for (size_t i = 0; i < s.pup.size(); ++i)
    if (s.pup[i].thing == thing) {
      if (peer) *peer = s.pup[i].peer_id;
      return int(i);
    }
  return -1;
}

// The thing's health component (0 = none / not found).
inline uint32_t health_comp_of(uint8_t* base, uint32_t thing) {
  if (!puppets::heap(base, thing, 80)) return 0;
  const uint32_t b = load_u32(base, thing + 72), e = load_u32(base, thing + 76);
  if (e < b || e - b > 512 * 8 || (e - b) % 8 || !puppets::heap(base, b, e - b)) return 0;
  for (uint32_t a = b; a < e; a += 8) {
    if (load_u32(base, a) != kHealthCompType) continue;
    const uint32_t c = load_u32(base, a + 4);
    if (puppets::heap(base, c, 32) && load_u32(base, c) == kHealthVtable && load_u32(base, c + 4) == thing)
      return c;
  }
  return 0;
}

// Game thread: apply the damage other players' games dealt to our hero.
inline void apply_incoming_hits(PPCContext& ctx, uint8_t* base, uint32_t hero) {
  int count = 0;
  const float dmg = Net::Get().take_hits(count);
  if (count == 0) return;
  const uint32_t comp = health_comp_of(base, hero);
  if (!comp) {
    REXLOG_WARN("[mpcombat] {} hit(s) for {:.1f} dropped: hero health not found", count, dmg);
    return;
  }
  const float before = load_f32(base, comp + 20);
  if (!(before > 0.0f)) return;  // already down
  const uint64_t r3 = ctx.r3.u64, r4 = ctx.r4.u64, r5 = ctx.r5.u64;
  const double f1 = ctx.f1.f64;
  ctx.r3.u64 = comp;
  ctx.r5.u64 = 0;
  ctx.f1.f64 = -double(dmg);
  __imp__sub_8268BD90(ctx, base);
  ctx.r3.u64 = r3;
  ctx.r4.u64 = r4;
  ctx.r5.u64 = r5;
  ctx.f1.f64 = f1;
  if (REXCVAR_GET(mp_combat_diag))
    REXLOG_INFO("[mpcombat] took {} hit(s) for {:.1f} from co-op: health {:.1f} -> {:.1f}", count, dmg,
                before, load_f32(base, comp + 20));
}

// Game thread, after puppets::tick.
inline void tick(PPCContext& ctx, uint8_t* base) {
  if (!REXCVAR_GET(mp_enable)) return;
  if (!Net::Get().has_hits()) return;
  const uint64_t r3 = ctx.r3.u64;
  sub_8222F1B0(ctx, base);
  const uint32_t hero = ctx.r3.u32;
  ctx.r3.u64 = r3;
  if (hero) apply_incoming_hits(ctx, base, hero);
}

}  // namespace fable2::net::combat

extern "C" void sub_8268BD90(PPCContext& ctx, uint8_t* base) {
  using namespace fable2::net::combat;
  const int diag = REXCVAR_GET(mp_combat_diag);
  const uint32_t comp = ctx.r3.u32;
  const bool ok = fable2::net::puppets::heap(base, comp, 24);
  const uint32_t owner = ok ? load_u32(base, comp + 4) : 0;
  const float before = ok ? load_f32(base, comp + 20) : 0.0f;
  const float amount = float(ctx.f1.f64);
  const uint32_t attacker = ctx.r5.u32;
  // Copies of the host's enemies (mp_enemies.h): what they do does no damage
  // (the host's enemy does the real hit). Damage to a copy goes to the host's
  // enemy (EHIT); here it never takes the copy below 1 health.
  if (attacker && fable2::net::enemies::is_copy(attacker)) {
    if (diag) REXLOG_INFO("[mpcombat] hit by enemy copy 0x{:08X} dropped ({:.2f})", attacker, amount);
    return;
  }
  if (ok && !fable2::net::enemies::applying_own()) {
    if (const uint16_t id = fable2::net::enemies::copy_id(owner)) {
      if (amount < 0.0f) fable2::net::Net::Get().queue_enemy_hit(id, -amount);
      if (diag) REXLOG_INFO("[mpcombat] hit on enemy copy {} (0x{:08X}) for {:.2f}: sent to the host", id, owner, amount);
      // The game still sees the hit (its reaction and the experience orbs it
      // gives), but the copy keeps at least 1 health: only the host's enemy
      // dying kills it. Its health is set to the host's again next tick.
      if (amount < 0.0f && before > 1.0f) {
        ctx.f1.f64 = std::max(double(amount), 1.0 - double(before));
        __imp__sub_8268BD90(ctx, base);
        ctx.f1.f64 = amount;
      }
      return;
    }
  }
  uint32_t peer = 0;
  if (ok && puppet_slot_of(owner, &peer) >= 0) {
    // A co-op player's body: never change its health here. Damage goes to
    // that player's game, which applies it to their real hero.
    if (amount < 0.0f && peer) fable2::net::Net::Get().queue_hit(peer, -amount);
    if (diag)
      REXLOG_INFO("[mpcombat] puppet 0x{:08X} hit for {:.2f} by 0x{:08X}: sent to {:08X}", owner, amount,
                  attacker, peer);
    return;
  }
  __imp__sub_8268BD90(ctx, base);
  if (diag && ok) {
    static std::atomic<int> logged{0};
    if (logged.fetch_add(1) < 400) {
      const float after = load_f32(base, comp + 20);
      REXLOG_INFO("[mpcombat] health comp 0x{:08X} owner 0x{:08X}{} amount {:.2f} attacker 0x{:08X}{} "
                  "health {:.2f} -> {:.2f}",
                  comp, owner, puppet_slot_of(owner) >= 0 ? " (puppet)" : "", amount, attacker,
                  puppet_slot_of(attacker) >= 0 ? " (puppet)" : "", before, after);
    }
  }
}
