namespace Teachy.Engine;

/// <summary>
/// Pure math for the invisible screenshot grid, matching the macOS
/// ScreenGridAnnotationUtility: 24 columns (A-X) by 16 rows (1-16).
/// Vision models reference cells like "M7"; this converts a cell id to a
/// normalized (0..1) center point that the caller maps onto real screen bounds.
/// </summary>
public static class GridGeometry
{
    public const int ColumnCount = 24;
    public const int RowCount = 16;

    /// <summary>Regex fragment matching a valid cell id, e.g. "E4" or "X16".</summary>
    public const string GridCellRegexFragment = "[A-Xa-x](?:1[0-6]|[1-9])";

    /// <summary>
    /// Converts a grid cell id (e.g. "M7") to the normalized center of that cell.
    /// Returns null when the cell id is out of range or malformed.
    /// </summary>
    public static (double NormalizedX, double NormalizedY)? NormalizedCenterForCell(string gridCellIdentifier)
    {
        if (string.IsNullOrWhiteSpace(gridCellIdentifier) || gridCellIdentifier.Length < 2)
        {
            return null;
        }

        char columnLetter = char.ToUpperInvariant(gridCellIdentifier[0]);
        int columnIndex = columnLetter - 'A';
        if (columnIndex < 0 || columnIndex >= ColumnCount)
        {
            return null;
        }

        if (!int.TryParse(gridCellIdentifier[1..], out int rowNumber) || rowNumber < 1 || rowNumber > RowCount)
        {
            return null;
        }

        double normalizedX = (columnIndex + 0.5) / ColumnCount;
        double normalizedY = (rowNumber - 1 + 0.5) / RowCount;
        return (normalizedX, normalizedY);
    }

    /// <summary>Cell id for a column/row index pair, e.g. (12, 6) -> "M7".</summary>
    public static string CellIdentifier(int columnIndex, int rowIndex)
    {
        char columnLetter = (char)('A' + columnIndex);
        return $"{columnLetter}{rowIndex + 1}";
    }
}
