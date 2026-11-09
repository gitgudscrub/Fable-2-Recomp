# Publishing a Project Sparrow release

Releases are built on the release PC, not in CI: the game can't be built without
`default.xex`, which never leaves that PC. Each release is a signed Velopack
package on this fork's GitHub Releases, and installed launchers update to it.

## One-time setup

1. **Tools**
   - .NET 8 SDK, the C++ toolchain from [Building](../README.md#building), Python 3.
   - `vpk`, at the same version as the launcher's Velopack package
     (`launcher/Fable2.Launcher/Fable2.Launcher.csproj`):
     ```
     dotnet tool install -g vpk --version 1.2.161
     ```
     If you update the Velopack package, update `vpk` to match.
   - GitHub CLI, logged in to the account that owns the fork: `gh auth login`.
2. **Signing key.** It lives at
   `%USERPROFILE%\.project-sparrow\update-signing-key.pem` and was created with
   `dotnet run --project tools/sparrow-sign -- keygen`.
   - **Back it up** somewhere safe and offline (password manager, USB stick).
     If it's lost, installed launchers will refuse every future update and
     players would have to reinstall a launcher with a new key.
   - **Never commit or share it.** Anyone with it can sign updates that
     players' launchers will install.
   - The matching public key is `ReleasePublicKey` in
     `launcher/Fable2.Launcher/UpdateSignature.cs`. `sparrow-sign` refuses to
     sign with a key that doesn't match it.

## Each release

1. **Pick a version.**
   - Stable: `1.8.0`. Tested builds; players on the Stable channel get them.
   - Beta: `1.8.0-beta.1`, `1.8.0-beta.2`, … Published as GitHub
     pre-releases; only players on the Beta channel get them.
   - Versions only go up within a channel.
2. **Commit and push everything that goes into the build.** The upload refuses
   a commit that isn't on GitHub, and warns about uncommitted changes. Build from
   committed code so the release matches the source.
3. **Build the game and the launcher:**
   ```
   build.cmd -release fable_2
   launcher\build-launcher.cmd
   ```
4. **Package, sign and publish:**
   ```
   python tools/package_release.py --velopack --version 1.8.0 --channel stable --upload
   ```
   Leave out `--upload` for a local dry run; the files land in
   `out\velopack\releases\<channel>`.

   What it does:
   - stages only the release allow-list (game exe and DLLs, launcher, config
     template, README, font licences, `data/scripts/recomp/*.lua`);
   - **refuses anything that looks like game content or player data**
     (`default.xex`, ISOs, disc `data/`, saves, logs), both in the staged folder
     and inside every built package;
   - downloads the previous release so `vpk` can build a small delta package;
   - signs every new package (`<file>.nupkg.sig`) and verifies the signatures;
   - creates the GitHub release as a draft, attaches the signatures, and only
     then publishes it, so launchers never see a release without signatures.
     The GitHub token is never printed.
5. **Check it.** On the release page you should see the full package (and a
   delta after the first release), a `.sig` for each package, `releases.<channel>.json`,
   `ProjectSparrow-<channel>-Setup.exe` and `ProjectSparrow-<channel>-Portable.zip`.
   Open an installed launcher: it should offer the update within a few seconds.

## If something goes wrong

- **"push this commit to GitHub before uploading a release"**: run `git push`,
  delete `out\velopack` and run the command again.
- **A launcher says an update "isn't signed by Project Sparrow"**: the `.sig`
  is missing or doesn't match its package. Check the release assets; if a
  signature is missing, attach it with
  `gh release upload v<version> out\velopack\releases\<channel>\*.sig`.
  Never sign a package you didn't build.
- **A bad release went out**: publish a fixed one with a higher version. To
  withdraw one, delete the release *and* its tag
  (`gh release delete v<version> --cleanup-tag`); launchers that already
  installed it keep it until the next update.
- **The key leaked**: generate a new key, put its public half in
  `UpdateSignature.cs`, and publish a release signed with the *old* key so
  installed launchers move to the new one. Then stop using the old key.

## Code signing (later)

Releases are not Authenticode-signed yet, so Windows SmartScreen warns about the
installer. When a certificate is available, add `--signParams` (signtool) or
`--azureTrustedSignFile` to the `vpk pack` call in `tools/package_release.py`.
Nothing else changes.
