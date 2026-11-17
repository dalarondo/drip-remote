import XCTest

final class CommandTopDisplayTests: XCTestCase {
    func testTappingCyclesTimeBannerNothingWhenABannerIsSet() {
        XCTAssertEqual(CommandTopDisplay.time.next(hasBanner: true), .banner)
        XCTAssertEqual(CommandTopDisplay.banner.next(hasBanner: true), .nothing)
        XCTAssertEqual(CommandTopDisplay.nothing.next(hasBanner: true), .time)
    }

    func testWithoutABannerTheTimeGoesStraightToNothing() {
        XCTAssertEqual(CommandTopDisplay.time.next(hasBanner: false), .nothing)
        XCTAssertEqual(CommandTopDisplay.nothing.next(hasBanner: false), .time)
    }
}
