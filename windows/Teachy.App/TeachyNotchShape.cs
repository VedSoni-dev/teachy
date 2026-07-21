using System.Windows;
using System.Windows.Media;
using System.Windows.Shapes;
using Point = System.Windows.Point;

namespace Teachy.App;

/// <summary>
/// The animatable notch silhouette — a direct port of the macOS ClickyNotchShape
/// (DynamicNotchKit / boring.notch NotchShape). Top corners curve outward from
/// the screen edge; bottom corners round inward. TopCornerRadius and
/// BottomCornerRadius are dependency properties so both can be animated during
/// the open/close spring.
/// </summary>
public sealed class TeachyNotchShape : Shape
{
    public static readonly DependencyProperty TopCornerRadiusProperty = DependencyProperty.Register(
        nameof(TopCornerRadius), typeof(double), typeof(TeachyNotchShape),
        new FrameworkPropertyMetadata(6.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty BottomCornerRadiusProperty = DependencyProperty.Register(
        nameof(BottomCornerRadius), typeof(double), typeof(TeachyNotchShape),
        new FrameworkPropertyMetadata(14.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public double TopCornerRadius
    {
        get => (double)GetValue(TopCornerRadiusProperty);
        set => SetValue(TopCornerRadiusProperty, value);
    }

    public double BottomCornerRadius
    {
        get => (double)GetValue(BottomCornerRadiusProperty);
        set => SetValue(BottomCornerRadiusProperty, value);
    }

    protected override Geometry DefiningGeometry
    {
        get
        {
            double width = Math.Max(ActualWidth, 1);
            double height = Math.Max(ActualHeight, 1);
            double topRadius = TopCornerRadius;
            double bottomRadius = BottomCornerRadius;

            // Same path as ClickyNotchShape.path(in:) — quadratic curves throughout.
            var notchGeometry = new StreamGeometry();
            using (StreamGeometryContext geometryContext = notchGeometry.Open())
            {
                geometryContext.BeginFigure(new Point(0, 0), isFilled: true, isClosed: true);

                // Top-left outward flare.
                geometryContext.QuadraticBezierTo(
                    new Point(topRadius, 0),
                    new Point(topRadius, topRadius),
                    isStroked: true, isSmoothJoin: true);

                // Left edge down.
                geometryContext.LineTo(new Point(topRadius, height - bottomRadius), true, true);

                // Bottom-left rounded corner.
                geometryContext.QuadraticBezierTo(
                    new Point(topRadius, height),
                    new Point(topRadius + bottomRadius, height),
                    true, true);

                // Bottom edge.
                geometryContext.LineTo(new Point(width - topRadius - bottomRadius, height), true, true);

                // Bottom-right rounded corner.
                geometryContext.QuadraticBezierTo(
                    new Point(width - topRadius, height),
                    new Point(width - topRadius, height - bottomRadius),
                    true, true);

                // Right edge up.
                geometryContext.LineTo(new Point(width - topRadius, topRadius), true, true);

                // Top-right outward flare.
                geometryContext.QuadraticBezierTo(
                    new Point(width - topRadius, 0),
                    new Point(width, 0),
                    true, true);
            }

            notchGeometry.Freeze();
            return notchGeometry;
        }
    }
}
