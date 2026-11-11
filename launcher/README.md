# Project Sparrow launcher

A .NET 8 WPF launcher for the Fable II recompilation. The design reference is
[design/mockup.html](design/mockup.html): the window is a storybook night
scene with a centred title, a gold seal as the main button, an edition ribbon
at the bottom, and a parchment page that turns in from the right edge for
Settings, Controls, Updates and Help.

## Where files live

The install folder (next to `Fable2Launcher.exe` and `fable_2.exe`) is
replaced by every update, so nothing the player owns is kept there.

```
%LOCALAPPDATA%\ProjectSparrow-Data\        home folder, never moves
  launcher.json                            data folder, game folder, channel, edition, theme
  fable_2.toml  launcher-settings.toml     graphics settings
  fable2_config.toml                       keys, mouse, patches
  saves\  cache\  logs\
  game\    default.xex  data\ ...          copied from the player's own disc image
```

- **Change data folder** (Help) moves everything except `launcher.json` to
  another folder, for example a bigger drive. It must be an empty folder.
- **Use game files from another folder** points at an existing extracted copy
  (`default.xex` + `data`) instead of copying.
- The game is started with `--game_data_root=<game folder>` and
  `--user_root=<data folder>`, with the data folder as working directory.
- Before each launch the shipped Lua scripts in
  `<install>\data\scripts\recomp\` are copied into the game folder (changed
  files only).
- `PROJECT_SPARROW_HOME` overrides the home folder: useful for running two
  copies side by side (multiplayer testing) or testing against a scratch
  folder.
- First run after the old portable layout (game files and saves beside the
  launcher): the launcher uses those game files where they are and copies
  `saves\` and settings into the data folder. Nothing is deleted.

## Disc images

The seal reads **Choose disc image** until game files exist. The chosen `.iso`
is read in two phases:

1. **`default.xex` only**, extracted under a temporary name and SHA-256
   checked against the version catalogue (`GameCompatibilityInspector.CheckHash`).
2. **The rest of the disc**, only if the hash is known. An unknown hash pauses
   with the reason and two buttons: **Copy it anyway** or **Stop** (which
   deletes the temporary XEX, leaving any earlier `default.xex` untouched).

The GDFX/ISO 9660 readers come from the shared `X360Extract` library
(`tools/x360extract/lib`), so the output matches the standalone tool.

## Modern textures

Settings > Modern textures downloads the pre-built texture pack (about
6 GB) in 16 parts with a progress bar each, pausable and resumable, from
the fork's `textures-v<N>` GitHub release. The manifest is signed with the
release key and every part is checksummed; parts unpack into a temporary
folder and move into `textureseplace` whole, so the game never sees a
half-written file. `[graphics] texture_pack` in `fable2_config.toml` stays
`false` until the last part is in. `PROJECT_SPARROW_TEXTURES=<folder>`
points the download at a local folder holding `manifest.json`, its `.sig`
and the parts, and `--preview=textures` starts it on launch. Format and
flow: [docs/TEXTURE_PACK_DOWNLOAD.md](../docs/TEXTURE_PACK_DOWNLOAD.md).

## Editions

| Edition | Sets |
|---|---|
| Original | 720p, 1× scale, game texture filtering, no FXAA, 30 fps, motion blur on |
| Enhanced | 1440p, 2× scale, 16× filtering, FXAA, 60 fps, motion blur off |
| Experimental | 1440p, 4× scale, 16× filtering, FXAA, unlimited fps, motion blur off, faster world and animation ticks |

Settings an edition doesn't name keep the player's value. Changing anything an
edition sets shows **Custom changes** on the ribbon. Settings are written when
the page closes and before launch; unknown keys in every file are preserved
and each file gets a one-time `.launcher-backup` before its first write.

## Themes

**Night** (darkest; the page becomes dark leather), **Dusk** (default) and
**Day** (sunlit scene, sparrows instead of fireflies). Switch with the three
buttons in the top-left corner or **Settings → Appearance**; the choice is
saved in `launcher.json`. Colours live in `Themes.cs`: the brushes in
`MainWindow.xaml` are the Dusk values and are read as `DynamicResource`, so a
new colour must be added in both places.

## Updates

Installed copies (Velopack, `%LOCALAPPDATA%\ProjectSparrow\`) check
https://github.com/gitgudscrub/Fable-2-Recomp releases on start and download
in the background. Stable sees full releases; Beta also sees pre-releases, and
switching back to Stable installs the newest stable build even if older.

- When an update is ready the seal reads **Restart / to update**, with
  **Play now, update later** underneath. Closing the launcher without playing
  also installs it. Nothing installs while `fable_2.exe` is running, since
  the update replaces the folder it runs from.
- Every package must have a valid `<file>.sig` (see `UpdateSignature.cs` and
  `tools/sparrow-sign`); otherwise it's rejected and the Updates page says so.
- Dev builds and the portable zip aren't installed, so they show no update
  controls.

## Help tools

- **Report a problem**: zips the last 3 logs, settings files (never saves),
  `fable2_build.json` and Windows/GPU details to the desktop, then opens a
  prefilled GitHub issue. Nothing is uploaded automatically.
- **Check game files**: hashes `default.xex` and every `data/` file and compares
  them with the disc's reference list (`constants/disc-manifests/<version>.txt`,
  embedded in the launcher), then lists missing or damaged files and offers to
  copy them again from the disc image. `data/dir.manifest` is skipped (the game
  repairs it itself) and extra files are ignored. Versions without a reference
  list fall back to the version and key-file check. To add a list for another
  version, run `x360extract <iso> --manifest constants/disc-manifests/<version id>.txt`.
- **Open save folder**, **Change data folder**, **Clear shader cache**
  (deletes `cache\shaders` only).

## Building

From the repository root:

```cmd
build.cmd launcher                 self-contained single file (default; ships with .NET)
build.cmd launcher-dev             framework-dependent (needs .NET installed)
dotnet run --project tests/Fable2.Launcher.ConfigTests -c Release
```

`--page=settings|controls|updates|help` opens the parchment page on start
(handy for screenshots). `--preview=update-ready` shows the update-ready seal in a dev build.
`--preview=check-files` opens Help and runs Check game files straight away.

Fonts: IM FELL English and Alegreya Sans, embedded as resources under the SIL
Open Font License (`Fonts/OFL-*.txt`, shipped in the release zip's
`licenses/`). The icon is the project-owned emblem; see
[asset provenance](../assets/README.md).
