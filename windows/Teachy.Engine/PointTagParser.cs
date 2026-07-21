using System.Text.RegularExpressions;

namespace Teachy.Engine;

/// <summary>
/// The pointing target extracted from a model reply, mirroring the macOS
/// CompanionManager POINT parsing. Exactly one of GridCellIdentifier /
/// PixelCoordinate is set, unless the model said [POINT:none].
/// </summary>
public sealed class ParsedPointTag
{
    /// <summary>
    /// UI Automation element id when the model used [POINT:ax:12:label] — the
    /// most accurate path, since the element's exact bounds are known.
    /// </summary>
    public int? AutomationElementId { get; init; }

    /// <summary>Grid cell like "M7" when the model used [POINT:M7:label].</summary>
    public string? GridCellIdentifier { get; init; }

    /// <summary>Raw screenshot pixel coordinate when the model used [POINT:842,310:label].</summary>
    public (int X, int Y)? PixelCoordinate { get; init; }

    /// <summary>Short human label for what is being pointed at, when provided.</summary>
    public string? Label { get; init; }
}

/// <summary>
/// Result of stripping [POINT:...] tags from a model reply. SpokenText is what
/// gets displayed/spoken; PointTag is the pointing instruction, if any.
/// Ported from the macOS CompanionManager parse logic (grid + pixel + none).
/// </summary>
public sealed class ParsedModelReply
{
    public required string SpokenText { get; init; }
    public ParsedPointTag? PointTag { get; init; }
}

public static class PointTagParser
{
    // [POINT:ax:12:label] — UI Automation element reference (exact bounds).
    private static readonly Regex AutomationElementPattern = new(
        @"\[POINT:\s*ax:\s*(\d+)\s*(?::\s*([^\]]*?))?\s*\]",
        RegexOptions.Compiled);

    // [POINT:E4:label] or [POINT:cell:E4:label], with optional ":screenN" suffix (ignored on Windows v0 — primary display only).
    private static readonly Regex GridCellPattern = new(
        @"\[POINT:(?:cell:)?\s*(" + GridGeometry.GridCellRegexFragment + @")\s*(?::\s*([^\]:\s][^\]:]*?))?(?::screen(\d+))?\s*\]",
        RegexOptions.Compiled);

    // [POINT:842,310:label]
    private static readonly Regex PixelPattern = new(
        @"\[POINT:\s*(\d+)\s*,\s*(\d+)\s*(?::\s*([^\]:\s][^\]:]*?))?(?::screen(\d+))?\s*\]",
        RegexOptions.Compiled);

    // [POINT:none]
    private static readonly Regex NonePattern = new(@"\[POINT:\s*none\s*\]", RegexOptions.Compiled | RegexOptions.IgnoreCase);

    // Any leftover / malformed POINT-ish tag that should never be spoken aloud.
    private static readonly Regex AnyPointTagPattern = new(@"\[POINT:[^\]]*\]", RegexOptions.Compiled);

    public static ParsedModelReply Parse(string modelReplyText)
    {
        ParsedPointTag? parsedPointTag = null;

        // Priority order matches macOS: ax element > grid cell > raw pixels.
        Match automationElementMatch = AutomationElementPattern.Match(modelReplyText);
        Match gridCellMatch = GridCellPattern.Match(modelReplyText);

        if (automationElementMatch.Success
            && int.TryParse(automationElementMatch.Groups[1].Value, out int automationElementId))
        {
            parsedPointTag = new ParsedPointTag
            {
                AutomationElementId = automationElementId,
                Label = automationElementMatch.Groups[2].Success ? automationElementMatch.Groups[2].Value.Trim() : null,
            };
        }
        else if (gridCellMatch.Success)
        {
            parsedPointTag = new ParsedPointTag
            {
                GridCellIdentifier = gridCellMatch.Groups[1].Value.ToUpperInvariant(),
                Label = gridCellMatch.Groups[2].Success ? gridCellMatch.Groups[2].Value.Trim() : null,
            };
        }
        else
        {
            Match pixelMatch = PixelPattern.Match(modelReplyText);
            if (pixelMatch.Success
                && int.TryParse(pixelMatch.Groups[1].Value, out int pixelX)
                && int.TryParse(pixelMatch.Groups[2].Value, out int pixelY))
            {
                parsedPointTag = new ParsedPointTag
                {
                    PixelCoordinate = (pixelX, pixelY),
                    Label = pixelMatch.Groups[3].Success ? pixelMatch.Groups[3].Value.Trim() : null,
                };
            }
        }

        // Strip every POINT-family tag (including [POINT:none] and malformed ones) from the spoken text.
        string spokenText = NonePattern.Replace(modelReplyText, "");
        spokenText = AnyPointTagPattern.Replace(spokenText, "");
        spokenText = Regex.Replace(spokenText, @"[ \t]{2,}", " ").Trim();

        return new ParsedModelReply { SpokenText = spokenText, PointTag = parsedPointTag };
    }
}
