using Microsoft.Win32;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace Fable2Launcher;

public partial class MainWindow : Window
{
    private enum LauncherState { NeedsDisc, Extracting, Ready, UpdateReady, Problem }

    private readonly LauncherHome _home;
    private readonly Dictionary<string, string> _graphics = new(StringComparer.OrdinalIgnoreCase);
    private Fable2ConfigValues _recomp = new();
    private LauncherState _state;
    private bool _applyingTheme;
    private bool _loading = true;
    private bool _dirty;
    private string _version = "dev build";
    private readonly Updater _updater;
    private bool _checkingUpdates;
    private bool _gameLaunched;
    private string? _updateError;
    private readonly DispatcherTimer _toastTimer = new() { Interval = TimeSpan.FromSeconds(3.5) };

    public MainWindow()
    {
        InitializeComponent();
        _home = LauncherHome.ForCurrentUser();
        _toastTimer.Tick += (_, _) => { _toastTimer.Stop(); Toast.Visibility = Visibility.Collapsed; };
        PreviewKeyDown += WindowPreviewKeyDown;
        StateChanged += (_, _) => Root.Margin = WindowState == WindowState.Maximized ? new Thickness(7) : new Thickness(0);

        foreach (var option in Constants.GraphicsOptions.FrameLimits)
            FrameLimitCombo.Items.Add(new ComboBoxItem { Tag = option.Value, Content = option.Label });
        foreach (var option in Constants.GraphicsOptions.HostFrameLimits)
            HostFrameLimitCombo.Items.Add(new ComboBoxItem { Tag = option.Value, Content = option.Label });

        string? note = null;
        try
        {
            _home.EnsureFolders();
            note = _home.MigrateFromPortableFolder();
            _home.SeedRecompConfig();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            note = "Could not prepare the data folder: " + exception.Message;
        }

        _updater = new Updater(_home.Settings.Channel);
        _version = _updater.CurrentVersion ?? ReadVersion();
        _updater.LoadPending();
        LoadSettings();
        _loading = false;
        UpdateVersionText();
        RefreshGameState();
        if (note is not null) ShowToast(note);

        Loaded += (_, _) =>
        {
            if (AnimationsOn) ((Storyboard)FindResource("Fireflies")).Begin(this, true);
            CheckForUpdates(quiet: true);
            // --page=settings|controls|updates|help opens the parchment page on start.
            string? page = Environment.GetCommandLineArgs()
                .FirstOrDefault(arg => arg.StartsWith("--page=", StringComparison.OrdinalIgnoreCase))?[7..];
            RadioButton? tab = page?.ToLowerInvariant() switch
            {
                "settings" => TabSettings, "controls" => TabControls,
                "updates" => TabUpdates, "help" => TabHelp, _ => null
            };
            if (tab is not null) OpenPage(tab);
        };
        Closing += (_, _) =>
        {
            if (_dirty) SaveAll(quiet: true);
            // Install a downloaded update once the launcher closes, unless the game is
            // (about to be) running from the folder the update replaces.
            if (_updater.Pending is not null && !_gameLaunched && !Updater.IsGameRunning(_home.InstallFolder))
                try { _updater.ApplyOnExit(); } catch (Exception) { }
        };
    }

    private static bool AnimationsOn => SystemParameters.ClientAreaAnimation;

    private string ReadVersion()
    {
        try
        {
            using JsonDocument doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(_home.InstallFolder, "fable2_build.json")));
            if (doc.RootElement.TryGetProperty("version", out JsonElement v) && v.GetString() is { Length: > 0 } text)
                return text;
        }
        catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException) { }
        return "dev build";
    }

    private void UpdateVersionText()
    {
        bool beta = _home.Settings.Channel == "beta";
        VersionText.Text = $"{_version} · {(beta ? "Beta" : "Stable")}";
        ChannelNote.Text = beta
            ? "Newest fixes first, less tested. Back up your saves before switching back to Stable."
            : "Tested releases. Updates download in the background; restart the launcher to install them.";
        UpdateActions.Visibility = _updater.IsInstalled ? Visibility.Visible : Visibility.Collapsed;
        CheckUpdatesButton.IsEnabled = !_checkingUpdates;
        RestartUpdateButton.Visibility = _updater.Pending is null ? Visibility.Collapsed : Visibility.Visible;
        UpdateStatusText.Text =
            !_updater.IsInstalled ? "Automatic updates start once Project Sparrow is installed with its installer. "
                                    + (_version == "dev build" ? "This is a dev build." : $"You're running {_version}.")
            : _updater.Pending is not null ? $"Version {_updater.Pending.Version} is ready. Restart to install it; your saves and settings stay as they are."
            : _checkingUpdates ? "Checking for updates…"
            : _updateError is not null ? _updateError
            : $"You're up to date ({_version}).";
    }

    // ---------------------------------------------------------------- updates

    private async void CheckForUpdates(bool quiet)
    {
        if (!_updater.IsInstalled || _checkingUpdates) return;
        _checkingUpdates = true;
        _updateError = null;
        UpdateVersionText();
        try
        {
            string? ready = await _updater.CheckAndDownloadAsync(percent => Dispatcher.BeginInvoke(() =>
            {
                UpdateBar.Visibility = percent is > 0 and < 100 ? Visibility.Visible : Visibility.Collapsed;
                UpdateBar.Value = percent;
            }));
            if (!quiet) ShowToast(ready is not null ? $"Update {ready} is ready." : "You're up to date.");
        }
        catch (UpdateSignatureException exception)
        {
            _updateError = exception.Message + " Please report this.";
        }
        catch (Exception exception)
        {
            _updateError = "Couldn't check for updates. Check your internet connection and try again. (" + exception.Message + ")";
            if (!quiet) ShowToast("Couldn't check for updates.");
        }
        finally
        {
            _checkingUpdates = false;
            UpdateBar.Visibility = Visibility.Collapsed;
            UpdateVersionText();
            if (_state is LauncherState.Ready or LauncherState.UpdateReady) RefreshGameState();
        }
    }

    private void CheckUpdatesClicked(object sender, RoutedEventArgs e) => CheckForUpdates(quiet: false);

    private void RestartToUpdateClicked(object sender, RoutedEventArgs e) => RestartToUpdate();

    private void RestartToUpdate()
    {
        if (Updater.IsGameRunning(_home.InstallFolder))
        {
            ShowToast("Close Fable II first, then restart to update.");
            return;
        }
        if (_dirty) SaveAll(quiet: true);
        try { _updater.ApplyAndRestart(); }
        catch (Exception exception) { ShowToast("Couldn't install the update: " + exception.Message); }
    }

    private void PlayWithoutUpdateClicked(object sender, RoutedEventArgs e) => LaunchGame();

    // ---------------------------------------------------------------- state

    private string ExecutableDirectory =>
        File.Exists(_home.ExecutablePath) ? _home.InstallFolder
        : File.Exists(Path.Combine(_home.GameFolder, "fable_2.exe")) ? _home.GameFolder   // dev: launcher outside the build folder
        : _home.InstallFolder;

    private void RefreshGameState()
    {
        DataFolderHint.Text = _home.DataFolder;
        if (!File.Exists(Path.Combine(ExecutableDirectory, "fable_2.exe")))
        {
            SetState(LauncherState.Problem, "Game program missing",
                "fable_2.exe isn't in the install folder. Reinstall Project Sparrow to fix this.", "Choose", "DISC IMAGE");
            return;
        }
        if (!File.Exists(Path.Combine(_home.GameFolder, "default.xex")))
        {
            SetState(LauncherState.NeedsDisc, "Choose your Fable II disc image",
                "Pick the .iso you made from your own Fable II Game of the Year disc. It's checked, then about 7 GB is copied into your data folder. The disc image is never uploaded.",
                "Choose", "DISC IMAGE");
            return;
        }
        try
        {
            GameCompatibility compatibility = GameCompatibilityInspector.Inspect(_home.GameFolder);
            GameLaunchPlanner.Create(ExecutableDirectory, _home.GameFolder, compatibility);
            if (_updater.Pending is not null)
                SetState(LauncherState.UpdateReady, $"Update {_updater.Pending.Version} is ready",
                    "Restarting installs it and keeps your saves and settings. It takes a few seconds.", "Restart", "TO UPDATE");
            else
                SetState(LauncherState.Ready, "Ready to play",
                    compatibility.Label + ". Keyboard: WASD to move, E or Shift to interact, Esc to pause.", "Play", null);
        }
        catch (Exception exception)
        {
            SetState(LauncherState.Problem, "This copy can't be played", exception.Message, "Choose", "ANOTHER DISC");
        }
    }

    private void SetState(LauncherState state, string title, string text, string seal, string? sealSub, bool warn = false)
    {
        _state = state;
        StatusTitle.Text = title;
        StatusText.Text = text;
        SealText.Text = seal;
        SealText.FontSize = sealSub is null ? 30 : 24;
        SealSubText.Text = sealSub ?? "";
        SealSubText.Visibility = sealSub is null ? Visibility.Collapsed : Visibility.Visible;
        SealButton.IsEnabled = state != LauncherState.Extracting;
        bool attention = warn || state is LauncherState.NeedsDisc or LauncherState.Problem;
        StatusDot.Fill = (Brush)FindResource(attention ? "Ember" : "Gold");
        ExtractBar.Visibility = state == LauncherState.Extracting ? Visibility.Visible : Visibility.Collapsed;
        ExtractActions.Visibility = state == LauncherState.Extracting ? Visibility.Visible : Visibility.Collapsed;
        PlayWithoutUpdateButton.Visibility = state == LauncherState.UpdateReady ? Visibility.Visible : Visibility.Collapsed;
    }

    private void SealClicked(object sender, RoutedEventArgs e)
    {
        switch (_state)
        {
            case LauncherState.Ready: LaunchGame(); break;
            case LauncherState.UpdateReady: RestartToUpdate(); break;
            case LauncherState.NeedsDisc:
            case LauncherState.Problem: ExtractFromIso(); break;
        }
    }

    // ---------------------------------------------------------------- settings

    private void LoadSettings()
    {
        _loading = true;
        try
        {
            _graphics.Clear();
            foreach ((string key, string value) in LauncherConfigFile.ReadLauncherValues(_home.DataFolder))
                _graphics[key] = value;
            _recomp = Fable2ConfigFile.Read(_home.RecompConfigPath);

            string resolution = (Get("window_width", ""), Get("window_height", "")) switch
            {
                ("1280", "720") => "720p", ("1920", "1080") => "1080p",
                ("2560", "1440") => "1440p", ("3840", "2160") => "4k",
                _ => "720p"
            };
            Edition edition = Edition.Find(_home.Settings.Edition);
            bool fresh = !_graphics.ContainsKey("resolution_scale");
            SelectByTag(ResolutionCombo, fresh ? edition.Resolution : resolution);
            SelectByTag(RenderScaleCombo, fresh ? edition.RenderScale : Get("resolution_scale", "1"));
            SelectByTag(AnisotropicCombo, fresh ? edition.Anisotropic : Get("anisotropic_override", "-1"));
            SelectByTag(AntiAliasingCombo, fresh ? edition.AntiAliasing : Unquote(Get("swap_post_effect", "none")));
            SelectByTag(FrameLimitCombo, fresh ? edition.FrameLimit : Get("frame_limit", "30"));
            SelectByTag(HostFrameLimitCombo, Get("host_frame_limit", "0"));
            bool fullscreen = ParseBool(Get("fullscreen", "true"), true);
            bool exclusive = ParseBool(Get("fullscreen_exclusive", "false"), false);
            SelectByTag(DisplayModeCombo, !fullscreen ? "windowed" : exclusive ? "exclusive" : "borderless");
            VsyncCheck.IsChecked = ParseBool(Get("vsync", "true"), true);

            SkipIntroCheck.IsChecked = _recomp.SkipIntroVideos;
            MotionBlurCheck.IsChecked = !_recomp.DisableMotionBlur;
            UnlockWebsiteCheck.IsChecked = _recomp.UnlockWebsite;
            UnlockCeCheck.IsChecked = _recomp.UnlockCe;
            HighTickCheck.IsChecked = _recomp.HighTickRate;
            HigherHfTickCheck.IsChecked = _recomp.HigherHfTickRate;
            MorphingCheck.IsChecked = _recomp.RealtimeTextureMorphing;
            ReadbackCheck.IsChecked = _recomp.HeroDogTextureReadback;
            YieldSlider.Value = Math.Clamp(_recomp.HotFuncYieldEvery, 0, 16);
            YieldValueText.Text = _recomp.HotFuncYieldEvery.ToString(CultureInfo.InvariantCulture);
            MouseLookCheck.IsChecked = _recomp.MouseLook;
            DirectMouseCheck.IsChecked = _recomp.DirectMouseLook;
            SensitivitySlider.Value = Math.Clamp(_recomp.MouseLookScale, 1, 4096);
            SensitivityBox.Text = _recomp.MouseLookScale.ToString(CultureInfo.InvariantCulture);
            BuildKeybindRows(Fable2ConfigFile.ParseKeybinds(_recomp.KeyboardGamepadMap));

            (edition.Id switch { "enhanced" => EditionEnhanced, "experimental" => EditionExperimental, _ => EditionOriginal })
                .IsChecked = true;
            (_home.Settings.Channel == "beta" ? ChannelBeta : ChannelStable).IsChecked = true;
        SetTheme(_home.Settings.Theme, save: false);
            if (fresh) _dirty = true;   // write the edition's settings on first save
        }
        finally { _loading = false; }
        UpdateCustomMarker();
    }

    private string Get(string key, string fallback) => _graphics.TryGetValue(key, out string? value) ? value : fallback;
    private static string Unquote(string value) => value.Trim().Trim('"', '\'');
    private static bool ParseBool(string value, bool fallback) => bool.TryParse(Unquote(value), out bool parsed) ? parsed : fallback;
    private static string TagOf(ComboBox combo, string fallback) => (combo.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? fallback;

    private static void SelectByTag(ComboBox combo, string tag)
    {
        foreach (object item in combo.Items)
            if (item is ComboBoxItem comboItem && string.Equals(comboItem.Tag?.ToString(), tag, StringComparison.OrdinalIgnoreCase))
            {
                combo.SelectedItem = comboItem;
                return;
            }
    }

    private void CollectRecomp()
    {
        _recomp.SkipIntroVideos = SkipIntroCheck.IsChecked == true;
        _recomp.DisableMotionBlur = MotionBlurCheck.IsChecked != true;
        _recomp.UnlockWebsite = UnlockWebsiteCheck.IsChecked == true;
        _recomp.UnlockCe = UnlockCeCheck.IsChecked == true;
        _recomp.HighTickRate = HighTickCheck.IsChecked == true;
        _recomp.HigherHfTickRate = HigherHfTickCheck.IsChecked == true;
        _recomp.RealtimeTextureMorphing = MorphingCheck.IsChecked == true;
        _recomp.HeroDogTextureReadback = ReadbackCheck.IsChecked == true;
        _recomp.HotFuncYieldEvery = (int)YieldSlider.Value;
        _recomp.MouseLook = MouseLookCheck.IsChecked == true;
        _recomp.DirectMouseLook = DirectMouseCheck.IsChecked == true;
        _recomp.MouseLookScale = (int)SensitivitySlider.Value;
        _recomp.KeyboardGamepadMap = CollectKeybinds();
    }

    private bool SaveAll(bool quiet = false)
    {
        try
        {
            Dictionary<string, string> graphics = GraphicsSettings.Create(TagOf(ResolutionCombo, "720p"),
                TagOf(RenderScaleCombo, "1"), TagOf(AnisotropicCombo, "-1"), TagOf(AntiAliasingCombo, "none"),
                TagOf(DisplayModeCombo, "borderless"), VsyncCheck.IsChecked == true,
                TagOf(FrameLimitCombo, "30"), TagOf(HostFrameLimitCombo, "0"));
            LauncherConfigFile.WriteValues(_home.GraphicsConfigPath, graphics, GraphicsSettings.ManagedKeys);
            LauncherConfigFile.WriteValues(_home.LauncherGraphicsPath, graphics, GraphicsSettings.ManagedKeys);
            CollectRecomp();
            Fable2ConfigFile.Write(_home.RecompConfigPath, _recomp);
            _home.Save();
            _dirty = false;
            return true;
        }
        catch (Exception exception)
        {
            if (!quiet)
                MessageBox.Show(this, exception.Message, "Could not save settings", MessageBoxButton.OK, MessageBoxImage.Error);
            return false;
        }
    }

    private void SettingChanged(object sender, SelectionChangedEventArgs e) => SettingChanged(sender, (RoutedEventArgs)e);

    private void SettingChanged(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _dirty = true;
        UpdateCustomMarker();
    }

    private void HighTickUnchecked(object sender, RoutedEventArgs e)
    {
        if (!_loading) HigherHfTickCheck.IsChecked = false;   // the faster animation tick needs it
        SettingChanged(sender, e);
    }

    private void HigherHfTickChecked(object sender, RoutedEventArgs e)
    {
        if (!_loading) HighTickCheck.IsChecked = true;
        SettingChanged(sender, e);
    }

    private void YieldChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (YieldValueText is null) return;
        YieldValueText.Text = ((int)e.NewValue).ToString(CultureInfo.InvariantCulture);
        SettingChanged(sender, e);
    }

    private void SensitivityChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (SensitivityBox is null) return;
        SensitivityBox.Text = ((int)e.NewValue).ToString(CultureInfo.InvariantCulture);
        SettingChanged(sender, e);
    }

    private void SensitivityBoxLostFocus(object sender, RoutedEventArgs e)
    {
        if (int.TryParse(SensitivityBox.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out int value))
            SensitivitySlider.Value = Math.Clamp(value, 1, 4096);
        SensitivityBox.Text = ((int)SensitivitySlider.Value).ToString(CultureInfo.InvariantCulture);
    }

    // ---------------------------------------------------------------- editions

    private void EditionChecked(object sender, RoutedEventArgs e)
    {
        if (_loading || sender is not RadioButton { IsChecked: true } choice) return;
        Edition edition = choice == EditionEnhanced ? Edition.Enhanced
                        : choice == EditionExperimental ? Edition.Experimental : Edition.Original;
        _loading = true;
        try
        {
            SelectByTag(ResolutionCombo, edition.Resolution);
            SelectByTag(RenderScaleCombo, edition.RenderScale);
            SelectByTag(AnisotropicCombo, edition.Anisotropic);
            SelectByTag(AntiAliasingCombo, edition.AntiAliasing);
            SelectByTag(FrameLimitCombo, edition.FrameLimit);
            MotionBlurCheck.IsChecked = !edition.DisableMotionBlur;
            HighTickCheck.IsChecked = edition.HighTickRate;
            HigherHfTickCheck.IsChecked = edition.HigherHfTickRate;
        }
        finally { _loading = false; }
        _home.Settings.Edition = edition.Id;
        if (SaveAll()) ShowToast($"{edition.Name} edition selected.");
        UpdateCustomMarker();
    }

    private void UpdateCustomMarker()
    {
        if (CustomMarker is null) return;
        CollectRecomp();
        bool matches = Edition.Find(_home.Settings.Edition).Matches(TagOf(ResolutionCombo, ""), TagOf(RenderScaleCombo, ""),
            TagOf(AnisotropicCombo, ""), TagOf(AntiAliasingCombo, ""), TagOf(FrameLimitCombo, ""), _recomp);
        CustomMarker.Visibility = matches ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ThemeChecked(object sender, RoutedEventArgs e)
    {
        if (_applyingTheme || sender is not RadioButton { Tag: string theme }) return;
        SetTheme(theme, save: !_loading);
    }

    /// <summary>Applies a theme and keeps the corner buttons and the Settings row in step.</summary>
    private void SetTheme(string theme, bool save)
    {
        theme = Themes.Normalize(theme);
        _applyingTheme = true;
        try
        {
            Themes.Apply(this, theme);
            (theme == Themes.Night ? QuickNight : theme == Themes.Day ? QuickDay : QuickDusk).IsChecked = true;
            (theme == Themes.Night ? ThemeNight : theme == Themes.Day ? ThemeDay : ThemeDusk).IsChecked = true;
        }
        finally { _applyingTheme = false; }
        if (_home.Settings.Theme == theme) return;
        _home.Settings.Theme = theme;
        if (save) try { _home.Save(); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private void ChannelChecked(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _home.Settings.Channel = ChannelBeta.IsChecked == true ? "beta" : "stable";
        try { _home.Save(); } catch (IOException) { }
        _updater.SetChannel(_home.Settings.Channel);
        RefreshGameState();
        CheckForUpdates(quiet: true);
        UpdateVersionText();
        ShowToast(_home.Settings.Channel == "beta"
            ? "Switched to Beta. Checking for beta updates…"
            : "Switched to Stable.");
    }

    // ---------------------------------------------------------------- launch

    private void LaunchGame()
    {
        try
        {
            GameLaunchPlan plan = GameLaunchPlanner.Create(ExecutableDirectory, _home.GameFolder,
                GameCompatibilityInspector.Inspect(_home.GameFolder));
            if (!SaveAll()) return;
            _home.SyncScripts();
            Directory.CreateDirectory(_home.DataFolder);
            var startInfo = new ProcessStartInfo
            {
                FileName = plan.Executable,
                // Logs and traces land in the data folder, never the install folder.
                WorkingDirectory = _home.DataFolder,
                UseShellExecute = false
            };
            startInfo.ArgumentList.Add("--game_data_root=" + plan.GameRoot);
            startInfo.ArgumentList.Add("--user_root=" + _home.DataFolder);
            Process.Start(startInfo);
            _gameLaunched = true;
            Close();
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "Could not start Fable II", MessageBoxButton.OK, MessageBoxImage.Error);
            RefreshGameState();
        }
    }

    // ---------------------------------------------------------------- disc extraction

    private volatile bool _stopRequested;
    private TaskCompletionSource<bool>? _hashDecision;
    private long _lastUiPush;
    private double _lastPushedPercent = -1;

    private void ExtractFromIso()
    {
        if (_state == LauncherState.Extracting) return;
        var dialog = new OpenFileDialog
        {
            Title = "Choose your Fable II disc image",
            Filter = "Disc image (*.iso)|*.iso",
            CheckFileExists = true
        };
        if (dialog.ShowDialog(this) != true) return;
        string isoPath = dialog.FileName;

        // New disc images always go into the data folder's own game folder.
        string? previousGameFolder = _home.Settings.GameFolder;
        _home.Settings.GameFolder = null;
        string outDir = _home.GameFolder;
        try { Directory.CreateDirectory(outDir); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            MessageBox.Show(this, exception.Message, "Could not create the game folder", MessageBoxButton.OK, MessageBoxImage.Error);
            return;
        }

        _stopRequested = false;
        SetState(LauncherState.Extracting, "Reading the disc image", "Looking for the Xbox 360 file system…", "…", "READING");
        ExtractBar.IsIndeterminate = true;
        ExtractAnywayButton.Visibility = Visibility.Collapsed;
        StopButton.IsEnabled = true;

        Task.Run(async () =>
        {
            string? error = null;
            bool cancelled = false;
            int files = 0;
            long bytes = 0;
            try
            {
                using DiscExtraction disc = DiscExtraction.Open(isoPath, _ => { });
                List<RootItem> layout = disc.Plan.ToList();
                var progress = new ExtractionProgress(layout, () => _stopRequested);
                progress.Changed += p => Dispatcher.BeginInvoke(() => PushProgress(p));
                if (_stopRequested) throw new ExtractionCancelledException();
                Dispatcher.Invoke(() => { ExtractBar.IsIndeterminate = false; ExtractBar.Value = 0; _lastPushedPercent = -1; });

                // Extract under a temporary name so a rejected disc never replaces a good default.xex.
                const string tempName = "default_new.xex";
                string tempXex = Path.Combine(outDir, tempName);
                string hash = disc.ExtractXex(outDir, _ => { }, progress, tempName);
                (bool ok, string message) = GameCompatibilityInspector.CheckHash(hash);
                if (!ok)
                {
                    var decision = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                    _hashDecision = decision;
                    Dispatcher.Invoke(() => ShowHashPrompt(message));
                    bool goOn = await decision.Task;
                    _hashDecision = null;
                    if (!goOn)
                    {
                        try { File.Delete(tempXex); } catch (IOException) { }
                        throw new ExtractionCancelledException();
                    }
                }
                File.Move(tempXex, Path.Combine(outDir, "default.xex"), overwrite: true);
                (files, bytes) = disc.ExtractRemaining(outDir, _ => { }, progress);
            }
            catch (ExtractionCancelledException) { cancelled = true; }
            catch (Exception exception) { error = exception.Message; }

            Dispatcher.Invoke(() =>
            {
                if (cancelled || error is not null) _home.Settings.GameFolder = previousGameFolder;
                try { _home.Save(); } catch (IOException) { }
                RefreshGameState();
                if (cancelled) ShowToast("Stopped copying the disc.");
                else if (error is not null)
                    MessageBox.Show(this, error, "Could not read the disc image", MessageBoxButton.OK, MessageBoxImage.Error);
                else ShowToast($"Copied {files:N0} files ({DiscExtraction.FormatSize(bytes)}) from {Path.GetFileName(isoPath)}.");
            });
        });
    }

    private void PushProgress(ExtractionProgress progress)
    {
        if (_state != LauncherState.Extracting || _hashDecision is not null) return;
        long now = Environment.TickCount64;
        double pct = progress.Percent;
        if (pct < 100 && now - _lastUiPush < 80 && pct - _lastPushedPercent < 0.25) return;
        _lastUiPush = now;
        _lastPushedPercent = pct;
        ExtractBar.Value = pct;
        SealText.Text = $"{pct:0}%";
        SealSubText.Text = "COPYING";
        StatusTitle.Text = "Copying game files";
        StatusText.Text = $"{DiscExtraction.FormatSize(progress.CompletedBytes + progress.CurrentFileWritten)} of "
                          + $"{DiscExtraction.FormatSize(progress.TotalBytes)} · {progress.CurrentFile ?? progress.Phase}";
    }

    private void ShowHashPrompt(string message)
    {
        StatusTitle.Text = "This disc isn't a known Fable II GOTY copy";
        StatusText.Text = message + " It probably won't run. You can stop, or copy it anyway.";
        StatusDot.Fill = (Brush)FindResource("Ember");
        ExtractAnywayButton.Visibility = Visibility.Visible;
    }

    private void ExtractAnywayClicked(object sender, RoutedEventArgs e)
    {
        ExtractAnywayButton.Visibility = Visibility.Collapsed;
        StatusDot.Fill = (Brush)FindResource("Gold");
        _hashDecision?.TrySetResult(true);
    }

    private void StopClicked(object sender, RoutedEventArgs e)
    {
        StopButton.IsEnabled = false;
        StatusTitle.Text = "Stopping…";
        if (_hashDecision is not null) _hashDecision.TrySetResult(false);
        else _stopRequested = true;
    }

    // ---------------------------------------------------------------- parchment page

    private bool _pageOpen;

    private void OpenSettingsClicked(object sender, RoutedEventArgs e) => OpenPage(TabSettings);
    private void OpenHelpClicked(object sender, RoutedEventArgs e) => OpenPage(TabHelp);
    private void ClosePageClicked(object sender, RoutedEventArgs e) => ClosePage();
    private void ScrimMouseDown(object sender, MouseButtonEventArgs e) => ClosePage();

    private void OpenPage(RadioButton tab)
    {
        _turnOnTabChange = false;
        tab.IsChecked = true;
        ShowPanel(tab);
        _turnOnTabChange = true;
        if (_pageOpen) return;
        _pageOpen = true;
        Scrim.Visibility = Visibility.Visible;
        PageHost.Visibility = Visibility.Visible;
        if (!AnimationsOn)
        {
            PageScale.ScaleX = 1;
            Scrim.Opacity = 1;
            return;
        }
        // The page swings in from the window's right edge, like a page being turned onto the scene.
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        var duration = TimeSpan.FromMilliseconds(650);
        PageScale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.02, 1, duration) { EasingFunction = ease });
        PageSkew.BeginAnimation(SkewTransform.AngleYProperty, new DoubleAnimation(-9, 0, duration) { EasingFunction = ease });
        PageShade.BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0, duration));
        Scrim.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(300)));
    }

    private void ClosePage()
    {
        if (!_pageOpen) return;
        _pageOpen = false;
        if (_dirty) SaveAll();
        _activeKeyField = null;
        if (!AnimationsOn)
        {
            PageHost.Visibility = Visibility.Collapsed;
            Scrim.Visibility = Visibility.Collapsed;
            return;
        }
        var ease = new CubicEase { EasingMode = EasingMode.EaseIn };
        var duration = TimeSpan.FromMilliseconds(420);
        var fold = new DoubleAnimation(1, 0.02, duration) { EasingFunction = ease };
        fold.Completed += (_, _) =>
        {
            if (_pageOpen) return;
            PageHost.Visibility = Visibility.Collapsed;
            Scrim.Visibility = Visibility.Collapsed;
        };
        PageScale.BeginAnimation(ScaleTransform.ScaleXProperty, fold);
        PageSkew.BeginAnimation(SkewTransform.AngleYProperty, new DoubleAnimation(0, -9, duration) { EasingFunction = ease });
        PageShade.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 0.8, duration));
        Scrim.BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0, duration));
    }

    private bool _turnOnTabChange = true;

    private void TabChecked(object sender, RoutedEventArgs e)
    {
        if (sender is not RadioButton tab || PanelSettings is null) return;
        ShowPanel(tab);
        if (!_turnOnTabChange || !_pageOpen || !AnimationsOn) return;
        // A new page turns in from the right edge.
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        var duration = TimeSpan.FromMilliseconds(480);
        ContentScale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.05, 1, duration) { EasingFunction = ease });
        PageShade.BeginAnimation(OpacityProperty, new DoubleAnimation(0.9, 0, duration));
    }

    private void ShowPanel(RadioButton tab)
    {
        PanelSettings.Visibility = tab == TabSettings ? Visibility.Visible : Visibility.Collapsed;
        PanelControls.Visibility = tab == TabControls ? Visibility.Visible : Visibility.Collapsed;
        PanelUpdates.Visibility = tab == TabUpdates ? Visibility.Visible : Visibility.Collapsed;
        PanelHelp.Visibility = tab == TabHelp ? Visibility.Visible : Visibility.Collapsed;
        PageScroll.ScrollToTop();
    }

    // ---------------------------------------------------------------- help actions

    private void ReportToggleClicked(object sender, RoutedEventArgs e) => Toggle(ReportPanel);

    private void FolderToggleClicked(object sender, RoutedEventArgs e)
    {
        FolderPanelText.Text = $"Your saves, settings and logs live in {_home.DataFolder}. "
            + (LauncherHome.IsInside(_home.GameFolder, _home.DataFolder)
                ? "The game files (about 7 GB) are in there too. "
                : $"The game files are read from {_home.GameFolder}. ")
            + "Updates never touch this folder.";
        Toggle(FolderPanel);
    }

    private static void Toggle(UIElement element) =>
        element.Visibility = element.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;

    private void CreateReportClicked(object sender, RoutedEventArgs e)
    {
        try
        {
            string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            string zip = ProblemReport.Create(_home, _version, _home.Settings.Edition, desktop);
            OpenInShell(ProblemReport.IssueUrl(_version, _home.Settings.Edition));
            ShowToast($"Saved {Path.GetFileName(zip)} to your desktop. Attach it to the GitHub issue that just opened.");
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "Could not create the report", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async void CheckFilesClicked(object sender, RoutedEventArgs e)
    {
        if (!File.Exists(Path.Combine(_home.GameFolder, "default.xex")))
        {
            ShowToast("No game files yet. Choose your disc image first.");
            return;
        }
        ShowToast("Checking game files…");
        string folder = _home.GameFolder;
        GameCompatibility result = await Task.Run(() => GameCompatibilityInspector.Inspect(folder));
        ShowToast(result.Supported ? $"Game files look good: {result.Label}." : $"{result.Label}: {result.Message}");
        RefreshGameState();
    }

    private void OpenSavesClicked(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(_home.SavesFolder);
        OpenInShell(_home.SavesFolder);
    }

    private async void MoveDataClicked(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Choose an empty folder for your Project Sparrow data" };
        if (dialog.ShowDialog(this) != true) return;
        string target = dialog.FolderName;
        MoveDataButton.IsEnabled = false;
        ShowToast("Moving your data. This can take a few minutes for the game files…");
        try
        {
            if (_dirty) SaveAll();
            await Task.Run(() => _home.MoveDataFolder(target));
            ShowToast($"Moved. Your data now lives in {_home.DataFolder}.");
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "Could not move the data folder", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            MoveDataButton.IsEnabled = true;
            FolderPanel.Visibility = Visibility.Collapsed;
            RefreshGameState();
        }
    }

    private void UseGameFolderClicked(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Choose a folder with default.xex and data" };
        if (dialog.ShowDialog(this) != true) return;
        if (!File.Exists(Path.Combine(dialog.FolderName, "default.xex")) ||
            !Directory.Exists(Path.Combine(dialog.FolderName, "data")))
        {
            ShowToast("That folder doesn't have default.xex and a data folder.");
            return;
        }
        _home.Settings.GameFolder = dialog.FolderName;
        try { _home.Save(); } catch (IOException) { }
        FolderPanel.Visibility = Visibility.Collapsed;
        RefreshGameState();
        ShowToast($"Using the game files in {dialog.FolderName}.");
    }

    private void ClearShaderCacheClicked(object sender, RoutedEventArgs e)
    {
        string shaders = Path.Combine(_home.CacheFolder, "shaders");
        try
        {
            if (Directory.Exists(shaders)) Directory.Delete(shaders, recursive: true);
            ShowToast("Shader cache cleared. The first few minutes may stutter while it rebuilds.");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            ShowToast("Couldn't clear the cache. Close the game first, then try again.");
        }
    }

    private static void OpenInShell(string target) =>
        Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });

    private void ShowToast(string message)
    {
        ToastText.Text = message;
        Toast.Visibility = Visibility.Visible;
        _toastTimer.Stop();
        _toastTimer.Start();
    }

    // ---------------------------------------------------------------- window chrome

    private void MinimizeClicked(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    private void MaximizeClicked(object sender, RoutedEventArgs e) =>
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
    private void CloseClicked(object sender, RoutedEventArgs e) => Close();

    // ---------------------------------------------------------------- keyboard keys editor

    private sealed class KeyCaptureField
    {
        public TextBlock Text = null!;
        public string Value = "";
    }

    private readonly List<Border> _keyFields = new();
    private readonly List<ComboBox> _buttonCombos = new();
    private Border? _activeKeyField;
    private static readonly Brush KeyIdleBackground = new SolidColorBrush(Color.FromRgb(0xF6, 0xEE, 0xD6));
    private static readonly Brush KeyIdleBorder = new SolidColorBrush(Color.FromRgb(0xBF, 0xAE, 0x80));
    private static readonly Brush KeyListeningBackground = new SolidColorBrush(Color.FromRgb(0xE4, 0xEF, 0xE4));
    private static readonly Brush KeyListeningBorder = new SolidColorBrush(Color.FromRgb(0x1F, 0x4A, 0x37));
    private static readonly Brush KeyText = new SolidColorBrush(Color.FromRgb(0x2B, 0x24, 0x14));

    private void BuildKeybindRows(List<KeybindEntry> entries)
    {
        KeybindList.Children.Clear();
        _keyFields.Clear();
        _buttonCombos.Clear();
        _activeKeyField = null;
        foreach (KeybindEntry entry in entries) AddKeybindRow(entry.Key, entry.Button);
    }

    private void AddKeybindClicked(object sender, RoutedEventArgs e)
    {
        AddKeybindRow("", Fable2ConfigFile.ButtonNames[0]);
        SettingChanged(sender, e);
    }

    private void ResetKeybindsClicked(object sender, RoutedEventArgs e)
    {
        BuildKeybindRows(Fable2ConfigFile.ParseKeybinds(Fable2ConfigValues.DefaultKeyboardGamepadMap));
        SettingChanged(sender, e);
    }

    private void AddKeybindRow(string key, string button)
    {
        var grid = new Grid { Margin = new Thickness(0, 0, 0, 6) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(10) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var capture = new KeyCaptureField { Value = key };
        var field = new Border
        {
            Background = KeyIdleBackground, BorderBrush = KeyIdleBorder, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6), MinHeight = 34, Padding = new Thickness(10, 4, 10, 4),
            Cursor = Cursors.Hand, Tag = capture
        };
        capture.Text = new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(key) ? "press a key…" : key, Foreground = KeyText,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, FontSize = 14
        };
        field.Child = capture.Text;
        field.MouseDown += (_, e) =>
        {
            string? mouse = e.ChangedButton switch
            {
                MouseButton.Left => "LMB", MouseButton.Right => "RMB", MouseButton.Middle => "MMB",
                MouseButton.XButton1 => "XMB1", MouseButton.XButton2 => "XMB2", _ => null
            };
            if (mouse is null) return;
            if (mouse == "LMB" && !ReferenceEquals(_activeKeyField, field)) { BeginKeyCapture(field); return; }
            if (ReferenceEquals(_activeKeyField, field)) SetKeyCaptureValue(field, mouse);
        };

        var combo = new ComboBox { MinWidth = 0 };
        foreach (string name in Fable2ConfigFile.ButtonNames)
            combo.Items.Add(new ComboBoxItem { Content = name, Tag = name });
        SelectByTag(combo, button);
        if (combo.SelectedItem is null) combo.SelectedIndex = 0;
        combo.SelectionChanged += (s, e) => SettingChanged(s, (RoutedEventArgs)e);

        var remove = new Button { Content = "✕", Style = (Style)FindResource("PageButton"), Margin = new Thickness(8, 0, 0, 0), ToolTip = "Remove this key" };
        remove.Click += (s, e) =>
        {
            KeybindList.Children.Remove(grid);
            _keyFields.Remove(field);
            _buttonCombos.Remove(combo);
            if (ReferenceEquals(_activeKeyField, field)) _activeKeyField = null;
            SettingChanged(s, e);
        };

        Grid.SetColumn(field, 0);
        Grid.SetColumn(combo, 2);
        Grid.SetColumn(remove, 3);
        grid.Children.Add(field);
        grid.Children.Add(combo);
        grid.Children.Add(remove);
        KeybindList.Children.Add(grid);
        _keyFields.Add(field);
        _buttonCombos.Add(combo);
    }

    private void BeginKeyCapture(Border field)
    {
        if (_activeKeyField is not null && _activeKeyField != field) SetKeyCaptureIdle(_activeKeyField);
        _activeKeyField = field;
        field.Background = KeyListeningBackground;
        field.BorderBrush = KeyListeningBorder;
        ((KeyCaptureField)field.Tag!).Text.Text = "listening…";
    }

    private void SetKeyCaptureValue(Border field, string name)
    {
        var capture = (KeyCaptureField)field.Tag!;
        capture.Value = name;
        capture.Text.Text = name;
        field.Background = KeyIdleBackground;
        field.BorderBrush = KeyIdleBorder;
        _activeKeyField = null;
        _dirty = true;
    }

    private static void SetKeyCaptureIdle(Border field)
    {
        var capture = (KeyCaptureField)field.Tag!;
        capture.Text.Text = string.IsNullOrWhiteSpace(capture.Value) ? "press a key…" : capture.Value;
        field.Background = KeyIdleBackground;
        field.BorderBrush = KeyIdleBorder;
    }

    private void WindowPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (_activeKeyField is null)
        {
            if (e.Key == Key.Escape && _pageOpen) { ClosePage(); e.Handled = true; }
            return;
        }
        if (e.Key == Key.Escape)
        {
            SetKeyCaptureIdle(_activeKeyField);
            _activeKeyField = null;
            e.Handled = true;
            return;
        }
        string? name = KeyToName(e.Key == Key.System ? e.SystemKey : e.Key);
        if (name is null) return;
        SetKeyCaptureValue(_activeKeyField, name);
        e.Handled = true;
    }

    private string CollectKeybinds()
    {
        var entries = new List<KeybindEntry>();
        for (int i = 0; i < _keyFields.Count; i++)
        {
            string key = ((KeyCaptureField)_keyFields[i].Tag!).Value;
            string button = (_buttonCombos[i].SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "";
            if (!string.IsNullOrWhiteSpace(key) || !string.IsNullOrWhiteSpace(button))
                entries.Add(new KeybindEntry { Key = key, Button = button });
        }
        return Fable2ConfigFile.BuildKeybinds(entries);
    }

    // Host-key names understood by rex::ui::ParseVirtualKey (see Fable2ConfigFile.KeyNames).
    private static string? KeyToName(Key key)
    {
        if (key >= Key.A && key <= Key.Z) return ((char)('A' + (key - Key.A))).ToString();
        if (key >= Key.D0 && key <= Key.D9) return ((char)('0' + (key - Key.D0))).ToString();
        if (key >= Key.F1 && key <= Key.F24) return "F" + (int)(key - Key.F1 + 1);
        if (key >= Key.NumPad0 && key <= Key.NumPad9) return "Numpad" + (int)(key - Key.NumPad0);
        return key switch
        {
            Key.Add => "NumpadPlus", Key.Subtract => "NumpadMinus", Key.Multiply => "NumpadStar",
            Key.Divide => "NumpadSlash", Key.Left => "Left", Key.Right => "Right", Key.Up => "Up",
            Key.Down => "Down", Key.Home => "Home", Key.End => "End", Key.PageUp => "PageUp",
            Key.PageDown => "PageDown", Key.Delete => "Delete", Key.Insert => "Insert",
            Key.Back => "Backspace", Key.Return => "Return", Key.Space => "Space", Key.Tab => "Tab",
            Key.LeftShift or Key.RightShift => "Shift", Key.LeftCtrl or Key.RightCtrl => "Control",
            Key.LeftAlt or Key.RightAlt => "Alt", Key.PrintScreen => "PrintScreen", Key.Pause => "Pause",
            Key.CapsLock => "CapsLock", Key.NumLock => "NumLock", Key.Scroll => "ScrollLock",
            Key.OemTilde => "Backtick", Key.OemMinus => "Minus", Key.OemPlus => "Plus",
            Key.OemComma => "Comma", Key.OemPeriod => "Period", Key.OemSemicolon => "Semicolon",
            Key.OemQuestion => "Slash", Key.OemBackslash => "Backslash", Key.OemOpenBrackets => "LBracket",
            Key.OemCloseBrackets => "RBracket", Key.OemQuotes => "Quote",
            _ => null,
        };
    }
}
