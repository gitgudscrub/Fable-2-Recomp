# Co-op error codes

When co-op goes wrong, the game shows a notice at the top of the screen with a
code like **CO-104**. The code is also shown in the window title and the game's
log, and in the launcher's Co-op page and tray pop-up (when the launcher is
waiting in the tray). If you report a problem, please include the code.

| Code | What you see | What it means | What to do |
|------|--------------|---------------|------------|
| CO-101 | Invite code not found | The co-op server has no game with that code. The code may be mistyped, or the host closed their game. | Check the code, or ask the host for a new one. |
| CO-102 | Game is full | That game already has 4 players. | Wait for someone to leave. |
| CO-103 | Co-op server busy | The server has too many games or players right now. | Try again in a few minutes. |
| CO-104 | Different game versions | The host's game version is different from yours. | Both players update from the launcher. |
| CO-105 | Server needs an update | Your game is newer than the co-op server. | Try again later (the server gets updated). |
| CO-106 | Co-op server not answering | Nothing came back from the server for 15 seconds. The game keeps trying, and the notice changes to "Co-op connected" when it gets in. | Check your internet connection. |
| CO-107 | Co-op server not found | The server's name couldn't be looked up, or the server box on the Co-op page is wrong. | Check your internet connection and the Co-op page's server box (leave it on the default). |
| CO-108 | Co-op game ended | You were in a game, the server lost it (e.g. it restarted), and the host didn't come back within a minute. | Ask the host to start a new game and send the new code. |
| CO-109 | Network blocked | The game couldn't open a network connection. | Restart the game. If it keeps happening, check that your firewall allows the game. |
| CO-110 | Update needed | The server turned the game away for a reason this version doesn't know. | Update from the launcher. |
| CO-111 | Co-op not set up | Co-op was started with neither Host nor Join chosen. | Pick Host or Join on the Co-op page. |

## For developers

- The table lives in `src/net/mp_errors.h`; `tests/native/test_mp_errors.cpp`
  checks that every code there is also listed here. Codes are never reused.
- The game writes the current state to `mp_status.txt` in its working folder:
  `ok`, or `error CO-1xx` followed by the title and message lines.
- The log line is `[mpnet] co-op problem CO-1xx: <title> - <message>`.
- Relay refusal reasons: 1 bad code (CO-101, or CO-108 after being in a
  session), 2 full (CO-102), 5 server full (CO-103), 6 host version (CO-104),
  7 unsupported game version (CO-105); any other reason gives CO-110.
- Games before beta.10 don't show these notices: they only write the refusal to
  the log, and a beta.8 game turned away for a version mismatch keeps retrying.
