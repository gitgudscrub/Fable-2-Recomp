using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using Fable2Launcher.Constants;

namespace Fable2Launcher;

public sealed record DiscFile(string Path, long Size, string Sha256);

public sealed record DiscCheckResult(int Checked, IReadOnlyList<string> Missing, IReadOnlyList<string> Damaged)
{
    public bool AllGood => Missing.Count == 0 && Damaged.Count == 0;
}

/// <summary>
/// Reference list of every file on a supported disc (sha256, size, path as
/// extracted), generated with <c>x360extract &lt;iso&gt; --manifest</c> and stored in
/// constants/disc-manifests/&lt;version id&gt;.txt. "Check game files" compares the
/// game folder against it.
/// </summary>
public sealed class DiscManifest
{
    public string XexHash { get; }
    public IReadOnlyList<DiscFile> Files { get; }

    private DiscManifest(string xexHash, IReadOnlyList<DiscFile> files)
    {
        XexHash = xexHash;
        Files = files;
    }

    /// <summary>
    /// Files the game reads: default.xex and data/. data/dir.manifest is left out
    /// because the game repairs it itself at startup. $SystemUpdate and nxeart
    /// are on the disc but never used.
    /// </summary>
    public static bool IsChecked(string path) =>
        path.Equals("default.xex", StringComparison.OrdinalIgnoreCase) ||
        (path.StartsWith("data/", StringComparison.OrdinalIgnoreCase) &&
         !path.Equals("data/dir.manifest", StringComparison.OrdinalIgnoreCase));

    public IEnumerable<DiscFile> CheckedFiles => Files.Where(file => IsChecked(file.Path));

    public static DiscManifest Parse(string text)
    {
        string? xexHash = null;
        var files = new List<DiscFile>();
        int lineNumber = 0;
        foreach (string raw in text.Split('\n'))
        {
            lineNumber++;
            string line = raw.TrimEnd('\r');
            if (line.Length == 0) continue;
            if (line.StartsWith('#'))
            {
                const string xexTag = "# default.xex ";
                if (line.StartsWith(xexTag, StringComparison.Ordinal)) xexHash = line[xexTag.Length..].Trim();
                continue;
            }
            string[] parts = line.Split(' ', 3);
            if (parts.Length != 3 || parts[0].Length != 64 || !long.TryParse(parts[1], out long size) || size < 0 ||
                parts[2].Length == 0 || parts[2].Contains("..") || Path.IsPathRooted(parts[2]))
                throw new InvalidDataException($"Bad line {lineNumber} in the disc reference list.");
            files.Add(new DiscFile(parts[2], size, parts[0].ToLowerInvariant()));
        }
        if (xexHash is null) throw new InvalidDataException("The disc reference list has no default.xex hash.");
        return new DiscManifest(xexHash.ToLowerInvariant(), files);
    }

    /// <summary>The embedded reference list for this default.xex hash, or null if there isn't one.</summary>
    public static DiscManifest? ForXex(string xexHash)
    {
        GameVersion? version = GameVersions.All.FirstOrDefault(v =>
            string.Equals(v.Hash, xexHash, StringComparison.OrdinalIgnoreCase));
        if (version is null) return null;
        using Stream? stream = Assembly.GetExecutingAssembly()
            .GetManifestResourceStream($"DiscManifests/{version.Id}.txt");
        if (stream is null) return null;
        using var reader = new StreamReader(stream);
        DiscManifest manifest = Parse(reader.ReadToEnd());
        return string.Equals(manifest.XexHash, xexHash, StringComparison.OrdinalIgnoreCase) ? manifest : null;
    }

    public static string HashFile(string path, Action<long>? onBytes = null, CancellationToken cancel = default)
    {
        using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        using FileStream input = new(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 1 << 20);
        byte[] buffer = new byte[1 << 20];
        int read;
        while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
        {
            cancel.ThrowIfCancellationRequested();
            sha.AppendData(buffer, 0, read);
            onBytes?.Invoke(read);
        }
        return Convert.ToHexString(sha.GetHashAndReset()).ToLowerInvariant();
    }

    /// <summary>
    /// Compare the game folder with the reference list. Extra files are ignored.
    /// <paramref name="progress"/> gets (bytes done, bytes total).
    /// </summary>
    public DiscCheckResult Verify(string folder, Action<long, long>? progress = null, CancellationToken cancel = default)
    {
        List<DiscFile> files = CheckedFiles.ToList();
        long total = files.Sum(file => file.Size);
        long done = 0;
        var missing = new List<string>();
        var damaged = new List<string>();
        foreach (DiscFile file in files)
        {
            cancel.ThrowIfCancellationRequested();
            string path = Path.Combine(folder, file.Path.Replace('/', Path.DirectorySeparatorChar));
            var info = new FileInfo(path);
            if (!info.Exists)
            {
                missing.Add(file.Path);
                done += file.Size;
            }
            else if (info.Length != file.Size)
            {
                damaged.Add(file.Path);
                done += file.Size;
            }
            else
            {
                string hash = HashFile(path, n => { done += n; progress?.Invoke(done, total); }, cancel);
                if (hash != file.Sha256) damaged.Add(file.Path);
                continue;
            }
            progress?.Invoke(done, total);
        }
        return new DiscCheckResult(files.Count, missing, damaged);
    }
}
