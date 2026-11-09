#!/usr/bin/env python3
"""Package a finished Release build.

Zip (portable):   python tools/package_release.py [--version 1.6.0]
Velopack:         python tools/package_release.py --velopack --version 1.8.0 [--channel stable|beta] [--upload]

Only the files listed here are packaged, so game content and local saves stay out.
Velopack builds also run a guard over the staged folder and the packed .nupkg files
that fails on anything that looks like game content (ISO, XEX, disc data/).

--velopack packs into out/velopack/releases/<channel> (with deltas against the last
published release), signs every new package with tools/sparrow-sign and verifies it.
--upload then creates a draft GitHub release, attaches the .sig files, and only then
publishes it, so launchers never see a release without signatures.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPO_URL = "https://github.com/gitgudscrub/Fable-2-Recomp"
REPO = "gitgudscrub/Fable-2-Recomp"
PACK_ID = "ProjectSparrow"
CHANNELS = ("stable", "beta")
BUILD_FILES = ("fable_2.exe", "rexruntime.dll", "rexgpu-xenos.dll", "fable2_build.json")
SYMBOL_FILES = ("fable_2.pdb", "rexruntime.pdb", "rexgpu-xenos.pdb")


def require(path):
    if not path.is_file():
        raise SystemExit(f"package_release: missing {path}")
    return path


def release_files(root, build, launcher):
    files = {name: require(build / name) for name in BUILD_FILES}
    files["Fable2Launcher.exe"] = require(launcher)
    files["README.md"] = require(root / "README.md")
    # The launcher embeds these fonts; the OFL asks for its text to travel with them.
    for licence in sorted((root / "launcher/Fable2.Launcher/Fonts").glob("OFL-*.txt")):
        files[f"licenses/{licence.name}"] = licence
    # From the repo: the build folder's copy may hold a developer's own settings.
    files["fable2_config.toml"] = require(root / "config/fable2_config.toml")
    # Shader pre-build list (shader hashes only, no game content): the game reads it
    # next to its exe so first-time pipeline builds happen at startup, not mid-game.
    files["shader_prebuild.txt"] = require(root / "config/shader_prebuild.txt")
    # dir.manifest stays out: the real one comes from the disc, and the game lists these scripts itself.
    scripts = sorted((build / "data/scripts/recomp").glob("*.lua"))
    if not scripts:
        raise SystemExit("package_release: no Lua scripts in data/scripts/recomp")
    for script in scripts:
        files[f"data/scripts/recomp/{script.name}"] = script
    return files


def write_zip(path, folder, files):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, source in files.items():
            if isinstance(source, str):
                archive.writestr(f"{folder}/{name}", source)
            else:
                archive.write(source, f"{folder}/{name}")


def stamped_build_info(source, version):
    info = json.loads(source.read_text(encoding="utf8"))
    info["version"] = version
    return json.dumps(info, indent=2) + "\n"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def package(root, build, launcher, output, version):
    files = release_files(root, build, launcher)
    files["fable2_build.json"] = stamped_build_info(files["fable2_build.json"], version)
    symbols = {name: require(build / name) for name in SYMBOL_FILES}
    shutil.rmtree(output, ignore_errors=True)
    output.mkdir(parents=True)
    archives = [output / f"Fable_2_recomp_v{version}_windows.zip",
                output / f"Fable_2_recomp_v{version}_symbols.zip"]
    write_zip(archives[0], f"Fable 2 {version}", files)
    write_zip(archives[1], f"Fable 2 {version} symbols", symbols)
    sums = "".join(f"{sha256(path)}  {path.name}\n" for path in archives)
    (output / "SHA256SUMS").write_text(sums, encoding="ascii", newline="\n")
    return archives


# ---------------------------------------------------------------- Velopack

GAME_SUFFIXES = (".iso", ".xex", ".god", ".xbe", ".xcp", ".stfs", ".pak", ".bnk", ".xwb", ".xma", ".bik")
DELTA_SUFFIXES = (".zsdiff", ".bsdiff", ".diff", ".shasum")
PLAYER_FOLDERS = ("saves", "cache", "logs", "play_logs")


def game_content_reason(relative):
    """Why a packaged path looks like game content or player data, or None if it's fine."""
    path = PurePosixPath(str(relative).replace("\\", "/"))
    name = path.name.lower()
    for suffix in DELTA_SUFFIXES:
        if name.endswith(suffix):
            name = name[: -len(suffix)]
            break
    parts = [part.lower() for part in path.parts[:-1]] + [name]
    if name == "default.xex" or name.endswith(GAME_SUFFIXES):
        return "game file"
    if parts[0] in PLAYER_FOLDERS:
        return "player data"
    if parts[0] == "data" and not (len(parts) == 4 and parts[1:3] == ["scripts", "recomp"] and name.endswith(".lua")):
        return "disc data/ (only data/scripts/recomp/*.lua may ship)"
    return None


def check_no_game_content(paths, where):
    bad = [(p, reason) for p in paths if (reason := game_content_reason(p))]
    if bad:
        listing = "\n".join(f"  {p}: {reason}" for p, reason in bad[:20])
        raise SystemExit(f"package_release: refusing to ship game content from {where}:\n{listing}")


def nupkg_app_paths(nupkg):
    """App file paths inside a Velopack full or delta package."""
    with zipfile.ZipFile(nupkg) as archive:
        return [name[len("lib/app/"):] for name in archive.namelist() if name.startswith("lib/app/")]


def shown_command(args):
    """The command as printed, with the GitHub token hidden."""
    return " ".join("***" if i > 0 and args[i - 1] == "--token" else a for i, a in enumerate(args))


def validate_version(version, channel):
    if channel not in CHANNELS:
        raise SystemExit(f"package_release: channel must be one of {', '.join(CHANNELS)}")
    if not re.fullmatch(r"\d+\.\d+\.\d+(-[0-9A-Za-z][0-9A-Za-z.]*)?", version or ""):
        raise SystemExit(f"package_release: '{version}' isn't a release version (use 1.8.0 or 1.8.0-beta.1)")
    if channel == "stable" and "-" in version:
        raise SystemExit("package_release: stable releases can't have a pre-release suffix")


def stage_velopack(root, build, launcher, stage, version):
    files = release_files(root, build, launcher)
    files["fable2_build.json"] = stamped_build_info(files["fable2_build.json"], version)
    check_no_game_content(files.keys(), "the release file list")
    shutil.rmtree(stage, ignore_errors=True)
    for name, source in files.items():
        target = stage / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(source, str):
            target.write_text(source, encoding="utf8", newline="\n")
        else:
            shutil.copy2(source, target)
    staged = [p.relative_to(stage).as_posix() for p in stage.rglob("*") if p.is_file()]
    check_no_game_content(staged, str(stage))
    if sorted(staged) != sorted(files):
        raise SystemExit("package_release: staged files don't match the release file list")
    return staged


def velopack_release(root, build, launcher, version, channel, upload=False, run=subprocess.run):
    validate_version(version, channel)
    out = root / "out/velopack"
    stage, releases = out / "stage", out / "releases" / channel
    stage_velopack(root, build, launcher, stage, version)
    releases.mkdir(parents=True, exist_ok=True)
    pre = ["--pre"] if channel == "beta" else []

    def call(args, check=True):
        print("> " + shown_command(args))
        return run(args, check=check)

    # The last published release lets vpk build a small delta package. None yet is fine.
    if call(["vpk", "download", "github", "--repoUrl", REPO_URL, "--channel", channel,
             "-o", str(releases)] + pre, check=False).returncode != 0:
        print("package_release: no earlier release downloaded; this one will be full-only")
    call(["vpk", "pack", "--packId", PACK_ID, "--packVersion", version, "--packDir", str(stage),
          "--mainExe", "Fable2Launcher.exe", "--packTitle", "Project Sparrow", "--packAuthors", "Project Sparrow",
          "--icon", str(root / "assets/app-icon.ico"), "--runtime", "win-x64", "--channel", channel,
          "-o", str(releases)])

    packages = sorted(releases.glob(f"{PACK_ID}-{version}-*.nupkg"))
    if not any(p.name.endswith("-full.nupkg") for p in packages):
        raise SystemExit(f"package_release: vpk didn't produce {PACK_ID}-{version}-full.nupkg")
    for nupkg in packages:
        check_no_game_content(nupkg_app_paths(nupkg), nupkg.name)

    sign = ["dotnet", "run", "--project", str(root / "tools/sparrow-sign"), "-c", "Release", "--"]
    call(sign + ["sign"] + [str(p) for p in packages])
    call(sign + ["verify"] + [str(p) for p in packages])
    signatures = [Path(str(p) + ".sig") for p in packages]

    if upload:
        upload_release(root, releases, version, channel, signatures, call)
    return packages


def upload_release(root, releases, version, channel, signatures, call):
    git = ["git", "-C", str(root)]
    head = subprocess.check_output(git + ["rev-parse", "HEAD"], text=True).strip()
    if not subprocess.check_output(git + ["branch", "-r", "--contains", head], text=True).strip():
        raise SystemExit("package_release: push this commit to GitHub before uploading a release")
    if subprocess.check_output(git + ["status", "--porcelain", "--untracked-files=no"], text=True).strip():
        print("package_release: warning: the working tree has uncommitted changes")
    token = os.environ.get("GITHUB_TOKEN") or subprocess.check_output(["gh", "auth", "token"], text=True).strip()
    tag = f"v{version}"
    # Draft first: launchers only see published releases, and this one must have its signatures.
    call(["vpk", "upload", "github", "--repoUrl", REPO_URL, "--token", token, "--channel", channel,
          "-o", str(releases), "--tag", tag, "--releaseName", f"Project Sparrow {version}",
          "--targetCommitish", head] + (["--pre"] if channel == "beta" else []))
    call(["gh", "release", "upload", tag, "--repo", REPO, "--clobber"] + [str(s) for s in signatures])
    call(["gh", "release", "edit", tag, "--repo", REPO, "--draft=false"])
    print(f"Published {REPO_URL}/releases/tag/{tag}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version", help="defaults to git describe --tags (zip only)")
    parser.add_argument("--velopack", action="store_true", help="build signed Velopack packages")
    parser.add_argument("--channel", default="stable", choices=CHANNELS)
    parser.add_argument("--upload", action="store_true", help="publish to GitHub (with --velopack)")
    args = parser.parse_args()
    build = ROOT / "out/build/win-amd64-release"
    launcher = ROOT / "out/tests/launcher-build/Fable2Launcher.exe"
    if args.velopack:
        for path in velopack_release(ROOT, build, launcher, args.version, args.channel, args.upload):
            print(f"Packaged {path}")
        return
    if args.upload:
        raise SystemExit("package_release: --upload needs --velopack")
    version = args.version or subprocess.check_output(
        ["git", "-C", str(ROOT), "describe", "--tags"], text=True).strip()
    archives = package(ROOT, build, launcher, ROOT / "out/dist", version)
    for path in archives:
        print(f"Packaged {path}")


if __name__ == "__main__":
    main()
