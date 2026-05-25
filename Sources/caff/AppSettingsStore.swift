import Foundation

enum MenuBarDisplayMode: String, CaseIterable, Codable {
    case iconOnly
    case title
    case countdown
    case source

    var label: String {
        switch self {
        case .iconOnly:
            return "Icon"
        case .title:
            return "CAFF"
        case .countdown:
            return "Countdown"
        case .source:
            return "Source"
        }
    }

    var next: MenuBarDisplayMode {
        let modes = Self.allCases
        let index = modes.firstIndex(of: self) ?? 0
        return modes[(index + 1) % modes.count]
    }
}

struct AppSettings: Codable, Equatable {
    var menuBarDisplayMode: MenuBarDisplayMode
    var openControlWindowOnLaunch: Bool

    static let standard = AppSettings(
        menuBarDisplayMode: .countdown,
        openControlWindowOnLaunch: true
    )
}

final class AppSettingsStore {
    private let key = "caff.app-settings.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .standard
        }

        return settings
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }

        defaults.set(data, forKey: key)
    }
}
