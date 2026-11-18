using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace Fable2Launcher;

/// <summary>
/// Co-op page, friends part: sign in / create an account, friends list with
/// online status, friend requests and invites (FriendsClient talks to the
/// service). While a co-op game runs, the launcher waits in the system tray so
/// friends can still be invited, and an invite pops up as a notification.
/// </summary>
public partial class MainWindow
{
    private FriendsClient? _friendsClient;
    private FriendsClient FriendsApi => _friendsClient ??= new FriendsClient(_home.Home, _home.InstallFolder);
    private readonly DispatcherTimer _friendsTimer = new() { Interval = TimeSpan.FromSeconds(15) };
    private readonly HashSet<long> _seenInvites = [];
    private List<FriendsClient.PendingInvite> _invites = [];
    private Process? _gameProcess;
    private DateTime _gameStarted;
    private Forms.NotifyIcon? _tray;
    private bool _friendsBusy;
    private bool _closeFromTray;
    private DateTime _lastPresence;
    /// <summary>Set while joining from an invite: overrides the Co-op page's mode, server and code once.</summary>
    private (string Code, string? Server)? _inviteJoin;

    private string SessionFile => Path.Combine(_home.DataFolder, "mp_session.txt");
    private bool GameRunning => _gameProcess is { HasExited: false };

    private void InitFriends()
    {
        if (!FriendsApi.Available)
        {
            FriendsSection.Visibility = Visibility.Collapsed;
            return;
        }
        _friendsTimer.Tick += async (_, _) => await RefreshFriends();
        _friendsTimer.Start();
        Closing += (_, e) =>
        {
            // The window's close button sends it back to the tray while a co-op game runs.
            if (_tray is { Visible: true } && GameRunning && !_closeFromTray)
            {
                e.Cancel = true;
                Hide();
                return;
            }
            _friendsTimer.Stop();
            FriendsApi.GoOfflineQuietly();
            if (_tray is not null) { _tray.Visible = false; _tray.Dispose(); }
        };
        ShowAccountState();
        _ = RefreshFriends();
    }

    private void ShowAccountState()
    {
        bool signedIn = FriendsApi.SignedIn;
        SignedOutPanel.Visibility = signedIn ? Visibility.Collapsed : Visibility.Visible;
        SignedInPanel.Visibility = signedIn ? Visibility.Visible : Visibility.Collapsed;
        SignedInText.Text = signedIn ? "Signed in as " + FriendsApi.Username : "";
        if (!signedIn) { InviteList.Children.Clear(); RequestList.Children.Clear(); FriendList.Children.Clear(); }
        RefreshCoop();
    }

    private void FriendsMessage(string? text)
    {
        FriendsNote.Text = text ?? "";
        FriendsNote.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
    }

    // ------------------------------------------------------------ account

    private void AccountPasswordKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) SignInClicked(sender, e);
    }

    private async void SignInClicked(object sender, RoutedEventArgs e) => await SignIn(create: false);
    private async void CreateAccountClicked(object sender, RoutedEventArgs e) => await SignIn(create: true);

    private async Task SignIn(bool create)
    {
        string name = AccountNameBox.Text.Trim();
        string password = AccountPasswordBox.Password;
        if (name.Length == 0 || password.Length == 0)
        {
            FriendsMessage("Enter a username and a password.");
            return;
        }
        SignInButton.IsEnabled = CreateAccountButton.IsEnabled = false;
        try
        {
            await FriendsApi.SignIn(name, password, create);
            AccountPasswordBox.Clear();
            FriendsMessage(create ? "Account created. Add friends by their username below." : null);
            ShowAccountState();
            await RefreshFriends();
        }
        catch (FriendsClient.FriendsException exception) { FriendsMessage(exception.Message); }
        finally { SignInButton.IsEnabled = CreateAccountButton.IsEnabled = true; }
    }

    private async void SignOutClicked(object sender, RoutedEventArgs e)
    {
        await FriendsApi.SignOut();
        FriendsMessage(null);
        ShowAccountState();
    }

    // ------------------------------------------------------------ friends list

    private void AddFriendKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) AddFriendClicked(sender, e);
    }

    private async void AddFriendClicked(object sender, RoutedEventArgs e)
    {
        string name = AddFriendBox.Text.Trim();
        if (name.Length == 0) return;
        await FriendsAction(async () =>
        {
            string result = await FriendsApi.Request(name);
            AddFriendBox.Clear();
            FriendsMessage(result switch
            {
                "friends" => $"You and {name} are now friends.",
                "already friends" => $"You and {name} are already friends.",
                _ => $"Friend request sent to {name}."
            });
        });
    }

    private async Task FriendsAction(Func<Task> action)
    {
        try
        {
            await action();
            await RefreshFriends();
        }
        catch (FriendsClient.FriendsException exception)
        {
            FriendsMessage(exception.Message);
            if (!FriendsApi.SignedIn) ShowAccountState();
        }
    }

    /// <summary>Presence report, friends list and invites (every 15 s and after each action).</summary>
    private async Task RefreshFriends()
    {
        if (_friendsBusy || !FriendsApi.Available) return;
        _friendsBusy = true;
        try
        {
            if (FriendsApi.Relay is null) { try { await FriendsApi.LoadConfig(); RefreshCoop(); } catch (FriendsClient.FriendsException) { } }
            if (!FriendsApi.SignedIn) return;
            string? code = CurrentSessionCode();
            if (DateTime.UtcNow - _lastPresence > TimeSpan.FromSeconds(30) || code is not null)
            {
                await FriendsApi.Presence(code is not null ? "playing" : "online", code);
                _lastPresence = DateTime.UtcNow;
            }
            FriendsClient.FriendList list = await FriendsApi.Friends();
            _invites = await FriendsApi.Invites();
            ShowFriends(list, code);
            NotifyNewInvites();
        }
        catch (FriendsClient.FriendsException exception)
        {
            if (!FriendsApi.SignedIn) ShowAccountState();
            FriendsMessage(exception.Message);
        }
        catch (Exception exception) when (exception is System.Text.Json.JsonException or InvalidOperationException
                                              or KeyNotFoundException)
        {
            FriendsMessage("Unexpected reply from the friends server: " + exception.Message);
        }
        finally { _friendsBusy = false; }
    }

    /// <summary>The invite code of the co-op session our game is in, if any.</summary>
    private string? CurrentSessionCode()
    {
        if (!GameRunning) return null;
        try
        {
            var info = new FileInfo(SessionFile);
            if (!info.Exists || info.LastWriteTimeUtc < _gameStarted) return null;
            string code = File.ReadAllText(SessionFile).Trim();
            return CoopCodePattern.IsMatch(code) ? code : null;
        }
        catch (IOException) { return null; }
    }

    private void ShowFriends(FriendsClient.FriendList list, string? sessionCode)
    {
        InviteList.Children.Clear();
        foreach (var invite in _invites)
        {
            var join = SmallButton("Join", green: true, () => _ = JoinInvite(invite));
            var dismiss = SmallButton("Dismiss", green: false, () => _ = FriendsAction(() => FriendsApi.Dismiss(invite.Id)));
            InviteList.Children.Add(FriendRow($"{invite.From} invited you to play", "Co-op invite", join, dismiss));
        }
        RequestList.Children.Clear();
        foreach (string name in list.Incoming)
        {
            var accept = SmallButton("Accept", green: true, () => _ = FriendsAction(() => FriendsApi.Accept(name)));
            var decline = SmallButton("Decline", green: false, () => _ = FriendsAction(() => FriendsApi.Remove(name)));
            RequestList.Children.Add(FriendRow(name, "Wants to be your friend", accept, decline));
        }
        foreach (string name in list.Outgoing)
        {
            var cancel = SmallButton("Cancel", green: false, () => _ = FriendsAction(() => FriendsApi.Remove(name)));
            RequestList.Children.Add(FriendRow(name, "Friend request sent", cancel));
        }
        FriendList.Children.Clear();
        foreach (var friend in list.Friends)
        {
            string status = friend.Status switch
            {
                "playing" => friend.InSession ? "Playing co-op" : "Playing",
                "online" => "Online",
                _ => "Offline"
            };
            var buttons = new List<Button>();
            if (sessionCode is not null && friend.Status != "offline")
                buttons.Add(SmallButton("Invite", green: true, () => _ = FriendsAction(async () =>
                {
                    await FriendsApi.SendInvite(friend.Name);
                    FriendsMessage($"Invite sent to {friend.Name}.");
                })));
            buttons.Add(SmallButton("Remove", green: false, () =>
            {
                if (MessageBox.Show(this, $"Remove {friend.Name} from your friends?", "Co-op",
                        MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
                    _ = FriendsAction(() => FriendsApi.Remove(friend.Name));
            }));
            FriendList.Children.Add(FriendRow(friend.Name, status, [.. buttons], online: friend.Status != "offline"));
        }
        if (list.Friends.Count == 0 && list.Incoming.Count == 0 && list.Outgoing.Count == 0)
            FriendList.Children.Add(new TextBlock
            {
                Text = "No friends yet. Add one by username below.",
                Style = (Style)FindResource("PageHint"),
                Margin = new Thickness(0, 8, 0, 4)
            });
    }

    private Button SmallButton(string text, bool green, Action click)
    {
        var button = new Button
        {
            Content = text,
            Style = (Style)FindResource(green ? "PageButtonGreen" : "PageButton"),
            Margin = new Thickness(8, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center
        };
        button.Click += (_, _) => click();
        return button;
    }

    private Border FriendRow(string title, string hint, Button first, params Button[] more) =>
        FriendRow(title, hint, [first, .. more], online: false);

    private Border FriendRow(string title, string hint, Button[] buttons, bool online)
    {
        var dock = new DockPanel();
        for (int i = buttons.Length - 1; i >= 0; i--)
        {
            DockPanel.SetDock(buttons[i], Dock.Right);
            dock.Children.Add(buttons[i]);
        }
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var name = new TextBlock { Text = title, Style = (Style)FindResource("PageText") };
        if (online) name.FontWeight = FontWeights.Bold;
        text.Children.Add(name);
        text.Children.Add(new TextBlock { Text = hint, Style = (Style)FindResource("PageHint") });
        dock.Children.Add(text);
        return new Border { Style = (Style)FindResource("Row"), Child = dock };
    }

    // ------------------------------------------------------------ invites

    private void NotifyNewInvites()
    {
        foreach (var invite in _invites)
        {
            if (!_seenInvites.Add(invite.Id)) continue;
            string text = $"{invite.From} invited you to play co-op.";
            if (_tray is { Visible: true })
                _tray.ShowBalloonTip(10000, "Project Sparrow", text + " Click to open.", Forms.ToolTipIcon.Info);
            else
                ShowToast(text + " See Co-op.");
        }
    }

    private async Task JoinInvite(FriendsClient.PendingInvite invite)
    {
        if (GameRunning)
        {
            if (MessageBox.Show(this, $"Join {invite.From}'s game? Your game closes first, so save before you go on.",
                    "Co-op invite", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK)
                return;
            Process old = _gameProcess!;
            _gameProcess = null;  // its exit must not close the launcher
            old.CloseMainWindow();
            await Task.Run(() => old.WaitForExit(30000));
            if (!old.HasExited)
            {
                _gameProcess = old;
                MessageBox.Show(this, "The game didn't close. Close it yourself, then press Join again.", "Co-op invite");
                return;
            }
        }
        try { await FriendsApi.Dismiss(invite.Id); } catch (FriendsClient.FriendsException) { }
        _inviteJoin = (invite.Code, FriendsApi.Relay);
        try { LaunchGame(); }
        finally { _inviteJoin = null; }
    }

    // ------------------------------------------------------------ tray while playing

    /// <summary>After starting a co-op game: wait in the tray (if signed in) instead of closing.</summary>
    private bool StayInTrayFor(Process? game)
    {
        if (game is null || !FriendsApi.Available || !FriendsApi.SignedIn) return false;
        _gameProcess = game;
        _gameStarted = DateTime.UtcNow.AddSeconds(-2);
        game.EnableRaisingEvents = true;
        game.Exited += (_, _) => Dispatcher.BeginInvoke(() =>
        {
            if (ReferenceEquals(game, _gameProcess) && IsLoaded) { _closeFromTray = true; Close(); }
        });
        if (_tray is null)
        {
            _tray = new Forms.NotifyIcon
            {
                Text = "Project Sparrow co-op",
                Icon = System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!)
            };
            var menu = new Forms.ContextMenuStrip();
            menu.Items.Add("Friends and invites", null, (_, _) => ShowFromTray());
            menu.Items.Add("Close launcher (the game keeps running)", null, (_, _) => { _closeFromTray = true; Close(); });
            _tray.ContextMenuStrip = menu;
            _tray.DoubleClick += (_, _) => ShowFromTray();
            _tray.BalloonTipClicked += (_, _) => ShowFromTray();
        }
        _tray.Visible = true;
        Hide();
        _ = RefreshFriends();
        return true;
    }

    private void ShowFromTray()
    {
        Show();
        WindowState = WindowState.Normal;
        Activate();
        OpenPage(TabCoop);
        _ = RefreshFriends();
    }
}
