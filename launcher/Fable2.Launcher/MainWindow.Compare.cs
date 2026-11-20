using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Imaging;

namespace Fable2Launcher;

/// <summary>One place shown in the comparison: Assets/compare/&lt;Id&gt;-classic.jpg and -modern.jpg.</summary>
public sealed record CompareView(string Id, string Name)
{
    /// <summary>The shots shipped with the launcher (tools/bench/compare_shots.ps1 takes them).</summary>
    public static readonly CompareView[] All =
    [
        new("market", "Bowerstone Market"), new("bower-lake", "Bower Lake"), new("brightwood", "Brightwood"),
        new("rookridge", "Rookridge"), new("oakfield", "Oakfield"), new("westcliff", "Westcliff"),
        new("wraithmarsh", "Wraithmarsh"), new("bloodstone", "Bloodstone"), new("fairfax-gardens", "Fairfax Gardens"),
        new("cemetery", "Bowerstone Cemetery"),
    ];

    public Uri Shot(string look) => new($"pack://application:,,,/Assets/compare/{Id}-{look}.jpg");
}

/// <summary>
/// The Compare overlay: the same spot in Classic (Original edition) and Modern
/// (Project Sparrow) graphics, one over the other, with a divider to drag.
/// </summary>
public partial class MainWindow
{
    private const double CompareWidth = 1600;   // CompareStage's size; the Viewbox scales it
    private const double CompareHeight = 900;
    private double _compareSplit = 0.5;

    private void OpenCompareClicked(object sender, RoutedEventArgs e)
    {
        if (CompareRegions.Children.Count == 0) return;
        if (_pageOpen) ClosePage();
        SetCompareSplit(0.5);
        // The shots load on first open, not at start-up.
        RadioButton chip = CompareRegions.Children.OfType<RadioButton>().FirstOrDefault(c => c.IsChecked == true)
            ?? CompareRegions.Children.OfType<RadioButton>().First();
        chip.IsChecked = true;
        CompareHost.Visibility = Visibility.Visible;
        chip.Focus();
    }

    private void CloseCompareClicked(object sender, RoutedEventArgs e) => CloseCompare();

    private void CloseCompare()
    {
        CompareHost.Visibility = Visibility.Collapsed;
        CompareButton.Focus();
    }

    private void BuildCompareRegions()
    {
        foreach (CompareView view in CompareView.All)
        {
            var chip = new RadioButton { Style = (Style)FindResource("CompareChip"), Content = view.Name, Tag = view };
            chip.Checked += (_, _) => ShowCompareView(view);
            CompareRegions.Children.Add(chip);
        }
        CompareButton.Visibility = CompareRegions.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ShowCompareView(CompareView view)
    {
        CompareClassic.Source = LoadCompareShot(view.Shot("classic"));
        CompareModern.Source = LoadCompareShot(view.Shot("modern"));
    }

    private static BitmapImage LoadCompareShot(Uri uri)
    {
        var image = new BitmapImage();
        image.BeginInit();
        image.UriSource = uri;
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.EndInit();
        image.Freeze();
        return image;
    }

    /// <summary>Moves the divider; 0 = all Modern, 1 = all Classic.</summary>
    private void SetCompareSplit(double split)
    {
        _compareSplit = Math.Clamp(split, 0, 1);
        double x = _compareSplit * CompareWidth;
        CompareClip.Rect = new Rect(0, 0, x, CompareHeight);
        Canvas.SetLeft(CompareLine, x - CompareLine.Width / 2);
        Canvas.SetLeft(CompareHandle, x - CompareHandle.Width / 2);
    }

    private void CompareStageMouseDown(object sender, MouseButtonEventArgs e)
    {
        CompareStage.CaptureMouse();
        SetCompareSplit(e.GetPosition(CompareStage).X / CompareWidth);
        e.Handled = true;
    }

    private void CompareStageMouseMove(object sender, MouseEventArgs e)
    {
        if (CompareStage.IsMouseCaptured) SetCompareSplit(e.GetPosition(CompareStage).X / CompareWidth);
    }

    private void CompareStageMouseUp(object sender, MouseButtonEventArgs e) => CompareStage.ReleaseMouseCapture();

    /// <summary>Esc closes; Left/Right move the divider (Shift for big steps); Tab moves between places.</summary>
    private void CompareKeyDown(KeyEventArgs e)
    {
        double step = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? 0.25 : 0.05;
        switch (e.Key)
        {
            case Key.Escape: CloseCompare(); break;
            case Key.Left: SetCompareSplit(_compareSplit - step); break;
            case Key.Right: SetCompareSplit(_compareSplit + step); break;
            case Key.Home: SetCompareSplit(0); break;
            case Key.End: SetCompareSplit(1); break;
            default: return;
        }
        e.Handled = true;
    }
}
