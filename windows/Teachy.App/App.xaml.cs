using System.Windows;
using Teachy.Platform;

namespace Teachy.App;

/// <summary>
/// Tray-only application entry point — the Windows equivalent of the macOS
/// LSUIElement menu-bar app. No main window; a tray icon toggles the panel and
/// a transparent overlay hosts the cursor companion.
/// </summary>
public partial class TeachyApplication : System.Windows.Application
{
    private CompanionManager? companionManager;
    private TrayIconManager? trayIconManager;

    protected override void OnStartup(StartupEventArgs startupEventArgs)
    {
        base.OnStartup(startupEventArgs);

        TeachyDataPaths.EnsureDirectoriesExist();

        companionManager = new CompanionManager();
        companionManager.Start();

        trayIconManager = new TrayIconManager(companionManager);
    }

    protected override void OnExit(ExitEventArgs exitEventArgs)
    {
        trayIconManager?.Dispose();
        companionManager?.Dispose();
        base.OnExit(exitEventArgs);
    }
}
