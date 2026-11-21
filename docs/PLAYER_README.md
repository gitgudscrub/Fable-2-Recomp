# Project Sparrow

Fable II, recompiled for Windows. Project Sparrow is an unofficial, fan-made
project. It is not affiliated with or endorsed by Microsoft or Xbox Game Studios.

You need your own Fable II Game of the Year disc image (`.iso`). No game files
come with Project Sparrow: the launcher copies them from your disc image.

## Getting started

1. Open **Project Sparrow** (the desktop or Start menu shortcut, or
   `Fable2Launcher.exe` in a portable copy).
2. Click the gold seal (**Choose disc image**) and pick your `.iso`. It's checked
   against the supported versions, then the game files are copied into your data
   folder (about 7 GB).
3. Pick an edition and click **Play**.

Supported discs: Fable II Game of the Year for USA/Europe, Germany, France,
Italy, Russia and Spain.

## Editions

- **Original**: 30 fps at 720p, as on the Xbox 360.
- **Enhanced**: 60 fps at 1440p, sharper textures and more detailed models.
  Press **F8** in game to switch between the Modern and Classic look.
- **Project Sparrow** (preview): Enhanced with new lighting: light from the sky,
  soft highlights, and lamps that light the walls and ground around them.
  Up to 6% slower than Enhanced.

Every setting can also be changed on its own under **Settings** and **Controls**.

**Compare** (on the main screen) shows the same places side by side in the
Classic and Modern look. Drag across the picture to slide between them.

## Controls

A controller works straight away. On keyboard and mouse the default keys are:

| Key | Does |
|---|---|
| Left mouse | X |
| Right mouse | Y |
| Middle mouse / B | B |
| Shift / E | A |
| W A S D | Move |
| Mouse | Camera |
| Q / R | Left / right trigger |
| Z / Tab | Left / right shoulder |
| Arrow keys | D-pad |
| Escape | Pause |
| M | Back |

Change them under **Controls** in the launcher.

## Co-op (experimental)

Up to 4 players. Each of you plays your own game and sees the others in your
world, wearing their own clothes. The host's enemies show up for everyone, so
you can fight side by side; hits from every player count, and everyone nearby
gets the kill and its experience. Fights get tougher the more of you there are.
Shared quests and loot come later.

Open **Co-op** in the launcher:

- **Friends**: make an account to add friends by username, see when they're
  playing and invite them with one click.
- **Play together**: one player picks **Host**, the others pick **Join** and
  type the 6-letter invite code shown in the host's game window title.
  Everyone needs the same version of Project Sparrow.

## Your files

`%LOCALAPPDATA%\ProjectSparrow-Data` holds your saves, settings, logs and the
game files. **Help → Change data folder** moves it, for example to a bigger
drive. Uninstalling Project Sparrow leaves this folder alone.

Your saves are backed up each time you click **Play** (only when something
changed). The last 5 backups are kept in `save-backups` inside the data folder;
**Help → Open save folder** opens your saves.

## Updates

Installed copies update themselves: when an update is ready the seal reads
**Restart / to update**. Updates never touch your saves, settings or game files.
Choose **Stable** or **Beta** under **Updates**. Portable copies don't update.

## Problems?

- **Help → Check game files** compares your game files with the original disc.
- **Help → Report a problem** collects your logs and settings for a bug report.
  Nothing is uploaded; you attach the zip yourself.
- If the game crashes, a crash report is saved to `crash-reports` in the data
  folder and the launcher offers to start a GitHub issue. Your saves are never
  in it.
- **Help → Record performance logs** (on by default) records frame rate,
  stutters and slow shader builds so problems can be found and fixed. The logs
  stay on your PC until you send them.
- Co-op problems show a notice at the top of the screen with a code like
  **CO-104**. Please include the code when you report it. All the codes:
  https://github.com/gitgudscrub/Fable-2-Recomp/blob/master/docs/COOP_ERRORS.md
- Ask on the Discord: https://discord.gg/8TQUZpPNeR

## Credits

Based on the Fable II recompilation by himdo
(https://github.com/himdo/Fable-2-Recomp), built on the ReXGlue SDK.
Source: https://github.com/gitgudscrub/Fable-2-Recomp.
Fonts: IM FELL English and Alegreya Sans, SIL Open Font License (see `licenses`).
