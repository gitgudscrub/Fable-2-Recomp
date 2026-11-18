// fable2_level_watch.h - the game's level object and the dense-region draw distance.
//
// The level object is the `this` the GetLevelLoaded Lua native
// (sub_821B57B8) is bound to; hotfunc ScriptApi_AddTableEntry_825B7858
// keeps it when the script API is set up. Its +0x24 is the region being
// loaded or played (switched as soon as a load starts, before the region's
// objects are created); region+4 points at data whose +0xAC is the region
// name as a string object (a pointer to a block whose first word is the
// char data), e.g. "BWSMarket".
#pragma once

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstdint>
#include <string>
#include <vector>

namespace fable2::levelwatch {

constexpr uint32_t kGetLevelLoadedMethod = 0x821B57B8;

inline std::atomic<uint32_t> g_level_object{0};

inline std::string Lower(std::string s) {
  std::transform(s.begin(), s.end(), s.begin(),
                 [](unsigned char c) { return char(std::tolower(c)); });
  return s;
}

// Comma-separated names -> trimmed, lower-case list.
inline std::vector<std::string> ParseRegionList(const std::string& list) {
  std::vector<std::string> out;
  std::string item;
  auto flush = [&]() {
    size_t b = item.find_first_not_of(" \t");
    size_t e = item.find_last_not_of(" \t");
    if (b != std::string::npos) out.push_back(Lower(item.substr(b, e - b + 1)));
    item.clear();
  };
  for (char c : list) {
    if (c == ',') flush();
    else item += c;
  }
  flush();
  return out;
}

}  // namespace fable2::levelwatch
