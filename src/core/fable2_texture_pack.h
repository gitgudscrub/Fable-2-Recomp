// fable_2 - Texture pack ("Classic" / "Modern" graphics).
//
// The SDK's texture cache shows replacement textures from
// <user root>/textures/replace (see the SDK's
// rex/graphics/pipeline/texture/replacement.h). This file seeds its cvars from
// fable2_config.toml [graphics] and switches them live with a hotkey.
//   texture_pack_root   <user root>/textures
//   texture_replacement [graphics] texture_pack, flipped by the toggle key
//   texture_dump        [graphics] texture_dump

#pragma once

#include <filesystem>
#include <string>

#include <rex/cvar.h>
#include <rex/filesystem.h>
#include <rex/logging.h>
#include <rex/ui/keybinds.h>
#include <rex/ui/virtual_key.h>

#include "fable2_config.h"

#ifdef _WIN32
#include <windows.h>
#endif

namespace fable2::texturepack {

// Call once after the GPU plugin is loaded (its cvars must exist) and before
// the graphics system starts. Command-line values win over the config.
// anisotropic_override value for a texture_filtering level (-1 = no override).
inline std::string AnisoCvarValue(bool modern) {
  if (!modern) return "-1";
  switch (config::Get().texture_filtering) {
    case 2: return "2";
    case 4: return "3";
    case 8: return "4";
    case 16: return "5";
    default: return "-1";
  }
}

inline void SeedCvars(const std::filesystem::path& user_root) {
  const config::Values& cfg = config::Get();
  auto seed = [](const char* name, const std::string& value) {
    if (rex::cvar::GetFlagSource(name) != rex::cvar::Source::kDefault) {
      REXSYS_INFO("[texture-pack] cvar {} already set elsewhere, not seeded", name);
      return;
    }
    if (rex::cvar::SetFlagByName(name, value)) {
      REXSYS_INFO("[texture-pack] seeded cvar {} = '{}'", name, value);
    } else {
      REXSYS_WARN("[texture-pack] cvar {} missing (SDK without texture packs?)", name);
    }
  };
  const std::u8string root = (user_root / "textures").u8string();
  seed("texture_pack_root", std::string(root.begin(), root.end()));
  seed("texture_replacement", cfg.texture_pack ? "true" : "false");
  seed("texture_dump", cfg.texture_dump ? "true" : "false");
  seed("anisotropic_override", AnisoCvarValue(cfg.texture_pack));
  seed("post_grade", cfg.texture_pack && cfg.post_processing ? "true" : "false");
  // AO, AA and bloom only run with the grade, so F8 switches them through
  // post_grade.
  seed("post_ao", cfg.ambient_occlusion ? "true" : "false");
  seed("post_sun_shadows", cfg.sun_shadows ? "true" : "false");
  seed("post_sun_map", cfg.sun_shadow_map ? "true" : "false");
  seed("post_aa", cfg.anti_aliasing ? "true" : "false");
  seed("post_bloom", cfg.bloom ? "true" : "false");
  seed("sparrow_renderer", cfg.sparrow_renderer ? "true" : "false");
  // Project Sparrow's sharper picture: SMAA instead of FXAA, contrast-adaptive
  // sharpening instead of the plain 3x3, and textures a half mip sharper.
  if (cfg.sparrow_renderer) {
    seed("post_smaa", "true");
    seed("post_grade_sharpen", "-0.5");
    if (cfg.texture_pack) seed("texture_lod_bias", "-0.5");
  }
  // Ultra (Sparrow Edition): heavier versions of the settings above.
  if (cfg.ultra) {
    seed("post_light_shafts", "true");
    seed("post_sun_map_interval", "1");
    seed("post_sun_map_size", "4096");
    seed("post_sun_map_radius", "180");
    seed("post_ao_strength", "0.75");
    seed("post_grade_dehaze_far", "0.3");
    // Deeper shadows: more S-curve and a lower black floor; softer shafts
    // that keep dark surfaces dark (post_light_shafts_shadows).
    seed("post_grade_contrast", "0.25");
    seed("post_grade_dehaze", "0.035");
    seed("post_light_shafts_strength", "1.0");
  }
  // Startup only: the SDK swaps shaders in when it translates them. Next to
  // the exe, not the working directory: the launcher starts the game in the
  // player's data folder.
  const std::u8string shaders =
      (rex::filesystem::GetExecutableFolder() / "shaders" /
       (cfg.sparrow_renderer ? "sparrow_replace" : "replace"))
          .u8string();
  seed("shader_replace_dir",
       cfg.shader_rewrites ? std::string(shaders.begin(), shaders.end()) : std::string());
  // Sparrow character materials (leather / metal / gloss by texture hash),
  // read by the SDK and passed to the character shaders in the draw flags.
  const std::u8string materials = (rex::filesystem::GetExecutableFolder() / "shaders" /
                                   "sparrow_replace" / "character_materials.txt")
                                      .u8string();
  seed("character_materials", cfg.sparrow_renderer && cfg.shader_rewrites
                                  ? std::string(materials.begin(), materials.end())
                                  : std::string());
}

// Per-frame poll of the toggle key (game window focused). Flips the SDK cvar;
// the texture cache picks the change up on its next draw.
inline void PollToggle(bool focused) {
#ifdef _WIN32
  static const uint16_t vk = static_cast<uint16_t>(
      rex::ui::ParseVirtualKey(config::Get().texture_pack_toggle_key));
  static bool was_down = false;
  if (vk == 0) {
    return;
  }
  const bool down = focused && (GetAsyncKeyState(vk) & 0x8000) != 0;
  const bool pressed = down && !was_down;
  was_down = down;
  if (!pressed) {
    return;
  }
  const bool modern = rex::cvar::GetFlagByName("texture_replacement") != "true";
  if (rex::cvar::SetFlagByName("texture_replacement", modern ? "true" : "false")) {
    REXSYS_INFO("[texture-pack] graphics: {}", modern ? "Modern (texture pack)" : "Classic");
  }
  if (rex::cvar::GetFlagSource("anisotropic_override") != rex::cvar::Source::kCommandLine) {
    rex::cvar::SetFlagByName("anisotropic_override", AnisoCvarValue(modern));
  }
  if (rex::cvar::GetFlagSource("post_grade") != rex::cvar::Source::kCommandLine) {
    rex::cvar::SetFlagByName("post_grade", modern && config::Get().post_processing ? "true" : "false");
  }
#endif
}

}  // namespace fable2::texturepack
