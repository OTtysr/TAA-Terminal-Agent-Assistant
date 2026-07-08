import AppKit
import XCTest

final class TerminalAgentsTests: XCTestCase {
    func testApplicationHostStarts() {
        XCTAssertNotNil(NSApp)
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.terminalagents.mac")
    }
}
