namespace Teachy.Platform;

/// <summary>
/// Windows equivalent of the macOS TeachyDataPaths — resolves %USERPROFILE%\.teachy
/// subdirectories so course JSON and connector manifests stay format-compatible
/// with the macOS app.
/// </summary>
public static class TeachyDataPaths
{
    public static string TeachyHomeDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".teachy");

    public static string CoursesDirectory => Path.Combine(TeachyHomeDirectory, "courses");

    public static string ConnectorsDirectory => Path.Combine(TeachyHomeDirectory, "connectors");

    public static string ConfigurationFilePath => Path.Combine(TeachyHomeDirectory, "config-windows.json");

    public static void EnsureDirectoriesExist()
    {
        Directory.CreateDirectory(TeachyHomeDirectory);
        Directory.CreateDirectory(CoursesDirectory);
        Directory.CreateDirectory(ConnectorsDirectory);
    }
}
