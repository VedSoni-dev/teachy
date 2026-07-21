namespace Teachy.Platform;

/// <summary>
/// Where the notch sits on the primary screen. The Mac has no equivalent
/// setting — its notch mimics a physical camera housing that is always
/// top-center. Windows has no such housing, so placement is a real user
/// preference: Custom is set automatically when the user drags the notch.
/// </summary>
public enum NotchPlacementPreset
{
    TopLeft,
    TopCenter,
    TopRight,
    Custom,
}
