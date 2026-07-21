using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Animation;

namespace Teachy.App;

/// <summary>
/// Full-screen transparent, click-through, non-activating overlay hosting the
/// blue cursor companion, response bubble, and pointing animation — the Windows
/// port of the macOS OverlayWindow NSPanel. Covers the primary screen; never
/// steals focus or intercepts clicks.
/// </summary>
public partial class OverlayWindow : Window
{
    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_TRANSPARENT = 0x00000020;
    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int WS_EX_TOOLWINDOW = 0x00000080;

    /// <summary>
    /// Drives the companion cursor's idle follow. Polls the real pointer and
    /// eases the triangle toward it so it trails with personality instead of
    /// being glued to the tip — the macOS companion behavior.
    /// </summary>
    private readonly System.Windows.Threading.DispatcherTimer cursorFollowTimer = new()
    {
        Interval = TimeSpan.FromMilliseconds(16), // ~60fps
    };

    private System.Windows.Point companionCursorPosition;
    private bool isFollowingPointer;

    /// <summary>Set while a pointing animation owns the cursor — follow pauses so the
    /// glide-to-target isn't fought by the follower.</summary>
    private bool isPointingAnimationActive;

    public OverlayWindow()
    {
        InitializeComponent();

        cursorFollowTimer.Tick += HandleCursorFollowTick;

        // Cover the primary screen in WPF device-independent units.
        Left = 0;
        Top = 0;
        Width = SystemParameters.PrimaryScreenWidth;
        Height = SystemParameters.PrimaryScreenHeight;

        SourceInitialized += (_, _) =>
        {
            // Make the overlay click-through and non-activating at the Win32 level —
            // WPF alone cannot express this.
            IntPtr overlayWindowHandle = new WindowInteropHelper(this).Handle;
            int currentExtendedStyle = GetWindowLong(overlayWindowHandle, GWL_EXSTYLE);
            SetWindowLong(
                overlayWindowHandle,
                GWL_EXSTYLE,
                currentExtendedStyle | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
        };
    }

    // ---- Idle follow ----

    /// <summary>
    /// Starts the always-on companion cursor that trails the real pointer
    /// ("Show Teachy" on macOS). Safe to call repeatedly.
    /// </summary>
    public void StartFollowingPointer()
    {
        if (isFollowingPointer)
        {
            return;
        }
        isFollowingPointer = true;

        System.Drawing.Point pointerPosition = System.Windows.Forms.Cursor.Position;
        companionCursorPosition = ConvertScreenPixelToDeviceIndependent(pointerPosition);
        companionCursorPosition.X += CompanionCursorTrailOffsetX;
        companionCursorPosition.Y += CompanionCursorTrailOffsetY;
        PlaceCompanionCursorAt(companionCursorPosition);

        CompanionCursor.BeginAnimation(OpacityProperty, new DoubleAnimation(IdleFollowOpacity, TimeSpan.FromMilliseconds(400)));
        cursorFollowTimer.Start();
    }

    public void StopFollowingPointer()
    {
        isFollowingPointer = false;
        cursorFollowTimer.Stop();
        CompanionCursor.BeginAnimation(OpacityProperty, new DoubleAnimation(0, TimeSpan.FromMilliseconds(300)));
    }

    /// <summary>How far below-right of the real pointer the companion trails.</summary>
    private const double CompanionCursorTrailOffsetX = 26;
    private const double CompanionCursorTrailOffsetY = 26;

    /// <summary>Resting opacity while idly following — present but not shouting.</summary>
    private const double IdleFollowOpacity = 0.82;

    /// <summary>Per-frame easing toward the pointer; lower = more lag/personality.</summary>
    private const double CursorFollowEasingFactor = 0.18;

    private void HandleCursorFollowTick(object? sender, EventArgs eventArgs)
    {
        if (isPointingAnimationActive)
        {
            return;
        }

        System.Drawing.Point pointerPosition = System.Windows.Forms.Cursor.Position;
        System.Windows.Point targetPoint = ConvertScreenPixelToDeviceIndependent(
            new System.Drawing.Point(pointerPosition.X, pointerPosition.Y));
        targetPoint.X += CompanionCursorTrailOffsetX;
        targetPoint.Y += CompanionCursorTrailOffsetY;

        // Exponential ease-in toward the pointer — smooth trailing, no jitter.
        companionCursorPosition.X += (targetPoint.X - companionCursorPosition.X) * CursorFollowEasingFactor;
        companionCursorPosition.Y += (targetPoint.Y - companionCursorPosition.Y) * CursorFollowEasingFactor;

        PlaceCompanionCursorAt(companionCursorPosition);

        // Keep the response bubble docked to the companion while it's visible.
        if (ResponseBubble.Opacity > 0.01)
        {
            PositionResponseBubbleNearCursorTarget(companionCursorPosition);
        }
    }

    private void PlaceCompanionCursorAt(System.Windows.Point deviceIndependentPoint)
    {
        System.Windows.Controls.Canvas.SetLeft(CompanionCursor, deviceIndependentPoint.X - CompanionCursor.Width / 2);
        System.Windows.Controls.Canvas.SetTop(CompanionCursor, deviceIndependentPoint.Y - CompanionCursor.Height / 2);
    }

    /// <summary>Shows the companion cursor near the given screen point (physical pixels).</summary>
    public void ShowCompanionCursorAtScreenPixel(System.Drawing.Point screenPixelPoint)
    {
        System.Windows.Point deviceIndependentPoint = ConvertScreenPixelToDeviceIndependent(screenPixelPoint);
        System.Windows.Controls.Canvas.SetLeft(CompanionCursor, deviceIndependentPoint.X - CompanionCursor.Width / 2);
        System.Windows.Controls.Canvas.SetTop(CompanionCursor, deviceIndependentPoint.Y - CompanionCursor.Height / 2);
        AnimateOpacity(CompanionCursor, 1.0, TimeSpan.FromMilliseconds(180));
        PositionResponseBubbleNearCursor();
    }

    /// <summary>Animates the cursor gliding to a target and pulses the pointing ring there.</summary>
    public void AnimatePointingToScreenPixel(System.Drawing.Point targetScreenPixelPoint)
    {
        System.Windows.Point targetPoint = ConvertScreenPixelToDeviceIndependent(targetScreenPixelPoint);
        Teachy.Platform.TeachyLog.Write(
            $"Point: physical=({targetScreenPixelPoint.X},{targetScreenPixelPoint.Y}) " +
            $"-> DIU=({targetPoint.X:F0},{targetPoint.Y:F0}) overlayWindowSize=({Width:F0}x{Height:F0}) " +
            $"currentCursorPos=({companionCursorPosition.X:F0},{companionCursorPosition.Y:F0}) isFollowing={isFollowingPointer}");

        // The glide owns the cursor until the pulse finishes; the idle follower
        // resumes from wherever it landed so it doesn't snap back.
        isPointingAnimationActive = true;

        double targetCursorLeft = targetPoint.X - CompanionCursor.Width / 2;
        double targetCursorTop = targetPoint.Y - CompanionCursor.Height / 2;

        double glideDurationMilliseconds = 550;
        var glideEasing = new CubicEase { EasingMode = EasingMode.EaseInOut };

        var leftAnimation = new DoubleAnimation(targetCursorLeft, TimeSpan.FromMilliseconds(glideDurationMilliseconds)) { EasingFunction = glideEasing };
        var topAnimation = new DoubleAnimation(targetCursorTop, TimeSpan.FromMilliseconds(glideDurationMilliseconds)) { EasingFunction = glideEasing };
        CompanionCursor.BeginAnimation(System.Windows.Controls.Canvas.LeftProperty, leftAnimation);
        CompanionCursor.BeginAnimation(System.Windows.Controls.Canvas.TopProperty, topAnimation);
        AnimateOpacity(CompanionCursor, 1.0, TimeSpan.FromMilliseconds(120));

        // Pulse the ring at the target after the glide lands.
        System.Windows.Controls.Canvas.SetLeft(PointingRing, targetPoint.X - PointingRing.Width / 2);
        System.Windows.Controls.Canvas.SetTop(PointingRing, targetPoint.Y - PointingRing.Height / 2);
        var ringPulseAnimation = new DoubleAnimation
        {
            From = 0.0,
            To = 1.0,
            BeginTime = TimeSpan.FromMilliseconds(glideDurationMilliseconds),
            Duration = TimeSpan.FromMilliseconds(260),
            AutoReverse = true,
            RepeatBehavior = new RepeatBehavior(3),
        };
        PointingRing.BeginAnimation(OpacityProperty, ringPulseAnimation);

        // Keep the bubble readable — dock it near the new cursor position.
        var bubbleFollowDelay = new DoubleAnimation
        {
            From = ResponseBubble.Opacity,
            To = ResponseBubble.Opacity,
            Duration = TimeSpan.FromMilliseconds(glideDurationMilliseconds),
        };
        bubbleFollowDelay.Completed += (_, _) => PositionResponseBubbleNearCursorTarget(targetPoint);
        ResponseBubble.BeginAnimation(OpacityProperty, bubbleFollowDelay);

        // Hand the cursor back to the idle follower once the pointing pulse is done.
        var releasePointingHoldTimer = new System.Windows.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(glideDurationMilliseconds + 260 * 6),
        };
        releasePointingHoldTimer.Tick += (_, _) =>
        {
            releasePointingHoldTimer.Stop();
            CompanionCursor.BeginAnimation(System.Windows.Controls.Canvas.LeftProperty, null);
            CompanionCursor.BeginAnimation(System.Windows.Controls.Canvas.TopProperty, null);
            companionCursorPosition = targetPoint;
            PlaceCompanionCursorAt(companionCursorPosition);
            isPointingAnimationActive = false;
        };
        releasePointingHoldTimer.Start();
    }

    /// <summary>Shows the "listening…" state in the bubble next to the current mouse position.</summary>
    public void ShowListeningState()
    {
        if (isFollowingPointer)
        {
            // Already trailing the pointer — just brighten it to full attention.
            CompanionCursor.BeginAnimation(OpacityProperty, new DoubleAnimation(1.0, TimeSpan.FromMilliseconds(140)));
            PositionResponseBubbleNearCursorTarget(companionCursorPosition);
        }
        else
        {
            System.Drawing.Point currentMousePosition = System.Windows.Forms.Cursor.Position;
            ShowCompanionCursorAtScreenPixel(new System.Drawing.Point(currentMousePosition.X + 28, currentMousePosition.Y + 28));
        }

        ResponseStatusText.Text = "listening…";
        ResponseStatusText.Visibility = Visibility.Visible;
        ResponseBodyText.Text = "";
        AnimateOpacity(ResponseBubble, 1.0, TimeSpan.FromMilliseconds(180));
    }

    /// <summary>Shows a status line (e.g. "thinking…") without body text.</summary>
    public void ShowStatus(string statusText)
    {
        ResponseStatusText.Text = statusText;
        ResponseStatusText.Visibility = Visibility.Visible;
        AnimateOpacity(ResponseBubble, 1.0, TimeSpan.FromMilliseconds(120));
        AnimateOpacity(CompanionCursor, 1.0, TimeSpan.FromMilliseconds(120));
    }

    /// <summary>Streams reply text into the bubble as it arrives from the model.</summary>
    public void ShowResponseText(string responseText)
    {
        ResponseStatusText.Visibility = Visibility.Collapsed;
        ResponseBodyText.Text = responseText;
        AnimateOpacity(ResponseBubble, 1.0, TimeSpan.FromMilliseconds(120));
    }

    /// <summary>
    /// Ends the interaction: the bubble and pointing ring fade out. While the
    /// companion is following the pointer it stays on screen (dimmed back to its
    /// resting opacity) instead of disappearing.
    /// </summary>
    public void FadeOutAfterDelay(TimeSpan delayBeforeFadeOut)
    {
        var fadeOutAnimation = new DoubleAnimation
        {
            To = 0.0,
            BeginTime = delayBeforeFadeOut,
            Duration = TimeSpan.FromMilliseconds(450),
        };
        ResponseBubble.BeginAnimation(OpacityProperty, fadeOutAnimation);
        PointingRing.BeginAnimation(OpacityProperty, fadeOutAnimation.Clone());

        CompanionCursor.BeginAnimation(OpacityProperty, new DoubleAnimation
        {
            To = isFollowingPointer ? IdleFollowOpacity : 0.0,
            BeginTime = delayBeforeFadeOut,
            Duration = TimeSpan.FromMilliseconds(450),
        });
    }

    private void PositionResponseBubbleNearCursor()
    {
        double cursorLeft = System.Windows.Controls.Canvas.GetLeft(CompanionCursor);
        double cursorTop = System.Windows.Controls.Canvas.GetTop(CompanionCursor);
        PositionResponseBubbleNearCursorTarget(new System.Windows.Point(cursorLeft, cursorTop));
    }

    private void PositionResponseBubbleNearCursorTarget(System.Windows.Point cursorPoint)
    {
        // Prefer below-right of the cursor; flip up/left near screen edges.
        double bubbleLeft = cursorPoint.X + 34;
        double bubbleTop = cursorPoint.Y + 34;

        ResponseBubble.Measure(new System.Windows.Size(double.PositiveInfinity, double.PositiveInfinity));
        double bubbleWidth = Math.Max(ResponseBubble.DesiredSize.Width, 120);
        double bubbleHeight = Math.Max(ResponseBubble.DesiredSize.Height, 40);

        if (bubbleLeft + bubbleWidth > Width - 16)
        {
            bubbleLeft = cursorPoint.X - bubbleWidth - 18;
        }
        if (bubbleTop + bubbleHeight > Height - 16)
        {
            bubbleTop = cursorPoint.Y - bubbleHeight - 18;
        }

        System.Windows.Controls.Canvas.SetLeft(ResponseBubble, Math.Max(8, bubbleLeft));
        System.Windows.Controls.Canvas.SetTop(ResponseBubble, Math.Max(8, bubbleTop));
    }

    private System.Windows.Point ConvertScreenPixelToDeviceIndependent(System.Drawing.Point screenPixelPoint)
    {
        PresentationSource? presentationSource = PresentationSource.FromVisual(this);
        if (presentationSource?.CompositionTarget is { } compositionTarget)
        {
            double dpiScaleX = compositionTarget.TransformToDevice.M11;
            double dpiScaleY = compositionTarget.TransformToDevice.M22;
            return new System.Windows.Point(screenPixelPoint.X / dpiScaleX, screenPixelPoint.Y / dpiScaleY);
        }
        return new System.Windows.Point(screenPixelPoint.X, screenPixelPoint.Y);
    }

    private static void AnimateOpacity(UIElement targetElement, double targetOpacity, TimeSpan animationDuration)
    {
        targetElement.BeginAnimation(OpacityProperty, new DoubleAnimation(targetOpacity, animationDuration));
    }

    [DllImport("user32.dll")]
    private static extern int GetWindowLong(IntPtr windowHandle, int styleIndex);

    [DllImport("user32.dll")]
    private static extern int SetWindowLong(IntPtr windowHandle, int styleIndex, int newStyleValue);
}
