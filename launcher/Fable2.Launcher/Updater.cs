using System.Diagnostics;
using System.IO;
using System.Net.Http;
using Velopack;
using Velopack.Logging;
using Velopack.Sources;

namespace Fable2Launcher;

/// <summary>Thrown when a downloaded package has no valid Project Sparrow signature.</summary>
public sealed class UpdateSignatureException(string message) : Exception(message);

/// <summary>
/// GitHub Releases source that refuses any package without a valid "&lt;file&gt;.sig" from the
/// same release (see UpdateSignature). Every package Velopack downloads, full or delta,
/// goes through DownloadReleaseEntry, so nothing unsigned reaches the installer.
/// </summary>
public sealed class SignedGithubSource(string repoUrl, bool prerelease)
    : GithubSource(repoUrl, null, prerelease)
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };

    public override async Task DownloadReleaseEntry(IVelopackLogger logger, VelopackAsset releaseEntry, string localFile,
        Action<int> progress, CancellationToken cancelToken = default)
    {
        // Fetch the signature first: no point downloading hundreds of MB we would reject.
        string signature = await DownloadSignature(releaseEntry, cancelToken).ConfigureAwait(false);
        await base.DownloadReleaseEntry(logger, releaseEntry, localFile, progress, cancelToken).ConfigureAwait(false);
        if (!UpdateSignature.VerifyFile(UpdateSignature.ReleasePublicKey, localFile, releaseEntry.FileName, signature))
        {
            TryDelete(localFile);
            throw new UpdateSignatureException($"{releaseEntry.FileName} isn't signed by Project Sparrow, so it wasn't installed.");
        }
    }

    private static async Task<string> DownloadSignature(VelopackAsset entry, CancellationToken cancelToken)
    {
        if (entry is not GitBaseAsset { Release.Assets: { } assets })
            throw new UpdateSignatureException($"No release information for {entry.FileName}.");
        string? url = assets.FirstOrDefault(a => string.Equals(a.Name, entry.FileName + ".sig", StringComparison.Ordinal))
            ?.BrowserDownloadUrl;
        if (url is null || !url.StartsWith("https://github.com/", StringComparison.OrdinalIgnoreCase))
            throw new UpdateSignatureException($"{entry.FileName} has no signature in its release, so it wasn't installed.");
        string text = await Http.GetStringAsync(url, cancelToken).ConfigureAwait(false);
        return text.Length > 4096 ? "" : text;
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}

/// <summary>
/// Background updates from the fork's GitHub Releases. Stable sees full releases only;
/// Beta also sees pre-releases. Switching channel allows a "downgrade" so Beta -> Stable
/// returns to the newest stable build.
/// </summary>
public sealed class Updater
{
    public const string RepoUrl = "https://github.com/gitgudscrub/Fable-2-Recomp";

    private UpdateManager _manager;
    private string _channel;

    public Updater(string channel)
    {
        _channel = channel;
        _manager = Create(channel);
    }

    /// <summary>False for dev builds and the portable zip: no update UI, everything else works.</summary>
    public bool IsInstalled => _manager.IsInstalled;
    public string? CurrentVersion => _manager.IsInstalled ? _manager.CurrentVersion?.ToString() : null;

    /// <summary>Channel the installed package was built for ("stable" or "beta"), or null.</summary>
    public string? InstalledChannel => _manager.IsInstalled ? _manager.DefaultChannel : null;

    /// <summary>An update already downloaded (this run or an earlier one) and waiting to install.</summary>
    public VelopackAsset? Pending { get; private set; }

    private static UpdateManager Create(string channel) =>
        new(new SignedGithubSource(RepoUrl, prerelease: channel == "beta"),
            new UpdateOptions { ExplicitChannel = channel, AllowVersionDowngrade = true });

    public void SetChannel(string channel)
    {
        if (channel == _channel) return;
        _channel = channel;
        _manager = Create(channel);
        Pending = null;
    }

    /// <summary>Checks and downloads. Returns the version now waiting to install, or null if up to date.</summary>
    public async Task<string?> CheckAndDownloadAsync(Action<int> progress, CancellationToken cancel = default)
    {
        if (!_manager.IsInstalled) return null;
        UpdateInfo? info = await _manager.CheckForUpdatesAsync().ConfigureAwait(false);
        if (info is null)
        {
            Pending = _manager.UpdatePendingRestart;
            return Pending?.Version.ToString();
        }
        await _manager.DownloadUpdatesAsync(info, progress, cancel).ConfigureAwait(false);
        Pending = info.TargetFullRelease;
        return Pending.Version.ToString();
    }

    /// <summary>Picks up an update downloaded in an earlier session without going online.</summary>
    public string? LoadPending()
    {
        if (_manager.IsInstalled) Pending = _manager.UpdatePendingRestart;
        return Pending?.Version.ToString();
    }

    /// <summary>
    /// Installing replaces the folder fable_2.exe runs from, so it must never happen while
    /// the game is open.
    /// </summary>
    public static bool IsGameRunning(string installFolder)
    {
        foreach (Process process in Process.GetProcessesByName("fable_2"))
        {
            using (process)
            {
                try
                {
                    string? path = process.MainModule?.FileName;
                    if (path is null || LauncherHome.IsInside(path, installFolder)) return true;
                }
                catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException)
                {
                    return true; // can't tell where it runs from: be safe
                }
            }
        }
        return false;
    }

    /// <summary>Installs the pending update and restarts the launcher.</summary>
    public void ApplyAndRestart()
    {
        if (Pending is not null) _manager.ApplyUpdatesAndRestart(Pending);
    }

    /// <summary>Installs the pending update after the launcher exits, without restarting it.</summary>
    public void ApplyOnExit()
    {
        if (Pending is not null) _manager.WaitExitThenApplyUpdates(Pending, silent: true, restart: false);
    }
}
