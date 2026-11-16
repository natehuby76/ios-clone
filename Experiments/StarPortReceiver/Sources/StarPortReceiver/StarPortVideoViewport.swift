import Foundation

/// Only content safe-area rectangles belong here. CarPlay's map-button guide
/// describes button placement and is not a viewport for video content.
public enum StarPortVideoViewport {
    public static func visibleRect(bounds: CGRect, contentSafeAreas: [CGRect], fallbackSideInset: CGFloat = 0) -> CGRect {
        guard valid(bounds) else { return .zero }
        var visible = bounds
        for safe in contentSafeAreas where valid(safe) {
            let clipped = visible.intersection(safe)
            if valid(clipped) { visible = clipped }
        }
        if visible.minX <= bounds.minX + 0.5 && visible.maxX >= bounds.maxX - 0.5,
           fallbackSideInset.isFinite, fallbackSideInset > 0 {
            // Some CarPlay systems report an entirely uninset map window while
            // the system dock overlays it. Without a reported dock side, leave
            // room on both edges rather than guessing left versus right.
            let gutter = min(fallbackSideInset, bounds.width / 4)
            visible = visible.insetBy(dx: gutter, dy: 0)
        }
        return visible
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.width > 0 && rect.height > 0 &&
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
    }
}
