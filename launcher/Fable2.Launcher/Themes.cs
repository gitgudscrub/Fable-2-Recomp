using System.Windows;
using System.Windows.Media;

namespace Fable2Launcher;

/// <summary>
/// Night, Dusk and Day looks for the launcher window (design: launcher/design/mockup.html).
/// Dusk is the default and matches the brushes declared in MainWindow.xaml; the other
/// themes replace those brushes, which the XAML reads as DynamicResource.
/// </summary>
public static class Themes
{
    public const string Night = "night";
    public const string Dusk = "dusk";
    public const string Day = "day";

    /// <summary>Unknown or missing values fall back to Dusk.</summary>
    public static string Normalize(string? theme) => theme?.Trim().ToLowerInvariant() switch
    {
        Night => Night,
        Day => Day,
        _ => Dusk,
    };

    private static readonly Dictionary<string, string> DuskColors = new()
    {
        ["Night"] = "#FF07140E", ["MossLine"] = "#FF2A4D3E", ["Gold"] = "#FFD6B25E", ["GoldHi"] = "#FFF1D98F",
        ["GoldDeep"] = "#FF8A6420", ["Ivory"] = "#FFEFE5C9", ["Sage"] = "#FFA9BCA9", ["SageDim"] = "#FF7A947F",
        ["Page"] = "#FFEFE4C6", ["Ink"] = "#FF2B2414", ["InkSoft"] = "#FF6A5C3D", ["InkGreen"] = "#FF1F4A37",
        ["Rule"] = "#FFD3C392",
        ["TitleBar"] = "#FF0A1A13", ["Pill"] = "#99071410", ["Well"] = "#CC071410", ["EdBg"] = "#B3071410",
        ["GoldLine"] = "#73D6B25E", ["GoldLineSoft"] = "#40D6B25E", ["ScrimBrush"] = "#73030A07",
        ["Hill1"] = "#FF163A2B", ["Tower"] = "#FF122F23", ["Hill2"] = "#FF0F2A1F", ["Hill3"] = "#FF0A1D16",
        ["Moon"] = "#D9EFE5C9",
        ["PageLine"] = "#FFD9C99F", ["CtlLine"] = "#FFBFAE80", ["WellPage"] = "#FFF6EED6", ["SwOff"] = "#FFE2D4AD",
        ["KnobOff"] = "#FFA99868", ["OnBg"] = "#FF1F4A37", ["OnText"] = "#FFEFE4C6", ["KnobOn"] = "#FFF1D98F",
        ["TabOnText"] = "#FF1F4A37", ["KeyListen"] = "#FFE4EFE4",
    };

    // Night: darker scene; the page becomes dark leather with ivory text and gold accents.
    private static readonly Dictionary<string, string> NightColors = new()
    {
        ["Night"] = "#FF08140F", ["MossLine"] = "#FF22392F", ["Ivory"] = "#FFE6DCC0", ["Sage"] = "#FF93A693",
        ["SageDim"] = "#FF6A8270",
        ["Page"] = "#FF1B231C", ["Ink"] = "#FFE8DCC0", ["InkSoft"] = "#FFA59A7E", ["InkGreen"] = "#FFD6B25E",
        ["GoldDeep"] = "#FFC9A24F", ["Rule"] = "#FF36423A",
        ["TitleBar"] = "#FF050E0A", ["Pill"] = "#BF030A07", ["Well"] = "#E6020805", ["EdBg"] = "#D9030A07",
        ["ScrimBrush"] = "#99000402",
        ["Hill1"] = "#FF123024", ["Tower"] = "#FF0F281D", ["Hill2"] = "#FF0C2118", ["Hill3"] = "#FF081811",
        ["Moon"] = "#B3D9D0B4",
        ["PageLine"] = "#FF2F3A2E", ["CtlLine"] = "#FF4A5747", ["WellPage"] = "#FF232D24", ["SwOff"] = "#FF2A352B",
        ["KnobOff"] = "#FF6F7A68", ["OnBg"] = "#FFD6B25E", ["OnText"] = "#FF1D1405", ["KnobOn"] = "#FF1D1405",
        ["TabOnText"] = "#FFD6B25E", ["KeyListen"] = "#FF33402A",
    };

    // Day: sunlit morning, dark ink on the scene, parchment page as in Dusk.
    private static readonly Dictionary<string, string> DayColors = new()
    {
        ["Night"] = "#FFEFE5C9", ["MossLine"] = "#FFC9B88A", ["Ivory"] = "#FF2B2414", ["Sage"] = "#FF4F5F45",
        ["SageDim"] = "#FF6B7A5E", ["Gold"] = "#FF8A6420", ["GoldHi"] = "#FFA87A2C",
        ["TitleBar"] = "#FFE9DCB8", ["Pill"] = "#CCFFFAEC", ["Well"] = "#E6FFFAEC", ["EdBg"] = "#CCFFFAEC",
        ["GoldLine"] = "#738A6420", ["GoldLineSoft"] = "#408A6420", ["ScrimBrush"] = "#403C2D0F",
        ["Hill1"] = "#FFA9BD8F", ["Tower"] = "#FF7D9670", ["Hill2"] = "#FF8AA77A", ["Hill3"] = "#FF6D8D62",
    };

    private sealed record Scene(string[] Sky, Color Glow, Color Vignette, Color Ribbon, string[] Sheet,
        bool Stars, bool Moon, bool Sun, bool Lamp, bool Flies, bool Birds);

    private static readonly string[] ParchmentSheet =
        ["#FFE4D6B0", "#FFEFE4C6", "#FFEFE4C6", "#FFDCCDA4", "#FFE9DCBA", "#FFD6C597"];

    private static Scene SceneFor(string theme) => theme switch
    {
        Night => new(["#FF010604", "#FF051209", "#FF0A1D15"], C("#1AF1D98F"), C("#B8010503"), C("#EB020805"),
            ["#FF141B15", "#FF1B231C", "#FF1B231C", "#FF263026", "#FF1F281F", "#FF2C372C"],
            Stars: true, Moon: true, Sun: false, Lamp: true, Flies: true, Birds: false),
        Day => new(["#FFF6EEDB", "#FFF3E2B8", "#FFEAD49A"], C("#B3FFF6D6"), C("#24785A1E"), C("#F0F6EED8"),
            ParchmentSheet, Stars: false, Moon: false, Sun: true, Lamp: false, Flies: false, Birds: true),
        _ => new(["#FF05110C", "#FF0D281D", "#FF1C4130"], C("#38F1D98F"), C("#8C040C08"), C("#D9050E0A"),
            ParchmentSheet, Stars: true, Moon: true, Sun: false, Lamp: true, Flies: true, Birds: false),
    };

    public static void Apply(MainWindow window, string theme)
    {
        theme = Normalize(theme);
        ResourceDictionary res = window.Resources;

        var colors = new Dictionary<string, string>(DuskColors);
        Dictionary<string, string>? overrides = theme == Night ? NightColors : theme == Day ? DayColors : null;
        if (overrides is not null)
            foreach (var (key, value) in overrides) colors[key] = value;
        foreach (var (key, value) in colors)
            res[key] = Frozen(new SolidColorBrush(C(value)));

        Scene scene = SceneFor(theme);
        res["SkyBrush"] = Frozen(Linear(new Point(0, 0), new Point(0, 1),
            (C(scene.Sky[0]), 0), (C(scene.Sky[1]), 0.5), (C(scene.Sky[2]), 1)));
        res["GlowBrush"] = Frozen(Radial(0.5, (scene.Glow, 0), (WithAlpha(scene.Glow, 0), 1)));
        res["VignetteBrush"] = Frozen(Radial(0.62, (WithAlpha(scene.Vignette, 0), 0), (scene.Vignette, 1)));
        res["RibbonBrush"] = Frozen(Linear(new Point(0, 0), new Point(0, 1),
            (WithAlpha(scene.Ribbon, 0), 0), (scene.Ribbon, 0.45)));
        res["SheetBrush"] = Frozen(Linear(new Point(0, 0), new Point(1, 0),
            (C(scene.Sheet[0]), 0), (C(scene.Sheet[1]), 0.04), (C(scene.Sheet[2]), 0.97),
            (C(scene.Sheet[3]), 0.975), (C(scene.Sheet[4]), 0.985), (C(scene.Sheet[5]), 1)));

        window.Stars.Visibility = Show(scene.Stars);
        window.MoonShape.Visibility = Show(scene.Moon);
        window.Sun.Visibility = Show(scene.Sun);
        window.Lamp.Visibility = Show(scene.Lamp);
        window.Flies.Visibility = Show(scene.Flies);
        window.Birds.Visibility = Show(scene.Birds);
    }

    private static Visibility Show(bool on) => on ? Visibility.Visible : Visibility.Collapsed;
    private static Color C(string hex) => (Color)ColorConverter.ConvertFromString(hex);
    private static Color WithAlpha(Color c, byte a) => Color.FromArgb(a, c.R, c.G, c.B);

    private static T Frozen<T>(T brush) where T : Freezable
    {
        brush.Freeze();
        return brush;
    }

    private static LinearGradientBrush Linear(Point start, Point end, params (Color, double)[] stops)
    {
        var brush = new LinearGradientBrush { StartPoint = start, EndPoint = end };
        foreach (var (color, offset) in stops) brush.GradientStops.Add(new GradientStop(color, offset));
        return brush;
    }

    private static RadialGradientBrush Radial(double radius, params (Color, double)[] stops)
    {
        var brush = new RadialGradientBrush
        {
            Center = new Point(0.5, 0.4), GradientOrigin = new Point(0.5, 0.4), RadiusX = radius, RadiusY = radius,
        };
        foreach (var (color, offset) in stops) brush.GradientStops.Add(new GradientStop(color, offset));
        return brush;
    }
}
