import XCTest
@testable import Music

final class HelpersTests: XCTestCase {
    func testFormatTime() {
        XCTAssertEqual(formatTime(0), "0:00")
        XCTAssertEqual(formatTime(5), "0:05")
        XCTAssertEqual(formatTime(65), "1:05")
        XCTAssertEqual(formatTime(3599), "59:59")
        XCTAssertEqual(formatTime(-3), "0:00")
        XCTAssertEqual(formatTime(.nan), "0:00")
        XCTAssertEqual(formatTime(.infinity), "0:00")
    }
}
