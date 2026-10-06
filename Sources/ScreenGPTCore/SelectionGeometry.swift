import CoreGraphics

public enum SelectionHandle: CaseIterable, Equatable, Sendable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
}

public enum SelectionDrag: Equatable, Sendable {
    case move
    case resize(SelectionHandle)
}

/// Hit testing and drag geometry for a selection in top-left-origin coordinates.
public enum SelectionGeometry {
    /// Returns the nearest applicable corner or edge handle, the move action for
    /// points inside the selection, or `nil` for points outside it.
    public static func hitTest(
        _ point: CGPoint,
        selection: CGRect,
        tolerance: CGFloat = 8
    ) -> SelectionDrag? {
        let rect = selection.standardized
        let distance = max(0, tolerance)

        // Corners take priority where their hit areas meet edge hit areas.
        let corners: [(SelectionHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY))
        ]
        for (handle, corner) in corners where
            abs(point.x - corner.x) <= distance && abs(point.y - corner.y) <= distance {
            return .resize(handle)
        }

        let horizontalEdges: [(SelectionHandle, CGFloat)] = [(.top, rect.minY), (.bottom, rect.maxY)]
        for (handle, y) in horizontalEdges where
            abs(point.y - y) <= distance && point.x >= rect.minX - distance && point.x <= rect.maxX + distance {
            return .resize(handle)
        }

        let verticalEdges: [(SelectionHandle, CGFloat)] = [(.right, rect.maxX), (.left, rect.minX)]
        for (handle, x) in verticalEdges where
            abs(point.x - x) <= distance && point.y >= rect.minY - distance && point.y <= rect.maxY + distance {
            return .resize(handle)
        }

        return rect.contains(point) ? .move : nil
    }

    /// Applies a drag measured from the original mouse-down location.
    /// Moving preserves the selection size and clamps its origin to `bounds`.
    /// Resizing keeps the opposite edge fixed and limits the result to `bounds`.
    public static func applying(
        _ drag: SelectionDrag,
        to original: CGRect,
        translation: CGSize,
        in bounds: CGRect,
        minimumSize: CGFloat = 12
    ) -> CGRect {
        let rect = original.standardized
        let limits = bounds.standardized

        switch drag {
        case .move:
            return CGRect(
                x: clamp(rect.minX + translation.width, lower: limits.minX,
                         upper: limits.maxX - rect.width),
                y: clamp(rect.minY + translation.height, lower: limits.minY,
                         upper: limits.maxY - rect.height),
                width: rect.width,
                height: rect.height
            )
        case .resize(let handle):
            let minimum = max(0, minimumSize)
            var left = rect.minX
            var right = rect.maxX
            var top = rect.minY
            var bottom = rect.maxY

            switch handle {
            case .topLeft, .left, .bottomLeft:
                left = resizedEdge(rect.minX + translation.width, anchoredAt: right,
                                   lowerBound: limits.minX, upperBound: limits.maxX,
                                   minimum: minimum, growsTowardIncreasingValues: false)
            case .topRight, .right, .bottomRight:
                right = resizedEdge(rect.maxX + translation.width, anchoredAt: left,
                                    lowerBound: limits.minX, upperBound: limits.maxX,
                                    minimum: minimum, growsTowardIncreasingValues: true)
            case .top, .bottom:
                break
            }

            switch handle {
            case .topLeft, .top, .topRight:
                top = resizedEdge(rect.minY + translation.height, anchoredAt: bottom,
                                  lowerBound: limits.minY, upperBound: limits.maxY,
                                  minimum: minimum, growsTowardIncreasingValues: false)
            case .bottomLeft, .bottom, .bottomRight:
                bottom = resizedEdge(rect.maxY + translation.height, anchoredAt: top,
                                     lowerBound: limits.minY, upperBound: limits.maxY,
                                     minimum: minimum, growsTowardIncreasingValues: true)
            case .right, .left:
                break
            }

            return CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
        }
    }

    /// The center of each resize handle, in the enum's declared order.
    public static func handlePoints(for selection: CGRect) -> [(SelectionHandle, CGPoint)] {
        let rect = selection.standardized
        return [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.top, CGPoint(x: rect.midX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.right, CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottom, CGPoint(x: rect.midX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.left, CGPoint(x: rect.minX, y: rect.midY))
        ]
    }

    private static func resizedEdge(
        _ proposed: CGFloat,
        anchoredAt anchor: CGFloat,
        lowerBound: CGFloat,
        upperBound: CGFloat,
        minimum: CGFloat,
        growsTowardIncreasingValues: Bool
    ) -> CGFloat {
        if growsTowardIncreasingValues {
            let effectiveMinimum = min(minimum, max(0, upperBound - anchor))
            return clamp(proposed, lower: anchor + effectiveMinimum, upper: upperBound)
        } else {
            let effectiveMinimum = min(minimum, max(0, anchor - lowerBound))
            return clamp(proposed, lower: lowerBound, upper: anchor - effectiveMinimum)
        }
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}
