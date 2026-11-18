// mp_session_notice.h - tells the app when the co-op session code is known, so
// it can show the invite code in the window title. Kept free of winsock so the
// app header (which includes windows.h first) can include it.
#pragma once

#include <cstdint>
#include <functional>
#include <mutex>
#include <string>

#include "mp_errors.h"

namespace fable2::net {

struct SessionNotice {
  std::mutex m;
  std::function<void(const std::string&)> listener;
  std::string code;  // last code seen, for a listener set late
  // Co-op problem shown to the player (None = all fine). serial goes up on
  // every change so the on-screen notice can tell a new problem from an old one.
  std::function<void(CoopError)> error_listener;
  CoopError error = CoopError::None;
  uint32_t error_serial = 0;
};
inline SessionNotice& session_notice() {
  static SessionNotice n;
  return n;
}

// App side: called (on the net thread) with each new session code.
inline void set_session_listener(std::function<void(const std::string&)> fn) {
  std::string code;
  {
    std::lock_guard<std::mutex> l(session_notice().m);
    session_notice().listener = fn;
    code = session_notice().code;
  }
  if (fn && !code.empty()) fn(code);
}

// Net side.
inline void notify_session(const std::string& code) {
  std::function<void(const std::string&)> fn;
  {
    std::lock_guard<std::mutex> l(session_notice().m);
    session_notice().code = code;
    fn = session_notice().listener;
  }
  if (fn) fn(code);
}

// --- co-op problems ---------------------------------------------------------

// App side: called (on the net thread) when the problem changes (None = fixed).
inline void set_error_listener(std::function<void(CoopError)> fn) {
  CoopError e;
  {
    std::lock_guard<std::mutex> l(session_notice().m);
    session_notice().error_listener = fn;
    e = session_notice().error;
  }
  if (fn && e != CoopError::None) fn(e);
}

// Net side. Returns false if that was already the current problem.
inline bool notify_error(CoopError e) {
  std::function<void(CoopError)> fn;
  {
    std::lock_guard<std::mutex> l(session_notice().m);
    if (session_notice().error == e) return false;
    session_notice().error = e;
    ++session_notice().error_serial;
    fn = session_notice().error_listener;
  }
  if (fn) fn(e);
  return true;
}

// For the on-screen notice (any thread).
inline CoopError current_error(uint32_t& serial) {
  std::lock_guard<std::mutex> l(session_notice().m);
  serial = session_notice().error_serial;
  return session_notice().error;
}

inline std::string current_session_code() {
  std::lock_guard<std::mutex> l(session_notice().m);
  return session_notice().code;
}

// Leaving: the SDK ends the process with _Exit when the window closes, which
// skips atexit, so the app calls this from OnClosing to send BYE first.
inline std::function<void()>& leave_hook() {
  static std::function<void()> fn;
  return fn;
}
inline void set_leave_hook(std::function<void()> fn) {
  std::lock_guard<std::mutex> l(session_notice().m);
  leave_hook() = std::move(fn);
}
inline void notify_leaving() {
  std::function<void()> fn;
  {
    std::lock_guard<std::mutex> l(session_notice().m);
    fn = leave_hook();
  }
  if (fn) fn();
}

}  // namespace fable2::net
