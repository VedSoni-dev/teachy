using System.Windows;

namespace Teachy.App;

/// <summary>
/// The floating course teaching HUD — Windows port of the macOS
/// CourseLessonHUDWindow. Docks under the notch at top-center and shows the
/// active goal, the last coach line, and the Hint / I did it / Exit controls.
/// </summary>
public partial class CourseLessonHUDWindow : Window
{
    private readonly CompanionManager companionManager;

    public CourseLessonHUDWindow(CompanionManager companionManager)
    {
        this.companionManager = companionManager;
        InitializeComponent();

        Loaded += (_, _) =>
        {
            Left = (SystemParameters.PrimaryScreenWidth - ActualWidth) / 2;
            Top = 48; // just under the collapsed notch
        };
    }

    public void ShowCourseState(string courseTitle, string goalTitle, int goalNumber, int totalGoals)
    {
        CourseTitleText.Text = courseTitle;
        GoalTitleText.Text = goalTitle.ToUpperInvariant();
        GoalProgressText.Text = $"goal {goalNumber} of {totalGoals}";
    }

    public void ShowCoachLine(string coachLine)
    {
        CoachLineText.Text = coachLine;
    }

    private void HandleHintClicked(object sender, RoutedEventArgs routedEventArgs)
    {
        companionManager.RequestCourseHint();
    }

    private void HandleDoItForMeClicked(object sender, RoutedEventArgs routedEventArgs)
    {
        companionManager.RequestDoItForMe();
    }

    private void HandleIDidItClicked(object sender, RoutedEventArgs routedEventArgs)
    {
        companionManager.RequestCourseVerification();
    }

    private void HandleExitClicked(object sender, RoutedEventArgs routedEventArgs)
    {
        companionManager.ExitCourse();
    }
}
