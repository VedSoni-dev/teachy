using System.Text.Json;
using System.Text.Json.Serialization;

namespace Teachy.Platform;

/// <summary>Per-course progress snapshot persisted between sessions.</summary>
public sealed class CourseProgress
{
    [JsonPropertyName("completedGoals")]
    public int CompletedGoalCount { get; set; }

    [JsonPropertyName("totalGoals")]
    public int TotalGoalCount { get; set; }

    [JsonPropertyName("lastActivityUtc")]
    public DateTime LastActivityUtc { get; set; }

    [JsonPropertyName("completed")]
    public bool IsCourseCompleted { get; set; }
}

/// <summary>
/// Durable learner progress at %USERPROFILE%\.teachy\windows-learner.json — the
/// v1 slice of the macOS learner model persistence ("projects that survive":
/// Teachy remembers where you left off across days).
/// </summary>
public sealed class LearnerProgressStore
{
    private static string StoreFilePath =>
        Path.Combine(TeachyDataPaths.TeachyHomeDirectory, "windows-learner.json");

    [JsonPropertyName("courses")]
    public Dictionary<string, CourseProgress> CourseProgressByCourseId { get; set; } = new();

    public static LearnerProgressStore Load()
    {
        try
        {
            if (File.Exists(StoreFilePath))
            {
                LearnerProgressStore? loadedStore =
                    JsonSerializer.Deserialize<LearnerProgressStore>(File.ReadAllText(StoreFilePath));
                if (loadedStore is not null)
                {
                    return loadedStore;
                }
            }
        }
        catch (Exception)
        {
            // Corrupt progress data should never block learning — start fresh.
        }
        return new LearnerProgressStore();
    }

    public void Save()
    {
        TeachyDataPaths.EnsureDirectoriesExist();
        File.WriteAllText(StoreFilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }

    public void RecordGoalCompleted(string courseIdentifier, int completedGoalCount, int totalGoalCount)
    {
        CourseProgressByCourseId[courseIdentifier] = new CourseProgress
        {
            CompletedGoalCount = completedGoalCount,
            TotalGoalCount = totalGoalCount,
            LastActivityUtc = DateTime.UtcNow,
            IsCourseCompleted = completedGoalCount >= totalGoalCount,
        };
        Save();
    }

    public CourseProgress? ProgressForCourse(string courseIdentifier) =>
        CourseProgressByCourseId.TryGetValue(courseIdentifier, out CourseProgress? courseProgress)
            ? courseProgress
            : null;
}
