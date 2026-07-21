namespace Teachy.Platform;

/// <summary>
/// Append-only diagnostic log at %USERPROFILE%\.teachy\windows-log.txt.
/// Voice and capture failures are otherwise invisible in a tray app with no
/// console — this is where to look first when something "just doesn't work".
/// </summary>
public static class TeachyLog
{
    private static readonly object logWriteLock = new();

    private static string LogFilePath => Path.Combine(TeachyDataPaths.TeachyHomeDirectory, "windows-log.txt");

    public static void Write(string message)
    {
        try
        {
            lock (logWriteLock)
            {
                TeachyDataPaths.EnsureDirectoriesExist();
                File.AppendAllText(LogFilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}{Environment.NewLine}");
            }
        }
        catch (Exception)
        {
            // Logging must never take down the app.
        }
    }
}
