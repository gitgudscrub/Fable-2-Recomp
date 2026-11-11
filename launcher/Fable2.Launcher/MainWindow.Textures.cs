using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;

namespace Fable2Launcher;

/// <summary>
/// Settings > Modern textures: downloads the pre-built texture pack in parts
/// (see TexturePack and docs/TEXTURE_PACK_DOWNLOAD.md). Modern graphics stay
/// off in fable2_config.toml until every part is in, so a half pack never
/// shows as a patchy mix; the player can still flip F8 in game.
/// </summary>
public partial class MainWindow
{
    private TexturePack Textures => new(_home.DataFolder);
    private TexturePackManifest? _texturesManifest;
    private bool _texturesChecked;
    private bool _texturesBusy;
    private CancellationTokenSource? _texturesCancel;
    private readonly Dictionary<string, (TextBlock Label, ProgressBar Bar)> _partRows = new();

    /// <summary>Shows what is installed, from disk only; checks for a pack online once per session.</summary>
    private void RefreshTexturesSection()
    {
        if (_texturesBusy) return;
        TexturePack pack = Textures;
        TexturePackState state = pack.State;
        bool installedSomething = state.Parts.Count > 0;
        TexturePackManifest? manifest = _texturesManifest;
        bool complete = manifest is not null && pack.IsComplete(manifest);
        List<TexturePackPart>? missing = manifest is null ? null : pack.MissingParts(manifest);

        TexturesParts.Visibility = Visibility.Collapsed;
        TexturesPauseButton.Visibility = Visibility.Collapsed;
        TexturesRemoveButton.Visibility = installedSomething ? Visibility.Visible : Visibility.Collapsed;
        TexturesDownloadButton.Visibility = Visibility.Visible;
        TexturesDownloadButton.IsEnabled = true;

        if (manifest is null)
        {
            TexturesStatusText.Text = installedSomething
                ? $"Version {state.Version} installed ({TexturePack.FormatSize(pack.InstalledBytes)}, {state.Parts.Count} parts)."
                : "Not installed.";
            TexturesHintText.Text = _texturesChecked
                ? "No texture pack has been published yet."
                : "Upscaled, hand-tuned textures for the whole game, drawn with a key from your own game files. "
                  + "Around 6 GB; downloads in parts and can be paused.";
            TexturesDownloadButton.Content = installedSomething ? "Check for updates" : "Download";
            return;
        }

        string size = TexturePack.FormatSize(manifest.TotalBytes);
        if (complete)
        {
            TexturesStatusText.Text = $"Version {manifest.Version} installed ({size}). You're up to date.";
            TexturesHintText.Text = "Shows at a render scale of 2× or more. F8 in game switches between Modern and Classic.";
            TexturesDownloadButton.Visibility = Visibility.Collapsed;
        }
        else if (installedSomething && missing is not null)
        {
            long remaining = missing.Sum(part => part.Size);
            TexturesStatusText.Text = state.Version == manifest.Version
                ? $"Version {manifest.Version}: {missing.Count} of {manifest.Parts.Count} parts still to download ({TexturePack.FormatSize(remaining)})."
                : $"Version {manifest.Version} is available: {missing.Count} parts changed ({TexturePack.FormatSize(remaining)}).";
            TexturesHintText.Text = "Modern textures stay off until every part is in, so the game never shows a half pack.";
            TexturesDownloadButton.Content = state.Version == manifest.Version ? "Resume" : "Update";
        }
        else
        {
            TexturesStatusText.Text = $"Version {manifest.Version}: {size} in {manifest.Parts.Count} parts.";
            TexturesHintText.Text = "Upscaled, hand-tuned textures for the whole game, drawn with a key from your own game files. "
                                    + "Shows at a render scale of 2× or more; skip it on a weaker PC.";
            TexturesDownloadButton.Content = "Download";
        }
    }

    /// <summary>Fetches the manifest once per session when the Settings page opens.</summary>
    private async void CheckTexturesQuietly()
    {
        if (_texturesChecked || _texturesBusy) return;
        _texturesChecked = true;
        try { _texturesManifest = await Textures.FetchManifestAsync(CancellationToken.None); }
        catch (Exception) { _texturesChecked = false; }   // offline: try again next time the page opens
        RefreshTexturesSection();
    }

    private async void TexturesDownloadClicked(object sender, RoutedEventArgs e)
    {
        if (_texturesBusy) return;
        _texturesBusy = true;
        _texturesCancel = new CancellationTokenSource();
        CancellationToken cancel = _texturesCancel.Token;
        TexturePack pack = Textures;
        TexturesDownloadButton.IsEnabled = false;
        TexturesRemoveButton.Visibility = Visibility.Collapsed;
        TexturesHintText.Text = "";
        string? failure = null;
        bool finished = false;
        try
        {
            TexturesStatusText.Text = "Looking for the newest texture pack…";
            TexturePackManifest? manifest = _texturesManifest ?? await pack.FetchManifestAsync(cancel);
            _texturesChecked = true;
            _texturesManifest = manifest;
            if (manifest is null)
            {
                failure = "No texture pack has been published yet.";
                return;
            }
            string? profile = GameCompatibilityInspector.Inspect(_home.GameFolder).Profile;
            if (!string.Equals(profile, manifest.GameProfile, StringComparison.OrdinalIgnoreCase))
            {
                failure = $"This pack was made for the {manifest.GameProfile} game files and won't open with yours ({profile ?? "unknown"}).";
                return;
            }
            if (pack.IsComplete(manifest))
            {
                finished = true;
                return;
            }

            // Off until the last part is in; a half pack would show as a patchy mix.
            SetModernGraphics(false);
            TexturesDownloadButton.Visibility = Visibility.Collapsed;
            TexturesPauseButton.Visibility = Visibility.Visible;
            BuildPartRows(pack.MissingParts(manifest));
            TexturesStatusText.Text = $"Downloading version {manifest.Version}…";
            TexturesHintText.Text = "You can close the launcher or play in the meantime; the download resumes where it stopped.";

            var progress = new Progress<PartProgress>(UpdatePartRow);
            await pack.DownloadAsync(manifest, progress, cancel);
            finished = true;
        }
        catch (OperationCanceledException)
        {
            TexturesHintText.Text = "Paused. The download resumes where it stopped.";
        }
        catch (TexturePackException exception) { failure = exception.Message; }
        catch (Exception exception)
        {
            failure = "Couldn't download the texture pack. Check your internet connection and try again. (" + exception.Message + ")";
        }
        finally
        {
            _texturesBusy = false;
            _texturesCancel.Dispose();
            _texturesCancel = null;
            if (finished)
            {
                SetModernGraphics(true);
                RefreshTexturesSection();
                ShowToast("Modern textures installed. They show the next time the game starts.");
            }
            else
            {
                RefreshTexturesSection();
                if (failure is not null) TexturesHintText.Text = failure;
            }
        }
    }

    private void TexturesPauseClicked(object sender, RoutedEventArgs e) => _texturesCancel?.Cancel();

    private void TexturesRemoveClicked(object sender, RoutedEventArgs e)
    {
        if (_texturesBusy) return;
        if (Updater.IsGameRunning(_home.InstallFolder))
        {
            ShowToast("Close Fable II first, then remove the textures.");
            return;
        }
        try
        {
            Textures.Remove();
            SetModernGraphics(true);   // the rest of Modern graphics works without the pack
            ShowToast("Modern textures removed.");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            ShowToast("Couldn't remove the textures: " + exception.Message);
        }
        RefreshTexturesSection();
    }

    /// <summary>Writes [graphics] texture_pack, keeping the in-memory settings in step.</summary>
    private void SetModernGraphics(bool on)
    {
        if (_recomp.TexturePack == on && File.Exists(_home.RecompConfigPath)) return;
        _recomp.TexturePack = on;
        try { Fable2ConfigFile.Write(_home.RecompConfigPath, _recomp); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            ShowToast("Couldn't update fable2_config.toml: " + exception.Message);
        }
    }

    private void BuildPartRows(List<TexturePackPart> parts)
    {
        TexturesParts.Children.Clear();
        _partRows.Clear();
        foreach (TexturePackPart part in parts)
        {
            var label = new TextBlock { Style = (Style)FindResource("PageHint"), Text = PartLabel(part, "waiting") };
            var bar = new ProgressBar { Style = (Style)FindResource("ThinBar"), Maximum = part.Size, Margin = new Thickness(0, 3, 0, 0) };
            var cell = new StackPanel { Margin = new Thickness(0, 2, 12, 4) };
            cell.Children.Add(label);
            cell.Children.Add(bar);
            TexturesParts.Children.Add(cell);
            _partRows[part.Name] = (label, bar);
        }
        TexturesParts.Visibility = parts.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void UpdatePartRow(PartProgress progress)
    {
        if (!_partRows.TryGetValue(progress.Name, out var row)) return;
        row.Bar.Value = progress.Status is PartStatus.Installed ? progress.Size : progress.Done;
        row.Label.Text = progress.Status switch
        {
            PartStatus.Downloading => $"{PartTitle(progress.Name)} · {TexturePack.FormatSize(progress.Done)} of {TexturePack.FormatSize(progress.Size)}",
            PartStatus.Verifying => $"{PartTitle(progress.Name)} · checking",
            PartStatus.Unpacking => $"{PartTitle(progress.Name)} · unpacking",
            PartStatus.Installed => $"{PartTitle(progress.Name)} · installed",
            PartStatus.Failed => $"{PartTitle(progress.Name)} · failed",
            _ => $"{PartTitle(progress.Name)} · waiting"
        };
    }

    private static string PartLabel(TexturePackPart part, string state) =>
        $"{PartTitle(part.Name)} · {TexturePack.FormatSize(part.Size)} · {state}";

    /// <summary>"modern-textures-v1-part07.zip" -> "Part 8".</summary>
    private static string PartTitle(string name)
    {
        int at = name.LastIndexOf("part", StringComparison.OrdinalIgnoreCase);
        return at >= 0 && int.TryParse(name.AsSpan(at + 4, 2), out int index) ? $"Part {index + 1}" : name;
    }
}
