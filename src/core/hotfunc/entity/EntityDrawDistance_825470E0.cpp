// Hand-tuned override: sub_825470E0 (recompiler output: fable_2_recomp.253.cpp),
// which sets an entity's draw distances from its definition as the entity is
// created: field 40 = the definition's distance x the matching multiplier
// global (0x83319368 static, +4 animated, +8 villager, +12 creature; the
// [graphics] draw_distance patch in fable2_patches.cpp).
//
// Fable 2 changes: smart_draw_distance (on by default) scales the multiplier
// down for small objects (1x at a base distance of 30 or less, full at 90+),
// which keeps busy towns fast with draw_distance 3.0. Optionally, for static
// and animated entities created while a region listed in [graphics]
// dense_regions is loading or playing, the multiplier is dense_draw_distance
// instead (off by default). The region comes from the game's level object
// (fable2_level_watch.h), which switches to the new region as soon as a load
// starts, before the region's entities are created. Everything else is the
// generated body unchanged.
#include "fable_2_pch.h"
#include "fable_2_funcs.253.h"

#include <mutex>

#include <rex/logging.h>

#include "../../fable2_config.h"
#include "../../fable2_level_watch.h"

namespace {

// True while a region on the dense list is loaded; cached per region object
// and name block (both change on every load).
bool InDenseRegion(uint8_t* base) {
  namespace lw = fable2::levelwatch;
  static const std::vector<std::string> dense =
      lw::ParseRegionList(fable2::config::Get().dense_regions);
  static std::mutex mutex;
  static uint32_t cached_region = 0, cached_rep = 0;
  static bool cached_dense = false;
  const uint32_t obj = lw::g_level_object.load(std::memory_order_relaxed);
  if (!obj || dense.empty()) return false;
  const uint32_t region = REX_LOAD_U32(obj + 0x24);
  if (region < 0x40000000 || region >= 0xA0000000) return false;
  const uint32_t data = REX_LOAD_U32(region + 4);
  if (data < 0x40000000 || data >= 0xA0000000) return false;
  const uint32_t rep = REX_LOAD_U32(data + 0xAC);
  std::lock_guard<std::mutex> lock(mutex);
  if (region == cached_region && rep == cached_rep) return cached_dense;
  cached_region = region;
  cached_rep = rep;
  cached_dense = false;
  const uint32_t chars = (rep >= 0x40000000 && rep < 0xA0000000) ? REX_LOAD_U32(rep) : 0;
  if (chars < 0x40000000 || chars >= 0xA0000000) return false;
  std::string name;
  for (uint32_t i = 0; i < 64; ++i) {
    const uint8_t c = REX_LOAD_U8(chars + i);
    if (!c) break;
    name += char(c);
  }
  name = lw::Lower(name);
  cached_dense = std::find(dense.begin(), dense.end(), name) != dense.end();
  REXSYS_INFO("[draw-distance] region '{}': {}", name,
              cached_dense ? "dense draw distance" : "normal draw distance");
  return cached_dense;
}

// f31 holds the multiplier the generated code just loaded.
void fable2_dense_draw_distance(PPCContext& ctx, uint8_t* base) {
  const float dense = fable2::config::Get().dense_draw_distance;
  if (dense <= 0.0f || !InDenseRegion(base)) return;
  ctx.f31.f64 = double(std::clamp(dense, 0.5f, 10.0f));
}

// smart_draw_distance: f1 is the definition's base draw distance, f31 the
// multiplier about to be applied. Objects with a base distance of 30 or less
// keep 1x, 90 or more get the full multiplier, linear in between.
void fable2_smart_draw_distance(PPCContext& ctx) {
  if (!fable2::config::Get().smart_draw_distance) return;
  const double multiplier = ctx.f31.f64;
  if (!(multiplier > 1.0)) return;
  constexpr double kSmall = 30.0, kFull = 90.0;
  const double t = std::clamp((ctx.f1.f64 - kSmall) / (kFull - kSmall), 0.0, 1.0);
  ctx.f31.f64 = 1.0 + (multiplier - 1.0) * t;
}

}  // namespace

extern "C" void sub_825470E0(PPCContext& __restrict ctx, uint8_t* base) {
	REX_FUNC_PROLOGUE();
	PPCRegister temp{};
	uint32_t ea{};
	// mflr r12
	ctx.r12.u64 = ctx.lr;
	// stw r12,-8(r1)
	REX_STORE_U32(ctx.r1.u32 + -8, ctx.r12.u32);
	// std r30,-24(r1)
	REX_STORE_U64(ctx.r1.u32 + -24, ctx.r30.u64);
	// std r31,-16(r1)
	REX_STORE_U64(ctx.r1.u32 + -16, ctx.r31.u64);
	// stfd f31,-32(r1)
	ctx.fpscr.disableFlushMode();
	REX_STORE_U64(ctx.r1.u32 + -32, ctx.f31.u64);
	// stwu r1,-112(r1)
	ea = -112 + ctx.r1.u32;
	REX_STORE_U32(ea, ctx.r1.u32);
	ctx.r1.u32 = ea;
	// mr r31,r3
	ctx.r31.u64 = ctx.r3.u64;
	// mr r30,r4
	ctx.r30.u64 = ctx.r4.u64;
	// lwz r11,4(r31)
	ctx.r11.u64 = REX_LOAD_U32(ctx.r31.u32 + 4);
	// lwz r11,36(r11)
	ctx.r11.u64 = REX_LOAD_U32(ctx.r11.u32 + 36);
	// rlwinm r10,r11,26,31,31
	ctx.r10.u64 = __builtin_rotateleft64(ctx.r11.u32 | (ctx.r11.u64 << 32), 26) & 0x1;
	// cmplwi cr6,r10,0
	ctx.cr6.compare<uint32_t>(ctx.r10.u32, 0, ctx.xer);
	// beq cr6,0x82547150
	if (ctx.cr6.eq) goto loc_82547150;
	// rlwinm r10,r11,12,31,31
	ctx.r10.u64 = __builtin_rotateleft64(ctx.r11.u32 | (ctx.r11.u64 << 32), 12) & 0x1;
	// cmplwi cr6,r10,0
	ctx.cr6.compare<uint32_t>(ctx.r10.u32, 0, ctx.xer);
	// beq cr6,0x82547144
	if (ctx.cr6.eq) goto loc_82547144;
	// rlwinm r11,r11,6,31,31
	ctx.r11.u64 = __builtin_rotateleft64(ctx.r11.u32 | (ctx.r11.u64 << 32), 6) & 0x1;
	// cmplwi cr6,r11,0
	ctx.cr6.compare<uint32_t>(ctx.r11.u32, 0, ctx.xer);
	// beq cr6,0x82547138
	if (ctx.cr6.eq) goto loc_82547138;
	// lis r11,-31950
	ctx.r11.s64 = -2093875200;
	// lfs f31,-27792(r11)
	temp.u32 = REX_LOAD_U32(ctx.r11.u32 + -27792);
	ctx.f31.f64 = double(temp.f32);
	// b 0x82547158
	goto loc_82547158;
loc_82547138:
	// lis r11,-31950
	ctx.r11.s64 = -2093875200;
	// lfs f31,-27788(r11)
	ctx.fpscr.disableFlushMode();
	temp.u32 = REX_LOAD_U32(ctx.r11.u32 + -27788);
	ctx.f31.f64 = double(temp.f32);
	// b 0x82547158
	goto loc_82547158;
loc_82547144:
	// lis r11,-31950
	ctx.r11.s64 = -2093875200;
	// lfs f31,-27796(r11)
	ctx.fpscr.disableFlushMode();
	temp.u32 = REX_LOAD_U32(ctx.r11.u32 + -27796);
	ctx.f31.f64 = double(temp.f32);
	fable2_dense_draw_distance(ctx, base);  // Fable 2: dense use dense_draw_distance
	// b 0x82547158
	goto loc_82547158;
loc_82547150:
	// lis r11,-31950
	ctx.r11.s64 = -2093875200;
	// lfs f31,-27800(r11)
	ctx.fpscr.disableFlushMode();
	temp.u32 = REX_LOAD_U32(ctx.r11.u32 + -27800);
	ctx.f31.f64 = double(temp.f32);
	fable2_dense_draw_distance(ctx, base);  // Fable 2: dense use dense_draw_distance
loc_82547158:
	// cmplwi cr6,r30,0
	ctx.cr6.compare<uint32_t>(ctx.r30.u32, 0, ctx.xer);
	// beq cr6,0x82547204
	if (ctx.cr6.eq) goto loc_82547204;
	// lis r11,-32244
	ctx.r11.s64 = -2113142784;
	// mr r3,r30
	ctx.r3.u64 = ctx.r30.u64;
	// addi r4,r11,-8180
	ctx.r4.s64 = ctx.r11.s64 + -8180;
	// bl 0x82196e10
	ctx.lr = 0x82547170;
	ProcessAndProcessAndProcess2670_82196E10(ctx, base);
	fable2_smart_draw_distance(ctx);  // Fable 2: smaller objects get less of the multiplier
	// fmuls f0,f1,f31
	ctx.fpscr.disableFlushMode();
	ctx.f0.f64 = double(float(ctx.f1.f64 * ctx.f31.f64));
	// stfs f0,40(r31)
	temp.f32 = float(ctx.f0.f64);
	REX_STORE_U32(ctx.r31.u32 + 40, temp.u32);
	// lis r10,-32244
	ctx.r10.s64 = -2113142784;
	// mr r3,r30
	ctx.r3.u64 = ctx.r30.u64;
	// addi r4,r10,-8164
	ctx.r4.s64 = ctx.r10.s64 + -8164;
	// bl 0x82196e10
	ctx.lr = 0x82547188;
	ProcessAndProcessAndProcess2670_82196E10(ctx, base);
	// stfs f1,36(r31)
	ctx.fpscr.disableFlushMode();
	temp.f32 = float(ctx.f1.f64);
	REX_STORE_U32(ctx.r31.u32 + 36, temp.u32);
	// lis r9,-32244
	ctx.r9.s64 = -2113142784;
	// mr r3,r30
	ctx.r3.u64 = ctx.r30.u64;
	// addi r4,r9,-8136
	ctx.r4.s64 = ctx.r9.s64 + -8136;
	// bl 0x82196e10
	ctx.lr = 0x8254719C;
	ProcessAndProcessAndProcess2670_82196E10(ctx, base);
	// stfs f1,44(r31)
	ctx.fpscr.disableFlushMode();
	temp.f32 = float(ctx.f1.f64);
	REX_STORE_U32(ctx.r31.u32 + 44, temp.u32);
	// lis r8,-32244
	ctx.r8.s64 = -2113142784;
	// mr r3,r30
	ctx.r3.u64 = ctx.r30.u64;
	// addi r4,r8,-8116
	ctx.r4.s64 = ctx.r8.s64 + -8116;
	// bl 0x82196e10
	ctx.lr = 0x825471B0;
	ProcessAndProcessAndProcess2670_82196E10(ctx, base);
	// stfs f1,48(r31)
	ctx.fpscr.disableFlushMode();
	temp.f32 = float(ctx.f1.f64);
	REX_STORE_U32(ctx.r31.u32 + 48, temp.u32);
	// lis r7,-32244
	ctx.r7.s64 = -2113142784;
	// mr r3,r30
	ctx.r3.u64 = ctx.r30.u64;
	// addi r4,r7,-8096
	ctx.r4.s64 = ctx.r7.s64 + -8096;
	// bl 0x82196e10
	ctx.lr = 0x825471C4;
	ProcessAndProcessAndProcess2670_82196E10(ctx, base);
	// stfs f1,52(r31)
	ctx.fpscr.disableFlushMode();
	temp.f32 = float(ctx.f1.f64);
	REX_STORE_U32(ctx.r31.u32 + 52, temp.u32);
	// lis r6,-32244
	ctx.r6.s64 = -2113142784;
	// mr r3,r30
	ctx.r3.u64 = ctx.r30.u64;
	// addi r4,r6,-8084
	ctx.r4.s64 = ctx.r6.s64 + -8084;
	// bl 0x82196e10
	ctx.lr = 0x825471D8;
	ProcessAndProcessAndProcess2670_82196E10(ctx, base);
	// stfs f1,56(r31)
	ctx.fpscr.disableFlushMode();
	temp.f32 = float(ctx.f1.f64);
	REX_STORE_U32(ctx.r31.u32 + 56, temp.u32);
	// lis r5,-32244
	ctx.r5.s64 = -2113142784;
	// mr r3,r30
	ctx.r3.u64 = ctx.r30.u64;
	// addi r4,r5,-8068
	ctx.r4.s64 = ctx.r5.s64 + -8068;
	// bl 0x82196e10
	ctx.lr = 0x825471EC;
	ProcessAndProcessAndProcess2670_82196E10(ctx, base);
	// stfs f1,60(r31)
	ctx.fpscr.disableFlushMode();
	temp.f32 = float(ctx.f1.f64);
	REX_STORE_U32(ctx.r31.u32 + 60, temp.u32);
	// lis r4,-32244
	ctx.r4.s64 = -2113142784;
	// mr r3,r30
	ctx.r3.u64 = ctx.r30.u64;
	// addi r4,r4,-8408
	ctx.r4.s64 = ctx.r4.s64 + -8408;
	// bl 0x82196e10
	ctx.lr = 0x82547200;
	ProcessAndProcessAndProcess2670_82196E10(ctx, base);
	// stfs f1,72(r31)
	ctx.fpscr.disableFlushMode();
	temp.f32 = float(ctx.f1.f64);
	REX_STORE_U32(ctx.r31.u32 + 72, temp.u32);
loc_82547204:
	// lis r11,-32246
	ctx.r11.s64 = -2113273856;
	// lfs f13,40(r31)
	ctx.fpscr.disableFlushMode();
	temp.u32 = REX_LOAD_U32(ctx.r31.u32 + 40);
	ctx.f13.f64 = double(temp.f32);
	// lfs f0,-27468(r11)
	temp.u32 = REX_LOAD_U32(ctx.r11.u32 + -27468);
	ctx.f0.f64 = double(temp.f32);
	// fcmpu cr6,f13,f0
	ctx.cr6.compare(ctx.f13.f64, ctx.f0.f64);
	// bgt cr6,0x8254721c
	if (ctx.cr6.gt) goto loc_8254721C;
	// stfs f0,40(r31)
	temp.f32 = float(ctx.f0.f64);
	REX_STORE_U32(ctx.r31.u32 + 40, temp.u32);
loc_8254721C:
	// lfs f0,40(r31)
	ctx.fpscr.disableFlushMode();
	temp.u32 = REX_LOAD_U32(ctx.r31.u32 + 40);
	ctx.f0.f64 = double(temp.f32);
	// lfs f13,48(r31)
	temp.u32 = REX_LOAD_U32(ctx.r31.u32 + 48);
	ctx.f13.f64 = double(temp.f32);
	// fcmpu cr6,f0,f13
	ctx.cr6.compare(ctx.f0.f64, ctx.f13.f64);
	// bge cr6,0x82547230
	if (!ctx.cr6.lt) goto loc_82547230;
	// stfs f0,48(r31)
	temp.f32 = float(ctx.f0.f64);
	REX_STORE_U32(ctx.r31.u32 + 48, temp.u32);
loc_82547230:
	// addi r1,r1,112
	ctx.r1.s64 = ctx.r1.s64 + 112;
	// lwz r12,-8(r1)
	ctx.r12.u64 = REX_LOAD_U32(ctx.r1.u32 + -8);
	// mtlr r12
	ctx.lr = ctx.r12.u64;
	// lfd f31,-32(r1)
	ctx.fpscr.disableFlushMode();
	ctx.f31.u64 = REX_LOAD_U64(ctx.r1.u32 + -32);
	// ld r30,-24(r1)
	ctx.r30.u64 = REX_LOAD_U64(ctx.r1.u32 + -24);
	// ld r31,-16(r1)
	ctx.r31.u64 = REX_LOAD_U64(ctx.r1.u32 + -16);
	// blr 
	return;
}
