using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Fable2Launcher;

/// <summary>
/// The Modern textures pack: a pre-built set of upscaled textures published as a
/// signed manifest plus 16 zip parts on a "textures-v&lt;N&gt;" GitHub release
/// (docs/TEXTURE_PACK_DOWNLOAD.md). Every file in it is encrypted with a key the
/// game derives from the player's own texture, so the download is useless
/// without the game data it was made for.
///
/// Parts download a few at a time, resume with range requests, are checked
/// against the manifest's SHA-256, unpacked into a temporary folder and moved
/// into textures\replace one part at a time, so the game never sees a
/// half-written file. pack-state.json remembers which parts (by hash) are
/// installed, so a reopened launcher resumes and a newer pack only fetches
/// the parts that changed.
/// </summary>
public sealed class TexturePackManifest
{
    [JsonPropertyName("pack")] public string Pack { get; set; } = "";
    [JsonPropertyName("version")] public int Version { get; set; }
    [JsonPropertyName("game_profile")] public string GameProfile { get; set; } = "";
    [JsonPropertyName("install_dir")] public string InstallDir { get; set; } = "textures/replace";
    [JsonPropertyName("total_bytes")] public long TotalBytes { get; set; }
    [JsonPropertyName("file_count")] public int FileCount { get; set; }
    [JsonPropertyName("parts")] public List<TexturePackPart> Parts { get; set; } = new();
}

public sealed class TexturePackPart
{
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("size")] public long Size { get; set; }
    [JsonPropertyName("sha256")] public string Sha256 { get; set; } = "";
    [JsonPropertyName("files")] public int Files { get; set; }
    [JsonPropertyName("url")] public string Url { get; set; } = "";
}

/// <summary>What is installed: written after every completed part.</summary>
public sealed class TexturePackState
{
    [JsonPropertyName("version")] public int Version { get; set; }
    [JsonPropertyName("game_profile")] public string GameProfile { get; set; } = "";
    /// <summary>Part name -> sha256 of the zip that was unpacked.</summary>
    [JsonPropertyName("parts")] public Dictionary<string, string> Parts { get; set; } = new();

    public static TexturePackState Load(string path)
    {
        try
        {
            if (File.Exists(path))
                return JsonSerializer.Deserialize<TexturePackState>(File.ReadAllText(path)) ?? new TexturePackState();
        }
        catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException) { }
        return new TexturePackState();
    }

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temp, path, overwrite: true);
    }
}

public sealed class TexturePackException(string message) : Exception(message);

public enum PartStatus { Waiting, Downloading, Verifying, Unpacking, Installed, Failed }

public sealed record PartProgress(string Name, PartStatus Status, long Done, long Size, string? Error = null);

public sealed class TexturePack
{
    public const string RepoApi = "https://api.github.com/repos/gitgudscrub/Fable-2-Recomp/releases?per_page=30";
    public const string TagPrefix = "textures-v";
    /// <summary>Folder (or manifest.json path) used instead of the GitHub release: for testing.</summary>
    public const string OverrideVariable = "PROJECT_SPARROW_TEXTURES";
    private const int Parallel = 3;

    private static readonly HttpClient Http = CreateClient();

    private readonly string _dataFolder;
    private string? _localSource;   // folder holding manifest.json and the parts, when overridden

    public TexturePack(string dataFolder) => _dataFolder = dataFolder;

    public string TexturesFolder => Path.Combine(_dataFolder, "textures");
    public string ReplaceFolder => Path.Combine(TexturesFolder, "replace");
    public string StatePath => Path.Combine(TexturesFolder, "pack-state.json");
    private string DownloadFolder => Path.Combine(TexturesFolder, "downloads");

    public TexturePackState State => TexturePackState.Load(StatePath);

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("ProjectSparrow-launcher");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return client;
    }

    // ------------------------------------------------------------- manifest

    /// <summary>
    /// The newest pack's manifest, signature-checked. Null when no pack release
    /// exists yet.
    /// </summary>
    public async Task<TexturePackManifest?> FetchManifestAsync(CancellationToken cancel)
    {
        string? overridePath = Environment.GetEnvironmentVariable(OverrideVariable);
        if (!string.IsNullOrEmpty(overridePath))
        {
            string manifestPath = Directory.Exists(overridePath) ? Path.Combine(overridePath, "manifest.json") : overridePath;
            _localSource = Path.GetDirectoryName(manifestPath);
            return Parse(await File.ReadAllBytesAsync(manifestPath, cancel), await File.ReadAllTextAsync(manifestPath + ".sig", cancel));
        }

        using JsonDocument releases = JsonDocument.Parse(await Http.GetStringAsync(RepoApi, cancel));
        int bestVersion = -1;
        string? manifestUrl = null, signatureUrl = null;
        foreach (JsonElement release in releases.RootElement.EnumerateArray())
        {
            if (release.TryGetProperty("draft", out JsonElement draft) && draft.GetBoolean()) continue;
            string tag = release.GetProperty("tag_name").GetString() ?? "";
            if (!tag.StartsWith(TagPrefix, StringComparison.Ordinal) || !int.TryParse(tag[TagPrefix.Length..], out int version)) continue;
            if (version <= bestVersion || !release.TryGetProperty("assets", out JsonElement assets)) continue;
            string? manifest = null, signature = null;
            foreach (JsonElement asset in assets.EnumerateArray())
            {
                string name = asset.GetProperty("name").GetString() ?? "";
                string url = asset.GetProperty("browser_download_url").GetString() ?? "";
                if (name == "manifest.json") manifest = url;
                else if (name == "manifest.json.sig") signature = url;
            }
            if (manifest is null || signature is null) continue;
            bestVersion = version;
            manifestUrl = manifest;
            signatureUrl = signature;
        }
        if (manifestUrl is null || signatureUrl is null) return null;
        if (!manifestUrl.StartsWith("https://github.com/", StringComparison.OrdinalIgnoreCase))
            throw new TexturePackException("The texture pack release points outside GitHub.");
        byte[] manifestBytes = await Http.GetByteArrayAsync(manifestUrl, cancel);
        string signatureText = await Http.GetStringAsync(signatureUrl, cancel);
        return Parse(manifestBytes, signatureText);
    }

    private static TexturePackManifest Parse(byte[] manifestBytes, string signatureText)
    {
        string sha = Convert.ToHexString(SHA256.HashData(manifestBytes)).ToLowerInvariant();
        if (signatureText.Length > 4096 || !UpdateSignature.Verify(UpdateSignature.ReleasePublicKey, "manifest.json", sha, signatureText))
            throw new TexturePackException("The texture pack's manifest isn't signed by Project Sparrow, so it wasn't used.");
        TexturePackManifest manifest = JsonSerializer.Deserialize<TexturePackManifest>(manifestBytes)
                                       ?? throw new TexturePackException("The texture pack's manifest is empty.");
        if (manifest.Parts.Count == 0) throw new TexturePackException("The texture pack's manifest lists no parts.");
        foreach (TexturePackPart part in manifest.Parts)
        {
            if (part.Name.Length == 0 || part.Name.Contains('/') || part.Name.Contains('\\') || part.Name.Contains("..")
                || !part.Name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) || part.Sha256.Length != 64 || part.Size <= 0)
                throw new TexturePackException("The texture pack's manifest has a malformed part entry.");
            if (!part.Url.StartsWith("https://github.com/", StringComparison.OrdinalIgnoreCase))
                throw new TexturePackException("The texture pack's manifest points outside GitHub.");
        }
        return manifest;
    }

    // ----------------------------------------------------------------- state

    /// <summary>Parts of this manifest that are not installed at this exact hash.</summary>
    public List<TexturePackPart> MissingParts(TexturePackManifest manifest)
    {
        TexturePackState state = State;
        return manifest.Parts.Where(part => !state.Parts.TryGetValue(part.Name, out string? sha)
                                            || !string.Equals(sha, part.Sha256, StringComparison.OrdinalIgnoreCase)).ToList();
    }

    public bool IsComplete(TexturePackManifest manifest) => MissingParts(manifest).Count == 0;

    public long InstalledBytes
    {
        get
        {
            try
            {
                return Directory.Exists(ReplaceFolder)
                    ? new DirectoryInfo(ReplaceFolder).EnumerateFiles("*.edds").Sum(file => file.Length) : 0;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return 0; }
        }
    }

    // -------------------------------------------------------------- download

    /// <summary>
    /// Downloads, checks and installs every missing part. Progress is reported
    /// per part. Throws on the first part that fails for a reason a retry would
    /// not fix; cancellation leaves finished parts installed and partial
    /// downloads on disk for the next run.
    /// </summary>
    public async Task DownloadAsync(TexturePackManifest manifest, IProgress<PartProgress> progress, CancellationToken cancel)
    {
        Directory.CreateDirectory(ReplaceFolder);
        Directory.CreateDirectory(DownloadFolder);
        List<TexturePackPart> missing = MissingParts(manifest);
        foreach (TexturePackPart part in missing) progress.Report(new PartProgress(part.Name, PartStatus.Waiting, 0, part.Size));

        var stateLock = new object();
        using var throttle = new SemaphoreSlim(Parallel);
        var tasks = missing.Select(async part =>
        {
            await throttle.WaitAsync(cancel);
            try
            {
                await InstallPartAsync(part, progress, cancel);
                lock (stateLock)
                {
                    TexturePackState state = State;
                    if (state.Version != manifest.Version)
                    {
                        // Parts from an older pack stay installed and get replaced as
                        // their new versions arrive; the state tracks the newest pack.
                        state.Version = manifest.Version;
                        state.GameProfile = manifest.GameProfile;
                    }
                    state.Parts[part.Name] = part.Sha256;
                    state.Save(StatePath);
                }
                progress.Report(new PartProgress(part.Name, PartStatus.Installed, part.Size, part.Size));
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception exception)
            {
                progress.Report(new PartProgress(part.Name, PartStatus.Failed, 0, part.Size, exception.Message));
                throw;
            }
            finally { throttle.Release(); }
        }).ToList();
        await Task.WhenAll(tasks);
        TryDeleteFolder(DownloadFolder);
    }

    private async Task InstallPartAsync(TexturePackPart part, IProgress<PartProgress> progress, CancellationToken cancel)
    {
        string zipPath = Path.Combine(DownloadFolder, part.Name + ".part");
        await DownloadPartAsync(part, zipPath, progress, cancel);

        progress.Report(new PartProgress(part.Name, PartStatus.Verifying, part.Size, part.Size));
        string sha;
        await using (FileStream stream = File.OpenRead(zipPath))
            sha = Convert.ToHexString(await SHA256.HashDataAsync(stream, cancel)).ToLowerInvariant();
        if (new FileInfo(zipPath).Length != part.Size || !string.Equals(sha, part.Sha256, StringComparison.OrdinalIgnoreCase))
        {
            File.Delete(zipPath);
            throw new TexturePackException($"{part.Name} didn't download correctly (checksum differs). Try again.");
        }

        progress.Report(new PartProgress(part.Name, PartStatus.Unpacking, part.Size, part.Size));
        string unpackFolder = Path.Combine(DownloadFolder, part.Name + ".unpack");
        TryDeleteFolder(unpackFolder);
        Directory.CreateDirectory(unpackFolder);
        await Task.Run(() =>
        {
            using (ZipArchive archive = ZipFile.OpenRead(zipPath))
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    cancel.ThrowIfCancellationRequested();
                    // Flat <HASH>.edds entries only: anything else is not ours.
                    string name = Path.GetFileName(entry.FullName);
                    if (name != entry.FullName || !name.EndsWith(".edds", StringComparison.OrdinalIgnoreCase) || name.Length != 21)
                        throw new TexturePackException($"{part.Name} holds an unexpected file ({entry.FullName}).");
                    entry.ExtractToFile(Path.Combine(unpackFolder, name), overwrite: true);
                }
            // The part is complete on disk: move its files into place. Each move is
            // atomic, so the game only ever sees whole files.
            foreach (string file in Directory.EnumerateFiles(unpackFolder, "*.edds"))
                File.Move(file, Path.Combine(ReplaceFolder, Path.GetFileName(file)), overwrite: true);
        }, cancel);
        TryDeleteFolder(unpackFolder);
        File.Delete(zipPath);
    }

    private async Task DownloadPartAsync(TexturePackPart part, string zipPath, IProgress<PartProgress> progress, CancellationToken cancel)
    {
        long have = File.Exists(zipPath) ? new FileInfo(zipPath).Length : 0;
        if (have > part.Size) { File.Delete(zipPath); have = 0; }
        if (have == part.Size) return;   // downloaded earlier, not yet verified

        if (_localSource is not null)
        {
            // Test source: copy the part from the folder beside the manifest.
            string source = Path.Combine(_localSource, part.Name);
            await using FileStream input = File.OpenRead(source);
            input.Seek(have, SeekOrigin.Begin);
            await using FileStream output = new(zipPath, FileMode.Append, FileAccess.Write, FileShare.None);
            await CopyWithProgressAsync(input, output, part, have, progress, cancel);
            return;
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, part.Url);
        if (have > 0) request.Headers.Range = new RangeHeaderValue(have, null);
        using HttpResponseMessage response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancel);
        if (have > 0 && response.StatusCode != System.Net.HttpStatusCode.PartialContent)
        {
            // The server ignored the range: start over.
            response.EnsureSuccessStatusCode();
            File.Delete(zipPath);
            have = 0;
        }
        response.EnsureSuccessStatusCode();
        await using Stream body = await response.Content.ReadAsStreamAsync(cancel);
        await using FileStream file = new(zipPath, have > 0 ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None);
        await CopyWithProgressAsync(body, file, part, have, progress, cancel);
    }

    private static async Task CopyWithProgressAsync(Stream input, Stream output, TexturePackPart part, long done,
                                                    IProgress<PartProgress> progress, CancellationToken cancel)
    {
        byte[] buffer = new byte[1 << 16];
        long lastReport = -1;
        int read;
        while ((read = await input.ReadAsync(buffer, cancel)) > 0)
        {
            await output.WriteAsync(buffer.AsMemory(0, read), cancel);
            done += read;
            if (done - lastReport >= 1 << 20 || done == part.Size)
            {
                lastReport = done;
                progress.Report(new PartProgress(part.Name, PartStatus.Downloading, done, part.Size));
            }
        }
    }

    // ---------------------------------------------------------------- remove

    /// <summary>Deletes the installed pack, its state and any partial downloads.</summary>
    public void Remove()
    {
        TryDeleteFolder(DownloadFolder);
        if (Directory.Exists(ReplaceFolder))
            foreach (string file in Directory.EnumerateFiles(ReplaceFolder, "*.edds"))
                File.Delete(file);
        if (File.Exists(StatePath)) File.Delete(StatePath);
    }

    private static void TryDeleteFolder(string folder)
    {
        try { if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    public static string FormatSize(long bytes) => bytes switch
    {
        >= 1L << 30 => $"{bytes / (double)(1L << 30):0.0} GB",
        >= 1L << 20 => $"{bytes / (double)(1L << 20):0} MB",
        _ => $"{bytes / 1024.0:0} KB"
    };
}
