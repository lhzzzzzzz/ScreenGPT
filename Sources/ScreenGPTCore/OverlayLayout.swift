import CoreGraphics

/// Geometry for placing the response and toolbar in a screen coordinate space
/// whose origin is at the top left.
public struct LayoutResult {
    public let toolbar: CGRect
    public let result: CGRect
    /// True when the response had to be placed over the selected region.
    public let isInside: Bool

    public init(toolbar: CGRect, result: CGRect, isInside: Bool) {
        self.toolbar = toolbar
        self.result = result
        self.isInside = isInside
    }
}

public enum OverlayLayout {
    private static let screenInset: CGFloat = 12
    private static let gap: CGFloat = 12

    /// Places a response near a selection and a toolbar near the selection.
    /// Screen coordinates use a top-left origin.
    public static func arrange(
        selection: CGRect,
        bounds: CGRect,
        resultSize: CGSize = CGSize(width: 360, height: 430),
        toolbarSize: CGSize = CGSize(width: 420, height: 48)
    ) -> LayoutResult {
        let screen = bounds.standardized
        let available = CGRect(
            x: screen.minX + min(screenInset, max(0, screen.width / 2)),
            y: screen.minY + min(screenInset, max(0, screen.height / 2)),
            width: max(0, screen.width - 2 * screenInset),
            height: max(0, screen.height - 2 * screenInset)
        )
        let selected = selection.standardized
        let fittedResultSize = fit(resultSize, in: available.size)
        let fittedToolbarSize = fit(toolbarSize, in: available.size)

        let toolbarOptions = toolbarCandidates(selection: selected, available: available,
                                               size: fittedToolbarSize)
        // Score toolbar/result pairs together. Keeping the toolbar close to the
        // selection dominates; panel distance and preferred side break ties.
        var exteriorPairs: [(toolbar: CGRect, result: CGRect, score: Double)] = []
        for (toolbarIndex, toolbar) in toolbarOptions.enumerated() {
            for (side, result) in exteriorCandidates(selection: selected, toolbar: toolbar,
                                                     available: available, size: fittedResultSize).enumerated() {
                guard !toolbar.intersects(result) else { continue }
                let toolbarPenalty = toolbar.intersects(selected) ? 1_000_000.0 : 0
                let score = toolbarPenalty + distance(toolbar, to: selected) * 100 +
                    Double(toolbarIndex) * 0.01 + Double(side) * 5 + distance(result, to: selected) * 0.1
                exteriorPairs.append((toolbar, result, score))
            }
        }
        let chosenExterior = exteriorPairs.min { $0.score < $1.score }
        let isInside = chosenExterior == nil
        let resultFrame = chosenExterior?.result ?? clamped(
            CGRect(x: selected.midX - fittedResultSize.width / 2,
                   y: selected.midY - fittedResultSize.height / 2,
                   width: fittedResultSize.width, height: fittedResultSize.height),
            in: available
        )
        let toolbarFrame = chosenExterior?.toolbar ?? bestToolbar(selection: selected, result: resultFrame,
                                                                  available: available, size: fittedToolbarSize)

        return LayoutResult(toolbar: toolbarFrame, result: resultFrame, isInside: isInside)
    }

    /// Converts a top-left-origin view-space selection to an outward-rounded,
    /// clipped pixel-space rectangle suitable for CGImage cropping.
    public static func cropRect(selection: CGRect, viewSize: CGSize, pixelSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0,
              pixelSize.width > 0, pixelSize.height > 0 else { return .zero }
        let viewBounds = CGRect(origin: .zero, size: viewSize)
        let clipped = selection.standardized.intersection(viewBounds)
        guard !clipped.isNull, !clipped.isEmpty else { return .zero }
        let scaleX = pixelSize.width / viewSize.width
        let scaleY = pixelSize.height / viewSize.height
        let pixelRect = CGRect(
            x: clipped.minX * scaleX,
            y: clipped.minY * scaleY,
            width: clipped.width * scaleX,
            height: clipped.height * scaleY
        ).integral
        return pixelRect.intersection(CGRect(origin: .zero, size: pixelSize))
    }

    private static func fit(_ requested: CGSize, in available: CGSize) -> CGSize {
        CGSize(width: min(max(0, requested.width), available.width),
               height: min(max(0, requested.height), available.height))
    }

    private static func toolbarCandidates(selection: CGRect, available: CGRect, size: CGSize) -> [CGRect] {
        [
            // Below is the default; above is the next preference.
            CGRect(x: selection.midX - size.width / 2,
                   y: selection.maxY + gap,
                   width: size.width, height: size.height),
            CGRect(x: selection.midX - size.width / 2,
                   y: selection.minY - gap - size.height,
                   width: size.width, height: size.height),
            CGRect(x: selection.minX - gap - size.width,
                   y: selection.midY - size.height / 2,
                   width: size.width, height: size.height),
            CGRect(x: selection.maxX + gap,
                   y: selection.midY - size.height / 2,
                   width: size.width, height: size.height),
            CGRect(x: selection.minX, y: selection.minY - gap - size.height,
                   width: size.width, height: size.height),
            CGRect(x: selection.maxX - size.width, y: selection.minY - gap - size.height,
                   width: size.width, height: size.height)
        ].map { clamped($0, in: available) }
    }

    private static func exteriorCandidates(selection: CGRect, toolbar: CGRect,
                                           available: CGRect, size: CGSize) -> [CGRect] {
        let baseY = clamp(selection.midY - size.height / 2,
                          lower: available.minY, upper: available.maxY - size.height)
        let baseX = clamp(selection.midX - size.width / 2,
                          lower: available.minX, upper: available.maxX - size.width)
        let rightX = selection.maxX + gap
        let leftX = selection.minX - gap - size.width
        let bottomY = selection.maxY + gap
        let topY = selection.minY - gap - size.height
        let rows = unique([
            baseY,
            clamp(toolbar.minY - gap - size.height, lower: available.minY, upper: available.maxY - size.height),
            clamp(toolbar.maxY + gap, lower: available.minY, upper: available.maxY - size.height)
        ])
        let columns = unique([
            baseX,
            clamp(toolbar.minX - gap - size.width, lower: available.minX, upper: available.maxX - size.width),
            clamp(toolbar.maxX + gap, lower: available.minX, upper: available.maxX - size.width)
        ])

        var candidates: [CGRect] = []
        // Preferred sides: right, bottom, left, then top. Add a second frame
        // shifted farther out when the natural adjacent position hits toolbar.
        for y in rows {
            candidates.append(CGRect(x: rightX, y: y, width: size.width, height: size.height))
            candidates.append(CGRect(x: max(rightX, toolbar.maxX + gap), y: y,
                                     width: size.width, height: size.height))
            candidates.append(CGRect(x: leftX, y: y, width: size.width, height: size.height))
            candidates.append(CGRect(x: min(leftX, toolbar.minX - gap - size.width), y: y,
                                     width: size.width, height: size.height))
        }
        for x in columns {
            candidates.append(CGRect(x: x, y: bottomY, width: size.width, height: size.height))
            candidates.append(CGRect(x: x, y: max(bottomY, toolbar.maxY + gap),
                                     width: size.width, height: size.height))
            candidates.append(CGRect(x: x, y: topY, width: size.width, height: size.height))
            candidates.append(CGRect(x: x, y: min(topY, toolbar.minY - gap - size.height),
                                     width: size.width, height: size.height))
        }
        return candidates.filter {
            contains(available, $0) && !$0.intersects(selection) && !$0.intersects(toolbar)
        }
    }

    private static func bestToolbar(selection: CGRect, result: CGRect,
                                    available: CGRect, size: CGSize) -> CGRect {
        toolbarCandidates(selection: selection, available: available, size: size).min { lhs, rhs in
            let lhsResultPenalty = lhs.intersects(result) ? 1_000_000.0 : 0
            let rhsResultPenalty = rhs.intersects(result) ? 1_000_000.0 : 0
            let lhsSelectionPenalty = lhs.intersects(selection) ? 100_000.0 : 0
            let rhsSelectionPenalty = rhs.intersects(selection) ? 100_000.0 : 0
            return lhsResultPenalty + lhsSelectionPenalty + distance(lhs, to: selection) <
                rhsResultPenalty + rhsSelectionPenalty + distance(rhs, to: selection)
        } ?? clamped(CGRect(origin: available.origin, size: size), in: available)
    }

    private static func unique(_ values: [CGFloat]) -> [CGFloat] {
        values.reduce(into: []) { result, value in
            if !result.contains(value) { result.append(value) }
        }
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }

    private static func clamped(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        let width = min(max(0, rect.width), bounds.width)
        let height = min(max(0, rect.height), bounds.height)
        let maxX = bounds.maxX - width
        let maxY = bounds.maxY - height
        return CGRect(x: min(max(rect.minX, bounds.minX), maxX),
                      y: min(max(rect.minY, bounds.minY), maxY),
                      width: width, height: height)
    }

    private static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        inner.minX >= outer.minX && inner.minY >= outer.minY &&
        inner.maxX <= outer.maxX && inner.maxY <= outer.maxY
    }

    private static func distance(_ rect: CGRect, to other: CGRect) -> Double {
        let dx = Double(rect.midX - other.midX)
        let dy = Double(rect.midY - other.midY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
