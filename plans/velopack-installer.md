# Velopack installer and auto-update

Goal: players download one small `ProjectSparrow-Setup.exe` from the fork's
GitHub releases. It installs the launcher and the recompiled game, asks for
their own Fable 2 GOTY ISO once, and from then on updates itself in place.
Nothing distributed ever contains game content (no ISO, no `default.xex`,
no `data/` from the disc).

## Constraints found in the code

- Velopack installs to `%LOCALAPPDATA%\ProjectSparrow\current\` and **replaces
  `current\` on every update**; uninstall deletes the whole
  `%LOCALAPPDATA%\ProjectSparrow\` folder.
- Today everything lives next to `fable_2.exe`:
  - game content: the launcher extracts the ISO into `AppContext.BaseDirectory`
    (`MainWindow.xaml.cs`, `outDir = AppContext.BaseDirectory`)
  - saves/cache: `Fable2App::OnConfigurePaths` forces `exe_dir/saves` and
    `exe_dir/cache` unconditionally (`src/core/fable_2_app.h`), so even
    `--user_data_root` / `--cache_root` are ignored
  - `fable2_config.toml` and `fable_2.toml`: loaded from `exe_dir`
  - logs: `current_path()/logs` (SDK `logging.cpp`)
  - shipped Lua scripts go into `<game>/data/scripts/recomp/`
  If installed as-is, the first update would wipe the player's game data, saves
  and settings.
- The game can't be built in CI (codegen needs `default.xex`), so releases are
  packed and uploaded from the developer PC.
- `UpdateChecker.cs` still points at `himdo/Fable-2-Recomp`.

## Target layout

```
%LOCALAPPDATA%\ProjectSparrow\              <- Velopack owned, wiped on update/uninstall
  Update.exe
  current\  Fable2Launcher.exe fable_2.exe *.dll fable2_build.json
            defaults\fable2_config.toml  scripts\recomp\*.lua
  packages\ (cached full/delta nupkgs)

%LOCALAPPDATA%\ProjectSparrow-Data\          <- ours, never touched by Velopack
  launcher.json        (launcher settings, chosen game folder)
  fable2_config.toml   fable_2.toml
  saves\  cache\  logs\
  game\   default.xex data\ ...            <- default game folder; player may pick
                                              another drive (7 GB)
```

Not Documents: the existing comment says the SDK's Documents-based user dir
caused save corruption (likely OneDrive sync). LocalAppData isn't synced.

## Phase 1: game honours a user root (C++)

- New fable2 cvar `user_root` (string, default empty = exe dir, keeps the
  current portable/dev layout working unchanged).
- `OnConfigurePaths`: `saves/`, `cache/` under `user_root`; set
  `paths.config_path = user_root/fable_2.toml`; load `fable2_config.toml`
  from `user_root`.
- Logs: launcher sets the working directory to the user root, so the SDK's
  `current_path()/logs` lands there with no SDK change.
- Release build + launch with and without `--user_root` to confirm saves,
  config and shader cache go where expected.

## Phase 2: launcher uses the data folder

- `DataPaths` class: resolves the data root, game folder (from launcher.json,
  default `Data\game`), saves, configs.
- Extract from ISO writes to the game folder (picker defaults to `Data\game`).
- Launch: `--game_data_root=<game> --user_root=<data>`, working dir `<data>`.
- Before each launch, sync `current\scripts\recomp\*.lua` into
  `<game>\data\scripts\recomp\` (the existing dir.manifest self-heal lists them).
- First run seeds `fable2_config.toml` from `current\defaults\` if missing.
  Updated defaults merge in via the existing non-destructive writer, so new keys
  appear and the player's values stay.
- Migration: if an old portable folder is found (or picked), offer to
  copy its `saves\`, configs and game content into the data folder.

## Phase 3: Velopack in the launcher

- NuGet `Velopack`; custom `Main` calling `VelopackApp.Build().Run()` first
  (WPF needs `App.xaml` switched off auto-Main).
- `UpdateManager(new GithubSource("https://github.com/gitgudscrub/Fable-2-Recomp", null, false))`.
- On start: check, download in the background, show "Update ready - restart".
  Never apply while `fable_2.exe` is running; `ApplyUpdatesAndRestart` only
  from the launcher with the game closed. If the player closes without
  restarting, the update is applied on exit (`WaitExitThenApplyUpdates`).
- Delete `UpdateChecker.cs`; read the version from `UpdateManager.CurrentVersion`.
- Running outside Velopack (dev builds, old zips): `IsInstalled == false` -> no
  update UI, all else works.
- Uninstall hook: leave `ProjectSparrow-Data` alone (saves + 7 GB of game data);
  show where it is so the player can delete it.

## Phase 4: packaging and release

`tools/package_release.py` gains `--velopack`:
1. Stage the exact allow-list (`BUILD_FILES`, launcher, defaults, Lua) into
   `out/dist/stage`. Add a guard that fails if anything named `*.iso`,
   `default.xex`, `*.xex`, or a disc `data/` path other than
   `data/scripts/recomp` ends up there.
2. `vpk download github --repoUrl <fork>` (previous release, for deltas).
3. `vpk pack --packId ProjectSparrow --packVersion <tag> --packDir stage
   --mainExe Fable2Launcher.exe --icon assets/app-icon.ico`
   (+ `--signParams` once signing exists).
4. `vpk upload github --repoUrl <fork> --publish --releaseName v<tag>
   --token %GITHUB_TOKEN%`.
- Versions must be clean SemVer tags (`v1.7.0`); refuse `git describe` output
  with a commit suffix for a published release.
- Launcher stops being single-file (Velopack ships the folder; deltas are
  smaller); stays self-contained so players need no .NET install.
- Keep the plain zip for people who want portable; it keeps working via the
  exe-dir default.

## Phase 5: docs and tests

- README "Install" section: download Setup, pick ISO, done. Updating section
  becomes "automatic".
- Tests: `DataPaths` resolution, script sync, config seeding/merge,
  package guard (stage with a fake `default.xex` must fail).

## Decisions

- **Name**: Project Sparrow (the hero's nickname in Fable II). Subtitle
  "Fable II, recompiled for Windows". Velopack packId `ProjectSparrow`.
  An unrelated Steam game uses the same name; accepted, as this is shared
  privately. Design: storybook scene launcher, mockup
  https://claude.ai/artifact/JkYafv1B7qLhG8Bkz996TP.
- **Update source**: GitHub Releases on the public fork
  (gitgudscrub/Fable-2-Recomp); release builds are publicly downloadable.

- **Data folder**: default `%LOCALAPPDATA%\ProjectSparrow-Data`, with a
  "Change folder" button in the launcher (moves game data/saves, or just
  repoints for game data on another drive).
- **Channels**: `stable` and `beta`, player-switchable in the launcher.
  - Release: `vpk pack --channel stable|beta`; both upload to the same fork
    (beta as GitHub pre-releases, `vpk upload github --pre`).
  - Launcher: channel stored in `launcher.json`; `UpdateManager` built with
    `UpdateOptions { ExplicitChannel = channel, AllowVersionDowngrade = true }`
    so switching beta -> stable installs the latest stable even if older.
  - Saves are forward-compatible-only risk: warn when switching beta -> stable.
- **Code signing**: pending (see below). Until then, ship unsigned but add our
  own update signature:
  - ed25519 key pair; private key stays on the release PC (never in repo).
  - `package_release.py` signs each `releases.<channel>.json` + nupkg hashes
    into a `.sig` uploaded as a release asset.
  - Launcher embeds the public key and refuses to apply an update whose
    signature doesn't verify. Free, and it means a hijacked GitHub account
    can't push code to players.
  - Authenticode (SmartScreen) can be added later via `vpk --signParams` /
    `--azureTrustedSignFile` without changing anything else.
