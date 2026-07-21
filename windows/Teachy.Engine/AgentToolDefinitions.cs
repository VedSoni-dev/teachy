using System.Text.Json.Nodes;

namespace Teachy.Engine;

/// <summary>
/// The action vocabulary offered to the "Do it for me" agent. Deliberately
/// narrow: screen-level interactions a learner could perform themselves, so a
/// confused model can only do what the learner could have done by hand. There
/// is no shell tool and no filesystem tool.
/// </summary>
public static class AgentToolDefinitions
{
    public const string ClickElementToolName = "click_element";
    public const string TypeTextToolName = "type_text";
    public const string PressKeyToolName = "press_key";
    public const string ScrollToolName = "scroll";
    public const string OpenUrlToolName = "open_url";
    public const string ObserveScreenToolName = "observe_screen";

    public static JsonArray BuildToolSchemaArray() => new()
    {
        BuildToolSchema(
            ClickElementToolName,
            "Click one interactive element from the element list, by its id number. Prefer this over coordinates — it clicks the real control.",
            new JsonObject
            {
                ["element_id"] = BuildProperty("integer", "The [id] of the element to click, from the element list."),
            },
            requiredPropertyNames: new[] { "element_id" }),

        BuildToolSchema(
            TypeTextToolName,
            "Type text into a text field. Give the element id of the field; it is focused first.",
            new JsonObject
            {
                ["element_id"] = BuildProperty("integer", "The [id] of the text field to type into."),
                ["text"] = BuildProperty("string", "The exact text to type."),
            },
            requiredPropertyNames: new[] { "element_id", "text" }),

        BuildToolSchema(
            PressKeyToolName,
            "Press a single key: enter, tab, escape, backspace, delete, up, down, left, right, home, end, space.",
            new JsonObject
            {
                ["key"] = BuildProperty("string", "The key name to press."),
            },
            requiredPropertyNames: new[] { "key" }),

        BuildToolSchema(
            ScrollToolName,
            "Scroll the window under the pointer. Positive scrolls up, negative scrolls down.",
            new JsonObject
            {
                ["notches"] = BuildProperty("integer", "Wheel notches, e.g. -3 to scroll down a bit."),
            },
            requiredPropertyNames: new[] { "notches" }),

        BuildToolSchema(
            OpenUrlToolName,
            "Open a web page in the learner's default browser.",
            new JsonObject
            {
                ["url"] = BuildProperty("string", "The full https:// URL to open."),
            },
            requiredPropertyNames: new[] { "url" }),

        BuildToolSchema(
            ObserveScreenToolName,
            "Take a fresh screenshot and re-read the interactive elements. Use this after the screen changes on its own (a page loading, a dialog appearing).",
            new JsonObject(),
            requiredPropertyNames: Array.Empty<string>()),
    };

    private static JsonObject BuildToolSchema(
        string toolName, string toolDescription, JsonObject propertySchemas, string[] requiredPropertyNames)
    {
        var requiredArray = new JsonArray();
        foreach (string requiredPropertyName in requiredPropertyNames)
        {
            requiredArray.Add(requiredPropertyName);
        }

        return new JsonObject
        {
            ["type"] = "function",
            ["function"] = new JsonObject
            {
                ["name"] = toolName,
                ["description"] = toolDescription,
                ["parameters"] = new JsonObject
                {
                    ["type"] = "object",
                    ["properties"] = propertySchemas,
                    ["required"] = requiredArray,
                },
            },
        };
    }

    private static JsonObject BuildProperty(string jsonType, string description) => new()
    {
        ["type"] = jsonType,
        ["description"] = description,
    };

    /// <summary>
    /// System prompt for the agent loop. Mirrors the macOS "do it for me"
    /// contract: narrate before acting, one small step at a time, teach while
    /// doing rather than silently completing the work.
    /// </summary>
    public static string BuildAgentSystemPrompt() => """
        You are Teachy, doing a step FOR the learner because they asked you to — but you
        are still a tutor, not a silent macro.

        How to work:
        - Before each action, say in one short sentence what you're about to do and why.
          That sentence is spoken aloud to the learner, so keep it natural and brief.
        - Take ONE small action at a time, then look at the result before deciding again.
        - Prefer click_element / type_text with element ids from the element list — those
          click the real control. Only fall back to other tools when no element fits.
        - If the screen doesn't look like you expected, call observe_screen and re-read it
          rather than guessing.
        - Stop as soon as the learner's immediate goal is met. Do not keep going into
          extra steps they didn't ask for.
        - Never enter passwords, payment details, or personal information. Never accept
          terms, submit a purchase, or send a message on the learner's behalf. If a step
          needs any of that, stop and tell the learner to do that part themselves.
        - When you're done, say what you did in one sentence and what they should look at.
        """;
}
