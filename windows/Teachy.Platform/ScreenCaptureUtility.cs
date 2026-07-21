using System.Drawing;
using System.Drawing.Imaging;
using System.Windows.Forms;

namespace Teachy.Platform;

/// <summary>A captured screenshot plus the screen bounds it came from.</summary>
public sealed class CapturedScreenshot
{
    public required byte[] JpegBytes { get; init; }
    public required int WidthInPixels { get; init; }
    public required int HeightInPixels { get; init; }

    /// <summary>Physical pixel bounds of the captured screen in virtual-desktop coordinates.</summary>
    public required Rectangle ScreenBoundsInPixels { get; init; }

    /// <summary>Grid cells the learner circled while asking, when they traced one.</summary>
    public string? CircledGridCells { get; init; }
}

/// <summary>
/// Primary-display screen capture — the Windows stand-in for the macOS
/// ScreenCaptureKit utility. GDI BitBlt (Graphics.CopyFromScreen) is used for
/// v0: simple, no extra permissions, works everywhere. Multi-monitor capture
/// and Windows.Graphics.Capture come later.
/// </summary>
public static class ScreenCaptureUtility
{
    /// <summary>
    /// Captures the primary screen, burns the faint model-facing coordinate grid
    /// into it, and returns JPEG bytes ready to attach to a vision model request.
    /// When the learner traced a path while holding push-to-talk, that path is
    /// also burned in as a yellow chalk stroke so the model knows what "this" is.
    /// </summary>
    public static CapturedScreenshot CapturePrimaryScreenWithGrid(
        IReadOnlyList<Point>? pointerOutlinePathInScreenPixels = null)
    {
        Rectangle primaryScreenBounds = Screen.PrimaryScreen?.Bounds
            ?? new Rectangle(0, 0, 1920, 1080);

        using var screenshotBitmap = new Bitmap(primaryScreenBounds.Width, primaryScreenBounds.Height, PixelFormat.Format32bppArgb);
        using (Graphics screenshotGraphics = Graphics.FromImage(screenshotBitmap))
        {
            screenshotGraphics.CopyFromScreen(
                primaryScreenBounds.X,
                primaryScreenBounds.Y,
                0,
                0,
                primaryScreenBounds.Size);
        }

        ScreenGridAnnotationUtility.BurnCoordinateGridIntoBitmap(screenshotBitmap);

        string? circledGridCells = null;
        if (pointerOutlinePathInScreenPixels is { Count: > 1 })
        {
            ScreenGridAnnotationUtility.BurnChalkOutlineIntoBitmap(
                screenshotBitmap, pointerOutlinePathInScreenPixels, primaryScreenBounds);
            circledGridCells = ScreenGridAnnotationUtility.DescribeTouchedGridCells(
                pointerOutlinePathInScreenPixels, primaryScreenBounds);
        }

        byte[] jpegBytes = EncodeAsJpeg(screenshotBitmap, jpegQuality: 72);

        return new CapturedScreenshot
        {
            JpegBytes = jpegBytes,
            WidthInPixels = screenshotBitmap.Width,
            HeightInPixels = screenshotBitmap.Height,
            ScreenBoundsInPixels = primaryScreenBounds,
            CircledGridCells = circledGridCells,
        };
    }

    private static byte[] EncodeAsJpeg(Bitmap sourceBitmap, long jpegQuality)
    {
        ImageCodecInfo jpegEncoder = ImageCodecInfo.GetImageEncoders()
            .First(encoderInfo => encoderInfo.FormatID == ImageFormat.Jpeg.Guid);

        using var encoderParameters = new EncoderParameters(1);
        encoderParameters.Param[0] = new EncoderParameter(Encoder.Quality, jpegQuality);

        using var jpegStream = new MemoryStream();
        sourceBitmap.Save(jpegStream, jpegEncoder, encoderParameters);
        return jpegStream.ToArray();
    }
}
