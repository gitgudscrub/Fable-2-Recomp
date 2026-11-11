# Modern textures: pack download

The Modern graphics texture pack (AI-upscaled and re-imagined textures) is
too large to ship with the game and takes hours to build, so the launcher
downloads a pre-built copy in parts. Every file in the pack is encrypted
with a key derived from the game texture it replaces, so the download is
useless without the player's own game data and the pack is never a loose
copy of the game's art (see `tools/keyed_pack.py`).

This page is the contract between the pack build (this repo's tools) and
the launcher's download screen.

## Producing a pack release

```
python tools/keyed_pack.py encrypt <textures> --out <textures_keyed>
python tools/keyed_pack.py verify  <textures> <textures_keyed>
python tools/keyed_pack.py split   <textures_keyed> --out <dist> --version N
dotnet run --project tools/sparrow-sign -- sign <dist>/manifest.json
```

`<textures>` is the game's textures folder (`dump/` + `replace/`). The
result in `<dist>` is 16 zip parts, `manifest.json` and
`manifest.json.sig`. Publish all of them as the assets of a GitHub release
on the public fork tagged `textures-v<N>`. The pack has its own tag so a
game release never re-uploads 6 GB, and a game release never needs a pack
release.

Parts are split by the first hex digit of the texture hash and written
deterministically (stored, sorted, fixed timestamps). A part whose
textures did not change between versions is byte-identical, and its
`sha256` in the manifest is the same, so the launcher only downloads the
parts that changed.

## manifest.json

```json
{
  "pack": "modern-textures",
  "version": 1,
  "game_profile": "goty-us-eu",
  "created": "2026-11-11",
  "file_format": "F2TXPK01",
  "install_dir": "textures/replace",
  "total_bytes": 6458842472,
  "file_count": 4914,
  "parts": [
    {
      "name": "modern-textures-v1-part00.zip",
      "size": 411725198,
      "sha256": "…64 hex…",
      "files": 338,
      "url": "https://github.com/gitgudscrub/Fable-2-Recomp/releases/download/textures-v1/modern-textures-v1-part00.zip"
    }
  ]
}
```

- `game_profile` is the disc manifest the pack was made from
  (`constants/disc-manifests/`). Offer the pack only when the player's
  game files passed the check for that profile. A pack keyed to other
  game data would not open (every file logs "does not open with this
  game's texture" and the original texture shows).
- `install_dir` is relative to the data folder
  (`%LOCALAPPDATA%\ProjectSparrow-Data`). Each zip holds flat
  `<HASH>.edds` entries; unpack them straight into that folder.
- `manifest.json.sig` is the same ECDSA signature as the update packages
  (`UpdateSignature.Verify` with file name `manifest.json`). Refuse an
  unsigned or mis-signed manifest; the parts are then covered by their
  `sha256`.

Finding the latest pack: list the fork's releases and take the highest
`textures-v<N>` tag, or fetch
`releases/download/textures-v<N>/manifest.json` for a known N.

## Launcher flow

1. After "Check game files" passes for `game_profile`, offer
   "Modern textures: 6.2 GB in 16 parts" with Download and Skip. The game
   runs without the pack (Classic textures).
2. Download parts a few at a time, each with its own progress bar.
   Resume with HTTP range requests; verify `sha256` and `size` before
   unpacking; unpack into a temporary folder under the data folder and
   move the files into `install_dir` when the part is complete, so the
   game never opens a half-written file. Delete the zip afterwards.
3. Keep a state file in the data folder, for example
   `textures/pack-state.json`: pack version and, per part name, the
   `sha256` that was installed. Reopening the launcher resumes with the
   parts not yet in the state; a newer manifest re-downloads only the
   parts whose `sha256` differs.
4. **Modern textures stay off until the pack is complete.** While any
   part is missing, write `texture_pack = false` in `fable2_config.toml`
   (the pack is read once at game start and a half pack shows a patchy
   mix of upscaled and original textures). When the last part is in,
   set `texture_pack = true`. The player can still flip F8 in game at
   any time.
5. Uninstall / "Remove textures": delete `install_dir` and the state
   file, set `texture_pack = false`.

## Game side

- The texture cache indexes `textures/replace` once at startup; files
  added while the game runs take effect at the next launch.
- `.edds` files are decrypted on the texture loader thread; a file that
  fails its integrity check leaves the original texture in place and
  logs one warning. Nothing in the pack can crash the game or run code.
- The pack only shows at an internal resolution scale of 2 or 3 (the
  launcher's resolution setting, `--resolution_scale`); at 1x the detail
  is not visible, so weaker PCs may prefer to skip it.
