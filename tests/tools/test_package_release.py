import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("package_release", ROOT / "tools/package_release.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class PackageReleaseTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)
        self.root, self.build = self.base / "repo", self.base / "build"
        self.launcher = self.base / "launcher/Fable2Launcher.exe"
        for path, text in {
            self.root / "README.md": "readme",
            self.root / "config/fable2_config.toml": "repo config",
            self.root / "config/shader_prebuild.txt": "shader hashes",
            self.launcher: "launcher",
            self.build / "fable_2.exe": "game",
            self.build / "fable_2.pdb": "symbols",
            self.build / "rexruntime.dll": "runtime",
            self.build / "rexruntime.pdb": "symbols",
            self.build / "rexgpu-xenos.dll": "plugin",
            self.build / "rexgpu-xenos.pdb": "symbols",
            self.build / "fable2_build.json": '{"profiles": ["goty"]}',
            self.build / "fable2_config.toml": "my own keybinds",
            self.build / "default.xex": "game code",
            self.build / "saves/slot1.sav": "save",
            self.build / "logs/fable_2_001.log": "log",
            self.build / "data/dir.manifest": "manifest",
            self.build / "data/art.pak": "game data",
            self.build / "data/scripts/quests/quest.lua": "game script",
            self.build / "data/scripts/recomp/F5.lua": "recomp script",
        }.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)

    def package(self):
        return packager.package(self.root, self.build, self.launcher, self.base / "dist", "1.6.0")

    def test_release_zip_contains_only_the_listed_files(self):
        release, _ = self.package()
        with zipfile.ZipFile(release) as archive:
            names = set(archive.namelist())
            config = archive.read("Fable 2 1.6.0/fable2_config.toml").decode()
            build_info = json.loads(archive.read("Fable 2 1.6.0/fable2_build.json"))
        self.assertEqual(names, {f"Fable 2 1.6.0/{name}" for name in (
            "fable_2.exe", "rexruntime.dll", "rexgpu-xenos.dll", "fable2_build.json", "Fable2Launcher.exe",
            "README.md", "fable2_config.toml", "shader_prebuild.txt", "data/scripts/recomp/F5.lua")})
        self.assertEqual(config, "repo config")
        self.assertEqual(build_info, {"profiles": ["goty"], "version": "1.6.0"})

    def test_symbols_are_separate(self):
        _, symbols = self.package()
        with zipfile.ZipFile(symbols) as archive:
            self.assertEqual(len(archive.namelist()), 3)
            self.assertTrue(all(name.endswith(".pdb") for name in archive.namelist()))

    def test_checksums_match_the_zips(self):
        archives = self.package()
        expected = "".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in archives)
        self.assertEqual((self.base / "dist/SHA256SUMS").read_text(), expected)

    def test_missing_file_fails(self):
        (self.build / "rexruntime.dll").unlink()
        with self.assertRaisesRegex(SystemExit, "rexruntime.dll"):
            self.package()
        self.assertFalse((self.base / "dist").exists())



class VelopackPackagingTests(PackageReleaseTests):
    """Reuses the fake repo and build folder (which includes game files that must stay out)."""

    def test_guard_flags_game_content_and_player_data(self):
        reason = packager.game_content_reason
        for bad in ("default.xex", "Fable2.iso", "data/art.pak", "data/dir.manifest", "data/scripts/quests/quest.lua",
                    "saves/slot1.sav", "logs/a.log", "DATA/Scripts/Recomp/x.lua.txt", "data\\art.bin",
                    "default.xex.zsdiff", "data/levels/a.bin.bsdiff"):
            self.assertIsNotNone(reason(bad), bad)
        for good in ("fable_2.exe", "rexruntime.dll", "Fable2Launcher.exe", "README.md", "fable2_config.toml",
                     "licenses/OFL-AlegreyaSans.txt", "data/scripts/recomp/F5.lua", "data/scripts/recomp/F5.lua.zsdiff"):
            self.assertIsNone(reason(good), good)

    def test_versions(self):
        for version, channel in (("1.8.0", "stable"), ("1.8.0-beta.1", "beta"), ("1.8.0", "beta")):
            packager.validate_version(version, channel)
        for version, channel in (("1.8.0-beta.1", "stable"), ("1.5.0-16-g55e38c4x", "stable"), ("v1.8.0", "stable"),
                                 ("1.8", "stable"), (None, "stable"), ("1.8.0", "nightly")):
            with self.assertRaises(SystemExit, msg=f"{version} {channel}"):
                packager.validate_version(version, channel)

    def test_stage_holds_only_the_release_files(self):
        stage = self.base / "stage"
        staged = packager.stage_velopack(self.root, self.build, self.launcher, stage, "1.8.0")
        self.assertEqual(set(staged), {"fable_2.exe", "rexruntime.dll", "rexgpu-xenos.dll", "fable2_build.json",
                                       "Fable2Launcher.exe", "README.md", "fable2_config.toml", "shader_prebuild.txt",
                                       "data/scripts/recomp/F5.lua"})
        self.assertEqual(json.loads((stage / "fable2_build.json").read_text())["version"], "1.8.0")
        self.assertFalse((stage / "default.xex").exists())

    def test_release_runs_pack_then_signs_and_rejects_game_content_in_the_package(self):
        commands = []
        releases = self.root / "out/velopack/releases/beta"

        def fake_run(args, check=True):
            commands.append(args)
            if args[:2] == ["vpk", "pack"]:
                releases.mkdir(parents=True, exist_ok=True)
                with zipfile.ZipFile(releases / "ProjectSparrow-1.8.0-beta.1-full.nupkg", "w") as archive:
                    archive.writestr("lib/app/fable_2.exe", "game")
                    archive.writestr("lib/app/data/scripts/recomp/F5.lua", "script")
            return type("Result", (), {"returncode": 1 if args[:2] == ["vpk", "download"] else 0})()

        packages = packager.velopack_release(self.root, self.build, self.launcher, "1.8.0-beta.1", "beta", run=fake_run)
        self.assertEqual([p.name for p in packages], ["ProjectSparrow-1.8.0-beta.1-full.nupkg"])
        steps = [c[0] if c[0] != "dotnet" else c[-2] for c in commands]
        self.assertEqual(steps, ["vpk", "vpk", "sign", "verify"])
        self.assertIn("--pre", commands[0])
        self.assertEqual(commands[1][commands[1].index("--channel") + 1], "beta")

        def bad_run(args, check=True):
            if args[:2] == ["vpk", "pack"]:
                with zipfile.ZipFile(releases / "ProjectSparrow-1.8.0-beta.1-full.nupkg", "w") as archive:
                    archive.writestr("lib/app/default.xex", "game code")
            return type("Result", (), {"returncode": 0})()

        with self.assertRaisesRegex(SystemExit, "default.xex"):
            packager.velopack_release(self.root, self.build, self.launcher, "1.8.0-beta.1", "beta", run=bad_run)


    def test_printed_commands_hide_the_token(self):
        shown = packager.shown_command(["vpk", "upload", "github", "--token", "gho_secret", "--channel", "beta"])
        self.assertNotIn("gho_secret", shown)
        self.assertIn("--token *** --channel beta", shown)


if __name__ == "__main__":
    unittest.main()
