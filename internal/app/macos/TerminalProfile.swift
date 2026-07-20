import Foundation

enum TerminalProfile: String, CaseIterable {
    case auto
    case terminal
    case kitty
    case iterm2
    case wezterm
    case ghostty
    case alacritty

    var bundleIdentifier: String? {
        switch self {
        case .auto:
            return nil
        case .terminal:
            return "com.apple.Terminal"
        case .kitty:
            return "net.kovidgoyal.kitty"
        case .iterm2:
            return "com.googlecode.iterm2"
        case .wezterm:
            return "com.github.wez.wezterm"
        case .ghostty:
            return "com.mitchellh.ghostty"
        case .alacritty:
            return "org.alacritty"
        }
    }

    var displayName: String {
        switch self {
        case .auto:
            return "Auto"
        case .terminal:
            return "Terminal"
        case .kitty:
            return "kitty"
        case .iterm2:
            return "iTerm2"
        case .wezterm:
            return "WezTerm"
        case .ghostty:
            return "Ghostty"
        case .alacritty:
            return "Alacritty"
        }
    }

    static func source(_ value: String?) -> TerminalProfile? {
        guard let value = normalizedText(value),
              let profile = TerminalProfile(rawValue: value),
              profile != .auto else {
            return nil
        }
        return profile
    }

    func resolved(source: TerminalProfile?) -> TerminalProfile {
        if self == .auto {
            return source ?? .terminal
        }
        return self
    }
}

struct TerminalPreferenceReader {
    let url: URL

    func load() throws -> TerminalProfile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .auto
        }
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(TerminalConfig.self, from: data)
        guard let value = normalizedText(config.terminal) else {
            return .auto
        }
        guard let profile = TerminalProfile(rawValue: value) else {
            throw TerminalPreferenceError.unsupported(value)
        }
        return profile
    }
}

private struct TerminalConfig: Decodable {
    let terminal: String?
}

private enum TerminalPreferenceError: LocalizedError {
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case let .unsupported(value):
            return "unsupported terminal preference \(value)"
        }
    }
}
