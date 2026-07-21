/**
 * Exact transcription of ClickyNotchShape.path(in:) from the macOS app
 * (originally DynamicNotchKit / boring.notch NotchShape).
 *
 * The Swift version walks: top-left outward flare, down the left edge,
 * bottom-left inward round, across the bottom, bottom-right inward round,
 * up the right edge, top-right outward flare. Reproduced here as an SVG path
 * so the silhouette is identical rather than approximated with border-radius.
 */
export function buildNotchPath(
  width: number,
  height: number,
  topCornerRadius: number,
  bottomCornerRadius: number,
): string {
  const minX = 0;
  const minY = 0;
  const maxX = width;
  const maxY = height;
  const topRadius = topCornerRadius;
  const bottomRadius = bottomCornerRadius;

  return [
    `M ${minX} ${minY}`,
    // Top-left outward flare
    `Q ${minX + topRadius} ${minY} ${minX + topRadius} ${minY + topRadius}`,
    // Left edge down
    `L ${minX + topRadius} ${maxY - bottomRadius}`,
    // Bottom-left inward round
    `Q ${minX + topRadius} ${maxY} ${minX + topRadius + bottomRadius} ${maxY}`,
    // Bottom edge
    `L ${maxX - topRadius - bottomRadius} ${maxY}`,
    // Bottom-right inward round
    `Q ${maxX - topRadius} ${maxY} ${maxX - topRadius} ${maxY - bottomRadius}`,
    // Right edge up
    `L ${maxX - topRadius} ${minY + topRadius}`,
    // Top-right outward flare
    `Q ${maxX - topRadius} ${minY} ${maxX} ${minY}`,
    `L ${minX} ${minY}`,
    'Z',
  ].join(' ');
}

/** ClickyNotchSizing.cornerRadiusInsets — opened/closed radii, verbatim. */
export const NOTCH_RADII = {
  opened: { top: 19, bottom: 24 },
  closed: { top: 6, bottom: 14 },
} as const;

/** ClickyNotchSizing sizes. Closed width 185 is the Mac's non-notch-display default. */
export const NOTCH_SIZE = {
  openWidth: 640,
  openHeight: 320,
  closedWidth: 185,
  closedHeight: 36,
} as const;

/**
 * The Teachy cursor mark: the Mac's equilateral Triangle() rotated -35°, with
 * the rotation baked into the points so it never depends on a transform.
 * Matches OverlayWindow.swift's Triangle shape.
 */
export function buildTriangleMarkPoints(size: number): string {
  const centerX = size / 2;
  const centerY = size / 2;
  const triangleHeight = (size * Math.sqrt(3)) / 2;

  const vertices: [number, number][] = [
    [centerX, centerY - triangleHeight / 1.5],
    [centerX - size / 2, centerY + triangleHeight / 3],
    [centerX + size / 2, centerY + triangleHeight / 3],
  ];

  const angleRadians = (-35 * Math.PI) / 180;
  return vertices
    .map(([x, y]) => {
      const deltaX = x - centerX;
      const deltaY = y - centerY;
      const rotatedX = centerX + deltaX * Math.cos(angleRadians) - deltaY * Math.sin(angleRadians);
      const rotatedY = centerY + deltaX * Math.sin(angleRadians) + deltaY * Math.cos(angleRadians);
      return `${rotatedX.toFixed(2)},${rotatedY.toFixed(2)}`;
    })
    .join(' ');
}
