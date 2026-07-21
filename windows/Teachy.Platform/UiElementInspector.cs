using System.Windows.Automation;

namespace Teachy.Platform;

/// <summary>
/// One interactive control found on screen. The model refers to these by
/// <see cref="ElementId"/>, which resolves to exact pixel bounds — the Windows
/// answer to the macOS accessibility element list behind [POINT:ax:ID:label].
/// </summary>
public sealed class InspectedUiElement
{
    public required int ElementId { get; init; }
    public required string Name { get; init; }
    public required string ControlTypeName { get; init; }

    /// <summary>Bounds in physical screen pixels.</summary>
    public required System.Drawing.Rectangle BoundsInScreenPixels { get; init; }

    public bool IsEnabled { get; init; } = true;

    /// <summary>The UIA element itself, used to invoke/focus without synthesizing input.</summary>
    public AutomationElement? AutomationElement { get; init; }

    public System.Drawing.Point CenterInScreenPixels => new(
        BoundsInScreenPixels.X + BoundsInScreenPixels.Width / 2,
        BoundsInScreenPixels.Y + BoundsInScreenPixels.Height / 2);

    /// <summary>One compact line for the model's element list.</summary>
    public string ToModelLine() =>
        $"[{ElementId}] {ControlTypeName}: \"{Name}\" at ({CenterInScreenPixels.X},{CenterInScreenPixels.Y})"
        + (IsEnabled ? "" : " (disabled)");
}

/// <summary>
/// Enumerates the interactive controls of the foreground window via UI
/// Automation. This is what lets Teachy click the *actual* control instead of
/// guessing pixels from a screenshot — the accuracy win that makes
/// "do it for me" trustworthy on Windows.
/// </summary>
public static class UiElementInspector
{
    /// <summary>Control types worth offering to the model — things a learner would click or type into.</summary>
    private static readonly ControlType[] InteractiveControlTypes =
    {
        ControlType.Button,
        ControlType.Edit,
        ControlType.CheckBox,
        ControlType.RadioButton,
        ControlType.ComboBox,
        ControlType.Hyperlink,
        ControlType.ListItem,
        ControlType.MenuItem,
        ControlType.TabItem,
        ControlType.Tree,
        ControlType.TreeItem,
        ControlType.Document,
        ControlType.Text,
    };

    /// <summary>Hard cap so a huge window (a browser DOM) can't blow up the prompt.</summary>
    private const int MaximumReportedElementCount = 60;

    /// <summary>
    /// Snapshots the foreground window's interactive elements, nearest-to-largest
    /// first. Returns an empty list when the window exposes no automation tree.
    /// </summary>
    public static IReadOnlyList<InspectedUiElement> InspectForegroundWindow() =>
        InspectWindow(NativeMethods.GetForegroundWindow());

    /// <summary>
    /// Snapshots one specific window's interactive elements. Taking the handle
    /// explicitly (rather than always reading the foreground) keeps this
    /// testable and lets callers target a window they already identified.
    /// </summary>
    public static IReadOnlyList<InspectedUiElement> InspectWindow(IntPtr windowHandle)
    {
        try
        {
            if (windowHandle == IntPtr.Zero)
            {
                return Array.Empty<InspectedUiElement>();
            }

            AutomationElement? foregroundWindowElement = AutomationElement.FromHandle(windowHandle);
            if (foregroundWindowElement is null)
            {
                return Array.Empty<InspectedUiElement>();
            }

            var interactiveCondition = new OrCondition(
                InteractiveControlTypes
                    .Select(controlType => (Condition)new PropertyCondition(AutomationElement.ControlTypeProperty, controlType))
                    .ToArray());

            AutomationElementCollection descendantElements =
                foregroundWindowElement.FindAll(TreeScope.Descendants, interactiveCondition);

            var inspectedElements = new List<InspectedUiElement>();
            int nextElementId = 1;

            foreach (AutomationElement automationElement in descendantElements)
            {
                if (inspectedElements.Count >= MaximumReportedElementCount)
                {
                    break;
                }

                InspectedUiElement? inspectedElement = TryDescribeElement(automationElement, nextElementId);
                if (inspectedElement is not null)
                {
                    inspectedElements.Add(inspectedElement);
                    nextElementId++;
                }
            }

            TeachyLog.Write($"UIA: inspected {inspectedElements.Count} interactive elements.");
            return inspectedElements;
        }
        catch (Exception inspectionError)
        {
            TeachyLog.Write($"UIA inspection failed: {inspectionError.GetType().Name}: {inspectionError.Message}");
            return Array.Empty<InspectedUiElement>();
        }
    }

    private static InspectedUiElement? TryDescribeElement(AutomationElement automationElement, int elementId)
    {
        try
        {
            System.Windows.Rect boundingRectangle = automationElement.Current.BoundingRectangle;

            // Offscreen, collapsed, or degenerate elements are noise to the model.
            if (automationElement.Current.IsOffscreen
                || double.IsInfinity(boundingRectangle.Width)
                || boundingRectangle.Width < 4
                || boundingRectangle.Height < 4)
            {
                return null;
            }

            string elementName = automationElement.Current.Name?.Trim() ?? "";
            if (elementName.Length == 0)
            {
                elementName = automationElement.Current.AutomationId?.Trim() ?? "";
            }
            if (elementName.Length == 0)
            {
                return null; // nothing the model could refer to meaningfully
            }
            if (elementName.Length > 80)
            {
                elementName = elementName[..80] + "…";
            }

            return new InspectedUiElement
            {
                ElementId = elementId,
                Name = elementName,
                ControlTypeName = automationElement.Current.ControlType.ProgrammaticName.Replace("ControlType.", ""),
                BoundsInScreenPixels = new System.Drawing.Rectangle(
                    (int)boundingRectangle.X, (int)boundingRectangle.Y,
                    (int)boundingRectangle.Width, (int)boundingRectangle.Height),
                IsEnabled = automationElement.Current.IsEnabled,
                AutomationElement = automationElement,
            };
        }
        catch (ElementNotAvailableException)
        {
            return null; // the element vanished mid-walk — normal in live UIs
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static class NativeMethods
    {
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        internal static extern IntPtr GetForegroundWindow();
    }
}
