using System.IO;

namespace Fable2Launcher;

/// <summary>
/// Copies the saves folder to save-backups/&lt;date-time&gt; before each launch and keeps
/// the newest few. Skips the copy when nothing changed since the newest backup.
/// A failed backup never stops the game from starting.
/// </summary>
public static class SaveBackups
{
    public const int Keep = 5;
    public const string FolderName = "save-backups";

    public static string BackupsFolder(string dataFolder) => Path.Combine(dataFolder, FolderName);

    /// <summary>Returns the new backup folder, or null when there was nothing new to back up.</summary>
    public static string? BackUp(string savesFolder, string dataFolder, DateTime now, int keep = Keep)
    {
        if (!Directory.Exists(savesFolder) || !Directory.EnumerateFiles(savesFolder, "*", SearchOption.AllDirectories).Any())
            return null;
        string root = BackupsFolder(dataFolder);
        Directory.CreateDirectory(root);
        string? newest = List(dataFolder).FirstOrDefault();
        if (newest is not null && SameFiles(savesFolder, newest)) return null;

        string name = now.ToString("yyyyMMdd-HHmmss");
        string target = Path.Combine(root, name);
        for (int i = 2; Directory.Exists(target); i++) target = Path.Combine(root, $"{name}-{i}");
        string temp = target + ".partial";
        if (Directory.Exists(temp)) Directory.Delete(temp, recursive: true);
        LauncherHome.CopyDirectory(savesFolder, temp);
        Directory.Move(temp, target);

        foreach (string old in List(dataFolder).Skip(keep))
        {
            try { Directory.Delete(old, recursive: true); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        return target;
    }

    /// <summary>Finished backups, newest first.</summary>
    public static List<string> List(string dataFolder)
    {
        string root = BackupsFolder(dataFolder);
        if (!Directory.Exists(root)) return [];
        return Directory.EnumerateDirectories(root)
            .Where(d => !d.EndsWith(".partial", StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(d => Path.GetFileName(d), StringComparer.Ordinal)
            .ToList();
    }

    private static bool SameFiles(string a, string b)
    {
        static Dictionary<string, (long, DateTime)> Index(string root) =>
            Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories).ToDictionary(
                f => Path.GetRelativePath(root, f).ToLowerInvariant(),
                f => (new FileInfo(f).Length, File.GetLastWriteTimeUtc(f)));
        var x = Index(a);
        var y = Index(b);
        return x.Count == y.Count && x.All(kv => y.TryGetValue(kv.Key, out var v) && v == kv.Value);
    }
}
