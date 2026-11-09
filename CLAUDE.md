\# Fable 2 Recomp (fork of himdo/Fable-2-Recomp)



Static recompilation of Fable II (Xbox 360) to a native Windows exe using

the ReXGlue SDK. Goals: stable/fast PC build -> custom multiplayer ->

(later) AI texture upscaling.



\## Build

\- `build.cmd -release fable\_2` for any performance or multiplayer testing.

&#x20; Debug builds are drastically slower and unusable for gameplay.

\- Run `python tools/check\_manifest\_collisions.py` before committing

&#x20; manifest name changes.

\- Full clean build compiles \~291 generated TUs. Do not clean unless asked.



\## Rules

\- NEVER commit game files (default.xex, data/, ISOs), saves, or logs.

\- Never edit files in `generated/` by hand; it is codegen output.

\- Manifest function names must not collide with XAPI exports

&#x20; (see "Function naming rule" in README).

\- Runtime config lives in fable2\_config.toml; add new settings in

&#x20; src/core/fable2\_config.{h,cpp} AND config/fable2\_config.toml.

\- Guest .text is never executed; code patches are mid-asm hooks only.



\## Layout

\- src/core: config, patches, hooks, func trace, F5 Lua runner

\- src/input: keyboard gamepad, remote control (Debug only)

\- src/diagnostics: fps probe, frame capture

\- FABLE2\_LUA\_API.md: \~25k line Lua API dump. Grep it, never read it whole.



\## Multiplayer project

\- Network code goes in src/net/ (new). Separate thread, ticked from the

&#x20; MainRenderLoop hook, message queue between them.

\- Network messages must be typed and validated. NEVER route network data

&#x20; into Lua RunScript or any arbitrary-code path.

\- Tick-rate patches change sim timing: use timestamps, not frame counts.

\- Testing: two Release instances on one PC, separate folders, shared

&#x20; --game\_data\_root.

