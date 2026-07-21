using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Teachy.App;

/// <summary>
/// Procedurally generates a small tileable grain texture, giving the ink
/// surfaces atmosphere instead of reading as flat vector color — the
/// "textured, not flat" cue that separates a designed dark UI from a default
/// one. Built once and cached; WPF has no built-in noise brush, so this bakes
/// per-pixel speckle into a tiny bitmap and tiles it.
/// </summary>
public static class GrainTextureFactory
{
    private static ImageBrush? cachedGrainBrush;

    /// <summary>A low-opacity, tileable speckle brush. Fixed seed so every launch looks identical.</summary>
    public static ImageBrush GetGrainBrush()
    {
        if (cachedGrainBrush is not null)
        {
            return cachedGrainBrush;
        }

        const int textureSize = 96;
        var grainBitmap = new WriteableBitmap(textureSize, textureSize, 96, 96, PixelFormats.Bgra32, null);
        var pixelBuffer = new byte[textureSize * textureSize * 4];
        var randomSource = new Random(1337); // fixed seed — stable across launches

        for (int pixelIndex = 0; pixelIndex < textureSize * textureSize; pixelIndex++)
        {
            int byteOffset = pixelIndex * 4;

            // Sparse speckle: most pixels fully transparent, occasional faint
            // warm-white or dark fleck — mimics fine paper/chalk-dust grain.
            double specklRoll = randomSource.NextDouble();
            if (specklRoll < 0.04)
            {
                bool isLightFleck = randomSource.NextDouble() < 0.6;
                byte alpha = (byte)randomSource.Next(10, 34);
                byte channelValue = isLightFleck ? (byte)235 : (byte)0;
                pixelBuffer[byteOffset + 0] = channelValue; // B
                pixelBuffer[byteOffset + 1] = channelValue; // G
                pixelBuffer[byteOffset + 2] = channelValue; // R
                pixelBuffer[byteOffset + 3] = alpha;        // A
            }
        }

        grainBitmap.WritePixels(new Int32Rect(0, 0, textureSize, textureSize), pixelBuffer, textureSize * 4, 0);
        grainBitmap.Freeze();

        cachedGrainBrush = new ImageBrush(grainBitmap)
        {
            TileMode = TileMode.Tile,
            Viewport = new System.Windows.Rect(0, 0, textureSize, textureSize),
            ViewportUnits = BrushMappingMode.Absolute,
            Stretch = Stretch.None,
        };
        cachedGrainBrush.Freeze();
        return cachedGrainBrush;
    }
}
