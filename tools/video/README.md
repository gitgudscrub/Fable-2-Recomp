# Comparison videos

Play a run once; the other editions replay your exact input, so the clips line
up for side-by-side shots.

1. **Record** (you play):

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\video\record_run.ps1 -Name lake1 -Region BowerLake -Hour 15
   ```

   The game boots, starts a New Game, jumps to the region and makes the hero an
   adult in the swashbuckler outfit. When **Recording** shows at the top of the
   screen, play (keyboard and mouse or a controller). Press **F10** to stop.
   Exploring replays well; fights don't (enemies act differently each time).

2. **Film** each edition (hands-free, about 4 minutes per edition plus the run):

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\video\replay_run.ps1 -Name lake1
   ```

   The game window stays on top while it films. Each replay reports how far the
   hero drifted from your path (usually under 1 m). Clips: `out\video\lake1\`.

3. **Cut** the videos:

   ```
   python tools/video/make_video.py lake1
   ```

   Writes `sequence.mp4` (the editions one after another), `split.mp4` (side by
   side, same moment) and one captioned clip per edition.

Under the hood: the `rec` / `play` console commands (`src/core/fable2_replay.h`)
record player 1's merged pad state with timestamps and replay it through their
own synthetic pad. Recordings live in `console\replays\`. Needs ffmpeg
(`winget install Gyan.FFmpeg`) and an NVIDIA GPU (or `make_video.py --cpu`).
Remade models are not loaded: the dev build plays from the plain game files.
