// mp_session_notice.h - tells the app when the co-op session code is known, so
// it can show the invite code in the window title. Kept free of winsock so the
// app header (which includes windows.h first) can include it.
#pragma once

#include <functional>
#include <mutex>
#include <string>

namespace fable2::net {

struct SessionNotice {
  std::mutex m;
  std::function<void(const std::string&)> listener;
  std::string code;  // last code seen, for a listener set late
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
