using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Teachy.Engine;

/// <summary>One action the model asked for, decoded from a tool call.</summary>
public sealed class AgentToolRequest
{
    public required string ToolCallId { get; init; }
    public required string ToolName { get; init; }
    public required JsonObject Arguments { get; init; }
}

/// <summary>What executing an action produced, fed back into the loop.</summary>
public sealed class AgentToolOutcome
{
    public required string ResultText { get; init; }

    /// <summary>Fresh screenshot after the action, when the tool re-observes the screen.</summary>
    public byte[]? ScreenshotJpegBytes { get; init; }
}

/// <summary>
/// The "Do it for me" agent loop — the Windows port of the macOS
/// BackgroundAgentManager tool-calling loop. The model sees the screen plus the
/// UI Automation element list, requests concrete actions, and observes the
/// result of each one before deciding the next. The host executes the actions;
/// this class only orchestrates the conversation.
/// </summary>
public sealed class AgentToolLoop
{
    private static readonly HttpClient SharedHttpClient = new() { Timeout = TimeSpan.FromMinutes(3) };
    private const string ChatCompletionsUrl = "https://openrouter.ai/api/v1/chat/completions";

    /// <summary>Ceiling on actions per request so a confused model can't flail forever.</summary>
    private const int MaximumAgentSteps = 12;

    private readonly string openRouterApiKey;
    private readonly string agentModelIdentifier;

    public AgentToolLoop(string openRouterApiKey, string agentModelIdentifier)
    {
        this.openRouterApiKey = openRouterApiKey;
        this.agentModelIdentifier = agentModelIdentifier;
    }

    /// <summary>
    /// Runs the loop until the model stops requesting actions (or the step cap
    /// trips). <paramref name="executeToolAsync"/> performs one action and
    /// returns what happened; <paramref name="onNarration"/> receives the
    /// model's spoken-aloud commentary as it works.
    /// </summary>
    public async Task<string> RunAsync(
        string systemPrompt,
        string userGoal,
        byte[] initialScreenshotJpegBytes,
        string initialElementList,
        Func<AgentToolRequest, Task<AgentToolOutcome>> executeToolAsync,
        Action<string>? onNarration,
        CancellationToken cancellationToken)
    {
        var conversationMessages = new JsonArray
        {
            new JsonObject { ["role"] = "system", ["content"] = systemPrompt },
            new JsonObject
            {
                ["role"] = "user",
                ["content"] = new JsonArray
                {
                    new JsonObject
                    {
                        ["type"] = "text",
                        ["text"] = $"{userGoal}\n\nInteractive elements on the active window right now:\n{initialElementList}",
                    },
                    new JsonObject
                    {
                        ["type"] = "image_url",
                        ["image_url"] = new JsonObject
                        {
                            ["url"] = "data:image/jpeg;base64," + Convert.ToBase64String(initialScreenshotJpegBytes),
                        },
                    },
                },
            },
        };

        for (int stepIndex = 0; stepIndex < MaximumAgentSteps; stepIndex++)
        {
            JsonObject assistantMessage = await RequestNextAssistantMessageAsync(conversationMessages, cancellationToken);
            conversationMessages.Add(assistantMessage.DeepClone());

            string? narrationText = assistantMessage["content"]?.GetValue<string>();
            if (!string.IsNullOrWhiteSpace(narrationText))
            {
                onNarration?.Invoke(narrationText);
            }

            if (assistantMessage["tool_calls"] is not JsonArray toolCallArray || toolCallArray.Count == 0)
            {
                // No more actions requested — the model considers the task done.
                return narrationText ?? "Done.";
            }

            foreach (JsonNode? toolCallNode in toolCallArray)
            {
                if (toolCallNode is not JsonObject toolCallObject)
                {
                    continue;
                }

                AgentToolRequest? toolRequest = TryDecodeToolRequest(toolCallObject);
                if (toolRequest is null)
                {
                    continue;
                }

                AgentToolOutcome toolOutcome = await executeToolAsync(toolRequest);

                conversationMessages.Add(new JsonObject
                {
                    ["role"] = "tool",
                    ["tool_call_id"] = toolRequest.ToolCallId,
                    ["content"] = toolOutcome.ResultText,
                });

                // Re-observing costs a message but is what keeps the loop honest —
                // the model sees what its own action actually did.
                if (toolOutcome.ScreenshotJpegBytes is not null)
                {
                    conversationMessages.Add(new JsonObject
                    {
                        ["role"] = "user",
                        ["content"] = new JsonArray
                        {
                            new JsonObject { ["type"] = "text", ["text"] = "Here is the screen after that action." },
                            new JsonObject
                            {
                                ["type"] = "image_url",
                                ["image_url"] = new JsonObject
                                {
                                    ["url"] = "data:image/jpeg;base64," + Convert.ToBase64String(toolOutcome.ScreenshotJpegBytes),
                                },
                            },
                        },
                    });
                }
            }
        }

        return "I've done as much as I safely can in one go — take a look and tell me what to do next.";
    }

    private async Task<JsonObject> RequestNextAssistantMessageAsync(
        JsonArray conversationMessages, CancellationToken cancellationToken)
    {
        var requestBody = new JsonObject
        {
            ["model"] = agentModelIdentifier,
            ["messages"] = conversationMessages.DeepClone(),
            ["tools"] = AgentToolDefinitions.BuildToolSchemaArray(),
            ["tool_choice"] = "auto",
        };

        using var httpRequest = new HttpRequestMessage(HttpMethod.Post, ChatCompletionsUrl);
        httpRequest.Headers.Authorization = new AuthenticationHeaderValue("Bearer", openRouterApiKey);
        httpRequest.Headers.Add("HTTP-Referer", "https://vedsoni-dev.github.io/teachy/");
        httpRequest.Headers.Add("X-Title", "Teachy");
        httpRequest.Content = new StringContent(requestBody.ToJsonString(), Encoding.UTF8, "application/json");

        using HttpResponseMessage httpResponse = await SharedHttpClient.SendAsync(httpRequest, cancellationToken);
        string responseBody = await httpResponse.Content.ReadAsStringAsync(cancellationToken);

        if (!httpResponse.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                $"Agent request failed ({(int)httpResponse.StatusCode}): {Truncate(responseBody)}");
        }

        JsonNode? responseJson = JsonNode.Parse(responseBody);
        JsonNode? assistantMessageNode = responseJson?["choices"]?[0]?["message"];
        if (assistantMessageNode is not JsonObject assistantMessage)
        {
            throw new InvalidOperationException($"Agent response had no message: {Truncate(responseBody)}");
        }

        return assistantMessage;
    }

    private static AgentToolRequest? TryDecodeToolRequest(JsonObject toolCallObject)
    {
        try
        {
            string? toolCallId = toolCallObject["id"]?.GetValue<string>();
            string? toolName = toolCallObject["function"]?["name"]?.GetValue<string>();
            string argumentsJson = toolCallObject["function"]?["arguments"]?.GetValue<string>() ?? "{}";

            if (toolCallId is null || toolName is null)
            {
                return null;
            }

            var argumentsObject = JsonNode.Parse(argumentsJson) as JsonObject ?? new JsonObject();
            return new AgentToolRequest
            {
                ToolCallId = toolCallId,
                ToolName = toolName,
                Arguments = argumentsObject,
            };
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string Truncate(string text) => text.Length <= 400 ? text : text[..400] + "…";
}
