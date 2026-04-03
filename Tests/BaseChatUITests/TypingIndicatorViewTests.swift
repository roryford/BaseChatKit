import XCTest
import SwiftUI
@testable import BaseChatUI

final class TypingIndicatorViewTests: XCTestCase {

    func testTypingIndicatorViewInitializes() {
        // Verify the view can be constructed without crashing.
        let view = TypingIndicatorView()
        XCTAssertNotNil(view)
    }

    func testStreamingCursorViewInitializes() {
        let view = StreamingCursorView()
        XCTAssertNotNil(view)
    }

    func testModelLoadingIndicatorViewInitializesWithoutProgress() {
        let view = ModelLoadingIndicatorView()
        XCTAssertNil(view.progress)
    }

    func testModelLoadingIndicatorViewInitializesWithProgress() {
        let view = ModelLoadingIndicatorView(progress: 0.75)
        XCTAssertEqual(view.progress, 0.75)
    }

    func testDefaultActivityIndicatorStyleInitializes() {
        let style = DefaultActivityIndicatorStyle()
        // Verify the style can produce all three indicator views without crashing.
        _ = style.makeTypingIndicator()
        _ = style.makeStreamingCursor()
        _ = style.makeLoadingIndicator(progress: nil)
        _ = style.makeLoadingIndicator(progress: 0.5)
    }
}
