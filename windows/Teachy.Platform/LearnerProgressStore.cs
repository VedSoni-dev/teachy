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
        catch (Exception loadError)
        {
            // Corrupt progress data must never block learning — but silently
            // starting fresh means someone loses weeks of progress with no trace
            // and no way back. Keep the bad file so it can be recovered by hand.
            QuarantineUnreadableStore(loadError);
        }
        return new LearnerProgressStore();
    }

    private static void QuarantineUnreadableStore(Exception loadError)
    {
        try
        {
            string quarantinePath = $"{StoreFilePath}.corrupt";
            File.Move(StoreFilePath, quarantinePath, overwrite: true);
            TeachyLog.Write($"Progress file unreadable ({loadError.GetType().Name}: {loadError.Message}); kept a copy at {quarantinePath}.");
        }
        catch (Exception quarantineError)
        {
            TeachyLog.Write($"Progress file unreadable and could not be preserved: {quarantineError.Message}");
        }
    }

    /// <summary>
    /// Writes progress durably.
    /// </summary>
    /// <remarks>
    /// Writing straight over the live file means a crash mid-write leaves
    /// truncated JSON, Load() cannot parse it, and every course the learner ever
    /// finished is gone. That is not hypothetical here — the sidecar has taken
    /// native crashes from audio drivers. Serialise first, write to a temp file in
    /// the same directory, then swap it in: the real file is only ever whole.
    /// </remarks>
    public void Save()
    {
        TeachyDataPaths.EnsureDirectoriesExist();
        string serializedStore = JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });

        string temporaryPath = $"{StoreFilePath}.tmp";
        File.WriteAllText(temporaryPath, serializedStore);

        if (File.Exists(StoreFilePath))
        {
            // Same-volume atomic swap. No backup file: we already hold the only
            // copy that matters in serializedStore.
            File.Replace(temporaryPath, StoreFilePath, destinationBackupFileName: null);
        }
        else
        {
            File.Move(temporaryPath, StoreFilePath);
        }
    }

    /// <summary>
    /// Records progress on a course. Progress only ever moves forward.
    /// </summary>
    /// <remarks>
    /// This used to overwrite whatever was stored, so replaying a course you had
    /// already finished walked your record backwards — goal 1 of 5 overwrote 5 of
    /// 5 — and the finished course dropped out of Portfolio. Nobody replays a
    /// course expecting to lose the badge for it.
    /// </remarks>
    public void RecordGoalCompleted(string courseIdentifier, int completedGoalCount, int totalGoalCount)
    {
        CourseProgress? existingProgress = ProgressForCourse(courseIdentifier);

        CourseProgressByCourseId[courseIdentifier] = new CourseProgress
        {
            CompletedGoalCount = Math.Max(completedGoalCount, existingProgress?.CompletedGoalCount ?? 0),
            TotalGoalCount = totalGoalCount,
            LastActivityUtc = DateTime.UtcNow,
            // Sticky: finishing a course is a fact about the past, and a later
            // partial replay does not undo it.
            IsCourseCompleted = (existingProgress?.IsCourseCompleted ?? false)
                || (totalGoalCount > 0 && completedGoalCount >= totalGoalCount),
        };
        Save();
    }

    public CourseProgress? ProgressForCourse(string courseIdentifier) =>
        CourseProgressByCourseId.TryGetValue(courseIdentifier, out CourseProgress? courseProgress)
            ? courseProgress
            : null;
}
