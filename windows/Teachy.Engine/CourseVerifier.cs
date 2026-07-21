using System.Text.Json;

namespace Teachy.Engine;

public enum CourseVerificationStatus { Pass, Partial, OffTrack }

/// <summary>Structured verification result — same shape as the macOS CourseVerificationResult.</summary>
public sealed class CourseVerificationResult
{
    public required CourseVerificationStatus Status { get; init; }
    public required string WhatsGood { get; init; }
    public string? WhatsMissing { get; init; }
    public string? SuggestedNextAction { get; init; }
    public string? VisibleErrorSummary { get; init; }
}

/// <summary>
/// Vision gate for course goal advancement — ported from the macOS
/// CourseVerifier. Sends the current screenshot plus the goal's natural-language
/// doneWhen criteria and expects a structured pass / partial / offTrack JSON.
/// </summary>
public static class CourseVerifier
{
    // Same verifier system prompt as the macOS CourseVerifier.verifyStructured.
    private const string VerifierSystemPrompt = """
        you verify whether a course goal is complete. look at the screenshot only.

        reply with ONLY a JSON object:
        {"status":"pass"|"partial"|"offTrack","whatsGood":"short description of what IS correct on screen","whatsMissing":"what's still missing or wrong — null if pass","suggestedNextAction":"one specific next move the learner should take — null if pass","visibleErrorSummary":"one plain-words sentence describing any error message, stack trace, or failure state visible on screen — null if none"}

        rules:
        - status "pass" = the goal is clearly complete on screen.
        - status "partial" = the learner made real progress but something specific is missing or incomplete. name exactly what they got right first, then what's missing.
        - status "offTrack" = the goal is not meaningfully progressed or the screen shows something unrelated. still name any partial progress if it exists.
        - whatsGood should always name something concrete the learner did or that is visible — never leave it empty.
        - suggestedNextAction should be one short, specific instruction — not a list.
        - be honest but kind. "close" is partial, not offTrack.
        - visibleErrorSummary: set this ONLY when an actual error message, exception, stack trace, or failure state is clearly visible on screen. null otherwise — do not set it for a missing feature or incomplete state.
        """;

    public static async Task<CourseVerificationResult> VerifyAsync(
        OpenRouterClient openRouterClient,
        string doneWhenCriteria,
        byte[] screenshotJpegBytes,
        CancellationToken cancellationToken)
    {
        string userPrompt = $"""
            completion criteria: {doneWhenCriteria}

            What is the current state on screen? Is this goal complete, partially complete, or off track?
            """;

        string rawResponse;
        try
        {
            rawResponse = await openRouterClient.StreamCompanionReplyAsync(
                VerifierSystemPrompt,
                Array.Empty<CompanionConversationTurn>(),
                userPrompt,
                screenshotJpegBytes,
                onPartialText: null,
                cancellationToken);
        }
        catch (Exception verificationError)
        {
            return new CourseVerificationResult
            {
                Status = CourseVerificationStatus.OffTrack,
                WhatsGood = "",
                WhatsMissing = $"vision check failed — {verificationError.Message}",
                SuggestedNextAction = "try the step and press I did it again",
            };
        }

        return ParseStructuredResult(rawResponse);
    }

    private static CourseVerificationResult ParseStructuredResult(string rawText)
    {
        string trimmedText = rawText.Trim();
        int jsonStartIndex = trimmedText.IndexOf('{');
        int jsonEndIndex = trimmedText.LastIndexOf('}');
        string jsonCandidate = jsonStartIndex >= 0 && jsonEndIndex > jsonStartIndex
            ? trimmedText[jsonStartIndex..(jsonEndIndex + 1)]
            : trimmedText;

        try
        {
            using JsonDocument parsedJson = JsonDocument.Parse(jsonCandidate);
            JsonElement rootElement = parsedJson.RootElement;

            string statusString = rootElement.TryGetProperty("status", out JsonElement statusElement)
                ? statusElement.GetString()?.ToLowerInvariant() ?? "offtrack"
                : "offtrack";

            CourseVerificationStatus status = statusString switch
            {
                "pass" => CourseVerificationStatus.Pass,
                "partial" => CourseVerificationStatus.Partial,
                _ => CourseVerificationStatus.OffTrack,
            };

            return new CourseVerificationResult
            {
                Status = status,
                WhatsGood = TryGetString(rootElement, "whatsGood") ?? "",
                WhatsMissing = TryGetString(rootElement, "whatsMissing"),
                SuggestedNextAction = TryGetString(rootElement, "suggestedNextAction"),
                VisibleErrorSummary = TryGetString(rootElement, "visibleErrorSummary"),
            };
        }
        catch (JsonException)
        {
            // Fallback: detect a YES-ish response from unparsed text (mac parity).
            if (trimmedText.StartsWith("yes", StringComparison.OrdinalIgnoreCase))
            {
                return new CourseVerificationResult
                {
                    Status = CourseVerificationStatus.Pass,
                    WhatsGood = "vision confirmed completion",
                };
            }
            return new CourseVerificationResult
            {
                Status = CourseVerificationStatus.OffTrack,
                WhatsGood = "",
                WhatsMissing = "could not parse verification response",
                SuggestedNextAction = "try the step and press I did it again",
            };
        }
    }

    private static string? TryGetString(JsonElement rootElement, string propertyName)
    {
        if (rootElement.TryGetProperty(propertyName, out JsonElement propertyElement)
            && propertyElement.ValueKind == JsonValueKind.String)
        {
            return propertyElement.GetString();
        }
        return null;
    }
}
