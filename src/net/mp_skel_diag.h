// mp_skel_diag.h - multiplayer puppet research: which skeletons belong to the hero?
//
// The engine evaluates every skinned mesh's pose in sub_8222E300(skel, anim, time)
// and hands the finished bone palette (vector of 3x4 float matrices, MODEL space,
// at skel+624) to the packer sub_82207A90(skel, vector*), which writes half floats
// for the GPU. Puppets will copy a hero's palettes onto their own skeletons, so we
// need the link from a creature entity to its skeleton instances.
//
// `cvar mp_skel_diag 1` (console): for one frame, records every skeleton the packer
// sees; on the next game-thread tick, walks pointers from the hero entity
// (GetPlayerHero native, sub_8222F1B0) up to depth 4 and logs each path that
// reaches a recorded skeleton. Research only; off by default.
#pragma once

#include <rex/cvar.h>
#include <rex/logging.h>
#include <rex/ppc/context.h>

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

REXCVAR_DEFINE_INT32(mp_skel_diag, 0, "Multiplayer",
                     "Research: 1 = log which skeletons are packed in one frame and the pointer "
                     "paths from the hero entity to them. Resets to 0 when done.");

DECLARE_REX_FUNC(sub_82207A90);
DECLARE_REX_FUNC(sub_8222F1B0);

namespace fable2::net::skeldiag {
namespace ta = fable2::textappend;

struct State {
  std::mutex m;
  int phase = 0;  // 0 idle, 1 recording, 2 recorded (walk on game thread)
  std::unordered_map<uint32_t, uint32_t> skels;  // skel -> bone count
};
inline State& S() {
  static State s;
  return s;
}

inline void log(const char* fmt, ...) {
  char buf[1024];
  va_list ap;
  va_start(ap, fmt);
  std::vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  REXLOG_INFO("[mpskel] {}", buf);
}

// Packer hook (any thread): record the skeleton while a capture is armed.
inline void on_pack(uint8_t* base, uint32_t skel, uint32_t vec) {
  State& s = S();
  if (s.phase != 1) return;
  uint32_t n = 0;
  if (ta::rdable2(base, vec + 4, 8)) {
    const uint32_t b = ta::load_be(base, vec + 4), e = ta::load_be(base, vec + 8);
    if (e >= b) n = (e - b) / 48;
  }
  std::lock_guard<std::mutex> l(s.m);
  s.skels[skel] = n;
}

// Game thread, once per frame.
inline void tick(PPCContext& ctx, uint8_t* base) {
  State& s = S();
  const int want = REXCVAR_GET(mp_skel_diag);
  if (want <= 0) return;
  if (s.phase == 0) {
    std::lock_guard<std::mutex> l(s.m);
    s.skels.clear();
    s.phase = 1;
    return;  // record during the next frame
  }
  if (s.phase == 1) {
    s.phase = 2;  // one full frame recorded
    return;
  }
  // phase 2: report + pointer walk
  std::unordered_map<uint32_t, uint32_t> skels;
  {
    std::lock_guard<std::mutex> l(s.m);
    skels = s.skels;
  }
  s.phase = 0;
  REXCVAR_SET(mp_skel_diag, 0);

  const uint64_t save_r3 = ctx.r3.u64;
  sub_8222F1B0(ctx, base);  // GetPlayerHero native -> hero CThing*
  const uint32_t hero = ctx.r3.u32;
  ctx.r3.u64 = save_r3;
  log("frame: %zu skeletons packed; hero thing 0x%08X", skels.size(), hero);
  std::unordered_map<uint32_t, int> bones_hist;
  for (auto& kv : skels) bones_hist[kv.second]++;
  for (auto& kv : bones_hist) log("  %u bones: %d skeletons", kv.first, kv.second);
  if (!hero) return;

  // BFS from the hero over guest pointers (heap range), depth <= 4.
  struct Node {
    uint32_t addr;
    int parent;
    uint32_t off;
    int depth;
  };
  std::vector<Node> nodes;
  std::unordered_set<uint32_t> seen;
  std::deque<int> q;
  nodes.push_back({hero, -1, 0, 0});
  seen.insert(hero);
  q.push_back(0);
  int found = 0;
  constexpr uint32_t kWindow = 0x400;
  while (!q.empty() && nodes.size() < 60000 && found < 40) {
    const int ni = q.front();
    q.pop_front();
    const Node nd = nodes[ni];
    if (nd.depth >= 4) continue;
    if (!ta::rdable2(base, nd.addr, kWindow)) continue;
    for (uint32_t o = 0; o < kWindow; o += 4) {
      const uint32_t p = ta::load_be(base, nd.addr + o);
      if (p < 0x40000000u || p >= 0x80000000u || (p & 3)) continue;
      if (skels.count(p)) {
        std::string path = "+" + std::to_string(o);
        for (int k = ni; nodes[k].parent >= 0; k = nodes[k].parent)
          path = "+" + std::to_string(nodes[k].off) + " -> " + path;
        log("  path hero%s => skel 0x%08X (%u bones)", path.c_str(), p, skels[p]);
        ++found;
      }
      if (seen.insert(p).second) {
        nodes.push_back({p, ni, o, nd.depth + 1});
        q.push_back(static_cast<int>(nodes.size() - 1));
      }
    }
  }
  log("walk done: %zu nodes, %d paths", nodes.size(), found);

  // Reverse direction: from each skeleton, look for a pointer back to the hero
  // (owner back-pointers are common), depth <= 3.
  for (auto& kv : skels) {
    log("  skel 0x%08X: %u bones", kv.first, kv.second);
    if (kv.second < 20) continue;
    std::vector<Node> rn;
    std::unordered_set<uint32_t> rs;
    std::deque<int> rq;
    rn.push_back({kv.first, -1, 0, 0});
    rs.insert(kv.first);
    rq.push_back(0);
    int hits = 0;
    while (!rq.empty() && rn.size() < 40000 && hits < 6) {
      const int ni = rq.front();
      rq.pop_front();
      const Node nd = rn[ni];
      if (nd.depth >= 3) continue;
      if (!ta::rdable2(base, nd.addr, kWindow)) continue;
      for (uint32_t o = 0; o < kWindow; o += 4) {
        const uint32_t p = ta::load_be(base, nd.addr + o);
        if (p < 0x40000000u || p >= 0x80000000u || (p & 3)) continue;
        if (p == hero) {
          std::string path = "+" + std::to_string(o);
          for (int k = ni; rn[k].parent >= 0; k = rn[k].parent)
            path = "+" + std::to_string(rn[k].off) + " -> " + path;
          log("    back-path skel%s => hero", path.c_str());
          ++hits;
        }
        if (rs.insert(p).second) {
          rn.push_back({p, ni, o, nd.depth + 1});
          rq.push_back(static_cast<int>(rn.size() - 1));
        }
      }
    }
  }
}

}  // namespace fable2::net::skeldiag
