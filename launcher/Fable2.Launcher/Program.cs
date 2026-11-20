using Velopack;

namespace Fable2Launcher;

public static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        // Must run first: handles Velopack's install/update/uninstall hooks and exits
        // when it was started for one of them. Does nothing for dev builds.
        VelopackApp.Build().Run();

        // Hidden crash watcher left behind when the launcher closes after starting the game.
        if (args.Length > 0 && args[0] == CrashWatch.Argument)
        {
            Environment.Exit(CrashWatch.Run(args));
            return;
        }

        var app = new App();
        app.InitializeComponent();
        app.Run();
    }
}
