using System.IO;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;

namespace Fable2Launcher;

/// <summary>
/// Co-op page (experimental): Off / Host / Join plus the relay server and the
/// invite code. The game does the rest (src/net/mp_net.h): a host gets a code
/// from the relay and shows it in its window title; friends join with it.
/// </summary>
public partial class MainWindow
{
    private static readonly Regex CoopServerPattern = new(@"^[A-Za-z0-9.\-]+:\d{1,5}$");
    private static readonly Regex CoopCodePattern = new(@"^[A-Z0-9]{4,8}$");

    private void LoadCoop()
    {
        string mode = _home.Settings.CoopMode;
        CoopOff.IsChecked = mode is not ("host" or "join");
        CoopHost.IsChecked = mode == "host";
        CoopJoin.IsChecked = mode == "join";
        CoopServerBox.Text = _home.Settings.CoopServer;
        CoopCodeBox.Text = _home.Settings.CoopCode;
        RefreshCoop();
    }

    private void CoopModeChecked(object sender, RoutedEventArgs e)
    {
        if (CoopServerBox is null) return;
        if (!_loading)
        {
            _home.Settings.CoopMode = CoopHost.IsChecked == true ? "host" : CoopJoin.IsChecked == true ? "join" : "off";
            try { _home.Save(); } catch (IOException) { }
        }
        RefreshCoop();
    }

    private void CoopTextChanged(object sender, TextChangedEventArgs e)
    {
        if (CoopNote is null || _loading) return;
        _home.Settings.CoopServer = CoopServerBox.Text.Trim();
        _home.Settings.CoopCode = CoopCodeBox.Text.Trim().ToUpperInvariant();
        try { _home.Save(); } catch (IOException) { }
        RefreshCoop();
    }

    private void RefreshCoop()
    {
        string mode = _home.Settings.CoopMode;
        CoopDetails.Visibility = mode is "host" or "join" ? Visibility.Visible : Visibility.Collapsed;
        CoopCodeRow.Visibility = mode == "join" ? Visibility.Visible : Visibility.Collapsed;
        CoopNote.Text = CoopProblem() ?? (mode == "host"
            ? "Press Play. Your invite code shows in the game window's title: give it and the server address to your friends."
            : "Press Play to join. Any save works.");
    }

    /// <summary>What still needs filling in before Play can start co-op, or null.</summary>
    private string? CoopProblem()
    {
        string mode = _home.Settings.CoopMode;
        if (mode is not ("host" or "join")) return null;
        string server = _home.Settings.CoopServer;
        if (server.Length == 0) return "Enter the server address first.";
        if (!CoopServerPattern.IsMatch(server)) return "The server address should look like example.net:27970.";
        if (mode == "join" && !CoopCodePattern.IsMatch(_home.Settings.CoopCode))
            return "Enter the invite code from the host (the letters in their game's window title).";
        return null;
    }

    /// <summary>Game arguments for the chosen co-op mode (none when off or not filled in).</summary>
    private IEnumerable<string> CoopArguments()
    {
        string mode = _home.Settings.CoopMode;
        if (mode is not ("host" or "join")) yield break;
        string? problem = CoopProblem();
        if (problem is not null)
            throw new InvalidOperationException("Co-op: " + problem + " Or set Co-op to Off to play alone.");
        yield return "--mp_enable=true";
        yield return "--mp_relay=" + _home.Settings.CoopServer;
        if (mode == "host") yield return "--mp_host=true";
        else yield return "--mp_join=" + _home.Settings.CoopCode;
    }
}
