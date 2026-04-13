import SwiftUI
import BaseChatCore  // AppearanceMode is re-exported from BaseChatInference via BaseChatCore

extension AppearanceMode {
    /// Maps to SwiftUI's `ColorScheme` for use with `.preferredColorScheme()`.
    /// Returns `nil` for `.system` to follow the OS setting.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
