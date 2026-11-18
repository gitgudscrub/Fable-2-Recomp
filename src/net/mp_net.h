// mp_net.h - multiplayer network layer (f4): UDP thread + typed, checked messages.
//
// Each game sends its own hero (position, facing, bone pose) to its peers and
// keeps the latest state of every peer. The game thread never touches the
// socket and the net thread never touches guest memory: they meet in two
// mutex-guarded snapshots (Local = what we send, PeerState = what arrived).
//
// Two ways to find the other players:
//  * relay (normal): `--mp_relay=host:port` plus `--mp_host=true` (start a
//    session; the relay hands back an invite code) or `--mp_join=CODE`. Every
//    packet goes through the relay (tools/mp_relay/relay.py), which checks it
//    and passes it to the others in the session; players never see each
//    other's IP addresses. Only packets from the relay's address are accepted.
//  * direct (testing): `--mp_peers=host:port,...`. Loopback test: list our own
//    port and the puppet copies our own hero through the whole send/receive path.
//
// Wire format (little-endian, version kProto):
//   Header 16 B: magic "F2MP", proto u8, type u8, flags u16, sender u32, seq u32
//   HELLO  (1): bone_count u16, reserved u16                    ~1 per second
//   STATE  (2): time_ms u32, pos f32 x3, qz f32, qw f32, pose_frame u32
//   POSE   (3): pose_frame u32, bone_count u16, first u16, count u16, part u8,
//               parts u8, count x 12 half floats (one 3x4 bone matrix each)
//               (a body can have several skeletons: the adult hero has 90 + 87
//               bones; parts are sorted by bone count, largest first)
// Relay messages (game <-> relay; the relay's header sender is 0):
//   CREATE  (16): wanted code char[8] (zeros = new; a host that lost the relay
//                 asks for its old code back)
//   JOIN    (17): code char[8]
//   WELCOME (18): code char[8], players u8, max u8, is_host u16
//   REFUSED (19): reason u8 (1 bad code, 2 full, 3 slow down, 4 not in a
//                 session, 5 server full), pad u8 x3
// A peer slot is only created by a HELLO; other messages from unknown senders
// are dropped.
// Every field is range-checked before it is stored; anything malformed is
// dropped and counted. Network data never reaches Lua or any code path.
#pragma once

#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "Ws2_32.lib")

#include <rex/cvar.h>
#include <rex/logging.h>

#include <array>
#include <atomic>
#include <chrono>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>

REXCVAR_DEFINE_BOOL(mp_enable, false, "Multiplayer",
                    "Turn on the multiplayer network layer (UDP).");
REXCVAR_DEFINE_INT32(mp_port, 27960, "Multiplayer", "UDP port this game listens on.");
REXCVAR_DEFINE_STRING(mp_peers, "", "Multiplayer",
                      "Peers to send to, comma separated host:port (until the relay exists). "
                      "Our own port = loopback test.");
REXCVAR_DEFINE_INT32(mp_send_hz, 30, "Multiplayer", "How often our hero is sent (per second).");
REXCVAR_DEFINE_STRING(mp_relay, "", "Multiplayer",
                      "Co-op relay server host:port. When set, mp_peers is ignored and every packet "
                      "goes through the relay.");
REXCVAR_DEFINE_BOOL(mp_host, false, "Multiplayer",
                    "With mp_relay: start a new session; the invite code is logged and written "
                    "to mp_session.txt next to the exe.");
REXCVAR_DEFINE_STRING(mp_join, "", "Multiplayer", "With mp_relay: invite code of the session to join.");

namespace fable2::net {

constexpr uint32_t kMagic = 0x504D3246;  // "F2MP" read as little-endian u32
constexpr uint8_t kProto = 1;
constexpr int kMaxPeers = 3;              // 4-player co-op: us + 3
constexpr uint32_t kMaxBones = 256;
constexpr uint32_t kMaxParts = 4;          // skeletons per body
constexpr uint32_t kBonesPerPacket = 48;  // 48 * 24 B = 1152 B: stays under one MTU
constexpr float kMaxCoord = 100000.0f;
constexpr auto kPeerTimeout = std::chrono::seconds(5);

enum class Msg : uint8_t { Hello = 1, State = 2, Pose = 3, Create = 16, Join = 17, Welcome = 18, Refused = 19 };
enum class Refuse : uint8_t { BadCode = 1, Full = 2, SlowDown = 3, NotJoined = 4, ServerFull = 5 };
constexpr size_t kCodeBytes = 8;

using Clock = std::chrono::steady_clock;

// --- half floats ----------------------------------------------------------
inline uint16_t to_half(float f) {
  uint32_t x;
  std::memcpy(&x, &f, 4);
  const uint32_t sign = (x >> 16) & 0x8000;
  int32_t e = int32_t((x >> 23) & 0xFF) - 127 + 15;
  uint32_t m = x & 0x7FFFFF;
  if (e <= 0) return uint16_t(sign);                  // tiny -> signed zero
  if (e >= 31) return uint16_t(sign | 0x7BFF);        // clamp to max finite
  m += 0x1000;                                        // round to nearest
  if (m & 0x800000) { m = 0; if (++e >= 31) return uint16_t(sign | 0x7BFF); }
  return uint16_t(sign | (uint32_t(e) << 10) | (m >> 13));
}
inline float from_half(uint16_t h) {
  const uint32_t sign = uint32_t(h & 0x8000) << 16;
  const uint32_t e = (h >> 10) & 0x1F, m = h & 0x3FF;
  uint32_t x;
  if (e == 0) {
    if (m == 0) x = sign;
    else {  // subnormal
      float f = std::ldexp(float(m), -24);
      std::memcpy(&x, &f, 4);
      x |= sign;
    }
  } else if (e == 31) {
    x = sign | 0x7F800000 | (m << 13);  // inf / nan (rejected by the checks)
  } else {
    x = sign | ((e - 15 + 127) << 23) | (m << 13);
  }
  float f;
  std::memcpy(&f, &x, 4);
  return f;
}

// --- byte writer / reader (little-endian) ---------------------------------
struct Writer {
  std::vector<uint8_t> b;
  void u8(uint8_t v) { b.push_back(v); }
  void u16(uint16_t v) { b.push_back(uint8_t(v)); b.push_back(uint8_t(v >> 8)); }
  void u32(uint32_t v) { for (int i = 0; i < 4; ++i) b.push_back(uint8_t(v >> (8 * i))); }
  void f32(float f) { uint32_t v; std::memcpy(&v, &f, 4); u32(v); }
};
struct Reader {
  const uint8_t* p;
  size_t n, i = 0;
  bool ok = true;
  bool need(size_t k) { if (i + k > n) ok = false; return ok; }
  uint8_t u8() { return need(1) ? p[i++] : 0; }
  uint16_t u16() { if (!need(2)) return 0; uint16_t v = uint16_t(p[i] | (p[i + 1] << 8)); i += 2; return v; }
  uint32_t u32() {
    if (!need(4)) return 0;
    uint32_t v = uint32_t(p[i]) | uint32_t(p[i + 1]) << 8 | uint32_t(p[i + 2]) << 16 | uint32_t(p[i + 3]) << 24;
    i += 4;
    return v;
  }
  float f32() { uint32_t v = u32(); float f; std::memcpy(&f, &v, 4); return f; }
};

// --- shared snapshots -----------------------------------------------------
// What we send. Written by the game thread (transform) and the packer hook
// (pose); read by the net thread.
struct Local {
  std::mutex m;
  bool valid = false;
  float pos[3] = {};
  float qz = 0, qw = 1;
  uint32_t pose_frame = 0;
  // per skeleton part: bone_count * 12 floats (3x4 per bone), host order
  std::array<std::vector<float>, kMaxParts> parts;
  uint32_t part_count = 0;
};

// One skeleton of a peer's body.
struct PeerPart {
  uint32_t version = 0;  // bumps when a new complete pose lands
  uint32_t frame = 0;
  std::vector<float> pose;
  uint32_t asm_frame = 0;
  std::vector<float> asm_pose;
  std::vector<uint8_t> asm_have;
  uint32_t asm_count = 0;
};

// What arrived from one peer. Written by the net thread, read by the game side.
struct PeerState {
  bool active = false;
  uint32_t id = 0;
  sockaddr_in addr{};
  Clock::time_point last_heard{};
  uint16_t bone_count = 0;  // main skeleton, from HELLO
  uint8_t part_count = 0;   // from POSE
  // transform
  bool have_state = false;
  uint32_t state_time = 0;
  float pos[3] = {};
  float qz = 0, qw = 1;
  std::array<PeerPart, kMaxParts> parts;
};

struct Stats {
  std::atomic<uint32_t> sent{0}, received{0}, dropped{0}, poses{0};
};

class Net {
 public:
  static Net& Get() {
    static Net n;
    return n;
  }

  Local& local() { return local_; }
  Stats& stats() { return stats_; }
  uint32_t self_id() const { return self_id_; }

  // Game side: a peer's id, main bone count and latest transform (no poses).
  struct PeerView {
    uint32_t id = 0;
    uint16_t bone_count = 0;
    uint8_t part_count = 0;
    bool have_state = false;
    float pos[3] = {};
    float qz = 0, qw = 1;
  };
  bool peer_view(int slot, PeerView& v) {
    std::lock_guard<std::mutex> l(peers_m_);
    if (slot < 0 || slot >= kMaxPeers || !peers_[slot].active) return false;
    const PeerState& p = peers_[slot];
    v.id = p.id;
    v.bone_count = p.bone_count;
    v.part_count = p.part_count;
    v.have_state = p.have_state;
    std::memcpy(v.pos, p.pos, sizeof(v.pos));
    v.qz = p.qz;
    v.qw = p.qw;
    return true;
  }
  // Copies one part's latest complete pose if it is newer than `have_version`.
  bool peer_pose(int slot, uint32_t part, uint32_t have_version, std::vector<float>& out,
                 uint32_t* version) {
    std::lock_guard<std::mutex> l(peers_m_);
    if (slot < 0 || slot >= kMaxPeers || part >= kMaxParts || !peers_[slot].active) return false;
    const PeerPart& p = peers_[slot].parts[part];
    if (p.version == have_version || p.pose.empty()) return false;
    out = p.pose;
    *version = p.version;
    return true;
  }

  // Starts the thread once when mp_enable is on (called every game tick).
  void ensure_started() {
    if (started_ || !REXCVAR_GET(mp_enable)) return;
    started_ = true;
    std::random_device rd;
    self_id_ = (uint32_t(rd()) << 1) | 1;  // never 0
    thread_ = std::thread([this] { run(); });
    thread_.detach();
  }

 private:
  Net() = default;

  void run() {
    WSADATA d;
    if (WSAStartup(MAKEWORD(2, 2), &d) != 0) {
      REXLOG_ERROR("[mpnet] WSAStartup failed ({})", WSAGetLastError());
      return;
    }
    sock_ = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock_ == INVALID_SOCKET) {
      REXLOG_ERROR("[mpnet] socket failed ({})", WSAGetLastError());
      return;
    }
    // A UDP socket on Windows reports ICMP "port unreachable" from an earlier
    // send as a recv error (WSAECONNRESET); turn that off, a missing peer is normal.
    {
      BOOL off = FALSE;
      DWORD ret = 0;
      constexpr DWORD kSioUdpConnReset = 0x9800000C;  // SIO_UDP_CONNRESET
      WSAIoctl(sock_, kSioUdpConnReset, &off, sizeof(off), nullptr, 0, &ret, nullptr, nullptr);
    }
    relay_mode_ = !REXCVAR_GET(mp_relay).empty();
    // With a relay any free local port will do (two games on one PC just work).
    const uint16_t port = relay_mode_ ? 0 : uint16_t(REXCVAR_GET(mp_port));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);
    if (::bind(sock_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
      REXLOG_ERROR("[mpnet] cannot bind UDP port {} ({})", port, WSAGetLastError());
      closesocket(sock_);
      return;
    }
    if (relay_mode_) {
      if (!setup_relay()) {
        closesocket(sock_);
        return;
      }
    } else {
      parse_peers();
      REXLOG_INFO("[mpnet] listening on UDP {}; id {:08X}; {} peer address(es)", port, self_id_,
                  targets_.size());
    }

    std::vector<uint8_t> buf(2048);
    auto next_send = Clock::now(), next_hello = Clock::now(), next_log = Clock::now() + std::chrono::seconds(10);
    for (;;) {
      fd_set rs;
      FD_ZERO(&rs);
      FD_SET(sock_, &rs);
      timeval tv{0, 2000};  // 2 ms
      if (::select(0, &rs, nullptr, nullptr, &tv) > 0) {
        for (int k = 0; k < 64; ++k) {  // drain
          sockaddr_in from{};
          int fl = sizeof(from);
          const int n = ::recvfrom(sock_, reinterpret_cast<char*>(buf.data()), int(buf.size()), 0,
                                   reinterpret_cast<sockaddr*>(&from), &fl);
          if (n <= 0) break;
          stats_.received.fetch_add(1, std::memory_order_relaxed);
          if (!handle(buf.data(), size_t(n), from)) stats_.dropped.fetch_add(1, std::memory_order_relaxed);
          u_long avail = 0;
          if (ioctlsocket(sock_, FIONREAD, &avail) != 0 || avail == 0) break;
        }
      }
      const auto now = Clock::now();
      if (relay_mode_ && !joined_) {
        if (!gave_up_ && now >= next_join_) {
          next_join_ = now + std::chrono::seconds(2);
          send_join();
        }
        continue;  // nothing goes out until the relay has let us in
      }
      if (now >= next_hello) {
        next_hello = now + std::chrono::seconds(1);
        send_hello();
        expire_peers(now);
      }
      const int hz = std::max(1, std::min(REXCVAR_GET(mp_send_hz), 120));
      if (now >= next_send) {
        next_send = now + std::chrono::microseconds(1000000 / hz);
        send_hero();
      }
      if (now >= next_log) {
        next_log = now + std::chrono::seconds(10);
        int active = 0;
        {
          std::lock_guard<std::mutex> l(peers_m_);
          for (auto& p : peers_) active += p.active;
        }
        REXLOG_INFO("[mpnet] sent {} received {} dropped {} poses {}; {} peer(s) active{}{}",
                    stats_.sent.load(), stats_.received.load(), stats_.dropped.load(),
                    stats_.poses.load(), active, code_.empty() ? "" : "; session ", code_);
      }
    }
  }

  static bool resolve(const std::string& item, sockaddr_in& out) {
    const size_t c = item.rfind(':');
    if (c == std::string::npos) return false;
    const std::string host = item.substr(0, c);
    const int port = std::atoi(item.c_str() + c + 1);
    if (port <= 0 || port > 65535) return false;
    addrinfo hints{}, *res = nullptr;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    if (getaddrinfo(host.c_str(), nullptr, &hints, &res) != 0 || !res) return false;
    out = *reinterpret_cast<sockaddr_in*>(res->ai_addr);
    out.sin_port = htons(uint16_t(port));
    freeaddrinfo(res);
    return true;
  }

  // Relay mode: the relay is our only target, and the only address we accept.
  bool setup_relay() {
    if (!resolve(REXCVAR_GET(mp_relay), relay_)) {
      REXLOG_ERROR("[mpnet] cannot resolve relay '{}' (expected host:port)", REXCVAR_GET(mp_relay));
      return false;
    }
    std::string code = REXCVAR_GET(mp_join);
    for (char& ch : code) ch = char(std::toupper(uint8_t(ch)));
    if (code.size() > kCodeBytes) code.resize(kCodeBytes);
    hosting_ = REXCVAR_GET(mp_host);
    if (!hosting_ && code.empty()) {
      REXLOG_ERROR("[mpnet] mp_relay is set but neither mp_host nor mp_join is; not connecting");
      return false;
    }
    if (hosting_) code.clear();
    join_code_ = code;
    targets_.assign(1, relay_);
    REXLOG_INFO("[mpnet] id {:08X}; {} through the relay", self_id_,
                hosting_ ? std::string("starting a session") : "joining session " + join_code_);
    return true;
  }

  void send_join() {
    Writer w;
    header(w, hosting_ ? Msg::Create : Msg::Join);
    // a host asks for its old code back if the relay forgot us (e.g. restarted)
    const std::string& c = hosting_ ? code_ : join_code_;
    for (size_t i = 0; i < kCodeBytes; ++i) w.u8(i < c.size() ? uint8_t(c[i]) : 0);
    send_all(w);
  }

  static bool same_addr(const sockaddr_in& a, const sockaddr_in& b) {
    return a.sin_addr.s_addr == b.sin_addr.s_addr && a.sin_port == b.sin_port;
  }

  // WELCOME / REFUSED from the relay. Returns false = dropped.
  bool handle_relay(Msg type, Reader& r, size_t n) {
    if (type == Msg::Welcome) {
      char code[kCodeBytes + 1] = {};
      for (size_t i = 0; i < kCodeBytes; ++i) code[i] = char(r.u8());
      const uint8_t players = r.u8(), max = r.u8();
      r.u16();
      if (!r.ok || r.i != n) return false;
      std::string c;
      for (size_t i = 0; i < kCodeBytes && code[i]; ++i) {
        if (!std::isalnum(uint8_t(code[i]))) return false;
        c += code[i];
      }
      if (c.empty()) return false;
      const bool first = !joined_ || c != code_;
      joined_ = true;
      code_ = c;
      if (first) {
        REXLOG_INFO("[mpnet] in session {} ({}/{} players){}", code_, players, max,
                    hosting_ ? " - give this invite code to your friends" : "");
        write_session_file();
      }
      return true;
    }
    if (type == Msg::Refused) {
      const uint8_t reason = r.u8();
      r.u8();
      r.u16();
      if (!r.ok || r.i != n) return false;
      switch (Refuse(reason)) {
        case Refuse::NotJoined:
          if (joined_) {
            REXLOG_WARN("[mpnet] the relay lost our session; rejoining");
            joined_ = false;
            next_join_ = Clock::now();
            // the host may not have re-made the session yet: keep trying for a minute
            rejoin_until_ = Clock::now() + std::chrono::seconds(60);
          }
          break;
        case Refuse::SlowDown:
          next_join_ = Clock::now() + std::chrono::seconds(5);
          break;
        case Refuse::BadCode:
        case Refuse::Full:
        case Refuse::ServerFull:
          if (Refuse(reason) == Refuse::BadCode && Clock::now() < rejoin_until_) break;
          if (!joined_ && !gave_up_) {
            gave_up_ = true;
            REXLOG_WARN("[mpnet] relay refused: {}",
                        reason == 1 ? "no session with that code"
                                    : reason == 2 ? "session is full" : "relay is full");
          }
          break;
        default:
          return false;
      }
      return true;
    }
    return false;
  }

  // mp_session.txt next to the exe, so a launcher (later) can show the code.
  void write_session_file() {
    wchar_t path[MAX_PATH];
    const DWORD len = GetModuleFileNameW(nullptr, path, MAX_PATH);
    if (!len || len >= MAX_PATH) return;
    std::wstring p(path, len);
    const size_t slash = p.find_last_of(L"\\/");
    p = (slash == std::wstring::npos ? L"" : p.substr(0, slash + 1)) + L"mp_session.txt";
    if (FILE* f = _wfopen(p.c_str(), L"w")) {
      std::fprintf(f, "%s\n", code_.c_str());
      std::fclose(f);
    }
  }

  void parse_peers() {
    const std::string list = REXCVAR_GET(mp_peers);
    size_t i = 0;
    while (i < list.size() && targets_.size() < 8) {
      size_t j = list.find(',', i);
      if (j == std::string::npos) j = list.size();
      std::string item = list.substr(i, j - i);
      i = j + 1;
      sockaddr_in a{};
      if (!resolve(item, a)) {
        REXLOG_WARN("[mpnet] cannot resolve peer '{}'", item);
        continue;
      }
      targets_.push_back(a);
    }
  }

  void header(Writer& w, Msg type) {
    w.u32(kMagic);
    w.u8(kProto);
    w.u8(uint8_t(type));
    w.u16(0);
    w.u32(self_id_);
    w.u32(++seq_);
  }
  void send_all(const Writer& w) {
    for (const sockaddr_in& a : targets_) {
      if (::sendto(sock_, reinterpret_cast<const char*>(w.b.data()), int(w.b.size()), 0,
                   reinterpret_cast<const sockaddr*>(&a), sizeof(a)) > 0)
        stats_.sent.fetch_add(1, std::memory_order_relaxed);
    }
  }

  void send_hello() {
    uint16_t bones = 0;
    {
      std::lock_guard<std::mutex> l(local_.m);
      if (!local_.valid) return;
      bones = uint16_t(local_.parts[0].size() / 12);
    }
    Writer w;
    header(w, Msg::Hello);
    w.u16(bones);
    w.u16(0);
    send_all(w);
  }

  void send_hero() {
    float pos[3], qz, qw;
    uint32_t frame, parts;
    {
      std::lock_guard<std::mutex> l(local_.m);
      if (!local_.valid) return;
      std::memcpy(pos, local_.pos, sizeof(pos));
      qz = local_.qz;
      qw = local_.qw;
      frame = local_.pose_frame;
      parts = std::min(local_.part_count, kMaxParts);
      for (uint32_t k = 0; k < parts; ++k) pose_tx_[k] = local_.parts[k];
    }
    const uint32_t t = uint32_t(std::chrono::duration_cast<std::chrono::milliseconds>(
                                    Clock::now().time_since_epoch()).count());
    Writer w;
    header(w, Msg::State);
    w.u32(t);
    for (float v : pos) w.f32(v);
    w.f32(qz);
    w.f32(qw);
    w.u32(frame);
    send_all(w);

    if (frame == last_pose_sent_) return;
    last_pose_sent_ = frame;
    for (uint32_t part = 0; part < parts; ++part) {
      const std::vector<float>& pose = pose_tx_[part];
      const uint32_t bones = uint32_t(pose.size() / 12);
      if (!bones || bones > kMaxBones) continue;
      for (uint32_t first = 0; first < bones; first += kBonesPerPacket) {
        const uint32_t count = std::min(kBonesPerPacket, bones - first);
        Writer p;
        p.b.reserve(32 + count * 24);
        header(p, Msg::Pose);
        p.u32(frame);
        p.u16(uint16_t(bones));
        p.u16(uint16_t(first));
        p.u16(uint16_t(count));
        p.u8(uint8_t(part));
        p.u8(uint8_t(parts));
        for (uint32_t k = first * 12; k < (first + count) * 12; ++k) p.u16(to_half(pose[k]));
        send_all(p);
      }
    }
  }

  // Finds the slot for a sender; only a HELLO may take a free one. Caller holds peers_m_.
  PeerState* slot_for(uint32_t id, const sockaddr_in& from, bool may_join) {
    for (auto& p : peers_)
      if (p.active && p.id == id) return &p;
    if (!may_join) return nullptr;
    for (auto& p : peers_) {
      if (!p.active) {
        p = PeerState{};
        p.active = true;
        p.id = id;
        p.addr = from;
        REXLOG_INFO("[mpnet] peer {:08X} joined{}", id, id == self_id_ ? " (loopback: ourselves)" : "");
        return &p;
      }
    }
    return nullptr;  // full
  }

  void expire_peers(Clock::time_point now) {
    std::lock_guard<std::mutex> l(peers_m_);
    for (auto& p : peers_) {
      if (p.active && now - p.last_heard > kPeerTimeout) {
        REXLOG_INFO("[mpnet] peer {:08X} timed out", p.id);
        p.active = false;
      }
    }
  }

  static bool finite_in(float v, float lim) { return std::isfinite(v) && std::fabs(v) <= lim; }

  // Parses and checks one datagram. Returns false = dropped.
  bool handle(const uint8_t* data, size_t n, const sockaddr_in& from) {
    Reader r{data, n};
    if (r.u32() != kMagic || r.u8() != kProto) return false;
    const uint8_t type = r.u8();
    r.u16();  // flags
    const uint32_t sender = r.u32();
    r.u32();  // seq (not used yet)
    if (!r.ok) return false;
    if (relay_mode_) {
      if (!same_addr(from, relay_)) return false;  // only the relay may talk to us
      if (Msg(type) == Msg::Welcome || Msg(type) == Msg::Refused)
        return sender == 0 && handle_relay(Msg(type), r, n);
      if (!joined_ || sender == self_id_) return false;
    }
    if (sender == 0) return false;

    std::lock_guard<std::mutex> l(peers_m_);
    PeerState* p = slot_for(sender, from, Msg(type) == Msg::Hello);
    if (!p) return false;
    switch (Msg(type)) {
      case Msg::Hello: {
        const uint16_t bones = r.u16();
        r.u16();
        if (!r.ok || r.i != n || bones > kMaxBones) return false;
        p->bone_count = bones;
        break;
      }
      case Msg::State: {
        const uint32_t t = r.u32();
        float pos[3];
        for (float& v : pos) v = r.f32();
        float qz = r.f32(), qw = r.f32();
        r.u32();  // pose frame
        if (!r.ok || r.i != n) return false;
        for (float v : pos)
          if (!finite_in(v, kMaxCoord)) return false;
        if (!finite_in(qz, 2.0f) || !finite_in(qw, 2.0f)) return false;
        const float len = std::sqrt(qz * qz + qw * qw);
        if (len < 0.5f || len > 1.5f) return false;
        // Out-of-order packets: keep the newest by sender time (wraps after 49 days).
        if (p->have_state && int32_t(t - p->state_time) < 0) break;
        p->have_state = true;
        p->state_time = t;
        std::memcpy(p->pos, pos, sizeof(pos));
        p->qz = qz / len;
        p->qw = qw / len;
        break;
      }
      case Msg::Pose: {
        const uint32_t frame = r.u32();
        const uint16_t bones = r.u16(), first = r.u16(), count = r.u16();
        const uint8_t part = r.u8(), parts = r.u8();
        if (!r.ok || bones == 0 || bones > kMaxBones || count == 0 || count > kBonesPerPacket ||
            uint32_t(first) + count > bones || parts == 0 || parts > kMaxParts || part >= parts ||
            n != r.i + size_t(count) * 24)
          return false;
        // Decode into a scratch buffer first: a bad value drops the whole packet.
        float vals[kBonesPerPacket * 12];
        for (uint32_t k = 0; k < uint32_t(count) * 12; ++k) {
          vals[k] = from_half(r.u16());
          if (!finite_in(vals[k], 1000.0f)) return false;
        }
        PeerPart& pp = p->parts[part];
        if (pp.asm_frame != frame || pp.asm_pose.size() != size_t(bones) * 12) {
          if (pp.asm_frame && int32_t(frame - pp.asm_frame) < 0) break;  // older frame
          pp.asm_frame = frame;
          pp.asm_pose.assign(size_t(bones) * 12, 0.0f);
          pp.asm_have.assign(bones, 0);
          pp.asm_count = 0;
        }
        std::memcpy(&pp.asm_pose[size_t(first) * 12], vals, size_t(count) * 12 * sizeof(float));
        for (uint32_t b = first; b < uint32_t(first) + count; ++b) {
          if (!pp.asm_have[b]) { pp.asm_have[b] = 1; ++pp.asm_count; }
        }
        p->part_count = parts;
        if (pp.asm_count == bones) {  // complete: publish
          pp.pose.swap(pp.asm_pose);
          pp.frame = frame;
          ++pp.version;
          pp.asm_pose.clear();
          pp.asm_count = 0;
          stats_.poses.fetch_add(1, std::memory_order_relaxed);
        }
        break;
      }
      default:
        return false;
    }
    p->last_heard = Clock::now();
    return true;
  }

  Local local_;
  Stats stats_;
  std::mutex peers_m_;
  std::array<PeerState, kMaxPeers> peers_{};
  std::vector<sockaddr_in> targets_;
  std::array<std::vector<float>, kMaxParts> pose_tx_;
  uint32_t last_pose_sent_ = 0;
  uint32_t self_id_ = 0;
  uint32_t seq_ = 0;
  bool started_ = false;
  // relay mode (net thread only)
  bool relay_mode_ = false;
  bool hosting_ = false;
  bool joined_ = false;
  bool gave_up_ = false;
  sockaddr_in relay_{};
  std::string join_code_;  // the code we were told to join
  std::string code_;       // the session we are in
  Clock::time_point next_join_{};
  Clock::time_point rejoin_until_{};
  SOCKET sock_ = INVALID_SOCKET;
  std::thread thread_;
};

}  // namespace fable2::net
