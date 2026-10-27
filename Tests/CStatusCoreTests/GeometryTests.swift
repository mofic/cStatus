import XCTest
import CoreGraphics
@testable import CStatusCore

final class GeometryTests: XCTestCase {
    func testPanelAnchorsToVisibleFrameWithNegativeScreenOrigin() {
        let screen = CGRect(x: -1920, y: 30, width: 1920, height: 1050)
        XCTAssertEqual(PanelGeometry.frame(screen: screen, side: .right, expanded: true, height: 600, y: 200), CGRect(x: -340, y: 200, width: 340, height: 600))
        XCTAssertEqual(PanelGeometry.frame(screen: screen, side: .left, expanded: false, height: 160, y: 300), CGRect(x: -1920, y: 300, width: 12, height: 160))
    }
    func testPanelIsClampedAfterScreenRemoval() {
        let frame = PanelGeometry.frame(screen: CGRect(x: 0, y: 0, width: 1000, height: 700), side: .right, expanded: true, height: 900, y: 1500)
        XCTAssertEqual(frame, CGRect(x: 660, y: 0, width: 340, height: 700))
    }
}
