using System.Diagnostics;
using System.IO;
using System.Windows;

namespace Fable2Launcher;

/// <summary>
/// Crash catcher. When the launcher closes after starting the game, it leaves a
/// small hidden copy of itself (--watch-game) that waits for the game to end.
/// A normal quit exits with code 0; anything else (0xC0000005 for a crash) saves
/// a problem report (logs, settings, PC details; never saves) and offers to open it.
/// </summary>
public static class CrashWatch
{
    public const string Argument = "--watch-game";
    public const string FolderName = "crash-reports";

    public static void StartFor(Process game, string version, string edition)
    {
        if (Environment.ProcessPath is not { } self) return;
        var info = new ProcessStartInfo(self) { UseShellExecute = false };
        info.ArgumentList.Add(Argument);
        info.ArgumentList.Add(game.Id.ToString());
        info.ArgumentList.Add(version);
        info.ArgumentList.Add(edition);
        Process.Start(info);
    }

    /// <summary>Is this exit code a crash (not a normal quit)?</summary>
    public static bool IsCrash(int exitCode) => exitCode != 0;

    public static string Describe(int exitCode) => unchecked((uint)exitCode) switch
    {
        0xC0000005 => "a memory access error (0xC0000005)",
        0xC0000409 => "a stack error (0xC0000409)",
        0xC00000FD => "a stack overflow (0xC00000FD)",
        0xE0434352 => "an unhandled error (0xE0434352)",
        uint code => $"error code 0x{code:X8}"
    };

    /// <summary>Runs the watcher (no main window). Returns the process exit code.</summary>
    public static int Run(string[] args)
    {
        if (args.Length < 2 || !int.TryParse(args[1], out int pid)) return 1;
        string version = args.Length > 2 ? args[2] : "unknown";
        string edition = args.Length > 3 ? args[3] : "unknown";
        Process game;
        try { game = Process.GetProcessById(pid); }
        catch (ArgumentException) { return 0; }  // already gone: nothing to tell
        DateTime started;
        int code;
        try
        {
            // Open the handle now: .NET can only read the exit code of a process it
            // didn't start if it held a handle before the process ended.
            _ = game.SafeHandle;
            started = game.StartTime;
            game.WaitForExit();
            code = game.ExitCode;
        }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { return 0; }
        if (!IsCrash(code)) return 0;
        // Closing it within a few seconds is more likely a start-up problem the launcher
        // already reports, but a report helps either way.
        var home = LauncherHome.ForCurrentUser();
        string? report = null;
        try { report = ProblemReport.Create(home, version, edition, Path.Combine(home.DataFolder, FolderName)); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }

        string playTime = (DateTime.Now - started).TotalMinutes is var minutes && minutes >= 1
            ? $" after {minutes:0} minute{(minutes >= 1.5 ? "s" : "")}" : "";
        string text = $"Fable II closed unexpectedly{playTime} with {Describe(code)}.\n\n"
            + (report is null
                ? "The crash report could not be saved."
                : "A crash report with the game logs was saved (your saves are not in it).\n\n"
                  + "Open the report and start a GitHub issue? Attach the selected zip to the issue.");
        var answer = MessageBox.Show(text, "Project Sparrow", report is null ? MessageBoxButton.OK : MessageBoxButton.YesNo,
            MessageBoxImage.Warning);
        if (report is not null && answer == MessageBoxResult.Yes)
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{report}\"") { UseShellExecute = true });
            Process.Start(new ProcessStartInfo(ProblemReport.IssueUrl(version, edition)) { UseShellExecute = true });
        }
        return 0;
    }
}
