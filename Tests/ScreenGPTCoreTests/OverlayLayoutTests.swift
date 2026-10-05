import CoreGraphics
import Foundation
import Testing
@testable import ScreenGPTCore

private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

@Test func responseUsesRightWhenItFits() {
    let selection = CGRect(x: 400, y: 250, width: 220, height: 150)
    let layout = OverlayLayout.arrange(selection: selection, bounds: screen)

    #expect(!layout.isInside)
    #expect(layout.result.minX >= selection.maxX + 12)
    #expect(inside(layout.result, screen.insetBy(dx: 12, dy: 12)))
    #expect(!layout.toolbar.intersects(layout.result))
}

@Test func nearTopSelectionUsesOutsideSpaceToTheRight() {
    let selection = CGRect(x: 40, y: 20, width: 200, height: 100)
    let layout = OverlayLayout.arrange(selection: selection, bounds: screen)

    #expect(!layout.isInside)
    #expect(inside(layout.result, screen.insetBy(dx: 12, dy: 12)))
    #expect(!layout.result.intersects(selection))
    #expect(!layout.toolbar.intersects(layout.result))
}

@Test func toolbarStaysNearSmallSelectionAndPanelMovesPastIt() {
    let selection = CGRect(x: 135, y: 150, width: 220, height: 45)
    let layout = OverlayLayout.arrange(selection: selection, bounds: screen)

    #expect(!layout.isInside)
    #expect(centerDistance(layout.toolbar, selection) <= 65)
    #expect(layout.result.minX >= layout.toolbar.maxX + 12 ||
            layout.result.minY >= layout.toolbar.maxY + 12 ||
            layout.result.maxX <= layout.toolbar.minX - 12 ||
            layout.result.maxY <= layout.toolbar.minY - 12)
    #expect(!layout.toolbar.intersects(layout.result))
    #expect(!layout.result.intersects(selection))
}

@Test func responseFallsBackAcrossScreenEdges() {
    let rightEdge = OverlayLayout.arrange(
        selection: CGRect(x: 1180, y: 300, width: 220, height: 350), bounds: screen)
    #expect(!rightEdge.isInside)
    #expect(rightEdge.result.maxX <= 1180 - 12)

    let bottomEdge = OverlayLayout.arrange(
        selection: CGRect(x: 0, y: 200, width: 1440, height: 100), bounds: screen)
    #expect(!bottomEdge.isInside)
    #expect(bottomEdge.result.minY >= 300 + 12)

    let leftEdge = OverlayLayout.arrange(
        selection: CGRect(x: 15, y: 300, width: 120, height: 130), bounds: screen)
    #expect(!leftEdge.isInside)
    #expect(leftEdge.result.minX >= 135 + 12)

    let topEdge = OverlayLayout.arrange(
        selection: CGRect(x: 0, y: 600, width: 1440, height: 100), bounds: screen)
    #expect(!topEdge.isInside)
    #expect(topEdge.result.maxY <= 600 - 12)

    for layout in [rightEdge, bottomEdge, leftEdge, topEdge] {
        #expect(inside(layout.result, screen.insetBy(dx: 12, dy: 12)))
        #expect(!layout.toolbar.intersects(layout.result))
    }
}

@Test func largeSelectionFallsBackInsideAndToolbarAvoidsResponse() {
    let selection = CGRect(x: 220, y: 140, width: 1000, height: 620)
    let layout = OverlayLayout.arrange(selection: selection, bounds: screen)

    #expect(layout.isInside)
    #expect(inside(layout.result, screen.insetBy(dx: 12, dy: 12)))
    #expect(selection.intersects(layout.result))
    #expect(layout.toolbar.minY >= selection.maxY)
    #expect(layout.toolbar.minY - selection.maxY <= 12.001)
    #expect(!layout.toolbar.intersects(layout.result))
}

@Test func tinyScreenFitsFramesWithoutLeavingBounds() {
    let tiny = CGRect(x: 0, y: 0, width: 80, height: 60)
    let layout = OverlayLayout.arrange(
        selection: CGRect(x: 20, y: 18, width: 25, height: 20),
        bounds: tiny,
        resultSize: CGSize(width: 360, height: 430),
        toolbarSize: CGSize(width: 420, height: 48)
    )
    let available = tiny.insetBy(dx: 12, dy: 12)
    #expect(layout.isInside)
    #expect(inside(layout.result, available))
    #expect(inside(layout.toolbar, available))
    #expect(layout.result.width <= 56)
    #expect(layout.result.height <= 36)
}

@Test func cropRectUsesRetinaScaleAndClipsToView() {
    let crop = OverlayLayout.cropRect(
        selection: CGRect(x: 10.25, y: 20.5, width: 30, height: 40),
        viewSize: CGSize(width: 200, height: 100),
        pixelSize: CGSize(width: 400, height: 200)
    )
    #expect(crop == CGRect(x: 20, y: 41, width: 61, height: 80))

    let clipped = OverlayLayout.cropRect(
        selection: CGRect(x: -5, y: 80, width: 30, height: 40),
        viewSize: CGSize(width: 200, height: 100),
        pixelSize: CGSize(width: 400, height: 200)
    )
    #expect(clipped == CGRect(x: 0, y: 160, width: 50, height: 40))
}

@Test func cropRectRoundsOutwardAndRejectsEmptyInputs() {
    let crop = OverlayLayout.cropRect(
        selection: CGRect(x: 2.2, y: 3.1, width: 4.4, height: 5.2),
        viewSize: CGSize(width: 20, height: 20),
        pixelSize: CGSize(width: 40, height: 40)
    )
    #expect(crop == CGRect(x: 4, y: 6, width: 10, height: 11))
    #expect(OverlayLayout.cropRect(
        selection: CGRect(x: 1, y: 1, width: 0, height: 2),
        viewSize: CGSize(width: 20, height: 20),
        pixelSize: CGSize(width: 40, height: 40)
    ) == .zero)
}

private func inside(_ inner: CGRect, _ outer: CGRect) -> Bool {
    inner.minX >= outer.minX && inner.minY >= outer.minY &&
        inner.maxX <= outer.maxX && inner.maxY <= outer.maxY
}

private func centerDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let dx = lhs.midX - rhs.midX
    let dy = lhs.midY - rhs.midY
    return (dx * dx + dy * dy).squareRoot()
}
