// Hand-tuned override: ScriptApi_AddTableEntry_825B7858 (recompiler output:
// fable_2_recomp.153.cpp), the helper that binds one Lua native as
// {object r5, method r6}. Identical to the generated body except for the
// first block: when it binds GetLevelLoaded (method sub_821B57B8) it keeps
// the object, the game's level object (fable2_level_watch.h), which the
// dense-region draw distance (hotfunc sub_825470E0) reads the loading region from.
// This runs while the script API is set up, before any level loads.
#include "fable_2_pch.h"
#include "fable_2_funcs.153.h"
#include "../../fable2_level_watch.h"

extern "C" void ScriptApi_AddTableEntry_825B7858(PPCContext& __restrict ctx, uint8_t* base) {
	REX_FUNC_PROLOGUE();
	if (ctx.r6.u32 == fable2::levelwatch::kGetLevelLoadedMethod) {
		fable2::levelwatch::g_level_object.store(ctx.r5.u32, std::memory_order_relaxed);
	}
	uint32_t ea{};
	// mflr r12
	ctx.r12.u64 = ctx.lr;
	// bl 0x82ca2be4
	ctx.lr = 0x825B7860;
	__savegprlr_27(ctx, base);
	// stwu r1,-128(r1)
	ea = -128 + ctx.r1.u32;
	REX_STORE_U32(ea, ctx.r1.u32);
	ctx.r1.u32 = ea;
	// mr r30,r3
	ctx.r30.u64 = ctx.r3.u64;
	// mr r31,r4
	ctx.r31.u64 = ctx.r4.u64;
	// mr r29,r5
	ctx.r29.u64 = ctx.r5.u64;
	// mr r28,r6
	ctx.r28.u64 = ctx.r6.u64;
	// lwz r11,0(r30)
	ctx.r11.u64 = REX_LOAD_U32(ctx.r30.u32 + 0);
	// cmplwi cr6,r11,0
	ctx.cr6.compare<uint32_t>(ctx.r11.u32, 0, ctx.xer);
	// beq cr6,0x825b78ec
	if (ctx.cr6.eq) goto loc_825B78EC;
	// lwz r27,0(r11)
	ctx.r27.u64 = REX_LOAD_U32(ctx.r11.u32 + 0);
	// li r4,-10000
	ctx.r4.s64 = -10000;
	// lwz r5,4(r11)
	ctx.r5.u64 = REX_LOAD_U32(ctx.r11.u32 + 4);
	// mr r3,r27
	ctx.r3.u64 = ctx.r27.u64;
	// bl 0x82229208
	ctx.lr = 0x825B7894;
	ProcessAndAppendElement_82229208(ctx, base);
	// li r4,8
	ctx.r4.s64 = 8;
	// mr r3,r27
	ctx.r3.u64 = ctx.r27.u64;
	// bl 0x822279a0
	ctx.lr = 0x825B78A0;
	ProcessAndDispatchAndResolve_822279A0(ctx, base);
	// mr r11,r3
	ctx.r11.u64 = ctx.r3.u64;
	// lis r10,-32107
	ctx.r10.s64 = -2104164352;
	// li r5,1
	ctx.r5.s64 = 1;
	// addi r4,r10,25424
	ctx.r4.s64 = ctx.r10.s64 + 25424;
	// mr r3,r27
	ctx.r3.u64 = ctx.r27.u64;
	// stw r29,0(r11)
	REX_STORE_U32(ctx.r11.u32 + 0, ctx.r29.u32);
	// stw r28,4(r11)
	REX_STORE_U32(ctx.r11.u32 + 4, ctx.r28.u32);
	// bl 0x8219ab28
	ctx.lr = 0x825B78C0;
	ProcessAndResolveTypedField_8219AB28(ctx, base);
	// mr r5,r31
	ctx.r5.u64 = ctx.r31.u64;
	// mr r4,r27
	ctx.r4.u64 = ctx.r27.u64;
	// mr r3,r30
	ctx.r3.u64 = ctx.r30.u64;
	// bl 0x824ef160
	ctx.lr = 0x825B78D0;
	ProcessAndCopyReferenceAndHash_824EF160(ctx, base);
	// mr r5,r31
	ctx.r5.u64 = ctx.r31.u64;
	// li r4,-2
	ctx.r4.s64 = -2;
	// mr r3,r27
	ctx.r3.u64 = ctx.r27.u64;
	// bl 0x82a1ec08
	ctx.lr = 0x825B78E0;
	ProcessAndHashString_82A1EC08(ctx, base);
	// lwz r11,8(r27)
	ctx.r11.u64 = REX_LOAD_U32(ctx.r27.u32 + 8);
	// addi r9,r11,-8
	ctx.r9.s64 = ctx.r11.s64 + -8;
	// stw r9,8(r27)
	REX_STORE_U32(ctx.r27.u32 + 8, ctx.r9.u32);
loc_825B78EC:
	// addi r1,r1,128
	ctx.r1.s64 = ctx.r1.s64 + 128;
	// b 0x82ca2c34
	__restgprlr_27(ctx, base);
	return;
}
