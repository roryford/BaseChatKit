import Foundation
import Observation
import SwiftUI

/// Manages global default settings persisted via UserDefaults.
///
/// Per-session overrides live in `ChatSession`; when a session's override is
/// `nil`, the view model falls back to these global defaults.
@Observable
public final class SettingsService: @unchecked Sendable {

    public static let shared = SettingsService()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Generation Defaults

    public var globalTemperature: Float {
        get {
            let value = defaults.float(forKey: "globalTemperature")
            return value == 0 ? 0.7 : value
        }
        set { defaults.set(newValue, forKey: "globalTemperature") }
    }

    public var globalTopP: Float {
        get {
            let value = defaults.float(forKey: "globalTopP")
            return value == 0 ? 0.9 : value
        }
        set { defaults.set(newValue, forKey: "globalTopP") }
    }

    public var globalRepeatPenalty: Float {
        get {
            let value = defaults.float(forKey: "globalRepeatPenalty")
            return value == 0 ? 1.1 : value
        }
        set { defaults.set(newValue, forKey: "globalRepeatPenalty") }
    }

    public var globalPromptTemplate: PromptTemplate? {
        get {
            guard let raw = defaults.string(forKey: "globalPromptTemplate") else { return nil }
            return PromptTemplate(rawValue: raw)
        }
        set { defaults.set(newValue?.rawValue, forKey: "globalPromptTemplate") }
    }

    // MARK: - Appearance

    public var appearanceMode: AppearanceMode {
        get {
            guard let raw = defaults.string(forKey: "appearanceMode") else { return .system }
            return AppearanceMode(rawValue: raw) ?? .system
        }
        set { defaults.set(newValue.rawValue, forKey: "appearanceMode") }
    }

    // MARK: - Resolution Helpers

    /// Returns the effective temperature, using session override if available.
    public func effectiveTemperature(session: ChatSession?) -> Float {
        session?.temperature ?? globalTemperature
    }

    public func effectiveTopP(session: ChatSession?) -> Float {
        session?.topP ?? globalTopP
    }

    public func effectiveRepeatPenalty(session: ChatSession?) -> Float {
        session?.repeatPenalty ?? globalRepeatPenalty
    }
}

/// Controls the app's color scheme preference.
public enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    public var id: String { rawValue }

    /// Maps to SwiftUI's `ColorScheme` for use with `.preferredColorScheme()`.
    /// Returns `nil` for `.system` to follow the OS setting.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
