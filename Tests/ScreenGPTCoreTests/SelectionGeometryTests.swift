import CoreGraphics
import Foundation
import Testing
@testable import ScreenGPTCore

@Test func hitTestPrefersCornersThenEdgesAndMovesInside() {
    let selection = CGRect(x: 20, y: 30, width: 100, height: 80)

    #expect(SelectionGeometry.hitTest(CGPoint(x: 19, y: 31), selection: selection) == .resize(.topLeft))
    #expect(SelectionGeometry.hitTest(CGPoint(x: 70, y: 30), selection: selection) == .resize(.top))
    #expect(SelectionGeometry.hitTest(CGPoint(x: 121, y: 75), selection: selection) == .resize(.right))
    #expect(SelectionGeometry.hitTest(CGPoint(x: 60, y: 70), selection: selection) == .move)
    #expect(SelectionGeometry.hitTest(CGPoint(x: 140, y: 130), selection: selection) == nil)
}

@Test func hitTestSupportsEveryCornerAndEdgeHandle() {
    let selection = CGRect(x: 20, y: 30, width: 100, height: 80)
    let expected: [SelectionHandle] = [.topLeft, .top, .topRight, .right,
                                       .bottomRight, .bottom, .bottomLeft, .left]
    let actual = SelectionGeometry.handlePoints(for: selection).map { handle, point in
        SelectionGeometry.hitTest(point, selection: selection).map { drag -> SelectionHandle? in
            if case .resize(let selectedHandle) = drag { return selectedHandle }
            return nil
        } ?? nil
    }

    #expect(actual == expected.map(Optional.some))
}

@Test func movingPreservesSizeAndClampsWithinNegativeOriginBounds() {
    let bounds = CGRect(x: -100, y: -50, width: 300, height: 200)
    let selection = CGRect(x: -40, y: -20, width: 80, height: 60)

    let moved = SelectionGeometry.applying(.move, to: selection,
                                            translation: CGSize(width: 500, height: -500), in: bounds)
    #expect(moved == CGRect(x: 120, y: -50, width: 80, height: 60))

    let movedToOrigin = SelectionGeometry.applying(.move, to: selection,
                                                   translation: CGSize(width: -500, height: 500), in: bounds)
    #expect(movedToOrigin == CGRect(x: -100, y: 90, width: 80, height: 60))
}

@Test func resizingKeepsOppositeEdgeAndHonorsMinimumWithoutFlipping() {
    let original = CGRect(x: 20, y: 30, width: 100, height: 80)

    let shrunkFromLeft = SelectionGeometry.applying(.resize(.left), to: original,
        translation: CGSize(width: 500, height: 0), in: CGRect(x: 0, y: 0, width: 300, height: 200))
    #expect(shrunkFromLeft == CGRect(x: 108, y: 30, width: 12, height: 80))

    let shrunkFromTopLeft = SelectionGeometry.applying(.resize(.topLeft), to: original,
        translation: CGSize(width: 500, height: 500), in: CGRect(x: 0, y: 0, width: 300, height: 200))
    #expect(shrunkFromTopLeft == CGRect(x: 108, y: 98, width: 12, height: 12))
}

@Test func resizingClampsAtBoundsAndHandlesExtremeExpansion() {
    let bounds = CGRect(x: -100, y: -50, width: 300, height: 200)
    let original = CGRect(x: -40, y: -20, width: 80, height: 60)

    let expanded = SelectionGeometry.applying(.resize(.bottomRight), to: original,
        translation: CGSize(width: 500, height: 500), in: bounds)
    #expect(expanded == CGRect(x: -40, y: -20, width: 240, height: 170))

    let movedPastLowerBounds = SelectionGeometry.applying(.resize(.topLeft), to: original,
        translation: CGSize(width: -500, height: -500), in: bounds)
    #expect(movedPastLowerBounds == CGRect(x: -100, y: -50, width: 140, height: 90))
}
