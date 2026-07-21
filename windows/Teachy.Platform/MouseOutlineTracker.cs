using System.Drawing;
using System.Windows.Forms;

namespace Teachy.Platform;

/// <summary>
/// Records the pointer path while push-to-talk is held — the Windows port of the
/// macOS MouseOutlineTracker. If the learner circles something on screen while
/// asking "what is this?", the path is burned into the model-facing screenshot
/// as a chalk stroke so "this" has a referent.
/// </summary>
public sealed class MouseOutlineTracker
{
    private readonly List<Point> recordedPointerPath = new();
    private readonly System.Timers.Timer samplingTimer;
    private readonly object pathWriteLock = new();

    /// <summary>Below this total path length the movement is incidental, not a deliberate circle.</summary>
    private const double MinimumMeaningfulPathLengthInPixels = 120;

    public MouseOutlineTracker()
    {
        // ~40 samples/sec — smooth enough to trace a circle, cheap enough to ignore.
        samplingTimer = new System.Timers.Timer(24) { AutoReset = true };
        samplingTimer.Elapsed += (_, _) => RecordCurrentPointerPosition();
    }

    public void StartTracking()
    {
        lock (pathWriteLock)
        {
            recordedPointerPath.Clear();
        }
        samplingTimer.Start();
    }

    /// <summary>
    /// Stops sampling and returns the traced path, or null when the learner
    /// didn't move enough for it to mean anything.
    /// </summary>
    public IReadOnlyList<Point>? StopTrackingAndGetOutline()
    {
        samplingTimer.Stop();

        lock (pathWriteLock)
        {
            if (recordedPointerPath.Count < 6 || TotalPathLengthInPixels() < MinimumMeaningfulPathLengthInPixels)
            {
                return null;
            }
            return recordedPointerPath.ToArray();
        }
    }

    private void RecordCurrentPointerPosition()
    {
        Point currentPointerPosition = Cursor.Position;

        lock (pathWriteLock)
        {
            // Skip duplicate samples so a resting pointer doesn't pad the path.
            if (recordedPointerPath.Count > 0 && recordedPointerPath[^1] == currentPointerPosition)
            {
                return;
            }
            recordedPointerPath.Add(currentPointerPosition);
        }
    }

    private double TotalPathLengthInPixels()
    {
        double totalLength = 0;
        for (int pointIndex = 1; pointIndex < recordedPointerPath.Count; pointIndex++)
        {
            Point previousPoint = recordedPointerPath[pointIndex - 1];
            Point currentPoint = recordedPointerPath[pointIndex];
            double deltaX = currentPoint.X - previousPoint.X;
            double deltaY = currentPoint.Y - previousPoint.Y;
            totalLength += Math.Sqrt(deltaX * deltaX + deltaY * deltaY);
        }
        return totalLength;
    }
}
