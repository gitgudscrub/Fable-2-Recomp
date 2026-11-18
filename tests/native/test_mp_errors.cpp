// Co-op error table (src/net/mp_errors.h): every code has a title and message,
// codes are unique, and each one is listed in docs/COOP_ERRORS.md.
#include "mp_errors.h"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <set>
#include <sstream>
#include <string>

using namespace fable2::net;

static int failures = 0;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); ++failures; } } while (0)

int main(int argc, char** argv) {
  std::set<int> seen;
  for (const CoopErrorInfo& i : kCoopErrors) {
    CHECK(i.code != CoopError::None);
    CHECK(seen.insert(int(i.code)).second);
    CHECK(i.title && *i.title && std::strlen(i.title) < 40);
    CHECK(i.message && std::strlen(i.message) > 10 && std::strlen(i.message) < 200);
    CHECK(coop_error_info(i.code) == &i);
  }
  CHECK(coop_error_info(CoopError::None) == nullptr);
  CHECK(coop_error_code(CoopError::HostVersion) == "CO-104");

  if (argc > 1) {  // the docs list every code
    std::ifstream f(argv[1]);
    CHECK(f.good());
    std::stringstream ss;
    ss << f.rdbuf();
    const std::string doc = ss.str();
    for (const CoopErrorInfo& i : kCoopErrors) {
      const std::string code = coop_error_code(i.code);
      if (doc.find(code) == std::string::npos) {
        std::printf("FAIL %s is not in %s\n", code.c_str(), argv[1]);
        ++failures;
      }
    }
  }
  if (failures) return 1;
  std::printf("co-op error table: %zu codes OK\n", seen.size());
  return 0;
}
