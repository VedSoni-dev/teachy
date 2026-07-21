using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using Teachy.Engine;
using Teachy.Platform;
using Button = System.Windows.Controls.Button;
using Color = System.Windows.Media.Color;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;
using FontFamily = System.Windows.Media.FontFamily;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using VerticalAlignment = System.Windows.VerticalAlignment;
using Orientation = System.Windows.Controls.Orientation;
using TextBlock = System.Windows.Controls.TextBlock;

namespace Teachy.App;

/// <summary>
/// The Teachy notch — Windows port of the macOS boring.notch-inspired panel.
/// Always on screen at top-center. Closed: a small black notch bar with the
/// glowing Teachy triangle on the right wing. Hover springs it open to the full
/// 640x320 panel with header tabs (Learn / Portfolio / Skills / Settings).
/// Mouse-leave (or the collapse chevron) closes it again.
/// </summary>
public partial class NotchWindow : Window
{
    private readonly CompanionManager companionManager;

    // ClickyNotchSizing ports.
    private const double OpenWidth = 640;
    private const double OpenHeight = 320;
    private const double ClosedHeight = 36;

    /// <summary>Closed black bar width — the Mac's non-notch display default (185).
    /// The idle triangle floats on a transparent wing beside it, not on the bar.</summary>
    private const double ClosedAreaWidth = 185;
    private const double OpenedTopCornerRadius = 19;
    private const double OpenedBottomCornerRadius = 24;
    private const double ClosedTopCornerRadius = 6;
    private const double ClosedBottomCornerRadius = 14;

    private bool isExpanded;
    private bool isShowingLiveActivity;
    private bool isSettingModelPickerProgrammatically;
    private readonly DispatcherTimer collapseAfterMouseLeaveTimer;

    private enum NotchTab { Learn, Portfolio, Skills, Settings }
    private NotchTab selectedTab = NotchTab.Learn;

    // "Chalkboard & Brass" palette — kept as Color constants for code-built elements.
    private static readonly Color BrassColor = Color.FromRgb(0xD9, 0xA4, 0x55);
    private static readonly Color LearnAccentColor = Color.FromRgb(0xD9, 0xA4, 0x55);
    private static readonly Color CodeAccentColor = Color.FromRgb(0x4F, 0xA9, 0x8C);
    private static readonly Color PhoneAccentColor = Color.FromRgb(0xC9, 0x7B, 0x63);
    private static readonly Color FluencyAccentColor = Color.FromRgb(0x9A, 0x7F, 0xC7);
    private static readonly Color PortfolioAccentColor = Color.FromRgb(0xE0, 0x95, 0x4D);
    private static readonly Color SkillsAccentColor = Color.FromRgb(0xB2, 0x7F, 0xE0);

    /// <summary>One warm accent per bundled course, so the catalog reads as a set of
    /// distinct subjects rather than four identical teal rows.</summary>
    private static Color AccentColorForCourse(string courseIdentifier) => courseIdentifier switch
    {
        "code-with-ai" => CodeAccentColor,
        "build-a-phone-agent" => PhoneAccentColor,
        "ai-fluency-essentials" => FluencyAccentColor,
        _ => LearnAccentColor, // build-a-website — the brass hero color
    };

    private const double TabSlotWidth = 30;

    public NotchWindow(CompanionManager companionManager)
    {
        this.companionManager = companionManager;
        InitializeComponent();

        NotchGrainOverlay.Fill = GrainTextureFactory.GetGrainBrush();

        ModelPickerComboBox.ItemsSource = OpenRouterModelOptions.Models;
        BuildCourseCatalogCards();

        // Hug the top screen edge, centered — the notch position.
        Loaded += (_, _) =>
        {
            ApplyPlacementFromConfig();
            RefreshStatusDisplay();
            StartIdleTrianglePulse();
        };

        NotchHoverCatcher.MouseLeftButtonDown += HandleNotchDragStart;

        collapseAfterMouseLeaveTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(600),
        };
        collapseAfterMouseLeaveTimer.Tick += (_, _) =>
        {
            collapseAfterMouseLeaveTimer.Stop();
            // Don't collapse while the user is typing a key or question.
            if (!IsMouseOver && !OpenRouterApiKeyInput.IsKeyboardFocused && !TypedQuestionInput.IsKeyboardFocused)
            {
                Collapse();
            }
        };
    }

    /// <summary>
    /// Places the window per the saved preset (or exact custom position). Also
    /// sets which edge of the drag frame the visible bar hugs — Left/Center/Right
    /// alignment on the closed-state hosts — so "top-left" actually sits flush
    /// against the left edge instead of centered-but-shifted.
    /// </summary>
    public void ApplyPlacementFromConfig()
    {
        (double screenLeft, double screenTop, double screenWidth, double _) = GetPrimaryScreenBoundsInDeviceIndependentUnits();

        NotchPlacementPreset placementPreset = companionManager.GetNotchPlacementPreset();
        HorizontalAlignment closedStateAlignment;

        switch (placementPreset)
        {
            case NotchPlacementPreset.TopLeft:
                closedStateAlignment = HorizontalAlignment.Left;
                Left = screenLeft;
                Top = screenTop;
                break;

            case NotchPlacementPreset.TopRight:
                closedStateAlignment = HorizontalAlignment.Right;
                Left = screenLeft + screenWidth - Width;
                Top = screenTop;
                break;

            case NotchPlacementPreset.Custom:
                (double Left, double Top, string HorizontalAlignment)? customPlacement = companionManager.GetCustomNotchPlacement();
                closedStateAlignment = ParseHorizontalAlignment(customPlacement?.HorizontalAlignment);
                Left = customPlacement?.Left ?? screenLeft + (screenWidth - Width) / 2;
                Top = customPlacement?.Top ?? screenTop;
                break;

            case NotchPlacementPreset.TopCenter:
            default:
                closedStateAlignment = HorizontalAlignment.Center;
                Left = screenLeft + (screenWidth - Width) / 2;
                Top = screenTop;
                break;
        }

        NotchArea.HorizontalAlignment = closedStateAlignment;
        NotchHoverCatcher.HorizontalAlignment = closedStateAlignment;
        IdleTriangleHost.HorizontalAlignment = closedStateAlignment;
        LiveActivityHost.HorizontalAlignment = closedStateAlignment;

        Teachy.Platform.TeachyLog.Write(
            $"Notch placed: preset={placementPreset} Left={Left:F0} Top={Top:F0} align={closedStateAlignment} " +
            $"[diag screenDIU={screenLeft:F0},{screenTop:F0},{screenWidth:F0} rawBounds={System.Windows.Forms.Screen.PrimaryScreen?.Bounds}]");
    }

    private (double ScreenLeft, double ScreenTop, double ScreenWidth, double ScreenHeight) GetPrimaryScreenBoundsInDeviceIndependentUnits()
    {
        System.Windows.Forms.Screen primaryScreen = System.Windows.Forms.Screen.PrimaryScreen
            ?? System.Windows.Forms.Screen.AllScreens[0];

        // Physical pixels -> DIU using this window's actual DPI. Screen.Bounds is
        // physical pixels while WPF's Left/Top are DIU — mixing them up pushes
        // the notch off-position on any scaled display.
        double dpiScaleX = 1.0;
        double dpiScaleY = 1.0;
        if (PresentationSource.FromVisual(this)?.CompositionTarget is { } compositionTarget)
        {
            dpiScaleX = compositionTarget.TransformToDevice.M11;
            dpiScaleY = compositionTarget.TransformToDevice.M22;
        }

        return (
            primaryScreen.Bounds.Left / dpiScaleX,
            primaryScreen.Bounds.Top / dpiScaleY,
            primaryScreen.Bounds.Width / dpiScaleX,
            primaryScreen.Bounds.Height / dpiScaleY);
    }

    private static HorizontalAlignment ParseHorizontalAlignment(string? alignmentName) => alignmentName switch
    {
        "Center" => HorizontalAlignment.Center,
        "Right" => HorizontalAlignment.Right,
        _ => HorizontalAlignment.Left,
    };

    // ---- Drag to reposition ----

    private void HandleNotchDragStart(object sender, System.Windows.Input.MouseButtonEventArgs mouseButtonEventArgs)
    {
        if (isExpanded)
        {
            return;
        }

        try
        {
            DragMove(); // blocks until the mouse button is released
        }
        catch (InvalidOperationException)
        {
            // DragMove throws if the button was already released — safe to ignore.
            return;
        }

        // Persist exactly where the user put it, using whichever edge alignment
        // was active during the drag so the bar doesn't jump on next launch.
        string currentAlignmentName = NotchArea.HorizontalAlignment.ToString();
        companionManager.SetCustomNotchPosition(Left, Top, currentAlignmentName);
    }

    // ---- Expand / collapse springs (ClickyNotchSizing.openSpring / closeSpring) ----

    public void Expand()
    {
        if (isExpanded)
        {
            return;
        }
        isExpanded = true;

        IdleTriangleHost.Visibility = Visibility.Collapsed;
        LiveActivityHost.Visibility = Visibility.Collapsed;
        NotchHoverCatcher.Visibility = Visibility.Collapsed; // open panel is its own hover target
        OpenContentHost.Visibility = Visibility.Visible;
        SelectTab(selectedTab);

        // Gentle overshoot ≈ the macOS open spring (response 0.42, damping 0.8).
        var openEase = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.14 };
        TimeSpan openDuration = TimeSpan.FromMilliseconds(400);

        AnimateNotchGeometry(OpenWidth, OpenHeight, OpenedTopCornerRadius, OpenedBottomCornerRadius, openDuration, openEase);

        OpenContentHost.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(220))
        {
            BeginTime = TimeSpan.FromMilliseconds(110),
        });
    }

    /// <summary>
    /// Animates the notch box + corner radii together at a pinned 60fps. The
    /// silhouette stretches to NotchArea, so only these properties animate —
    /// keeping the spring smooth instead of fighting a second width animation.
    /// </summary>
    private void AnimateNotchGeometry(
        double targetWidth, double targetHeight,
        double targetTopCornerRadius, double targetBottomCornerRadius,
        TimeSpan duration, IEasingFunction easingFunction)
    {
        var widthAnimation = new DoubleAnimation(targetWidth, duration) { EasingFunction = easingFunction };
        var heightAnimation = new DoubleAnimation(targetHeight, duration) { EasingFunction = easingFunction };
        var topRadiusAnimation = new DoubleAnimation(targetTopCornerRadius, duration);
        var bottomRadiusAnimation = new DoubleAnimation(targetBottomCornerRadius, duration);

        foreach (DoubleAnimation notchAnimation in new[] { widthAnimation, heightAnimation, topRadiusAnimation, bottomRadiusAnimation })
        {
            Timeline.SetDesiredFrameRate(notchAnimation, 60);
        }

        NotchArea.BeginAnimation(WidthProperty, widthAnimation);
        NotchArea.BeginAnimation(HeightProperty, heightAnimation);
        NotchBackground.BeginAnimation(TeachyNotchShape.TopCornerRadiusProperty, topRadiusAnimation);
        NotchBackground.BeginAnimation(TeachyNotchShape.BottomCornerRadiusProperty, bottomRadiusAnimation);
    }

    public void Collapse()
    {
        if (!isExpanded)
        {
            return;
        }
        isExpanded = false;

        // Fully damped close (macOS closeSpring: response 0.45, damping 1.0 — no overshoot).
        var closeEase = new CubicEase { EasingMode = EasingMode.EaseInOut };
        TimeSpan closeDuration = TimeSpan.FromMilliseconds(340);

        OpenContentHost.BeginAnimation(OpacityProperty, new DoubleAnimation(0, TimeSpan.FromMilliseconds(120)));

        AnimateNotchGeometry(ClosedAreaWidth, ClosedHeight, ClosedTopCornerRadius, ClosedBottomCornerRadius, closeDuration, closeEase);

        var restoreClosedStateTimer = new DispatcherTimer { Interval = closeDuration };
        restoreClosedStateTimer.Tick += (_, _) =>
        {
            restoreClosedStateTimer.Stop();
            if (!isExpanded)
            {
                OpenContentHost.Visibility = Visibility.Collapsed;
                NotchHoverCatcher.Visibility = Visibility.Visible;
                IdleTriangleHost.Visibility = isShowingLiveActivity ? Visibility.Collapsed : Visibility.Visible;
                LiveActivityHost.Visibility = isShowingLiveActivity ? Visibility.Visible : Visibility.Collapsed;
            }
        };
        restoreClosedStateTimer.Start();
    }

    public void ToggleExpanded()
    {
        if (isExpanded)
        {
            Collapse();
        }
        else
        {
            Expand();
        }
    }

    public void ExpandToSettings()
    {
        selectedTab = NotchTab.Settings;
        Expand();
        SelectTab(NotchTab.Settings);
    }

    private void HandleNotchMouseEnter(object sender, System.Windows.Input.MouseEventArgs mouseEventArgs)
    {
        collapseAfterMouseLeaveTimer.Stop();
        if (!isExpanded)
        {
            Expand();
        }
    }

    private void HandleWindowMouseLeave(object sender, System.Windows.Input.MouseEventArgs mouseEventArgs)
    {
        if (isExpanded)
        {
            collapseAfterMouseLeaveTimer.Stop();
            collapseAfterMouseLeaveTimer.Start();
        }
    }

    private void HandleCollapseClicked(object sender, RoutedEventArgs routedEventArgs)
    {
        Collapse();
    }

    // ---- Closed live activity (listening / thinking wings, like the mac liveActivityRow) ----

    /// <summary>Shows or hides the closed-notch live-activity wings (triangle + spectrum).</summary>
    public void SetLiveActivity(bool isLiveActivityActive)
    {
        Dispatcher.BeginInvoke(() =>
        {
            isShowingLiveActivity = isLiveActivityActive;

            if (isExpanded)
            {
                return; // open notch has its own header; wings are a closed-state thing
            }

            if (isLiveActivityActive)
            {
                IdleTriangleHost.Visibility = Visibility.Collapsed;
                LiveActivityHost.Visibility = Visibility.Visible;
                StartSpectrumAnimation();
            }
            else
            {
                LiveActivityHost.Visibility = Visibility.Collapsed;
                IdleTriangleHost.Visibility = Visibility.Visible;
            }
        });
    }

    private void StartSpectrumAnimation()
    {
        AnimateSpectrumBar(SpectrumBar1, 5, 13, 0.34);
        AnimateSpectrumBar(SpectrumBar2, 7, 16, 0.27);
        AnimateSpectrumBar(SpectrumBar3, 4, 12, 0.42);
        AnimateSpectrumBar(SpectrumBar4, 8, 15, 0.31);
    }

    private static void AnimateSpectrumBar(System.Windows.Shapes.Rectangle spectrumBar, double minHeight, double maxHeight, double periodSeconds)
    {
        var heightBounce = new DoubleAnimation(minHeight, maxHeight, TimeSpan.FromSeconds(periodSeconds))
        {
            AutoReverse = true,
            RepeatBehavior = RepeatBehavior.Forever,
            EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
        };
        spectrumBar.BeginAnimation(HeightProperty, heightBounce);
    }

    // ---- Idle triangle pulse (macOS idleIconPulseScale 1.0 -> 1.12 forever) ----

    private void StartIdleTrianglePulse()
    {
        var corePulse = new DoubleAnimation(1.0, 1.12, TimeSpan.FromSeconds(1.4))
        {
            AutoReverse = true,
            RepeatBehavior = RepeatBehavior.Forever,
            EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
        };
        IdleCorePulseScale.BeginAnimation(ScaleTransform.ScaleXProperty, corePulse);
        IdleCorePulseScale.BeginAnimation(ScaleTransform.ScaleYProperty, corePulse);

        var glowPulse = new DoubleAnimation(1.35, 1.5, TimeSpan.FromSeconds(1.4))
        {
            AutoReverse = true,
            RepeatBehavior = RepeatBehavior.Forever,
            EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
        };
        IdleGlowPulseScale.BeginAnimation(ScaleTransform.ScaleXProperty, glowPulse);
        IdleGlowPulseScale.BeginAnimation(ScaleTransform.ScaleYProperty, glowPulse);
    }

    // ---- Tabs ----

    private void HandleLearnTabClicked(object sender, RoutedEventArgs e) => SelectTab(NotchTab.Learn);
    private void HandlePortfolioTabClicked(object sender, RoutedEventArgs e) => SelectTab(NotchTab.Portfolio);
    private void HandleSkillsTabClicked(object sender, RoutedEventArgs e) => SelectTab(NotchTab.Skills);
    private void HandleSettingsTabClicked(object sender, RoutedEventArgs e) => SelectTab(NotchTab.Settings);

    private void SelectTab(NotchTab tabToSelect)
    {
        selectedTab = tabToSelect;

        if (tabToSelect == NotchTab.Skills)
        {
            RebuildSkillsTab();
        }
        else if (tabToSelect == NotchTab.Portfolio)
        {
            RebuildPortfolioTab();
        }

        LearnTabPanel.Visibility = tabToSelect == NotchTab.Learn ? Visibility.Visible : Visibility.Collapsed;
        PortfolioTabPanel.Visibility = tabToSelect == NotchTab.Portfolio ? Visibility.Visible : Visibility.Collapsed;
        SkillsTabPanel.Visibility = tabToSelect == NotchTab.Skills ? Visibility.Visible : Visibility.Collapsed;
        SettingsTabPanel.Visibility = tabToSelect == NotchTab.Settings ? Visibility.Visible : Visibility.Collapsed;

        StyleTabGlyph(LearnTabGlyph, tabToSelect == NotchTab.Learn, LearnAccentColor);
        StyleTabGlyph(PortfolioTabGlyph, tabToSelect == NotchTab.Portfolio, PortfolioAccentColor);
        StyleTabGlyph(SkillsTabGlyph, tabToSelect == NotchTab.Skills, SkillsAccentColor);
        StyleTabGlyph(SettingsTabGlyph, tabToSelect == NotchTab.Settings, BrassColor);

        AnimateTabIndicatorTo(TabIndexFor(tabToSelect));
    }

    private static int TabIndexFor(NotchTab tab) => tab switch
    {
        NotchTab.Learn => 0,
        NotchTab.Portfolio => 1,
        NotchTab.Skills => 2,
        NotchTab.Settings => 3,
        _ => 0,
    };

    /// <summary>Slides the single shared brass pill behind the newly active tab icon.</summary>
    private void AnimateTabIndicatorTo(int tabIndex)
    {
        var slideAnimation = new DoubleAnimation(tabIndex * TabSlotWidth, TimeSpan.FromMilliseconds(220))
        {
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
        };
        TabIndicatorTranslate.BeginAnimation(TranslateTransform.XProperty, slideAnimation);
    }

    private static void StyleTabGlyph(TextBlock tabGlyph, bool isSelected, Color accentColor)
    {
        tabGlyph.Foreground = isSelected ? new SolidColorBrush(accentColor) : Brushes.Gray;
    }

    // ---- Skills tab: learner progress per course domain ----

    private void RebuildSkillsTab()
    {
        var trackedCourses = CourseCatalog.BundledCourses
            .Select(courseEntry => (courseEntry, progress: companionManager.learnerProgress.ProgressForCourse(courseEntry.CourseIdentifier)))
            .Where(pair => pair.progress is { CompletedGoalCount: > 0 })
            .ToList();

        bool hasAnySkillData = trackedCourses.Count > 0;
        SkillsEmptyState.Visibility = hasAnySkillData ? Visibility.Collapsed : Visibility.Visible;
        SkillsListScroller.Visibility = hasAnySkillData ? Visibility.Visible : Visibility.Collapsed;

        SkillsListHost.Children.Clear();
        foreach ((CourseCatalogEntry courseEntry, Teachy.Platform.CourseProgress? progress) in trackedCourses)
        {
            if (progress is null)
            {
                continue;
            }

            var skillRow = new Border
            {
                Background = (Brush)FindResource("Surface1"),
                CornerRadius = new CornerRadius(12),
                Padding = new Thickness(14, 10, 14, 10),
                Margin = new Thickness(0, 0, 6, 8),
            };
            var rowStack = new StackPanel();
            var headerRow = new DockPanel();
            headerRow.Children.Add(new TextBlock
            {
                Text = courseEntry.Title,
                Foreground = (Brush)FindResource("TextPrimary"),
                FontFamily = (FontFamily)FindResource("BodyFont"),
                FontSize = 12.5,
                FontWeight = FontWeights.SemiBold,
            });
            var proficiencyLabel = new TextBlock
            {
                Text = progress.IsCourseCompleted
                    ? "proficient"
                    : progress.CompletedGoalCount >= progress.TotalGoalCount / 2 ? "developing" : "learning",
                Foreground = new SolidColorBrush(SkillsAccentColor),
                FontFamily = (FontFamily)FindResource("BodyFont"),
                FontSize = 10.5,
                FontWeight = FontWeights.SemiBold,
                HorizontalAlignment = HorizontalAlignment.Right,
            };
            DockPanel.SetDock(proficiencyLabel, Dock.Right);
            headerRow.Children.Add(proficiencyLabel);
            rowStack.Children.Add(headerRow);

            var skillTrack = new Border
            {
                Background = (Brush)FindResource("Surface2"),
                CornerRadius = new CornerRadius(2),
                Height = 4,
                Margin = new Thickness(0, 8, 0, 4),
            };
            skillTrack.Child = new Border
            {
                Background = new SolidColorBrush(SkillsAccentColor),
                CornerRadius = new CornerRadius(2),
                HorizontalAlignment = HorizontalAlignment.Left,
                Width = 500 * Math.Clamp((double)progress.CompletedGoalCount / Math.Max(1, progress.TotalGoalCount), 0, 1),
            };
            rowStack.Children.Add(skillTrack);

            rowStack.Children.Add(new TextBlock
            {
                Text = $"{progress.CompletedGoalCount} of {progress.TotalGoalCount} goals · last practiced {progress.LastActivityUtc.ToLocalTime():MMM d}",
                Foreground = (Brush)FindResource("TextTertiary"),
                FontFamily = (FontFamily)FindResource("BodyFont"),
                FontSize = 10,
            });

            skillRow.Child = rowStack;
            SkillsListHost.Children.Add(skillRow);
        }
    }

    // ---- Portfolio tab: artifacts from completed courses ----

    private void RebuildPortfolioTab()
    {
        var completedCourses = CourseCatalog.BundledCourses
            .Select(courseEntry => (courseEntry, progress: companionManager.learnerProgress.ProgressForCourse(courseEntry.CourseIdentifier)))
            .Where(pair => pair.progress is { IsCourseCompleted: true })
            .ToList();

        bool hasArtifacts = completedCourses.Count > 0;
        PortfolioEmptyState.Visibility = hasArtifacts ? Visibility.Collapsed : Visibility.Visible;
        PortfolioListScroller.Visibility = hasArtifacts ? Visibility.Visible : Visibility.Collapsed;

        PortfolioListHost.Children.Clear();
        foreach ((CourseCatalogEntry courseEntry, Teachy.Platform.CourseProgress? progress) in completedCourses)
        {
            var artifactCard = new Border
            {
                Background = (Brush)FindResource("Surface1"),
                CornerRadius = new CornerRadius(12),
                Padding = new Thickness(14, 11, 14, 11),
                Margin = new Thickness(0, 0, 6, 8),
            };
            var cardStack = new StackPanel();
            var titleRow = new DockPanel();
            titleRow.Children.Add(new TextBlock
            {
                Text = courseEntry.Title,
                Foreground = (Brush)FindResource("TextPrimary"),
                FontFamily = (FontFamily)FindResource("BodyFont"),
                FontSize = 12.5,
                FontWeight = FontWeights.SemiBold,
            });
            var completedBadge = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0x24, PortfolioAccentColor.R, PortfolioAccentColor.G, PortfolioAccentColor.B)),
                CornerRadius = new CornerRadius(7),
                Padding = new Thickness(8, 2, 8, 2),
                HorizontalAlignment = HorizontalAlignment.Right,
                Child = new TextBlock
                {
                    Text = "shipped",
                    Foreground = new SolidColorBrush(PortfolioAccentColor),
                    FontFamily = (FontFamily)FindResource("BodyFont"),
                    FontSize = 10,
                    FontWeight = FontWeights.SemiBold,
                },
            };
            DockPanel.SetDock(completedBadge, Dock.Right);
            titleRow.Children.Add(completedBadge);
            cardStack.Children.Add(titleRow);

            cardStack.Children.Add(new TextBlock
            {
                Text = courseEntry.Subtitle,
                Foreground = (Brush)FindResource("TextSecondary"),
                FontFamily = (FontFamily)FindResource("BodyFont"),
                FontSize = 11,
                Margin = new Thickness(0, 3, 0, 0),
            });
            if (progress is not null)
            {
                cardStack.Children.Add(new TextBlock
                {
                    Text = $"completed {progress.LastActivityUtc.ToLocalTime():MMMM d, yyyy}",
                    Foreground = (Brush)FindResource("TextTertiary"),
                    FontFamily = (FontFamily)FindResource("BodyFont"),
                    FontSize = 10,
                    Margin = new Thickness(0, 5, 0, 0),
                });
            }

            artifactCard.Child = cardStack;
            PortfolioListHost.Children.Add(artifactCard);
        }
    }

    // ---- Learn tab: course catalog cards ----

    private void BuildCourseCatalogCards()
    {
        foreach (CourseCatalogEntry courseEntry in CourseCatalog.BundledCourses)
        {
            CourseListHost.Children.Add(BuildCourseCard(courseEntry));
        }
    }

    private UIElement BuildCourseCard(CourseCatalogEntry courseEntry)
    {
        Color courseAccentColor = AccentColorForCourse(courseEntry.CourseIdentifier);
        var courseAccentBrush = new SolidColorBrush(courseAccentColor);

        var cardBorder = new Border
        {
            Background = (Brush)FindResource("Surface1"),
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(14, 12, 14, 12),
            Margin = new Thickness(0, 0, 4, 9),
            Cursor = System.Windows.Input.Cursors.Hand,
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x16, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
        };
        cardBorder.RenderTransform = new TranslateTransform();
        cardBorder.RenderTransformOrigin = new System.Windows.Point(0.5, 0.5);

        // Soft lift + accent-tinted glow on hover — each course's own color, not one flat teal.
        cardBorder.MouseEnter += (_, _) =>
        {
            cardBorder.Background = (Brush)FindResource("Surface2");
            cardBorder.Effect = new DropShadowEffect { Color = courseAccentColor, BlurRadius = 22, ShadowDepth = 0, Opacity = 0.28 };
            ((TranslateTransform)cardBorder.RenderTransform).BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(-1.5, TimeSpan.FromMilliseconds(140)));
        };
        cardBorder.MouseLeave += (_, _) =>
        {
            cardBorder.Background = (Brush)FindResource("Surface1");
            cardBorder.Effect = null;
            ((TranslateTransform)cardBorder.RenderTransform).BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, TimeSpan.FromMilliseconds(180)));
        };

        var cardRootGrid = new Grid();
        cardRootGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        cardRootGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        cardRootGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        // Course icon: a radial glow disc in the course's own accent, not a flat square.
        var badgeGradient = new RadialGradientBrush(
            Color.FromArgb(0x55, courseAccentColor.R, courseAccentColor.G, courseAccentColor.B),
            Color.FromArgb(0x18, courseAccentColor.R, courseAccentColor.G, courseAccentColor.B));
        var iconBadge = new Border
        {
            Background = badgeGradient,
            CornerRadius = new CornerRadius(18),
            Width = 36,
            Height = 36,
            Margin = new Thickness(0, 0, 12, 0),
            VerticalAlignment = VerticalAlignment.Center,
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x40, courseAccentColor.R, courseAccentColor.G, courseAccentColor.B)),
            BorderThickness = new Thickness(1),
            Child = new TextBlock
            {
                Text = courseEntry.IconGlyph,
                FontFamily = (FontFamily)FindResource("IconFont"),
                FontSize = 15,
                Foreground = courseAccentBrush,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        };
        Grid.SetColumn(iconBadge, 0);
        cardRootGrid.Children.Add(iconBadge);

        var titleStack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titleStack.Children.Add(new TextBlock
        {
            Text = courseEntry.Title,
            Foreground = (Brush)FindResource("TextPrimary"),
            FontFamily = (FontFamily)FindResource("DisplayFont"),
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
        });
        titleStack.Children.Add(new TextBlock
        {
            Text = courseEntry.Subtitle,
            Foreground = (Brush)FindResource("TextSecondary"),
            FontFamily = (FontFamily)FindResource("BodyFont"),
            FontSize = 11.5,
            Margin = new Thickness(0, 2, 0, 0),
        });

        // Saved progress: thin glowing pill in the course's own accent.
        Teachy.Platform.CourseProgress? savedProgress =
            companionManager.learnerProgress.ProgressForCourse(courseEntry.CourseIdentifier);
        if (savedProgress is not null && savedProgress.CompletedGoalCount > 0)
        {
            var progressTrack = new Border
            {
                Background = (Brush)FindResource("Surface2"),
                CornerRadius = new CornerRadius(2),
                Height = 4,
                Margin = new Thickness(0, 8, 40, 0),
            };
            double progressFraction = Math.Clamp(
                (double)savedProgress.CompletedGoalCount / Math.Max(1, savedProgress.TotalGoalCount), 0, 1);
            progressTrack.Child = new Border
            {
                Background = courseAccentBrush,
                CornerRadius = new CornerRadius(2),
                HorizontalAlignment = HorizontalAlignment.Left,
                Width = 280 * progressFraction, // track is ~280 wide inside the card
                Effect = new DropShadowEffect { Color = courseAccentColor, BlurRadius = 6, ShadowDepth = 0, Opacity = 0.7 },
            };
            titleStack.Children.Add(progressTrack);
            titleStack.Children.Add(new TextBlock
            {
                Text = savedProgress.IsCourseCompleted
                    ? "Completed"
                    : $"{savedProgress.CompletedGoalCount} of {savedProgress.TotalGoalCount} goals",
                Foreground = (Brush)FindResource("TextTertiary"),
                FontFamily = (FontFamily)FindResource("BodyFont"),
                FontSize = 10,
                Margin = new Thickness(0, 4, 0, 0),
            });
        }

        // Expandable description, hidden until the row is clicked (mac expandable preview).
        var descriptionText = new TextBlock
        {
            Text = courseEntry.Description,
            Foreground = (Brush)FindResource("TextSecondary"),
            FontFamily = (FontFamily)FindResource("BodyFont"),
            FontSize = 11.5,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 9, 0, 0),
            Visibility = Visibility.Collapsed,
        };
        titleStack.Children.Add(descriptionText);
        Grid.SetColumn(titleStack, 1);
        cardRootGrid.Children.Add(titleStack);

        var actionStack = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center,
        };
        actionStack.Children.Add(new TextBlock
        {
            Text = $"{courseEntry.EstimatedMinutes} min",
            Foreground = (Brush)FindResource("TextTertiary"),
            FontFamily = (FontFamily)FindResource("BodyFont"),
            FontSize = 10.5,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 10, 0),
        });

        var startButton = new Button
        {
            Content = savedProgress is { CompletedGoalCount: > 0, IsCourseCompleted: false } ? "Continue" : "Start",
            Background = courseAccentBrush,
            Style = (Style)FindResource("CourseActionPillButtonStyle"),
        };
        startButton.Click += (_, clickEventArgs) =>
        {
            clickEventArgs.Handled = true;
            companionManager.StartCourse(courseEntry);
        };
        actionStack.Children.Add(startButton);
        Grid.SetColumn(actionStack, 2);
        cardRootGrid.Children.Add(actionStack);

        cardBorder.Child = cardRootGrid;
        cardBorder.MouseLeftButtonUp += (_, _) =>
        {
            descriptionText.Visibility = descriptionText.Visibility == Visibility.Visible
                ? Visibility.Collapsed
                : Visibility.Visible;
        };

        return cardBorder;
    }

    // ---- Settings tab handlers ----

    public void RefreshStatusDisplay()
    {
        bool hasApiKey = companionManager.HasOpenRouterApiKey;
        StatusBadgeText.Text = hasApiKey
            ? $"● ready · {companionManager.ChatModelIdentifier}"
            : "● needs API key";
        ApiKeyStatusText.Text = hasApiKey
            ? "Key saved (encrypted with Windows DPAPI). Paste a new one to rotate it."
            : "Paste your free OpenRouter API key (openrouter.ai) — stored encrypted on this machine.";

        isSettingModelPickerProgrammatically = true;
        ModelPickerComboBox.SelectedItem =
            OpenRouterModelOptions.OptionForModelIdentifier(companionManager.ChatModelIdentifier);
        ShowTeachyCursorToggle.IsChecked = companionManager.ShowTeachyCursor;
        isSettingModelPickerProgrammatically = false;

        RefreshPlacementButtonHighlight(companionManager.GetNotchPlacementPreset());
    }

    private void HandlePlacementTopLeftClicked(object sender, RoutedEventArgs routedEventArgs) =>
        ApplyPlacementPresetAndRefreshButtons(NotchPlacementPreset.TopLeft);

    private void HandlePlacementTopCenterClicked(object sender, RoutedEventArgs routedEventArgs) =>
        ApplyPlacementPresetAndRefreshButtons(NotchPlacementPreset.TopCenter);

    private void HandlePlacementTopRightClicked(object sender, RoutedEventArgs routedEventArgs) =>
        ApplyPlacementPresetAndRefreshButtons(NotchPlacementPreset.TopRight);

    private void ApplyPlacementPresetAndRefreshButtons(NotchPlacementPreset placementPreset)
    {
        companionManager.SetNotchPlacementPreset(placementPreset);
        RefreshPlacementButtonHighlight(placementPreset);
    }

    private void RefreshPlacementButtonHighlight(NotchPlacementPreset activePreset)
    {
        StylePlacementChip(PlacementTopLeftButton, activePreset == NotchPlacementPreset.TopLeft);
        StylePlacementChip(PlacementTopCenterButton, activePreset == NotchPlacementPreset.TopCenter);
        StylePlacementChip(PlacementTopRightButton, activePreset == NotchPlacementPreset.TopRight);
    }

    private void StylePlacementChip(Button chipButton, bool isSelected)
    {
        chipButton.Background = isSelected ? (Brush)FindResource("BrassAccent") : (Brush)FindResource("Surface2");
        chipButton.Foreground = isSelected ? new SolidColorBrush(Color.FromRgb(0x1B, 0x17, 0x12)) : (Brush)FindResource("TextSecondary");
    }

    private void HandleShowTeachyCursorChanged(object sender, RoutedEventArgs routedEventArgs)
    {
        if (isSettingModelPickerProgrammatically)
        {
            return;
        }
        companionManager.SetShowTeachyCursor(ShowTeachyCursorToggle.IsChecked == true);
    }

    private void HandleSaveApiKeyClicked(object sender, RoutedEventArgs routedEventArgs)
    {
        string enteredApiKey = OpenRouterApiKeyInput.Password.Trim();
        if (enteredApiKey.Length == 0)
        {
            ApiKeyStatusText.Text = "Key is empty — paste your OpenRouter key first.";
            return;
        }

        companionManager.SaveOpenRouterApiKey(enteredApiKey);
        OpenRouterApiKeyInput.Clear();
        RefreshStatusDisplay();
    }

    private void HandleModelSelectionChanged(object sender, SelectionChangedEventArgs selectionChangedEventArgs)
    {
        if (isSettingModelPickerProgrammatically)
        {
            return;
        }

        if (ModelPickerComboBox.SelectedItem is OpenRouterModelOption selectedModelOption)
        {
            companionManager.SetChosenChatModel(selectedModelOption.ModelIdentifier);
            RefreshStatusDisplay();
        }
    }

    private void HandleAskButtonClicked(object sender, RoutedEventArgs routedEventArgs)
    {
        SubmitTypedQuestion();
    }

    private void HandleTypedQuestionKeyDown(object sender, System.Windows.Input.KeyEventArgs keyEventArgs)
    {
        if (keyEventArgs.Key == System.Windows.Input.Key.Enter)
        {
            SubmitTypedQuestion();
        }
    }

    private void SubmitTypedQuestion()
    {
        string typedQuestion = TypedQuestionInput.Text.Trim();
        if (typedQuestion.Length == 0)
        {
            return;
        }

        TypedQuestionInput.Clear();
        Collapse(); // get the notch out of the way before the screenshot
        companionManager.HandleTypedQuestion(typedQuestion);
    }

    private void HandleQuitClicked(object sender, RoutedEventArgs routedEventArgs)
    {
        System.Windows.Application.Current.Shutdown();
    }
}
