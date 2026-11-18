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
        if (CoopDetails is null) return;
        string mode = _home.Settings.CoopMode;
        CoopDetails.Visibility = mode is "host" or "join" ? Visibility.Visible : Visibility.Collapsed;
        CoopCodeRow.Visibility = mode == "join" ? Visibility.Visible : Visibility.Collapsed;
        CoopServerHint.Text = FriendsApi.Relay is not null
            ? "Leave empty to use the Project Sparrow co-op server."
            : "The co-op server's address, like example.net:27970. The host gives it to you.";
        CoopNote.Text = CoopProblem() ?? (mode == "host"
            ? FriendsApi.SignedIn
                ? "Press Play, then invite friends from this page (the launcher waits in the tray while you play). The invite code also shows in the game window's title."
                : "Press Play. Your invite code shows in the game window's title: give it to your friends."
            : "Press Play to join. Any save works.");
    }

    private string CoopMode => _inviteJoin is not null ? "join" : _home.Settings.CoopMode;
    private string CoopServer => _inviteJoin is { } invite ? invite.Server ?? ""
        : _home.Settings.CoopServer.Length > 0 ? _home.Settings.CoopServer : FriendsApi.Relay ?? "";
    private string CoopCode => _inviteJoin?.Code ?? _home.Settings.CoopCode;

    /// <summary>What still needs filling in before Play can start co-op, or null.</summary>
    private string? CoopProblem()
    {
        string mode = CoopMode;
        if (mode is not ("host" or "join")) return null;
        string server = CoopServer;
        if (server.Length == 0) return "Enter the server address first.";
        if (!CoopServerPattern.IsMatch(server)) return "The server address should look like example.net:27970.";
        if (mode == "join" && !CoopCodePattern.IsMatch(CoopCode))
            return "Enter the invite code from the host (the letters in their game's window title).";
        return null;
    }

    private bool CoopOn => CoopMode is "host" or "join";

    /// <summary>Game arguments for the chosen co-op mode (none when off).</summary>
    private List<string> CoopArguments()
    {
        if (!CoopOn) return [];
        string? problem = CoopProblem();
        if (problem is not null)
            throw new InvalidOperationException("Co-op: " + problem + " Or set Co-op to Off to play alone.");
        var args = new List<string> { "--mp_enable=true", "--mp_relay=" + CoopServer };
        args.Add(CoopMode == "host" ? "--mp_host=true" : "--mp_join=" + CoopCode);
        return args;
    }
}
