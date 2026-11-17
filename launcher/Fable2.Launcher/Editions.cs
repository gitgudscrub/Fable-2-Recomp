namespace Fable2Launcher;

/// <summary>
/// One edition: a named bundle of graphics settings (fable_2.toml), recomp
/// patches (fable2_config.toml) and which game data to load. Settings the
/// edition doesn't name are left as the player set them.
/// </summary>
/// <param name="ModernGraphics">[graphics] texture_pack: Modern textures, filtering and grade.</param>
/// <param name="Models">Load the remade model pack on top of the game files (when the Remade models switch is on).</param>
/// <param name="Ultra">[graphics] ultra when the edition is picked: light shafts, a sharper sun shadow map redrawn
/// every frame, stronger AO. Afterwards the Ultra lighting switch owns it.</param>
/// <param name="NewLighting">[graphics] sparrow_renderer: Project Sparrow's new lighting (shaders/sparrow_replace).</param>
public sealed record Edition(
    string Id, string Name, string Summary,
    string Resolution, string RenderScale, string Anisotropic, string AntiAliasing, string FrameLimit,
    bool DisableMotionBlur, bool HighTickRate, bool HigherHfTickRate, bool ModernGraphics, bool Models,
    bool Ultra = false, bool NewLighting = false)
{
    public static readonly Edition Original = new("original", "Original", "30 fps · 720p · as on Xbox",
        "720p", "1", "-1", "none", "30",
        DisableMotionBlur: false, HighTickRate: false, HigherHfTickRate: false, ModernGraphics: false, Models: false);

    // Enhanced is what Sparrow Edition was: Modern textures, detailed models and Ultra lighting, with F8 switching
    // between Classic and Modern graphics in game.
    public static readonly Edition Enhanced = new("enhanced", "Enhanced", "60 fps · 1440p · sharper textures, detailed models",
        "1440p", "2", "5", "fxaa", "60",
        DisableMotionBlur: true, HighTickRate: false, HigherHfTickRate: false, ModernGraphics: true, Models: true,
        Ultra: true);

    // Project Sparrow: Enhanced drawn with the new lighting (light from the sky, soft highlights, lamps that
    // light the walls and ground). Its id is not "sparrow": that was the old Sparrow Edition, now Enhanced.
    public static readonly Edition ProjectSparrow = new("project-sparrow", "Project Sparrow",
        "60 fps · Enhanced with new lighting (preview)",
        "1440p", "2", "5", "fxaa", "60",
        DisableMotionBlur: true, HighTickRate: false, HigherHfTickRate: false, ModernGraphics: true, Models: true,
        Ultra: true, NewLighting: true);

    public static readonly Edition[] All = [Original, Enhanced, ProjectSparrow];

    /// <summary>The saved edition. "experimental" and "sparrow" (both folded into Enhanced) become Enhanced;
    /// the player's own settings stay.</summary>
    public static Edition Find(string? id) =>
        id is "experimental" or "sparrow" ? Enhanced : All.FirstOrDefault(edition => edition.Id == id) ?? Original;

    /// <summary>True when the current settings are exactly what this edition sets.</summary>
    public bool Matches(string resolution, string renderScale, string anisotropic, string antiAliasing,
        string frameLimit, Fable2ConfigValues recomp) =>
        resolution == Resolution && renderScale == RenderScale && anisotropic == Anisotropic &&
        antiAliasing == AntiAliasing && frameLimit == FrameLimit &&
        recomp.DisableMotionBlur == DisableMotionBlur && recomp.HighTickRate == HighTickRate &&
        recomp.HigherHfTickRate == HigherHfTickRate && recomp.TexturePack == ModernGraphics &&
        recomp.SparrowRenderer == NewLighting;
}
