using System.Text.Json;
using Teachy.Platform;
using Xunit;

namespace Teachy.Platform.Tests;

/// <summary>
/// Progress is the one thing in the app the learner cannot recreate. A wrong
/// screenshot is an annoyance; a lost record of the course they finished last
/// week is why someone stops opening the app.
///
/// Every test redirects TEACHY_HOME at a temp directory so a run can never touch
/// real learner data.
/// </summary>
public sealed class LearnerProgressStoreTests : IDisposable
{
    private readonly string temporaryHomeDirectory;
    private readonly string? previousHomeDirectory;

    public LearnerProgressStoreTests()
    {
        previousHomeDirectory = Environment.GetEnvironmentVariable(TeachyDataPaths.HomeDirectoryEnvironmentVariable);
        temporaryHomeDirectory = Path.Combine(Path.GetTempPath(), $"teachy-tests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(temporaryHomeDirectory);
        Environment.SetEnvironmentVariable(TeachyDataPaths.HomeDirectoryEnvironmentVariable, temporaryHomeDirectory);
    }

    public void Dispose()
    {
        Environment.SetEnvironmentVariable(TeachyDataPaths.HomeDirectoryEnvironmentVariable, previousHomeDirectory);
        try
        {
            Directory.Delete(temporaryHomeDirectory, recursive: true);
        }
        catch (IOException)
        {
            // A leftover temp directory is not worth failing a test over.
        }
    }

    private string StoreFilePath => Path.Combine(temporaryHomeDirectory, "windows-learner.json");

    [Fact]
    public void RoundTripsProgressAcrossSessions()
    {
        new LearnerProgressStore().RecordGoalCompleted("build-a-website", completedGoalCount: 3, totalGoalCount: 5);

        LearnerProgressStore reloaded = LearnerProgressStore.Load();
        CourseProgress? progress = reloaded.ProgressForCourse("build-a-website");

        Assert.NotNull(progress);
        Assert.Equal(3, progress!.CompletedGoalCount);
        Assert.Equal(5, progress.TotalGoalCount);
        Assert.False(progress.IsCourseCompleted);
    }

    [Fact]
    public void MarksACourseCompleteOnTheFinalGoal()
    {
        new LearnerProgressStore().RecordGoalCompleted("build-a-website", completedGoalCount: 5, totalGoalCount: 5);

        Assert.True(LearnerProgressStore.Load().ProgressForCourse("build-a-website")!.IsCourseCompleted);
    }

    [Fact]
    public void NeverWalksProgressBackwards()
    {
        LearnerProgressStore store = new();
        store.RecordGoalCompleted("build-a-website", completedGoalCount: 4, totalGoalCount: 5);
        // A replay, a resumed session, or a late duplicate command.
        store.RecordGoalCompleted("build-a-website", completedGoalCount: 1, totalGoalCount: 5);

        Assert.Equal(4, LearnerProgressStore.Load().ProgressForCourse("build-a-website")!.CompletedGoalCount);
    }

    [Fact]
    public void KeepsACompletedCourseCompletedWhenTheLearnerReplaysIt()
    {
        LearnerProgressStore store = new();
        store.RecordGoalCompleted("build-a-website", completedGoalCount: 5, totalGoalCount: 5);
        store.RecordGoalCompleted("build-a-website", completedGoalCount: 1, totalGoalCount: 5);

        // Replaying a finished course must not take the badge out of Portfolio.
        Assert.True(LearnerProgressStore.Load().ProgressForCourse("build-a-website")!.IsCourseCompleted);
    }

    [Fact]
    public void DoesNotCallAZeroGoalCourseComplete()
    {
        new LearnerProgressStore().RecordGoalCompleted("empty-course", completedGoalCount: 0, totalGoalCount: 0);

        Assert.False(LearnerProgressStore.Load().ProgressForCourse("empty-course")!.IsCourseCompleted);
    }

    [Fact]
    public void KeepsCoursesIndependent()
    {
        LearnerProgressStore store = new();
        store.RecordGoalCompleted("course-a", completedGoalCount: 2, totalGoalCount: 4);
        store.RecordGoalCompleted("course-b", completedGoalCount: 1, totalGoalCount: 3);

        LearnerProgressStore reloaded = LearnerProgressStore.Load();
        Assert.Equal(2, reloaded.ProgressForCourse("course-a")!.CompletedGoalCount);
        Assert.Equal(1, reloaded.ProgressForCourse("course-b")!.CompletedGoalCount);
    }

    [Fact]
    public void ReturnsNullForACourseTheLearnerHasNotStarted()
    {
        Assert.Null(LearnerProgressStore.Load().ProgressForCourse("never-opened"));
    }

    [Fact]
    public void LeavesNoTemporaryFileBehindAfterSaving()
    {
        new LearnerProgressStore().RecordGoalCompleted("build-a-website", completedGoalCount: 1, totalGoalCount: 5);

        Assert.False(File.Exists($"{StoreFilePath}.tmp"), "the atomic-write temp file was not cleaned up");
    }

    [Fact]
    public void WritesCompleteJsonEveryTimeSoACrashCannotTruncateIt()
    {
        LearnerProgressStore store = new();
        for (int goalNumber = 1; goalNumber <= 5; goalNumber++)
        {
            store.RecordGoalCompleted("build-a-website", goalNumber, totalGoalCount: 5);

            // Whatever moment a crash lands on, the file on disk must parse.
            string fileContents = File.ReadAllText(StoreFilePath);
            JsonDocument parsed = JsonDocument.Parse(fileContents);
            Assert.True(parsed.RootElement.TryGetProperty("courses", out _));
        }
    }

    [Fact]
    public void StartsFreshOnACorruptFileRatherThanThrowing()
    {
        Directory.CreateDirectory(temporaryHomeDirectory);
        File.WriteAllText(StoreFilePath, "{\"courses\": {\"build-a-web");

        LearnerProgressStore recovered = LearnerProgressStore.Load();

        Assert.Empty(recovered.CourseProgressByCourseId);
    }

    [Fact]
    public void KeepsTheCorruptFileSoProgressCanBeRecoveredByHand()
    {
        const string truncatedJson = "{\"courses\": {\"build-a-web";
        File.WriteAllText(StoreFilePath, truncatedJson);

        LearnerProgressStore.Load();

        string quarantinePath = $"{StoreFilePath}.corrupt";
        Assert.True(File.Exists(quarantinePath), "the unreadable progress file was deleted instead of preserved");
        Assert.Equal(truncatedJson, File.ReadAllText(quarantinePath));
    }

    [Fact]
    public void SurvivesAnEmptyProgressFile()
    {
        File.WriteAllText(StoreFilePath, string.Empty);

        Assert.Empty(LearnerProgressStore.Load().CourseProgressByCourseId);
    }
}
