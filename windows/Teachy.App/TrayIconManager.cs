using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Windows.Forms;

namespace Teachy.App;

/// <summary>
/// System tray icon — the Windows stand-in for the macOS NSStatusItem menu-bar
/// icon. Left-click toggles the Teachy panel; the context menu offers Open and
/// Quit. The icon itself is drawn at runtime (blue Teachy dot) so no asset
/// pipeline is needed yet.
/// </summary>
public sealed class TrayIconManager : IDisposable
{
    private readonly NotifyIcon trayNotifyIcon;
    private readonly CompanionManager companionManager;

    public TrayIconManager(CompanionManager companionManager)
    {
        this.companionManager = companionManager;

        trayNotifyIcon = new NotifyIcon
        {
            Icon = LoadTeachyAppIcon(),
            Text = "Teachy — hold Ctrl+Alt to talk",
            Visible = true,
        };

        trayNotifyIcon.MouseClick += (_, mouseEventArgs) =>
        {
            if (mouseEventArgs.Button == MouseButtons.Left)
            {
                companionManager.TogglePanel();
            }
        };

        var trayContextMenu = new ContextMenuStrip();
        trayContextMenu.Items.Add("Open Teachy", null, (_, _) => companionManager.TogglePanel());
        trayContextMenu.Items.Add(new ToolStripSeparator());
        trayContextMenu.Items.Add("Quit Teachy", null, (_, _) => System.Windows.Application.Current.Shutdown());
        trayNotifyIcon.ContextMenuStrip = trayContextMenu;
    }

    /// <summary>
    /// Loads the real Teachy app icon (shared with the macOS AppIcon asset).
    /// Falls back to a drawn triangle if the asset is missing from the output.
    /// </summary>
    private static Icon LoadTeachyAppIcon()
    {
        string appIconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "tray-icon-32.png");
        if (File.Exists(appIconPath))
        {
            using var iconBitmap = new Bitmap(appIconPath);
            return Icon.FromHandle(iconBitmap.GetHicon());
        }

        // Fallback: the glowing Teachy triangle.
        using var fallbackBitmap = new Bitmap(32, 32);
        using (Graphics iconGraphics = Graphics.FromImage(fallbackBitmap))
        {
            iconGraphics.SmoothingMode = SmoothingMode.AntiAlias;
            using var triangleBrush = new SolidBrush(Color.FromArgb(255, 10, 132, 255));
            iconGraphics.FillPolygon(triangleBrush, new[]
            {
                new PointF(16, 4),
                new PointF(28, 28),
                new PointF(4, 28),
            });
        }
        return Icon.FromHandle(fallbackBitmap.GetHicon());
    }

    public void Dispose()
    {
        trayNotifyIcon.Visible = false;
        trayNotifyIcon.Dispose();
    }
}
