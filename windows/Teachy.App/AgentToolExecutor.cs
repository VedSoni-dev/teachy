using System.Text.Json.Nodes;
using Teachy.Engine;
using Teachy.Platform;

namespace Teachy.App;

/// <summary>
/// Executes the actions the agent loop asks for, against the real desktop.
/// Keeps a live element list so ids the model cites resolve to actual controls,
/// and re-observes the screen after every action so the loop sees consequences.
/// </summary>
public sealed class AgentToolExecutor
{
    private IReadOnlyList<InspectedUiElement> currentElements;

    public AgentToolExecutor(IReadOnlyList<InspectedUiElement> initialElements)
    {
        currentElements = initialElements;
    }

    /// <summary>Renders the current element list for the model prompt.</summary>
    public static string FormatElementList(IReadOnlyList<InspectedUiElement> elements)
    {
        if (elements.Count == 0)
        {
            return "(no interactive elements could be read from this window — rely on the screenshot)";
        }
        return string.Join("\n", elements.Select(element => element.ToModelLine()));
    }

    public async Task<AgentToolOutcome> ExecuteAsync(AgentToolRequest toolRequest)
    {
        try
        {
            switch (toolRequest.ToolName)
            {
                case AgentToolDefinitions.ClickElementToolName:
                    return await ExecuteClickAsync(toolRequest.Arguments);

                case AgentToolDefinitions.TypeTextToolName:
                    return await ExecuteTypeAsync(toolRequest.Arguments);

                case AgentToolDefinitions.PressKeyToolName:
                {
                    string keyName = toolRequest.Arguments["key"]?.GetValue<string>() ?? "";
                    bool pressed = InputSynthesizer.PressKey(keyName);
                    return await ObserveAfterActionAsync(pressed ? $"Pressed {keyName}." : $"Could not press \"{keyName}\".");
                }

                case AgentToolDefinitions.ScrollToolName:
                {
                    int wheelNotches = TryReadInteger(toolRequest.Arguments, "notches") ?? -3;
                    InputSynthesizer.Scroll(wheelNotches);
                    return await ObserveAfterActionAsync($"Scrolled {wheelNotches} notches.");
                }

                case AgentToolDefinitions.OpenUrlToolName:
                    return await ExecuteOpenUrlAsync(toolRequest.Arguments);

                case AgentToolDefinitions.ObserveScreenToolName:
                    return await ObserveAfterActionAsync("Re-read the screen.");

                default:
                    return new AgentToolOutcome { ResultText = $"Unknown tool \"{toolRequest.ToolName}\"." };
            }
        }
        catch (Exception executionError)
        {
            TeachyLog.Write($"Tool {toolRequest.ToolName} threw: {executionError.Message}");
            return new AgentToolOutcome { ResultText = $"That action failed: {executionError.Message}" };
        }
    }

    private async Task<AgentToolOutcome> ExecuteClickAsync(JsonObject arguments)
    {
        int? elementId = TryReadInteger(arguments, "element_id");
        InspectedUiElement? targetElement = FindElementById(elementId);
        if (targetElement is null)
        {
            return new AgentToolOutcome
            {
                ResultText = $"No element with id {elementId} exists. Call observe_screen to get a fresh list.",
            };
        }

        bool clicked = InputSynthesizer.ClickElement(targetElement);
        return await ObserveAfterActionAsync(
            clicked ? $"Clicked \"{targetElement.Name}\"." : $"Could not click \"{targetElement.Name}\".");
    }

    private async Task<AgentToolOutcome> ExecuteTypeAsync(JsonObject arguments)
    {
        int? elementId = TryReadInteger(arguments, "element_id");
        string textToType = arguments["text"]?.GetValue<string>() ?? "";
        InspectedUiElement? targetElement = FindElementById(elementId);

        if (targetElement is null)
        {
            return new AgentToolOutcome
            {
                ResultText = $"No element with id {elementId} exists. Call observe_screen to get a fresh list.",
            };
        }

        bool typed = InputSynthesizer.TypeIntoElement(targetElement, textToType);
        return await ObserveAfterActionAsync(
            typed ? $"Typed into \"{targetElement.Name}\"." : $"Could not type into \"{targetElement.Name}\".");
    }

    private async Task<AgentToolOutcome> ExecuteOpenUrlAsync(JsonObject arguments)
    {
        string requestedUrl = arguments["url"]?.GetValue<string>() ?? "";

        // Only http(s) — this tool must not become a way to launch arbitrary programs.
        if (!Uri.TryCreate(requestedUrl, UriKind.Absolute, out Uri? parsedUrl)
            || (parsedUrl.Scheme != Uri.UriSchemeHttp && parsedUrl.Scheme != Uri.UriSchemeHttps))
        {
            return new AgentToolOutcome { ResultText = $"Refused to open \"{requestedUrl}\" — only http/https URLs are allowed." };
        }

        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
        {
            FileName = parsedUrl.ToString(),
            UseShellExecute = true,
        });

        await Task.Delay(2200); // let the page start rendering before observing
        return await ObserveAfterActionAsync($"Opened {parsedUrl}.");
    }

    /// <summary>
    /// Re-reads the screen and element list after an action so the model's next
    /// decision is grounded in what actually happened, not what it intended.
    /// </summary>
    private async Task<AgentToolOutcome> ObserveAfterActionAsync(string resultText)
    {
        await Task.Delay(450); // let the UI settle

        currentElements = UiElementInspector.InspectForegroundWindow();
        CapturedScreenshot freshScreenshot = ScreenCaptureUtility.CapturePrimaryScreenWithGrid();

        return new AgentToolOutcome
        {
            ResultText = $"{resultText}\n\nInteractive elements now:\n{FormatElementList(currentElements)}",
            ScreenshotJpegBytes = freshScreenshot.JpegBytes,
        };
    }

    private InspectedUiElement? FindElementById(int? elementId) =>
        elementId is null ? null : currentElements.FirstOrDefault(element => element.ElementId == elementId.Value);

    private static int? TryReadInteger(JsonObject arguments, string propertyName)
    {
        JsonNode? valueNode = arguments[propertyName];
        if (valueNode is null)
        {
            return null;
        }

        try
        {
            return valueNode.GetValue<int>();
        }
        catch (Exception)
        {
            // Models sometimes send numbers as strings.
            return int.TryParse(valueNode.ToString(), out int parsedValue) ? parsedValue : null;
        }
    }
}
