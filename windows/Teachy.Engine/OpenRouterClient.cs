using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Teachy.Engine;

/// <summary>One turn of companion conversation history (text only — screenshots attach to the newest turn).</summary>
public sealed class CompanionConversationTurn
{
    public required string Role { get; init; } // "user" or "assistant"
    public required string Text { get; init; }
}

/// <summary>
/// Direct OpenRouter chat-completions client with SSE streaming — the Windows
/// equivalent of the macOS BYOK path (app talks to OpenRouter with the user's
/// key; no proxy server required). Vision via data-URL image attachments.
/// </summary>
public sealed class OpenRouterClient
{
    private static readonly HttpClient SharedHttpClient = new() { Timeout = TimeSpan.FromMinutes(3) };

    private const string ChatCompletionsUrl = "https://openrouter.ai/api/v1/chat/completions";

    private readonly string openRouterApiKey;
    private readonly string chatModelIdentifier;

    public OpenRouterClient(string openRouterApiKey, string chatModelIdentifier)
    {
        this.openRouterApiKey = openRouterApiKey;
        this.chatModelIdentifier = chatModelIdentifier;
    }

    /// <summary>
    /// Sends the conversation + latest user message (with an optional JPEG screenshot)
    /// and streams the reply. Calls onPartialText with the accumulated text as deltas
    /// arrive; returns the full reply text.
    /// </summary>
    public async Task<string> StreamCompanionReplyAsync(
        string systemPrompt,
        IReadOnlyList<CompanionConversationTurn> priorConversationTurns,
        string latestUserMessageText,
        byte[]? screenshotJpegBytes,
        Action<string>? onPartialText,
        CancellationToken cancellationToken)
    {
        var messagesArray = new JsonArray
        {
            new JsonObject { ["role"] = "system", ["content"] = systemPrompt },
        };

        foreach (CompanionConversationTurn conversationTurn in priorConversationTurns)
        {
            messagesArray.Add(new JsonObject
            {
                ["role"] = conversationTurn.Role,
                ["content"] = conversationTurn.Text,
            });
        }

        if (screenshotJpegBytes is not null)
        {
            string screenshotDataUrl = "data:image/jpeg;base64," + Convert.ToBase64String(screenshotJpegBytes);
            messagesArray.Add(new JsonObject
            {
                ["role"] = "user",
                ["content"] = new JsonArray
                {
                    new JsonObject { ["type"] = "text", ["text"] = latestUserMessageText },
                    new JsonObject
                    {
                        ["type"] = "image_url",
                        ["image_url"] = new JsonObject { ["url"] = screenshotDataUrl },
                    },
                },
            });
        }
        else
        {
            messagesArray.Add(new JsonObject { ["role"] = "user", ["content"] = latestUserMessageText });
        }

        var requestBodyObject = new JsonObject
        {
            ["model"] = chatModelIdentifier,
            ["messages"] = messagesArray,
            ["stream"] = true,
        };

        using var httpRequest = new HttpRequestMessage(HttpMethod.Post, ChatCompletionsUrl);
        httpRequest.Headers.Authorization = new AuthenticationHeaderValue("Bearer", openRouterApiKey);
        httpRequest.Headers.Add("HTTP-Referer", "https://vedsoni-dev.github.io/teachy/");
        httpRequest.Headers.Add("X-Title", "Teachy");
        httpRequest.Content = new StringContent(requestBodyObject.ToJsonString(), Encoding.UTF8, "application/json");

        using HttpResponseMessage httpResponse = await SharedHttpClient.SendAsync(
            httpRequest, HttpCompletionOption.ResponseHeadersRead, cancellationToken);

        if (!httpResponse.IsSuccessStatusCode)
        {
            string errorBody = await httpResponse.Content.ReadAsStringAsync(cancellationToken);
            throw new InvalidOperationException(
                $"OpenRouter request failed ({(int)httpResponse.StatusCode}): {TruncateForError(errorBody)}");
        }

        var accumulatedReplyText = new StringBuilder();
        await using Stream responseStream = await httpResponse.Content.ReadAsStreamAsync(cancellationToken);
        using var responseReader = new StreamReader(responseStream);

        while (await responseReader.ReadLineAsync(cancellationToken) is { } sseLine)
        {
            if (!sseLine.StartsWith("data: ", StringComparison.Ordinal))
            {
                continue;
            }

            string sseDataPayload = sseLine["data: ".Length..].Trim();
            if (sseDataPayload == "[DONE]")
            {
                break;
            }

            string? deltaText = TryExtractDeltaText(sseDataPayload);
            if (!string.IsNullOrEmpty(deltaText))
            {
                accumulatedReplyText.Append(deltaText);
                onPartialText?.Invoke(accumulatedReplyText.ToString());
            }
        }

        return accumulatedReplyText.ToString();
    }

    private static string? TryExtractDeltaText(string sseDataPayload)
    {
        try
        {
            using JsonDocument sseJson = JsonDocument.Parse(sseDataPayload);
            if (sseJson.RootElement.TryGetProperty("choices", out JsonElement choicesElement)
                && choicesElement.GetArrayLength() > 0
                && choicesElement[0].TryGetProperty("delta", out JsonElement deltaElement)
                && deltaElement.TryGetProperty("content", out JsonElement contentElement)
                && contentElement.ValueKind == JsonValueKind.String)
            {
                return contentElement.GetString();
            }
        }
        catch (JsonException)
        {
            // Malformed keep-alive / comment lines are expected in SSE streams — skip them.
        }

        return null;
    }

    private static string TruncateForError(string errorBody)
    {
        const int maximumErrorLength = 400;
        return errorBody.Length <= maximumErrorLength ? errorBody : errorBody[..maximumErrorLength] + "…";
    }
}
