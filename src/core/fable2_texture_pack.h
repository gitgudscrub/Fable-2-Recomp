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
inline void SeedCvars(const std::filesystem::path& user_root) {
  const config::Values& cfg = config::Get();
  auto seed = [](const char* name, const std::string& value) {
    if (rex::cvar::GetFlagSource(name) != rex::cvar::Source::kDefault) {
      return;
    }
    if (!rex::cvar::SetFlagByName(name, value)) {
      REXSYS_WARN("[texture-pack] cvar {} missing (SDK without texture packs?)", name);
    }
  };
  const std::u8string root = (user_root / "textures").u8string();
  seed("texture_pack_root", std::string(root.begin(), root.end()));
  seed("texture_replacement", cfg.texture_pack ? "true" : "false");
  seed("texture_dump", cfg.texture_dump ? "true" : "false");
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
#endif
}

}  // namespace fable2::texturepack
