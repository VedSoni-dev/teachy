namespace Teachy.Platform;

/// <summary>
/// Windows equivalent of the macOS TeachyDataPaths — resolves %USERPROFILE%\.teachy
/// subdirectories so course JSON and connector manifests stay format-compatible
/// with the macOS app.
/// </summary>
public static class TeachyDataPaths
{
    /// <summary>
    /// Overrides the Teachy home directory. Set TEACHY_HOME to keep progress,
    /// config and courses somewhere other than the user profile — a portable
    /// install, a second profile, or a test run that must not touch real learner
    /// data.
    /// </summary>
    public const string HomeDirectoryEnvironmentVariable = "TEACHY_HOME";

    public static string TeachyHomeDirectory
    {
        get
        {
            string? overrideDirectory = Environment.GetEnvironmentVariable(HomeDirectoryEnvironmentVariable);
            return string.IsNullOrWhiteSpace(overrideDirectory)
                ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".teachy")
                : overrideDirectory;
        }
    }

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
