using System.IO;
using System.Windows;

namespace Fable2Launcher;

/// <summary>
/// Settings > Remade models: downloads the keyed model pack (TexturePack with
/// PackKind.Models), then builds the game files it changes on this PC
/// (SparrowModels.Build into ModelPack.PackFolder). Each model opens only with
/// the player's own original, so the pack holds no game data. Playing Sparrow
/// Edition rebuilds first when the game files or the pack changed.
/// </summary>
public partial class MainWindow
{
    private TexturePack ModelDownloads => new(_home.DataFolder, PackKind.Models);
    private ModelPack Models => new(_home.DataFolder);
    private TexturePackManifest? _modelsManifest;
    private bool _modelsChecked;
    private bool _modelsBusy;
    private CancellationTokenSource? _modelsCancel;
    private CancellationTokenSource? _buildCancel;

    private void RefreshModelsSection()
    {
        if (_modelsBusy) return;
        TexturePack pack = ModelDownloads;
        ModelPack models = Models;
        TexturePackManifest? manifest = _modelsManifest;
        bool downloaded = pack.State.Parts.Count > 0;
        bool complete = manifest is not null ? pack.IsComplete(manifest) : models.Downloaded;
        bool built = models.Ready(_home.GameFolder);

        ModelsBar.Visibility = Visibility.Collapsed;
        ModelsPauseButton.Visibility = Visibility.Collapsed;
        ModelsRemoveButton.Visibility = downloaded || models.Installed && !models.Custom ? Visibility.Visible : Visibility.Collapsed;
        ModelsDownloadButton.Visibility = Visibility.Visible;
        ModelsDownloadButton.IsEnabled = true;
        string about = "More detailed characters, creatures and objects for Enhanced and Project Sparrow, built from your own game files on this PC.";

        if (models.Custom)
        {
            ModelsStatusText.Text = models.Installed ? "Using a local model pack (PROJECT_SPARROW_MODELS)." : "The local model pack folder is empty.";
            ModelsHintText.Text = models.PackFolder;
            ModelsDownloadButton.Visibility = Visibility.Collapsed;
            ModelsRemoveButton.Visibility = Visibility.Collapsed;
            return;
        }
        if (manifest is not null && complete && built)
        {
            ModelsStatusText.Text = $"Version {manifest.Version} installed. You're up to date.";
            ModelsHintText.Text = "Shows in Enhanced and Project Sparrow with Use detailed models on.";
            ModelsDownloadButton.Visibility = Visibility.Collapsed;
        }
        else if (manifest is not null && downloaded && !complete)
        {
            ModelsStatusText.Text = pack.State.Version == manifest.Version
                ? $"Version {manifest.Version}: download stopped part-way."
                : $"Version {manifest.Version} is available.";
            ModelsHintText.Text = "Enhanced and Project Sparrow keep the original models until the download finishes.";
            ModelsDownloadButton.Content = pack.State.Version == manifest.Version ? "Resume" : "Update";
        }
        else if (complete && !built)
        {
            ModelsStatusText.Text = "Downloaded; the models still need to be built for your game files.";
            ModelsHintText.Text = "Takes a few minutes and about " + TexturePack.FormatSize(ModelPack.BuildBytes(_home.GameFolder))
                                  + " of disk space. It also runs on its own when you play Enhanced or Project Sparrow.";
            ModelsDownloadButton.Content = "Build";
        }
        else if (complete)
        {
            ModelsStatusText.Text = $"Version {pack.State.Version} installed.";
            ModelsHintText.Text = "Shows in Enhanced and Project Sparrow with Use detailed models on.";
            ModelsDownloadButton.Content = "Check for updates";
        }
        else if (manifest is not null)
        {
            ModelsStatusText.Text = $"Version {manifest.Version}: {TexturePack.FormatSize(manifest.TotalBytes)} to download.";
            ModelsHintText.Text = about;
            ModelsDownloadButton.Content = "Download";
        }
        else
        {
            ModelsStatusText.Text = "Not installed.";
            ModelsHintText.Text = _modelsChecked ? "No model pack has been published yet." : about;
            ModelsDownloadButton.Content = "Download";
        }
    }

    private async void CheckModelsQuietly()
    {
        if (_modelsChecked || _modelsBusy || Models.Custom) return;
        _modelsChecked = true;
        try { _modelsManifest = await ModelDownloads.FetchManifestAsync(CancellationToken.None); }
        catch (Exception) { _modelsChecked = false; }   // offline: try again next time the page opens
        RefreshModelsSection();
    }

    private async void ModelsDownloadClicked(object sender, RoutedEventArgs e)
    {
        if (_modelsBusy || _buildCancel is not null) return;
        _modelsBusy = true;
        _modelsCancel = new CancellationTokenSource();
        CancellationToken cancel = _modelsCancel.Token;
        TexturePack pack = ModelDownloads;
        ModelsDownloadButton.IsEnabled = false;
        ModelsRemoveButton.Visibility = Visibility.Collapsed;
        ModelsHintText.Text = "";
        string? failure = null;
        string? done = null;
        try
        {
            ModelsStatusText.Text = "Looking for the newest model pack…";
            TexturePackManifest? manifest;
            try { manifest = await pack.FetchManifestAsync(cancel); }
            catch (Exception) when (_modelsManifest is not null || Models.Downloaded) { manifest = _modelsManifest; }   // offline: build what's here
            _modelsChecked = true;
            _modelsManifest = manifest ?? _modelsManifest;
            if (manifest is null && !Models.Downloaded)
            {
                failure = "No model pack has been published yet.";
                return;
            }
            if (manifest is not null && !pack.IsComplete(manifest))
            {
                string? profile = GameCompatibilityInspector.Inspect(_home.GameFolder).Profile;
                if (!string.Equals(profile, manifest.GameProfile, StringComparison.OrdinalIgnoreCase))
                {
                    failure = $"This pack was made for the {manifest.GameProfile} game files and won't open with yours ({profile ?? "unknown"}).";
                    return;
                }
                ModelsDownloadButton.Visibility = Visibility.Collapsed;
                ModelsPauseButton.Visibility = Visibility.Visible;
                ModelsBar.Visibility = Visibility.Visible;
                ModelsBar.Value = 0;
                ModelsStatusText.Text = $"Downloading version {manifest.Version}…";
                ModelsHintText.Text = "You can close the launcher in the meantime; the download resumes where it stopped.";
                List<TexturePackPart> missing = pack.MissingParts(manifest);
                long total = Math.Max(1, missing.Sum(part => part.Size));
                var doneBytes = new Dictionary<string, long>();
                var progress = new Progress<PartProgress>(p =>
                {
                    doneBytes[p.Name] = p.Status is PartStatus.Installed or PartStatus.Verifying or PartStatus.Unpacking ? p.Size : p.Done;
                    ModelsBar.Value = (double)doneBytes.Values.Sum() / total;
                    ModelsHintText.Text = $"{TexturePack.FormatSize(doneBytes.Values.Sum())} of {TexturePack.FormatSize(total)}";
                });
                await pack.DownloadAsync(manifest, progress, cancel);
            }

            ModelsPauseButton.Visibility = Visibility.Collapsed;
            ModelsDownloadButton.Visibility = Visibility.Collapsed;
            ModelsBar.Visibility = Visibility.Visible;
            var steps = new Progress<(string Step, double Fraction)>(p =>
            {
                ModelsBar.Value = p.Fraction;
                ModelsStatusText.Text = "Building the detailed models: " + p.Step.ToLowerInvariant() + "…";
            });
            ModelsHintText.Text = "This takes a few minutes. Your game folder isn't changed.";
            SparrowModels.Result? result = await BuildModelsAsync(steps);
            if (result is not null) done = $"Detailed models installed ({result.Models} models). They show when you play Enhanced or Project Sparrow.";
        }
        catch (OperationCanceledException)
        {
            ModelsHintText.Text = "Paused. The download resumes where it stopped.";
        }
        catch (TexturePackException exception) { failure = exception.Message; }
        catch (Exception exception) { failure = exception.Message; }
        finally
        {
            _modelsBusy = false;
            _modelsCancel.Dispose();
            _modelsCancel = null;
            RefreshModelsSection();
            if (failure is not null) ModelsHintText.Text = failure;
            if (done is not null) ShowToast(done);
        }
    }

    private void ModelsPauseClicked(object sender, RoutedEventArgs e) => _modelsCancel?.Cancel();

    private void ModelsRemoveClicked(object sender, RoutedEventArgs e)
    {
        if (_modelsBusy || _buildCancel is not null) return;
        if (Updater.IsGameRunning(_home.InstallFolder))
        {
            ShowToast("Close Fable II first, then remove the models.");
            return;
        }
        try
        {
            Models.RemoveBuild();
            ModelDownloads.Remove();
            ShowToast("Detailed models removed. Enhanced and Project Sparrow show the original models.");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            ShowToast("Couldn't remove the models: " + exception.Message);
        }
        RefreshModelsSection();
    }

    /// <summary>
    /// Builds the model banks on a worker thread. Returns null (after telling the
    /// player why) when it can't run; throws OperationCanceledException when stopped.
    /// </summary>
    private async Task<SparrowModels.Result?> BuildModelsAsync(IProgress<(string Step, double Fraction)> progress)
    {
        ModelPack models = Models;
        string game = Path.GetFullPath(_home.GameFolder);
        if (Updater.IsGameRunning(_home.InstallFolder))
        {
            ShowToast("Close Fable II first; the models are built while it isn't running.");
            return null;
        }
        long need = ModelPack.BuildBytes(game);
        long free = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(_home.DataFolder))!).AvailableFreeSpace;
        if (free < need)
            throw new InvalidOperationException($"Building the detailed models needs {TexturePack.FormatSize(need)} free on the data folder's drive "
                                                + $"({TexturePack.FormatSize(free)} free).");
        _buildCancel = new CancellationTokenSource();
        CancellationToken cancel = _buildCancel.Token;
        try
        {
            // The old overlay links the files about to be replaced; drop it so their space comes back.
            if (Directory.Exists(models.OverlayFolder)) Directory.Delete(models.OverlayFolder, recursive: true);
            return await Task.Run(() => SparrowModels.Build(game, models.ModelsFolder, models.PackFolder, progress, cancel), cancel);
        }
        finally
        {
            _buildCancel.Dispose();
            _buildCancel = null;
        }
    }

    /// <summary>Play pressed with remade models that need building: build on the home page, then play.</summary>
    private async void BuildThenLaunch()
    {
        SetState(LauncherState.Extracting, "Building the detailed models", "Building the models from your game files…", "0%", "BUILDING");
        ExtractBar.IsIndeterminate = false;
        ExtractBar.Value = 0;
        ExtractAnywayButton.Visibility = Visibility.Collapsed;
        StopButton.IsEnabled = true;
        var progress = new Progress<(string Step, double Fraction)>(p =>
        {
            if (_state != LauncherState.Extracting) return;
            ExtractBar.Value = p.Fraction * 100;
            SealText.Text = $"{p.Fraction * 100:0}%";
            StatusText.Text = p.Step + "…";
        });
        bool launch = false;
        try
        {
            launch = await BuildModelsAsync(progress) is not null;
        }
        catch (OperationCanceledException)
        {
            ShowToast("Stopped. The detailed models build again the next time you play.");
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "Could not build the detailed models", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        RefreshGameState();
        RefreshModelsSection();
        if (launch && _state == LauncherState.Ready) LaunchGame();
    }
}
