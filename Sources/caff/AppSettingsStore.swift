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
    var languageMode: AppLanguageMode

    static let standard = AppSettings(
        menuBarDisplayMode: .countdown,
        openControlWindowOnLaunch: true,
        languageMode: .system
    )

    init(
        menuBarDisplayMode: MenuBarDisplayMode,
        openControlWindowOnLaunch: Bool,
        languageMode: AppLanguageMode = .system
    ) {
        self.menuBarDisplayMode = menuBarDisplayMode
        self.openControlWindowOnLaunch = openControlWindowOnLaunch
        self.languageMode = languageMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        menuBarDisplayMode = try container.decode(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode)
        openControlWindowOnLaunch = try container.decode(Bool.self, forKey: .openControlWindowOnLaunch)
        languageMode = try container.decodeIfPresent(AppLanguageMode.self, forKey: .languageMode) ?? .system
    }
}

final class AppSettingsStore {
    private let key = "caff.app-settings.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else {
            return .standard
        }

        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            fputs("Caff failed to load app settings: \(error)\n", stderr)
            return .standard
        }
    }

    func save(_ settings: AppSettings) {
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: key)
        } catch {
            fputs("Caff failed to save app settings: \(error)\n", stderr)
        }
    }
}
