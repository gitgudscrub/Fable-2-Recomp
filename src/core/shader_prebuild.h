// shader_prebuild.h - fills the SDK's shader cache from config/shader_prebuild.txt
// before the cache is loaded, so known pipelines are built at boot instead of
// stuttering the first time an area is visited. See shader_prebuild.cpp.
#pragma once

#include <filesystem>

namespace rex::memory {
class Memory;
}

namespace fable2::shaderprebuild {

// Adds every shader and pipeline in `list_path` that the cache in
// `cache_root` doesn't have yet. Shader code comes from the game's own shader
// banks under `game_data_root` and from the loaded default.xex in `memory`.
// Never fails the launch: problems are logged and the cache is left usable.
void MergeIntoCache(const std::filesystem::path& list_path,
                    const std::filesystem::path& game_data_root,
                    const std::filesystem::path& cache_root, rex::memory::Memory* memory);

}  // namespace fable2::shaderprebuild
