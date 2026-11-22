"""Cut the clips from replay_run.ps1 into comparison videos.

Reads out/video/<name>/<edition>.mp4 + .json, trims each clip to the replay
(the json's lead_s and length_s) and writes, next to them:

  <edition>_cut.mp4   the run, with the edition's name in the corner
  sequence.mp4        the editions one after another
  split.mp4           the editions side by side in vertical strips, same moment

Needs ffmpeg (winget install Gyan.FFmpeg) and an NVIDIA GPU for h264_nvenc
(pass --cpu to encode with libx264 instead).

  python tools/video/make_video.py lake1 [--editions original,enhanced,sparrow] [--cpu]
"""
import argparse
import glob
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LABELS = {"original": "Original", "enhanced": "Enhanced", "sparrow": "Project Sparrow"}
FONT = "C\\:/Windows/Fonts/segoeuib.ttf"


def find_ffmpeg():
    found = shutil.which("ffmpeg")
    if found:
        return found
    pattern = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Microsoft", "WinGet", "Packages",
                           "Gyan.FFmpeg*", "*", "bin", "ffmpeg.exe")
    hits = glob.glob(pattern)
    if not hits:
        sys.exit("make_video: ffmpeg not found (winget install Gyan.FFmpeg)")
    return hits[0]


def encoder(cpu):
    if cpu:
        return ["-c:v", "libx264", "-preset", "slow", "-crf", "20", "-maxrate", "16M", "-bufsize", "32M", "-pix_fmt", "yuv420p"]
    return ["-c:v", "h264_nvenc", "-preset", "p6", "-rc", "vbr", "-cq", "24", "-b:v", "12M", "-maxrate", "16M", "-bufsize", "32M", "-pix_fmt", "yuv420p"]


def caption(text, size=44):
    safe = text.replace(":", "\\:").replace("'", "\\'")
    return (f"drawtext=fontfile='{FONT}':text='{safe}':fontsize={size}:fontcolor=white:"
            f"x=40:y=h-th-40:shadowcolor=black@0.7:shadowx=2:shadowy=2")


def run(ffmpeg, args):
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y"] + args
    result = subprocess.run(cmd)
    if result.returncode:
        sys.exit("make_video: ffmpeg failed: " + " ".join(cmd))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("name")
    parser.add_argument("--editions", default="original,enhanced,sparrow")
    parser.add_argument("--cpu", action="store_true", help="encode with libx264 instead of NVENC")
    args = parser.parse_args()

    folder = os.path.join(ROOT, "out", "video", args.name)
    editions = [e for e in args.editions.split(",") if e]
    infos = {}
    for edition in editions:
        meta = os.path.join(folder, edition + ".json")
        if not os.path.exists(meta):
            sys.exit(f"make_video: no {meta} (film it with replay_run.ps1)")
        with open(meta, encoding="utf-8-sig") as f:
            infos[edition] = json.load(f)
    ffmpeg = find_ffmpeg()
    enc = encoder(args.cpu)
    length = min(info["length_s"] for info in infos.values())

    cuts = []
    for edition in editions:
        info = infos[edition]
        out = os.path.join(folder, edition + "_cut.mp4")
        run(ffmpeg, ["-ss", f"{info['lead_s']:.3f}", "-i", info["clip"], "-t", f"{length:.3f}",
                     "-vf", caption(LABELS.get(edition, edition)) + ",fps=60", "-an"] + enc + [out])
        cuts.append(out)
        drift = info.get("drift") or {}
        print(f"{edition}: cut from {info['lead_s']:.2f} s; drift largest {drift.get('max_m', '?')} m")

    # One after another.
    inputs = sum((["-i", c] for c in cuts), [])
    streams = "".join(f"[{i}:v]" for i in range(len(cuts)))
    run(ffmpeg, inputs + ["-filter_complex", f"{streams}concat=n={len(cuts)}:v=1:a=0[v]", "-map", "[v]"] + enc +
        [os.path.join(folder, "sequence.mp4")])

    # Side by side: the middle third of each frame, same moment, each strip labelled.
    parts = []
    for i, edition in enumerate(editions):
        info = infos[edition]
        parts.append(f"[{i}:v]crop=iw/{len(editions)}:ih:iw*{len(editions) - 1}/{2 * len(editions)}:0,"
                     f"{caption(LABELS.get(edition, edition), 36)},fps=60[s{i}]")
    strips = "".join(f"[s{i}]" for i in range(len(editions)))
    graph = ";".join(parts) + f";{strips}hstack=inputs={len(editions)}[v]"
    raw = sum((["-ss", f"{infos[e]['lead_s']:.3f}", "-t", f"{length:.3f}", "-i", infos[e]["clip"]] for e in editions), [])
    run(ffmpeg, raw + ["-filter_complex", graph, "-map", "[v]", "-an"] + enc + [os.path.join(folder, "split.mp4")])
    print("videos in", folder)


if __name__ == "__main__":
    main()
