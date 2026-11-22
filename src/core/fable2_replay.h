// fable_2 - Input recorder / replayer (comparison videos, hub task f17)
//
// Record a run once, then replay the same inputs in each edition so the videos
// line up. Console commands (src/core/fable2_console.h):
//
//   rec start <name>   record player 1's input from now on
//   rec stop           stop and save (F10 in the game window does the same)
//   play <name>        replay a recording from now on
//   play stop          stop a replay early
//
// What is recorded: the merged gamepad state the game receives for player 1
// (keyboard, mouse look and controllers are all folded into it by the SDK's
// InputSystem, see InputSystem::SetStateObserver), each change stamped with
// the time since `rec start`. A replay feeds those states back through its own
// synthetic pad at the same times, so the run plays the same in 30 and 60 fps
// editions (the game moves the hero by game time, not by frame).
//
// The hero's position is sampled 10 times a second in both modes. A replay
// compares its track with the recorded one and reports how far it drifted, so
// a bad take is obvious before any video is cut.
//
// Files: <console dir>/replays/<name>.f2rec (text). Each replay also writes
// <name>.played.txt with its own track.
//
// Threads: the observer and the driver run on guest threads that poll input;
// commands and hero samples run on the game thread. One mutex guards State.
#pragma once

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

#include <rex/input/input.h>
#include <rex/input/input_driver.h>
#include <rex/input/input_system.h>
#include <rex/ui/overlay/notice.h>

#include "fable2_console.h"

#ifdef _WIN32
#include <windows.h>
#endif

namespace fable2::replay {

namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;
using rex::X_RESULT;
using rex::X_STATUS;

struct PadEvent {
  int64_t t_us = 0;
  uint16_t buttons = 0;
  uint8_t lt = 0, rt = 0;
  int16_t lx = 0, ly = 0, rx = 0, ry = 0;
  bool same_input(const PadEvent& o) const {
    return buttons == o.buttons && lt == o.lt && rt == o.rt && lx == o.lx && ly == o.ly && rx == o.rx &&
           ry == o.ry;
  }
};

struct HeroSample {
  int64_t t_us = 0;
  float x = 0, y = 0, z = 0, qz = 0, qw = 1;
};

enum Mode : int { kIdle = 0, kRecording = 1, kPlaying = 2 };

constexpr auto kHeroEvery = std::chrono::milliseconds(100);
constexpr int64_t kPlayTailUs = 500000;  // keep sampling the hero this long after the last input

struct State {
  std::mutex m;
  std::atomic<int> mode{kIdle};
  Clock::time_point t0{};
  std::string name;
  std::vector<PadEvent> pads;      // recording: appended; playing: the recording
  std::vector<HeroSample> hero;    // recording: appended; playing: the recorded track
  std::vector<HeroSample> played;  // playing: this run's track
  PadEvent last{};
  bool have_last = false;
  int64_t end_us = 0;  // playing: when the recording stopped
  size_t cursor = 0;   // playing: current event
  Clock::time_point next_hero{};
  double max_drift = 0, last_drift = 0;
  int64_t max_drift_at = 0;
};

inline State& S() {
  static State s;
  return s;
}

inline int64_t elapsed_us(const State& s) {
  return std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - s.t0).count();
}

inline fs::path dir() { return fable2::console::dir() / "replays"; }

inline bool valid_name(const std::string& n) {
  if (n.empty() || n.size() > 40) return false;
  return std::all_of(n.begin(), n.end(), [](char c) {
    return std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '-';
  });
}

inline void out(const std::string& tag, const std::string& msg, bool err = false) {
  fable2::console::out(tag, msg, err);
}

inline std::string secs(int64_t us) {
  char b[32];
  std::snprintf(b, sizeof(b), "%.1f s", us / 1e6);
  return b;
}

// --- files -------------------------------------------------------------------

inline bool save_recording(const State& s, std::string& err) {
  std::error_code ec;
  fs::create_directories(dir(), ec);
  const fs::path path = dir() / (s.name + ".f2rec");
  std::ofstream f(path, std::ios::trunc);
  if (!f) return err = "can't write " + path.string(), false;
  f << "f2rec 1\n";
  f << "# I t_us buttons lt rt lx ly rx ry | P t_us x y z qz qw | E t_us\n";
  for (const auto& e : s.pads)
    f << "I " << e.t_us << ' ' << e.buttons << ' ' << int(e.lt) << ' ' << int(e.rt) << ' ' << e.lx << ' '
      << e.ly << ' ' << e.rx << ' ' << e.ry << '\n';
  char b[160];
  for (const auto& h : s.hero) {
    std::snprintf(b, sizeof(b), "P %lld %.3f %.3f %.3f %.5f %.5f\n", static_cast<long long>(h.t_us), h.x, h.y,
                  h.z, h.qz, h.qw);
    f << b;
  }
  f << "E " << s.end_us << '\n';
  return f.good() ? true : (err = "write failed", false);
}

inline bool load_recording(const std::string& name, State& s, std::string& err) {
  const fs::path path = dir() / (name + ".f2rec");
  std::ifstream f(path);
  if (!f) return err = "no recording " + path.string(), false;
  std::string line;
  if (!std::getline(f, line) || line.rfind("f2rec 1", 0) != 0) return err = "not a recording", false;
  s.pads.clear();
  s.hero.clear();
  s.end_us = 0;
  while (std::getline(f, line)) {
    std::istringstream in(line);
    char kind = 0;
    in >> kind;
    if (kind == 'I') {
      PadEvent e;
      long long t;
      int b, lt, rt, lx, ly, rx, ry;
      if (!(in >> t >> b >> lt >> rt >> lx >> ly >> rx >> ry)) continue;
      e.t_us = t;
      e.buttons = static_cast<uint16_t>(b);
      e.lt = static_cast<uint8_t>(lt);
      e.rt = static_cast<uint8_t>(rt);
      e.lx = static_cast<int16_t>(lx);
      e.ly = static_cast<int16_t>(ly);
      e.rx = static_cast<int16_t>(rx);
      e.ry = static_cast<int16_t>(ry);
      s.pads.push_back(e);
    } else if (kind == 'P') {
      HeroSample h;
      long long t;
      if (!(in >> t >> h.x >> h.y >> h.z >> h.qz >> h.qw)) continue;
      h.t_us = t;
      s.hero.push_back(h);
    } else if (kind == 'E') {
      long long t;
      if (in >> t) s.end_us = t;
    }
  }
  if (!s.end_us && !s.pads.empty()) s.end_us = s.pads.back().t_us;
  return true;
}

inline void save_played(const State& s) {
  std::error_code ec;
  fs::create_directories(dir(), ec);
  std::ofstream f(dir() / (s.name + ".played.txt"), std::ios::trunc);
  char b[160];
  for (const auto& h : s.played) {
    std::snprintf(b, sizeof(b), "P %lld %.3f %.3f %.3f %.5f %.5f\n", static_cast<long long>(h.t_us), h.x, h.y,
                  h.z, h.qz, h.qw);
    f << b;
  }
}

// --- recording ---------------------------------------------------------------

// InputSystem state observer: every merged state the guest receives.
inline void on_input_state(uint32_t user, const rex::input::X_INPUT_STATE& st) {
  if (user != 0) return;
  State& s = S();
  if (s.mode.load(std::memory_order_relaxed) != kRecording) return;
  PadEvent e;
  e.buttons = st.gamepad.buttons;
  e.lt = st.gamepad.left_trigger;
  e.rt = st.gamepad.right_trigger;
  e.lx = st.gamepad.thumb_lx;
  e.ly = st.gamepad.thumb_ly;
  e.rx = st.gamepad.thumb_rx;
  e.ry = st.gamepad.thumb_ry;
  std::lock_guard<std::mutex> l(s.m);
  if (s.mode.load(std::memory_order_relaxed) != kRecording) return;
  if (s.have_last && e.same_input(s.last)) return;
  e.t_us = elapsed_us(s);
  s.pads.push_back(e);
  s.last = e;
  s.have_last = true;
}

inline void start_recording(const std::string& name) {
  State& s = S();
  std::lock_guard<std::mutex> l(s.m);
  if (s.mode != kIdle) return out("rec", "busy: stop the current recording or replay first", true);
  s.name = name;
  s.pads.clear();
  s.hero.clear();
  s.played.clear();
  s.have_last = false;
  s.end_us = 0;
  s.t0 = Clock::now();
  s.next_hero = s.t0;
  s.mode = kRecording;
  out("rec", "recording '" + name + "' (rec stop or F10 to finish)");
  rex::ui::ShowNotice(rex::ui::NoticeKind::kInfo, "Recording", "Play now. Press F10 to stop.", "", 4.0f);
}

inline void stop_recording() {
  State& s = S();
  std::lock_guard<std::mutex> l(s.m);
  if (s.mode != kRecording) return out("rec", "not recording", true);
  s.mode = kIdle;
  s.end_us = elapsed_us(s);
  std::string err;
  if (!save_recording(s, err)) return out("rec", err, true);
  out("rec", "saved '" + s.name + "': " + secs(s.end_us) + ", " + std::to_string(s.pads.size()) +
                 " input changes, " + std::to_string(s.hero.size()) + " hero samples");
  rex::ui::ShowNotice(rex::ui::NoticeKind::kInfo, "Recording saved", s.name + ", " + secs(s.end_us), "", 4.0f);
}

// --- replay ------------------------------------------------------------------

inline void start_replay(const std::string& name) {
  State& s = S();
  std::lock_guard<std::mutex> l(s.m);
  if (s.mode != kIdle) return out("play", "busy: stop the current recording or replay first", true);
  std::string err;
  if (!load_recording(name, s, err)) return out("play", err, true);
  s.name = name;
  s.played.clear();
  s.cursor = 0;
  s.max_drift = s.last_drift = 0;
  s.max_drift_at = 0;
  s.t0 = Clock::now();
  s.next_hero = s.t0;
  s.mode = kPlaying;
  out("play", "playing '" + name + "' (" + secs(s.end_us) + ", " + std::to_string(s.pads.size()) +
                  " input changes)");
}

// Caller holds s.m.
inline void finish_replay(State& s, const char* why) {
  s.mode = kIdle;
  save_played(s);
  char b[200];
  std::snprintf(b, sizeof(b), "%s '%s': drift at the end %.2f m, largest %.2f m at %.1f s", why, s.name.c_str(),
                s.last_drift, s.max_drift, s.max_drift_at / 1e6);
  out("play", b);
}

inline void stop_replay() {
  State& s = S();
  std::lock_guard<std::mutex> l(s.m);
  if (s.mode != kPlaying) return out("play", "not playing", true);
  finish_replay(s, "stopped");
}

// Recorded hero position at time t (nearest sample). Caller holds s.m.
inline const HeroSample* recorded_at(const State& s, int64_t t) {
  if (s.hero.empty()) return nullptr;
  auto it = std::lower_bound(s.hero.begin(), s.hero.end(), t,
                             [](const HeroSample& h, int64_t v) { return h.t_us < v; });
  if (it == s.hero.end()) return &s.hero.back();
  if (it != s.hero.begin() && t - (it - 1)->t_us < it->t_us - t) --it;
  return &*it;
}

// The replay's synthetic pad: the recorded state for "now".
class ReplayDriver final : public rex::input::InputDriver {
 public:
  ReplayDriver(rex::ui::Window* window, size_t z) : rex::input::InputDriver(window, z) {}
  X_STATUS Setup() override { return X_STATUS_SUCCESS; }
  void EnumerateDevices(std::vector<rex::input::DeviceInfo>& out_devices) override {
    rex::input::DeviceInfo info;
    info.id = kId;
    info.name = "Input replay";
    info.guid = "fable2-input-replay";
    info.synthetic = true;  // routed to player 1
    out_devices.push_back(info);
  }
  X_RESULT GetDeviceState(rex::input::DeviceId id, rex::input::X_INPUT_STATE* st) override {
    if (id != kId) return X_ERROR_DEVICE_NOT_CONNECTED;
    PadEvent e;
    State& s = S();
    if (s.mode.load(std::memory_order_relaxed) == kPlaying) {
      std::lock_guard<std::mutex> l(s.m);
      if (s.mode == kPlaying && !s.pads.empty()) {
        const int64_t t = elapsed_us(s);
        while (s.cursor + 1 < s.pads.size() && s.pads[s.cursor + 1].t_us <= t) ++s.cursor;
        if (s.pads[s.cursor].t_us <= t && t <= s.end_us) e = s.pads[s.cursor];
      }
    }
    if (!have_prev_ || !prev_.same_input(e)) {
      ++packet_;
      prev_ = e;
      have_prev_ = true;
    }
    st->packet_number.set(packet_);
    st->gamepad.buttons.set(e.buttons);
    st->gamepad.left_trigger = e.lt;
    st->gamepad.right_trigger = e.rt;
    st->gamepad.thumb_lx.set(e.lx);
    st->gamepad.thumb_ly.set(e.ly);
    st->gamepad.thumb_rx.set(e.rx);
    st->gamepad.thumb_ry.set(e.ry);
    return X_ERROR_SUCCESS;
  }
  X_RESULT GetDeviceCapabilities(rex::input::DeviceId id, uint32_t,
                                 rex::input::X_INPUT_CAPABILITIES* caps) override {
    if (id != kId) return X_ERROR_DEVICE_NOT_CONNECTED;
    *caps = rex::input::X_INPUT_CAPABILITIES{};
    caps->type = rex::input::XINPUT_DEVTYPE_GAMEPAD;
    caps->sub_type = 0x05;
    return X_ERROR_SUCCESS;
  }
  X_RESULT SetDeviceVibration(rex::input::DeviceId id, rex::input::X_INPUT_VIBRATION*) override {
    return id == kId ? X_ERROR_SUCCESS : X_ERROR_DEVICE_NOT_CONNECTED;
  }
  X_RESULT GetDeviceKeystroke(rex::input::DeviceId id, uint32_t, rex::input::X_INPUT_KEYSTROKE*) override {
    return id == kId ? X_ERROR_EMPTY : X_ERROR_DEVICE_NOT_CONNECTED;
  }

  // Must not collide with the other synthetic pads (keyboard 1<<60, remote
  // 1<<61, console 1<<62 + 0..3).
  static constexpr rex::input::DeviceId kId{1ull << 59};

 private:
  uint32_t packet_ = 0;
  PadEvent prev_{};
  bool have_prev_ = false;
};

// --- game thread -------------------------------------------------------------

// True when a hero sample is due (cheap; called many times per frame).
inline bool wants_hero() {
  State& s = S();
  return s.mode.load(std::memory_order_relaxed) != kIdle && Clock::now() >= s.next_hero;
}

inline void on_hero(float x, float y, float z, float qz, float qw) {
  State& s = S();
  std::lock_guard<std::mutex> l(s.m);
  if (s.mode == kIdle) return;
  s.next_hero = Clock::now() + kHeroEvery;
  HeroSample h{elapsed_us(s), x, y, z, qz, qw};
  if (s.mode == kRecording) {
    s.hero.push_back(h);
    return;
  }
  s.played.push_back(h);
  if (const HeroSample* r = recorded_at(s, h.t_us)) {
    const double d = std::sqrt(double(h.x - r->x) * (h.x - r->x) + double(h.y - r->y) * (h.y - r->y) +
                               double(h.z - r->z) * (h.z - r->z));
    s.last_drift = d;
    if (d > s.max_drift) s.max_drift = d, s.max_drift_at = h.t_us;
  }
}

// Once per game-thread tick: F10 ends a recording; a replay ends on its own.
inline void game_tick() {
  State& s = S();
  const int mode = s.mode.load(std::memory_order_relaxed);
  if (mode == kIdle) return;
#ifdef _WIN32
  static bool prev = false;
  const bool down = (GetAsyncKeyState(VK_F10) & 0x8000) != 0;
  const bool edge = down && !prev;
  prev = down;
  if (edge && mode == kRecording) {
    DWORD pid = 0;
    GetWindowThreadProcessId(GetForegroundWindow(), &pid);
    if (pid == GetCurrentProcessId()) stop_recording();
    return;
  }
#endif
  if (mode == kPlaying) {
    std::lock_guard<std::mutex> l(s.m);
    if (s.mode == kPlaying && elapsed_us(s) > s.end_us + kPlayTailUs) finish_replay(s, "finished");
  }
}

inline bool command(const std::vector<std::string>& w) {
  if (w.empty()) return false;
  std::string name = w[0];
  for (auto& c : name) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  if (name != "rec" && name != "play") return false;
  const std::string arg = w.size() > 1 ? w[1] : "";
  if (name == "rec") {
    if (arg == "stop") return stop_recording(), true;
    if (arg == "start" && w.size() > 2 && valid_name(w[2])) return start_recording(w[2]), true;
    return out("rec", "usage: rec start <name> | rec stop  (names: letters, digits, - and _)", true), true;
  }
  if (arg == "stop") return stop_replay(), true;
  if (valid_name(arg)) return start_replay(arg), true;
  return out("play", "usage: play <name> | play stop", true), true;
}

inline const bool kRegistered = (fable2::console::ExtraCommands() = &command, true);

}  // namespace fable2::replay
