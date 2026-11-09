namespace Fable2Launcher;

/// <summary>
/// One edition: a named bundle of graphics settings (fable_2.toml) and recomp
/// patches (fable2_config.toml). Settings the edition doesn't name are left as
/// the player set them.
/// </summary>
public sealed record Edition(
    string Id, string Name, string Summary,
    string Resolution, string RenderScale, string Anisotropic, string AntiAliasing, string FrameLimit,
    bool DisableMotionBlur, bool HighTickRate, bool HigherHfTickRate)
{
    public static readonly Edition Original = new("original", "Original", "30 fps · 720p · as on Xbox",
        "720p", "1", "-1", "none", "30", DisableMotionBlur: false, HighTickRate: false, HigherHfTickRate: false);

    public static readonly Edition Enhanced = new("enhanced", "Enhanced", "60 fps · 1440p · FXAA",
        "1440p", "2", "5", "fxaa", "60", DisableMotionBlur: true, HighTickRate: false, HigherHfTickRate: false);

    public static readonly Edition Experimental = new("experimental", "Experimental", "Uncapped · 4x scale · may glitch",
        "1440p", "4", "5", "fxaa", "0", DisableMotionBlur: true, HighTickRate: true, HigherHfTickRate: true);

    public static readonly Edition[] All = [Original, Enhanced, Experimental];

    public static Edition Find(string? id) =>
        All.FirstOrDefault(edition => edition.Id == id) ?? Original;

    /// <summary>True when the current settings are exactly what this edition sets.</summary>
    public bool Matches(string resolution, string renderScale, string anisotropic, string antiAliasing,
        string frameLimit, Fable2ConfigValues recomp) =>
        resolution == Resolution && renderScale == RenderScale && anisotropic == Anisotropic &&
        antiAliasing == AntiAliasing && frameLimit == FrameLimit &&
        recomp.DisableMotionBlur == DisableMotionBlur && recomp.HighTickRate == HighTickRate &&
        recomp.HigherHfTickRate == HigherHfTickRate;
}
