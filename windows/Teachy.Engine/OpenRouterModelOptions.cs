namespace Teachy.Engine;

/// <summary>One selectable OpenRouter model — ported from the macOS OpenRouterModelOptions.</summary>
public sealed class OpenRouterModelOption
{
    public required string ModelIdentifier { get; init; }
    public required string DisplayName { get; init; }
    public required string Subtitle { get; init; }
    public required bool SupportsVision { get; init; }
}

/// <summary>
/// Curated OpenRouter model list + key-aware defaults, kept in sync with the
/// macOS OpenRouterModelOptions.swift. Bring-your-own-key users (their own
/// bill) default to the smartest tutor; keyless/worker users stay on the
/// free-tier default.
/// </summary>
public static class OpenRouterModelOptions
{
    public const string FreeTierDefaultModelIdentifier = "google/gemini-2.5-flash";
    public const string BringYourOwnKeyDefaultModelIdentifier = "anthropic/claude-sonnet-4.6";
    public const string VisionFallbackModelIdentifier = "google/gemini-2.5-flash";

    public static readonly IReadOnlyList<OpenRouterModelOption> Models = new[]
    {
        new OpenRouterModelOption
        {
            ModelIdentifier = "google/gemini-2.5-flash",
            DisplayName = "Gemini 2.5 Flash",
            Subtitle = "Vision + tools · free default",
            SupportsVision = true,
        },
        new OpenRouterModelOption
        {
            ModelIdentifier = "anthropic/claude-sonnet-4.6",
            DisplayName = "Claude Sonnet 4.6",
            Subtitle = "Smartest tutor · needs your own key",
            SupportsVision = true,
        },
        new OpenRouterModelOption
        {
            ModelIdentifier = "anthropic/claude-haiku-4.5",
            DisplayName = "Claude Haiku 4.5",
            Subtitle = "Fast + sharp · needs your own key",
            SupportsVision = true,
        },
        new OpenRouterModelOption
        {
            ModelIdentifier = "google/gemma-4-26b-a4b-it",
            DisplayName = "Gemma 4 26B",
            Subtitle = "Vision + tools · cheaper",
            SupportsVision = true,
        },
        new OpenRouterModelOption
        {
            ModelIdentifier = "google/gemini-2.5-flash-lite",
            DisplayName = "Gemini 2.5 Flash Lite",
            Subtitle = "Vision + tools · fast",
            SupportsVision = true,
        },
        new OpenRouterModelOption
        {
            ModelIdentifier = "qwen/qwen3-vl-30b-a3b-instruct",
            DisplayName = "Qwen3 VL 30B",
            Subtitle = "Vision + tools",
            SupportsVision = true,
        },
    };

    /// <summary>Key-aware default, mirroring OpenRouterModelOptions.defaultModelID on macOS.</summary>
    public static string DefaultModelIdentifier(bool hasOwnOpenRouterApiKey) =>
        hasOwnOpenRouterApiKey ? BringYourOwnKeyDefaultModelIdentifier : FreeTierDefaultModelIdentifier;

    /// <summary>Returns a known model id, or the key-aware default for stale/unknown stored values.</summary>
    public static string SanitizedModelIdentifier(string? storedModelIdentifier, bool hasOwnOpenRouterApiKey)
    {
        if (storedModelIdentifier is not null
            && Models.Any(modelOption => modelOption.ModelIdentifier == storedModelIdentifier))
        {
            return storedModelIdentifier;
        }
        return DefaultModelIdentifier(hasOwnOpenRouterApiKey);
    }

    public static OpenRouterModelOption OptionForModelIdentifier(string modelIdentifier) =>
        Models.FirstOrDefault(modelOption => modelOption.ModelIdentifier == modelIdentifier) ?? Models[0];
}
