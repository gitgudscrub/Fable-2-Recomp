// mp_combat.h - multiplayer combat (research stage).
//
// The game's native "modify health" function, sub_8268BD90:
//   r3 = health component (+4 owner CThing*, +20 health float), f1 = amount
//   (negative = damage), r5 = the entity causing it (0 = none).
// Plan: on the host, damage to a puppet body is not applied to the body but
// sent to the player it stands for; that player's game applies it to their hero.
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

// Which puppet slot owns this thing (-1 = none).
inline int puppet_slot_of(uint32_t thing) {
  if (!thing) return -1;
  auto& s = puppets::S();
  std::lock_guard<std::mutex> l(s.m);
  for (size_t i = 0; i < s.pup.size(); ++i)
    if (s.pup[i].thing == thing) return int(i);
  return -1;
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
