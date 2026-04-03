import SwiftUI

/// Protocol for custom activity indicator styles.
public protocol ActivityIndicatorStyle {
    associatedtype TypingBody: View
    associatedtype StreamingBody: View
    associatedtype LoadingBody: View

    @ViewBuilder func makeTypingIndicator() -> TypingBody
    @ViewBuilder func makeStreamingCursor() -> StreamingBody
    @ViewBuilder func makeLoadingIndicator(progress: Double?) -> LoadingBody
}

/// Default activity indicator style using the built-in views.
public struct DefaultActivityIndicatorStyle: ActivityIndicatorStyle {
    public init() {}

    public func makeTypingIndicator() -> some View { TypingIndicatorView() }
    public func makeStreamingCursor() -> some View { StreamingCursorView() }
    public func makeLoadingIndicator(progress: Double?) -> some View { ModelLoadingIndicatorView(progress: progress) }
}
