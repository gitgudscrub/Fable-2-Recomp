using System.IO;
using System.Text.Json;

namespace Fable2Launcher;

/// <summary>
/// Launcher settings stored in launcher.json in the fixed home folder
/// (%LOCALAPPDATA%\ProjectSparrow-Data). The home folder never moves, so it can
/// always find a data folder the player moved elsewhere.
/// </summary>
public sealed class LauncherSettings
{
    /// <summary>Saves, cache, logs, config files and (by default) the game files. Null = the home folder.</summary>
    public string? DataFolder { get; set; }
    /// <summary>Game files folder when the player points at an existing copy. Null = DataFolder\game.</summary>
    public string? GameFolder { get; set; }
    public string Channel { get; set; } = "stable";
    public string Edition { get; set; } = "original";
    public bool Migrated { get; set; }
}

/// <summary>
/// Where Project Sparrow keeps its files. The install folder (next to the
/// launcher) is replaced by every update, so nothing the player owns lives there.
/// </summary>
public sealed class LauncherHome
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    public string Home { get; }
    public string InstallFolder { get; }
    public LauncherSettings Settings { get; }

    public LauncherHome(string home, string installFolder)
    {
        Home = Path.GetFullPath(home);
        InstallFolder = Path.GetFullPath(installFolder);
        Settings = Load(SettingsPath);
    }

    /// <summary>
    /// The player's home folder. PROJECT_SPARROW_HOME overrides it, so two copies
    /// can run side by side (multiplayer testing) or tests can use a scratch folder.
    /// </summary>
    public static LauncherHome ForCurrentUser() => new(
        Environment.GetEnvironmentVariable("PROJECT_SPARROW_HOME") is { Length: > 0 } custom
            ? custom
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ProjectSparrow-Data"),
        AppContext.BaseDirectory);

    public string SettingsPath => Path.Combine(Home, "launcher.json");
    public string DataFolder => Path.GetFullPath(Settings.DataFolder ?? Home);
    public string GameFolder => Path.GetFullPath(Settings.GameFolder ?? Path.Combine(DataFolder, "game"));
    public string SavesFolder => Path.Combine(DataFolder, "saves");
    public string CacheFolder => Path.Combine(DataFolder, "cache");
    public string LogsFolder => Path.Combine(DataFolder, "logs");
    public string GraphicsConfigPath => Path.Combine(DataFolder, "fable_2.toml");
    public string LauncherGraphicsPath => Path.Combine(DataFolder, "launcher-settings.toml");
    public string RecompConfigPath => Path.Combine(DataFolder, "fable2_config.toml");
    public string ExecutablePath => Path.Combine(InstallFolder, "fable_2.exe");

    private static LauncherSettings Load(string path)
    {
        try
        {
            if (File.Exists(path))
                return JsonSerializer.Deserialize<LauncherSettings>(File.ReadAllText(path)) ?? new();
        }
        catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException)
        {
            // A damaged settings file falls back to defaults rather than blocking play.
        }
        return new();
    }

    public void Save()
    {
        Directory.CreateDirectory(Home);
        string temp = SettingsPath + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(Settings, JsonOptions));
        File.Move(temp, SettingsPath, overwrite: true);
    }

    public void EnsureFolders()
    {
        Directory.CreateDirectory(DataFolder);
        Directory.CreateDirectory(SavesFolder);
    }

    /// <summary>
    /// First run after the old portable layout (game files, saves and configs next
    /// to the launcher): use those game files where they are and copy the saves
    /// and settings into the data folder. Never deletes or overwrites anything.
    /// </summary>
    public string? MigrateFromPortableFolder()
    {
        if (Settings.Migrated) return null;
        Settings.Migrated = true;
        string? note = null;
        bool portableGame = File.Exists(Path.Combine(InstallFolder, "default.xex")) &&
                            Directory.Exists(Path.Combine(InstallFolder, "data"));
        if (portableGame && Settings.GameFolder is null && !File.Exists(Path.Combine(GameFolder, "default.xex")))
        {
            Settings.GameFolder = InstallFolder;
            note = "Using the game files next to the launcher.";
        }
        string oldSaves = Path.Combine(InstallFolder, "saves");
        if (Directory.Exists(oldSaves) && !Directory.EnumerateFileSystemEntries(SavesFolder).Any())
        {
            CopyDirectory(oldSaves, SavesFolder);
            note = "Copied your saves from the launcher folder.";
        }
        foreach (string name in new[] { "fable_2.toml", "launcher-settings.toml", "fable2_config.toml" })
        {
            string from = Path.Combine(InstallFolder, name), to = Path.Combine(DataFolder, name);
            // The shipped fable2_config.toml is only a template; copy it only if the player changed it.
            if (File.Exists(from) && !File.Exists(to) &&
                (name != "fable2_config.toml" || File.Exists(from + ".launcher-backup")))
                File.Copy(from, to);
        }
        Save();
        return note;
    }

    /// <summary>Seed fable2_config.toml from the shipped template on first run.</summary>
    public void SeedRecompConfig()
    {
        string template = Path.Combine(InstallFolder, "fable2_config.toml");
        if (!File.Exists(RecompConfigPath) && File.Exists(template))
            File.Copy(template, RecompConfigPath);
    }

    /// <summary>
    /// Copy the recomp's own Lua scripts (shipped with each update) into the game
    /// folder so the game can load them. Only changed files are written.
    /// </summary>
    public int SyncScripts()
    {
        string source = Path.Combine(InstallFolder, "data", "scripts", "recomp");
        string target = Path.Combine(GameFolder, "data", "scripts", "recomp");
        if (!Directory.Exists(source) || PathsEqual(source, target)) return 0;
        Directory.CreateDirectory(target);
        int copied = 0;
        foreach (string file in Directory.EnumerateFiles(source, "*.lua"))
        {
            string destination = Path.Combine(target, Path.GetFileName(file));
            if (File.Exists(destination) && FilesEqual(file, destination)) continue;
            File.Copy(file, destination, overwrite: true);
            copied++;
        }
        return copied;
    }

    /// <summary>Move everything in the data folder (except a game folder kept elsewhere) to a new folder.</summary>
    public void MoveDataFolder(string newFolder, IProgress<string>? progress = null)
    {
        newFolder = Path.GetFullPath(newFolder);
        string oldFolder = DataFolder;
        if (PathsEqual(oldFolder, newFolder)) return;
        if (IsInside(newFolder, oldFolder))
            throw new InvalidOperationException("Choose a folder outside the current data folder.");
        Directory.CreateDirectory(newFolder);
        if (Directory.EnumerateFileSystemEntries(newFolder).Any())
            throw new InvalidOperationException("Choose an empty folder, so nothing already there gets mixed in.");

        foreach (string entry in Directory.EnumerateFileSystemEntries(oldFolder))
        {
            string name = Path.GetFileName(entry);
            if (PathsEqual(entry, SettingsPath)) continue;   // launcher.json stays in the home folder
            progress?.Report(name);
            string destination = Path.Combine(newFolder, name);
            if (Directory.Exists(entry)) MoveDirectory(entry, destination);
            else MoveFile(entry, destination);
        }
        Settings.DataFolder = PathsEqual(newFolder, Home) ? null : newFolder;
        Save();
    }

    private static void MoveDirectory(string from, string to)
    {
        if (string.Equals(Path.GetPathRoot(from), Path.GetPathRoot(to), StringComparison.OrdinalIgnoreCase))
        {
            Directory.Move(from, to);
            return;
        }
        CopyDirectory(from, to);
        Directory.Delete(from, recursive: true);
    }

    private static void MoveFile(string from, string to)
    {
        File.Copy(from, to);
        File.Delete(from);
    }

    public static void CopyDirectory(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (string dir in Directory.EnumerateDirectories(from, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(to, Path.GetRelativePath(from, dir)));
        foreach (string file in Directory.EnumerateFiles(from, "*", SearchOption.AllDirectories))
            File.Copy(file, Path.Combine(to, Path.GetRelativePath(from, file)), overwrite: false);
    }

    public static bool PathsEqual(string a, string b) =>
        string.Equals(Path.GetFullPath(a).TrimEnd('\\', '/'), Path.GetFullPath(b).TrimEnd('\\', '/'),
            StringComparison.OrdinalIgnoreCase);

    public static bool IsInside(string path, string folder)
    {
        string full = Path.GetFullPath(path).TrimEnd('\\', '/') + Path.DirectorySeparatorChar;
        string parent = Path.GetFullPath(folder).TrimEnd('\\', '/') + Path.DirectorySeparatorChar;
        return full.StartsWith(parent, StringComparison.OrdinalIgnoreCase);
    }

    private static bool FilesEqual(string a, string b)
    {
        var infoA = new FileInfo(a);
        var infoB = new FileInfo(b);
        return infoA.Length == infoB.Length && File.ReadAllBytes(a).AsSpan().SequenceEqual(File.ReadAllBytes(b));
    }
}
