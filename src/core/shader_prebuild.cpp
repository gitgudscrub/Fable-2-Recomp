// shader_prebuild.cpp - fills the SDK's shader cache from the pre-build list.
//
// The first visit to an area used to hitch while the driver built each new
// D3D12 pipeline. The SDK already rebuilds every pipeline in its cache at boot
// (on all cores, before the title screen), so a fresh install only needs the
// cache filled in. config/shader_prebuild.txt (made by
// tools/shaders/shader_prebuild.py from a warm cache) lists the shaders and
// pipelines without any of the game's shader code: each shader is a reference
// into the game's own shader banks (data/Shaders/*.sbk) or into default.xex,
// plus the small vertex-layout patches the Xbox D3D runtime applies to vertex
// shaders. Here, before the SDK opens the cache, every listed shader and
// pipeline the cache lacks is rebuilt from the player's game data and
// appended. Each rebuilt shader must hash to the value the SDK expects
// (XXH3-64 of the ucode, the SDK's own check), so a bad match is never added.

#include "shader_prebuild.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <system_error>
#include <unordered_set>
#include <vector>

#define XXH_INLINE_ALL
#include <xxhash.h>
#include <zlib-ng.h>

#include <rex/logging/macros.h>
#include <rex/system/xmemory.h>

namespace fable2::shaderprebuild {
namespace {

constexpr int kFormat = 1;
constexpr const char* kTitle = "4D5307F1";
constexpr size_t kXshHeaderSize = 8;
constexpr size_t kXshRecordHeaderSize = 12;
constexpr size_t kXpsoHeaderSize = 12;
constexpr size_t kXpsoRecordSize = 72;

using Bytes = std::vector<uint8_t>;

struct ListShader {
  uint64_t hash = 0;
  uint32_t packed = 0;
  bool from_xex = false;
  std::string bank;
  uint32_t entry = 0;
  uint32_t offset = 0;  // bank entry offset, or guest address for xex
  std::vector<std::pair<uint32_t, uint32_t>> patches;  // dword index, xor
};

struct List {
  Bytes xsh_header, xpso_header;
  std::vector<ListShader> shaders;
  std::vector<Bytes> pipelines;
};

uint32_t ReadBE32(const uint8_t* p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
}

bool ParseHex(const std::string& hex, Bytes& out) {
  if (hex.size() % 2) return false;
  out.resize(hex.size() / 2);
  for (size_t i = 0; i < out.size(); ++i) {
    char* end = nullptr;
    std::string pair = hex.substr(i * 2, 2);
    out[i] = uint8_t(std::strtoul(pair.c_str(), &end, 16));
    if (end != pair.c_str() + 2) return false;
  }
  return true;
}

bool ReadList(const std::filesystem::path& path, List& list) {
  std::ifstream file(path);
  if (!file) return false;
  std::string line;
  bool format_ok = false;
  while (std::getline(file, line)) {
    std::istringstream in(line);
    std::string kind;
    if (!(in >> kind)) continue;
    if (kind == "fable2-shader-prebuild") {
      int format = 0;
      in >> format;
      if (format != kFormat) {
        REXSYS_WARN("[shader-prebuild] unsupported list format {}", format);
        return false;
      }
      format_ok = true;
    } else if (kind == "title") {
      std::string title;
      in >> title;
      if (title != kTitle) return false;
    } else if (kind == "xsh-header" || kind == "xpso-header") {
      std::string hex;
      in >> hex;
      if (!ParseHex(hex, kind == "xsh-header" ? list.xsh_header : list.xpso_header)) return false;
    } else if (kind == "pipeline") {
      std::string hex;
      Bytes record;
      in >> hex;
      if (!ParseHex(hex, record) || record.size() != kXpsoRecordSize) return false;
      list.pipelines.push_back(std::move(record));
    } else if (kind == "shader") {
      ListShader s;
      std::string hash, packed, source;
      in >> hash >> packed >> source;
      s.hash = std::stoull(hash, nullptr, 16);
      s.packed = uint32_t(std::stoul(packed, nullptr, 16));
      if (source == "bank") {
        in >> s.bank >> s.entry >> s.offset;
      } else if (source == "xex") {
        std::string address;
        in >> address;
        s.from_xex = true;
        s.offset = uint32_t(std::stoul(address, nullptr, 16));
      } else {
        return false;
      }
      std::string patch;
      while (in >> patch) {
        size_t colon = patch.find(':');
        if (colon == std::string::npos) return false;
        s.patches.emplace_back(uint32_t(std::stoul(patch.substr(0, colon))),
                               uint32_t(std::stoul(patch.substr(colon + 1), nullptr, 16)));
      }
      list.shaders.push_back(std::move(s));
    }
  }
  return format_ok && list.xsh_header.size() == kXshHeaderSize &&
         list.xpso_header.size() == kXpsoHeaderSize;
}

bool ReadFile(const std::filesystem::path& path, Bytes& out) {
  std::ifstream file(path, std::ios::binary);
  if (!file) return false;
  out.assign(std::istreambuf_iterator<char>(file), {});
  return true;
}

// Each bank entry is zlib that ends with a sync flush instead of a final
// block: drop the 2-byte zlib header, add an empty final block, inflate raw.
bool InflateEntry(const uint8_t* data, size_t size, Bytes& out) {
  if (size < 2) return false;
  Bytes in(data + 2, data + size);
  in.push_back(0x03);
  in.push_back(0x00);
  zng_stream z{};
  if (zng_inflateInit2(&z, -15) != Z_OK) return false;
  z.next_in = in.data();
  z.avail_in = uint32_t(in.size());
  uint8_t buffer[1 << 16];
  int result;
  do {
    z.next_out = buffer;
    z.avail_out = sizeof(buffer);
    result = zng_inflate(&z, Z_NO_FLUSH);
    if (result != Z_OK && result != Z_STREAM_END) break;
    out.insert(out.end(), buffer, buffer + (sizeof(buffer) - z.avail_out));
  } while (result != Z_STREAM_END);
  zng_inflateEnd(&z);
  return result == Z_STREAM_END;
}

// A "ShaderBankFile": header and metadata, a table of big-endian entry
// offsets whose last value is the data length, then per entry a big-endian
// size and that many bytes of zlib.
bool ReadBank(const std::filesystem::path& path, std::vector<Bytes>& entries) {
  Bytes d;
  if (!ReadFile(path, d) || d.size() < 32 || std::memcmp(d.data(), "ShaderBankFile", 14) != 0) {
    return false;
  }
  size_t start = 0;
  for (size_t i = 16; i + 6 <= d.size(); ++i) {
    if (ReadBE32(&d[i - 4]) == d.size() - i && d[i + 4] == 0x78) {
      start = i;
      break;
    }
  }
  if (!start) return false;
  for (size_t pos = start; pos + 4 <= d.size();) {
    uint32_t size = ReadBE32(&d[pos]);
    if (pos + 4 + size > d.size()) return false;
    Bytes entry;
    if (!InflateEntry(&d[pos + 4], size, entry)) return false;
    entries.push_back(std::move(entry));
    pos += 4 + size;
  }
  return true;
}

// Reads the hashes of the complete records and returns where they end, so a
// record cut short when the game last closed can be dropped before appending.
size_t ScanXsh(const Bytes& xsh, std::unordered_set<uint64_t>& hashes) {
  size_t pos = kXshHeaderSize;
  while (pos + kXshRecordHeaderSize <= xsh.size()) {
    uint64_t hash;
    uint32_t packed;
    std::memcpy(&hash, &xsh[pos], 8);
    std::memcpy(&packed, &xsh[pos + 8], 4);
    size_t end = pos + kXshRecordHeaderSize + size_t(packed & 0x7FFFFFFF) * 4;
    if (end > xsh.size()) break;
    hashes.insert(hash);
    pos = end;
  }
  return pos;
}

bool AppendToFile(const std::filesystem::path& path, size_t keep_bytes, const Bytes& header,
                  const Bytes& data) {
  std::error_code ec;
  if (std::filesystem::exists(path, ec)) {
    std::filesystem::resize_file(path, keep_bytes, ec);
    if (ec) return false;
  }
  std::ofstream file(path, std::ios::binary | std::ios::app);
  if (!file) return false;
  if (keep_bytes == 0) file.write(reinterpret_cast<const char*>(header.data()), header.size());
  file.write(reinterpret_cast<const char*>(data.data()), data.size());
  return bool(file);
}

}  // namespace

void MergeIntoCache(const std::filesystem::path& list_path,
                    const std::filesystem::path& game_data_root,
                    const std::filesystem::path& cache_root, rex::memory::Memory* memory) {
  std::error_code ec;
  if (!std::filesystem::exists(list_path, ec)) return;
  List list;
  if (!ReadList(list_path, list)) {
    REXSYS_WARN("[shader-prebuild] could not read {}", list_path.string());
    return;
  }
  const auto shareable = cache_root / "shaders" / "shareable";
  std::filesystem::create_directories(shareable, ec);
  const auto xsh_path = shareable / (std::string(kTitle) + ".xsh");
  const auto xpso_path = shareable / (std::string(kTitle) + ".rtv.d3d12.xpso");

  // Shaders.
  Bytes xsh;
  size_t xsh_keep = 0;
  std::unordered_set<uint64_t> have;
  if (ReadFile(xsh_path, xsh) && xsh.size() >= kXshHeaderSize) {
    if (!std::equal(list.xsh_header.begin(), list.xsh_header.end(), xsh.begin())) {
      REXSYS_WARN("[shader-prebuild] shader cache version differs from the list; not merging");
      return;
    }
    xsh_keep = ScanXsh(xsh, have);
  }
  std::map<std::string, std::vector<Bytes>> banks;
  Bytes added_shaders;
  int shaders_added = 0, shaders_failed = 0;
  for (const ListShader& s : list.shaders) {
    if (have.count(s.hash)) continue;
    const size_t byte_count = size_t(s.packed & 0x7FFFFFFF) * 4;
    Bytes ucode(byte_count);
    if (s.from_xex) {
      if (!memory) {
        ++shaders_failed;
        continue;
      }
      std::memcpy(ucode.data(), memory->TranslateVirtual<const uint8_t*>(s.offset), byte_count);
    } else {
      auto it = banks.find(s.bank);
      if (it == banks.end()) {
        std::vector<Bytes> entries;
        if (!ReadBank(game_data_root / s.bank, entries)) {
          REXSYS_WARN("[shader-prebuild] could not read shader bank {}", s.bank);
        }
        it = banks.emplace(s.bank, std::move(entries)).first;
      }
      if (s.entry >= it->second.size() || s.offset + byte_count > it->second[s.entry].size()) {
        ++shaders_failed;
        continue;
      }
      std::memcpy(ucode.data(), it->second[s.entry].data() + s.offset, byte_count);
    }
    bool patch_ok = true;
    for (const auto& [index, xor_value] : s.patches) {
      if (size_t(index) * 4 + 4 > byte_count) {
        patch_ok = false;
        break;
      }
      for (int b = 0; b < 4; ++b) ucode[index * 4 + b] ^= uint8_t(xor_value >> (24 - 8 * b));
    }
    if (!patch_ok || XXH3_64bits(ucode.data(), byte_count) != s.hash) {
      ++shaders_failed;
      continue;
    }
    const uint8_t* hash_bytes = reinterpret_cast<const uint8_t*>(&s.hash);
    const uint8_t* packed_bytes = reinterpret_cast<const uint8_t*>(&s.packed);
    added_shaders.insert(added_shaders.end(), hash_bytes, hash_bytes + 8);
    added_shaders.insert(added_shaders.end(), packed_bytes, packed_bytes + 4);
    added_shaders.insert(added_shaders.end(), ucode.begin(), ucode.end());
    have.insert(s.hash);
    ++shaders_added;
  }
  if (shaders_added && !AppendToFile(xsh_path, xsh_keep, list.xsh_header, added_shaders)) {
    REXSYS_WARN("[shader-prebuild] could not write {}", xsh_path.string());
    return;
  }

  // Pipelines (only ones whose shaders are all in the cache are useful, but
  // the SDK skips any it can't build, so they are all added).
  Bytes xpso;
  size_t xpso_keep = 0;
  std::set<Bytes> have_pipelines;
  if (ReadFile(xpso_path, xpso) && xpso.size() >= kXpsoHeaderSize) {
    if (!std::equal(list.xpso_header.begin(), list.xpso_header.end(), xpso.begin())) {
      REXSYS_WARN("[shader-prebuild] pipeline cache version differs from the list; not merging");
      return;
    }
    xpso_keep = kXpsoHeaderSize + (xpso.size() - kXpsoHeaderSize) / kXpsoRecordSize * kXpsoRecordSize;
    for (size_t pos = kXpsoHeaderSize; pos < xpso_keep; pos += kXpsoRecordSize) {
      have_pipelines.emplace(xpso.begin() + pos, xpso.begin() + pos + kXpsoRecordSize);
    }
  }
  Bytes added_pipelines;
  int pipelines_added = 0;
  for (const Bytes& record : list.pipelines) {
    if (have_pipelines.insert(record).second) {
      added_pipelines.insert(added_pipelines.end(), record.begin(), record.end());
      ++pipelines_added;
    }
  }
  if (pipelines_added && !AppendToFile(xpso_path, xpso_keep, list.xpso_header, added_pipelines)) {
    REXSYS_WARN("[shader-prebuild] could not write {}", xpso_path.string());
    return;
  }
  REXSYS_INFO("[shader-prebuild] added {} shaders and {} pipelines to the cache ({} shaders failed)",
              shaders_added, pipelines_added, shaders_failed);
}

}  // namespace fable2::shaderprebuild
