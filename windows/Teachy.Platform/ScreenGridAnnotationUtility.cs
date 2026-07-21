using System.Drawing;
using Teachy.Engine;

namespace Teachy.Platform;

/// <summary>
/// Burns the near-invisible 24x16 coordinate grid (columns A-X, rows 1-16) into
/// screenshots before they go to vision models — ported from the macOS
/// ScreenGridAnnotationUtility. The grid is faint enough that a human ignores it
/// but a vision model can read cell labels to answer with [POINT:M7:...] tags.
/// </summary>
public static class ScreenGridAnnotationUtility
{
    // Same chalk yellow as the macOS ScreenGridAnnotationUtility.
    private static readonly Color ChalkStrokeColor = Color.FromArgb(235, 255, 235, 89);
    private static readonly Color ChalkGlowColor = Color.FromArgb(90, 255, 235, 89);

    /// <summary>
    /// Burns the learner's pointer path onto the screenshot as a yellow chalk
    /// stroke — the visual half of the macOS "circle this and ask" gesture. The
    /// path is in virtual-desktop pixels and is offset into screenshot space.
    /// </summary>
    public static void BurnChalkOutlineIntoBitmap(
        Bitmap screenshotBitmap,
        IReadOnlyList<Point> pointerPathInScreenPixels,
        Rectangle capturedScreenBoundsInPixels)
    {
        if (pointerPathInScreenPixels.Count < 2)
        {
            return;
        }

        Point[] pathInScreenshotSpace = pointerPathInScreenPixels
            .Select(pathPoint => new Point(
                pathPoint.X - capturedScreenBoundsInPixels.X,
                pathPoint.Y - capturedScreenBoundsInPixels.Y))
            .ToArray();

        using Graphics chalkGraphics = Graphics.FromImage(screenshotBitmap);
        chalkGraphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;

        // Wide soft glow underneath, crisp stroke on top — matches the mac look.
        using var chalkGlowPen = new Pen(ChalkGlowColor, 13f)
        {
            StartCap = System.Drawing.Drawing2D.LineCap.Round,
            EndCap = System.Drawing.Drawing2D.LineCap.Round,
            LineJoin = System.Drawing.Drawing2D.LineJoin.Round,
        };
        chalkGraphics.DrawLines(chalkGlowPen, pathInScreenshotSpace);

        using var chalkStrokePen = new Pen(ChalkStrokeColor, 5f)
        {
            StartCap = System.Drawing.Drawing2D.LineCap.Round,
            EndCap = System.Drawing.Drawing2D.LineCap.Round,
            LineJoin = System.Drawing.Drawing2D.LineJoin.Round,
        };
        chalkGraphics.DrawLines(chalkStrokePen, pathInScreenshotSpace);
    }

    /// <summary>
    /// Lists the grid cells the pointer path passed through, as a spatial label
    /// for the model ("the user circled cells M6, M7, N7").
    /// </summary>
    public static string? DescribeTouchedGridCells(
        IReadOnlyList<Point> pointerPathInScreenPixels,
        Rectangle capturedScreenBoundsInPixels)
    {
        if (pointerPathInScreenPixels.Count < 2)
        {
            return null;
        }

        var touchedCellIdentifiers = new List<string>();
        foreach (Point pathPoint in pointerPathInScreenPixels)
        {
            double normalizedX = (double)(pathPoint.X - capturedScreenBoundsInPixels.X) / capturedScreenBoundsInPixels.Width;
            double normalizedY = (double)(pathPoint.Y - capturedScreenBoundsInPixels.Y) / capturedScreenBoundsInPixels.Height;
            if (normalizedX is < 0 or > 1 || normalizedY is < 0 or > 1)
            {
                continue;
            }

            int columnIndex = Math.Clamp((int)(normalizedX * GridGeometry.ColumnCount), 0, GridGeometry.ColumnCount - 1);
            int rowIndex = Math.Clamp((int)(normalizedY * GridGeometry.RowCount), 0, GridGeometry.RowCount - 1);
            string cellIdentifier = GridGeometry.CellIdentifier(columnIndex, rowIndex);
            if (!touchedCellIdentifiers.Contains(cellIdentifier))
            {
                touchedCellIdentifiers.Add(cellIdentifier);
            }
        }

        return touchedCellIdentifiers.Count > 0 ? string.Join(", ", touchedCellIdentifiers) : null;
    }

    public static void BurnCoordinateGridIntoBitmap(Bitmap screenshotBitmap)
    {
        int imageWidth = screenshotBitmap.Width;
        int imageHeight = screenshotBitmap.Height;
        float cellWidth = (float)imageWidth / GridGeometry.ColumnCount;
        float cellHeight = (float)imageHeight / GridGeometry.RowCount;

        using Graphics gridGraphics = Graphics.FromImage(screenshotBitmap);

        // Faint grid lines — visible to the model at JPEG quality 72, ignorable by humans.
        using var gridLinePen = new Pen(Color.FromArgb(18, 128, 128, 128), 1f);
        for (int columnIndex = 0; columnIndex <= GridGeometry.ColumnCount; columnIndex++)
        {
            float lineX = columnIndex * cellWidth;
            gridGraphics.DrawLine(gridLinePen, lineX, 0, lineX, imageHeight);
        }
        for (int rowIndex = 0; rowIndex <= GridGeometry.RowCount; rowIndex++)
        {
            float lineY = rowIndex * cellHeight;
            gridGraphics.DrawLine(gridLinePen, 0, lineY, imageWidth, lineY);
        }

        // Faint cell labels in each cell's top-left corner (e.g. "M7").
        float labelFontSize = Math.Max(8f, cellHeight * 0.16f);
        using var labelFont = new Font("Segoe UI", labelFontSize, FontStyle.Regular, GraphicsUnit.Pixel);
        using var labelBrush = new SolidBrush(Color.FromArgb(46, 128, 128, 128));
        for (int rowIndex = 0; rowIndex < GridGeometry.RowCount; rowIndex++)
        {
            for (int columnIndex = 0; columnIndex < GridGeometry.ColumnCount; columnIndex++)
            {
                string cellIdentifier = GridGeometry.CellIdentifier(columnIndex, rowIndex);
                float labelX = columnIndex * cellWidth + 2f;
                float labelY = rowIndex * cellHeight + 2f;
                gridGraphics.DrawString(cellIdentifier, labelFont, labelBrush, labelX, labelY);
            }
        }
    }

    /// <summary>
    /// Maps a parsed POINT tag to virtual-desktop pixel coordinates using the
    /// captured screen's bounds. Returns null when the tag can't be resolved.
    /// </summary>
    public static Point? ResolvePointTagToScreenPixel(ParsedPointTag pointTag, CapturedScreenshot capturedScreenshot)
    {
        if (pointTag.GridCellIdentifier is not null)
        {
            (double NormalizedX, double NormalizedY)? normalizedCenter =
                GridGeometry.NormalizedCenterForCell(pointTag.GridCellIdentifier);
            if (normalizedCenter is null)
            {
                return null;
            }

            return new Point(
                capturedScreenshot.ScreenBoundsInPixels.X + (int)(normalizedCenter.Value.NormalizedX * capturedScreenshot.ScreenBoundsInPixels.Width),
                capturedScreenshot.ScreenBoundsInPixels.Y + (int)(normalizedCenter.Value.NormalizedY * capturedScreenshot.ScreenBoundsInPixels.Height));
        }

        if (pointTag.PixelCoordinate is not null)
        {
            // Model pixel coordinates are in screenshot space, which for the primary
            // screen matches physical pixels; offset into virtual-desktop space.
            double horizontalScale = (double)capturedScreenshot.ScreenBoundsInPixels.Width / capturedScreenshot.WidthInPixels;
            double verticalScale = (double)capturedScreenshot.ScreenBoundsInPixels.Height / capturedScreenshot.HeightInPixels;
            return new Point(
                capturedScreenshot.ScreenBoundsInPixels.X + (int)(pointTag.PixelCoordinate.Value.X * horizontalScale),
                capturedScreenshot.ScreenBoundsInPixels.Y + (int)(pointTag.PixelCoordinate.Value.Y * verticalScale));
        }

        return null;
    }
}
