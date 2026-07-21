namespace Teachy.Engine;

/// <summary>One bundled Teachy course — catalog metadata ported from the macOS ClickyCourseCatalog.</summary>
public sealed class CourseCatalogEntry
{
    public required string CourseIdentifier { get; init; }
    public required string Title { get; init; }
    public required string Subtitle { get; init; }
    public required string Description { get; init; }
    public required int EstimatedMinutes { get; init; }

    /// <summary>Segoe MDL2 Assets glyph standing in for the macOS SF Symbol icon.</summary>
    public required string IconGlyph { get; init; }

    /// <summary>Soft-start URL the course opens, when it has one.</summary>
    public string? StartUrl { get; init; }
}

/// <summary>
/// The bundled course catalog — same four flagship courses, titles, subtitles,
/// descriptions, and durations as ClickyCourseCatalog.bundledCourses on macOS.
/// </summary>
public static class CourseCatalog
{
    public static readonly IReadOnlyList<CourseCatalogEntry> BundledCourses = new[]
    {
        new CourseCatalogEntry
        {
            CourseIdentifier = "build-a-website",
            Title = "Build & Deploy a Website",
            Subtitle = "From zero to a live site the world can visit",
            Description = "Build a real personal website from scratch with HTML & CSS, then deploy it to GitHub Pages so anyone on the internet can see it.",
            EstimatedMinutes = 45,
            IconGlyph = "", // monitor
            StartUrl = "https://github.com/new",
        },
        new CourseCatalogEntry
        {
            CourseIdentifier = "code-with-ai",
            Title = "Code with AI",
            Subtitle = "Direct an AI coding agent like a pro",
            Description = "Non-developers bounce off coding agents because they don't know how to instruct them. This course teaches you the instruct → verify → iterate loop so you can actually ship things.",
            EstimatedMinutes = 40,
            IconGlyph = "", // code braces
            StartUrl = null,
        },
        new CourseCatalogEntry
        {
            CourseIdentifier = "build-a-phone-agent",
            Title = "Build a Phone Agent",
            Subtitle = "A voice AI that answers calls for you",
            Description = "Build a working voice AI assistant that can handle phone calls — without writing a single line of code. You'll have something you can actually talk to in the browser before this course ends.",
            EstimatedMinutes = 35,
            IconGlyph = "", // phone
            StartUrl = "https://dashboard.vapi.ai",
        },
        new CourseCatalogEntry
        {
            CourseIdentifier = "ai-fluency-essentials",
            Title = "AI Fluency Essentials",
            Subtitle = "Prompt, pick tools, and trust — the core skills",
            Description = "The mental models behind getting reliable results from AI — not tricks, but durable habits that apply to every tool you will ever use.",
            EstimatedMinutes = 25,
            IconGlyph = "", // lightbulb-ish
            StartUrl = null,
        },
    };

    /// <summary>Featured course ids shown first for new learners — same as macOS.</summary>
    public static readonly IReadOnlyList<string> FeaturedCourseIdentifiers = new[]
    {
        "build-a-website",
        "code-with-ai",
    };
}
