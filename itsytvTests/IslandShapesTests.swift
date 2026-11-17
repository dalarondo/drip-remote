import XCTest
import SwiftUI

final class IslandShapesTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let pill = CGRect(x: 662, y: 0, width: 187, height: 40)
    private let card = CGRect(x: 546, y: 0, width: 420, height: 262)

    private func reveal(_ progress: CGFloat, source: CGRect, radius: CGFloat = 20, includeSource: Bool = true) -> Path {
        IslandReveal(source: source, sourceRadius: radius, includeSource: includeSource, progress: progress).path(in: screen)
    }

    func testCollapsedIsExactlyTheIslandShape() {
        let box = reveal(0, source: pill).boundingRect
        XCTAssertEqual(box.minX, pill.minX, accuracy: 0.5)
        XCTAssertEqual(box.maxX, pill.maxX, accuracy: 0.5)
        XCTAssertEqual(box.maxY, pill.maxY, accuracy: 0.5)
    }

    func testCollapsedDrawsNothingWhenTheRealWidgetIsStillOnScreen() {
        XCTAssertTrue(reveal(0, source: pill, includeSource: false).isEmpty)
    }

    func testFullyRevealedCoversTheWholeScreen() {
        XCTAssertEqual(reveal(1, source: pill).boundingRect, screen)
    }

    func testEveryStageIsFiniteAndStaysConnectedToTheSourceWhileSwelling() {
        for source in [pill, card] {
            for step in 0...100 {
                let p = CGFloat(step) / 100
                let box = reveal(p, source: source).boundingRect
                XCTAssertFalse(box.isNull || box.isInfinite, "progress \(p)")
                XCTAssertFalse(box.width.isNaN || box.height.isNaN, "progress \(p)")
                // While the drop hangs (first third), the shape reaches from the source downwards.
                if p > 0, p < 0.3 {
                    XCTAssertLessThanOrEqual(box.minY, source.maxY, "progress \(p)")
                    XCTAssertGreaterThan(box.maxY, source.maxY - 1, "progress \(p)")
                }
            }
        }
    }

    func testOverlappingPiecesNeverCancelIntoAHole() {
        // The middle of the neck, just under the island, must be filled while the drop hangs.
        let path = reveal(0.2, source: pill)
        XCTAssertTrue(path.contains(CGPoint(x: pill.midX, y: pill.maxY + 6)))
        // …and so must the island itself, where the neck overlaps it.
        XCTAssertTrue(path.contains(CGPoint(x: pill.midX, y: pill.maxY - 3)))
    }

    func testABiggerDropFallsFromTheOpenCard() {
        let fromPill = reveal(0.31, source: pill).boundingRect
        let fromCard = reveal(0.31, source: card, radius: 36).boundingRect
        XCTAssertGreaterThan(fromCard.maxY - card.maxY, fromPill.maxY - pill.maxY)
    }

    // MARK: - Remote pour

    private let remote = CGRect(x: 0, y: 0, width: 588, height: 600)

    func testRemoteIsInvisibleWhenPutAway() {
        XCTAssertTrue(RemotePour(neckWidth: 187, progress: 0).path(in: remote).isEmpty)
    }

    func testRemoteFullyOutSpansItsWidthAndHangsFromANeck() {
        let path = RemotePour(neckWidth: 187, progress: 1).path(in: remote)
        let box = path.boundingRect
        XCTAssertEqual(box.minX, remote.minX, accuracy: 0.5)
        XCTAssertEqual(box.maxX, remote.maxX, accuracy: 0.5)
        XCTAssertEqual(box.maxY, remote.maxY, accuracy: 0.5)
        // The neck: filled at the top centre, empty at the top corners.
        XCTAssertTrue(path.contains(CGPoint(x: remote.midX, y: 4)))
        XCTAssertFalse(path.contains(CGPoint(x: 10, y: 4)))
    }

    func testRemoteNeckNeverExceedsTheRemoteItself() {
        let box = RemotePour(neckWidth: 2000, progress: 1).path(in: remote).boundingRect
        XCTAssertLessThanOrEqual(box.width, remote.width + 0.5)
    }
}
