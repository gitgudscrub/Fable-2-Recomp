// mp_errors.h - multiplayer: the co-op problems a player can see, each with a
// code (CO-1xx) they can quote when reporting it. The game shows the message
// in an on-screen notice, the window title and the log, and writes it to
// mp_status.txt for the launcher. docs/COOP_ERRORS.md lists the same codes
// with what causes each one; keep the two in step (codes are never reused).
// No game, SDK or winsock headers, so tests/native can check the table.
#pragma once

#include <cstdio>
#include <string>

namespace fable2::net {

enum class CoopError : int {
  None = 0,
  BadCode = 101,         // relay: no session with that code
  SessionFull = 102,     // relay: session has 4 players
  ServerFull = 103,      // relay: too many sessions/players
  HostVersion = 104,     // relay: the host runs another game version
  ServerVersion = 105,   // relay: does not know this game version
  NoAnswer = 106,        // nothing back from the relay for a while
  BadAddress = 107,      // relay name does not resolve / malformed
  SessionLost = 108,     // the relay lost the session and the host never came back
  NetworkError = 109,    // WSAStartup / socket / bind failed
  UnknownRefusal = 110,  // relay refused for a reason this version does not know
  NoMode = 111,          // co-op on but neither host nor join (launcher bug)
};

struct CoopErrorInfo {
  CoopError code;
  const char* title;    // short, for the notice heading and window title
  const char* message;  // what happened and what the player can do
};

inline constexpr CoopErrorInfo kCoopErrors[] = {
    {CoopError::BadCode, "Invite code not found",
     "No co-op game has that invite code. Check the code, or ask the host to send it again."},
    {CoopError::SessionFull, "Game is full",
     "That co-op game already has 4 players."},
    {CoopError::ServerFull, "Co-op server busy",
     "The co-op server is full right now. Try again in a few minutes."},
    {CoopError::HostVersion, "Different game versions",
     "The host has a different version of the game. Both of you need the latest update from the launcher."},
    {CoopError::ServerVersion, "Server needs an update",
     "The co-op server doesn't support this version of the game yet. Try again later."},
    {CoopError::NoAnswer, "Co-op server not answering",
     "The co-op server isn't answering. Check your internet connection. The game keeps trying."},
    {CoopError::BadAddress, "Co-op server not found",
     "The co-op server's address can't be found. Check your internet connection and the server on the Co-op page."},
    {CoopError::SessionLost, "Co-op game ended",
     "The connection to the co-op game was lost and the host didn't come back."},
    {CoopError::NetworkError, "Network blocked",
     "The game couldn't open a network connection. Restart the game; if it keeps happening, check your firewall."},
    {CoopError::UnknownRefusal, "Update needed",
     "The co-op server turned the game away for a reason this version doesn't know. Update from the launcher."},
    {CoopError::NoMode, "Co-op not set up",
     "Co-op is on, but neither hosting nor joining was chosen. Pick one on the launcher's Co-op page."},
};

inline const CoopErrorInfo* coop_error_info(CoopError e) {
  for (const CoopErrorInfo& i : kCoopErrors)
    if (i.code == e) return &i;
  return nullptr;
}

// "CO-104"
inline std::string coop_error_code(CoopError e) {
  char buf[16];
  std::snprintf(buf, sizeof(buf), "CO-%03d", int(e));
  return buf;
}

}  // namespace fable2::net
