import Foundation
import CaffCore

enum AppLanguage: String {
    case english = "en"
    case simplifiedChinese = "zh"

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        if let override = environment["CAFF_LANGUAGE"]?.lowercased() {
            if override.hasPrefix("zh") {
                return .simplifiedChinese
            }
            if override.hasPrefix("en") {
                return .english
            }
        }

        let firstLanguage = preferredLanguages.first?.lowercased() ?? ""
        return firstLanguage.hasPrefix("zh") ? .simplifiedChinese : .english
    }
}

enum AppLanguageMode: String, CaseIterable, Codable {
    case system
    case english
    case simplifiedChinese

    func resolvedLanguage(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        switch self {
        case .system:
            return .current(environment: environment, preferredLanguages: preferredLanguages)
        case .english:
            return .english
        case .simplifiedChinese:
            return .simplifiedChinese
        }
    }
}

struct AppText {
    let language: AppLanguage

    static let current = AppText(language: .current())

    var off: String { choose(en: "Off", zh: "关闭") }
    var on: String { choose(en: "On", zh: "开启") }
    var error: String { choose(en: "Error", zh: "错误") }
    var none: String { choose(en: "None", zh: "无") }
    var unknownError: String { choose(en: "Unknown error", zh: "未知错误") }
    var start: String { choose(en: "Start", zh: "开始") }
    var stop: String { choose(en: "Stop", zh: "停止") }
    var disabled: String { choose(en: "Disabled", zh: "已禁用") }
    var watching: String { choose(en: "Watching", zh: "监控中") }
    var active: String { choose(en: "Active", zh: "活动中") }
    var waiting: String { choose(en: "Waiting", zh: "等待中") }
    var currentSession: String { choose(en: "Current Session", zh: "当前会话") }
    var currentSessionSubtitle: String { choose(en: "Current session details reported by Caff", zh: "Caff 报告的当前会话详情") }
    var wakeLock: String { choose(en: "Wake Lock", zh: "防休眠") }
    var wakeLockSubtitle: String { choose(en: "Keep your Mac awake while agents are working", zh: "Agent 工作时保持 Mac 醒着") }
    var automation: String { choose(en: "Automation", zh: "自动化") }
    var automationSubtitle: String { choose(en: "Agent hook events keep Caff in sync with active CLI work", zh: "Agent hook 事件让 Caff 与活跃的 CLI 工作保持同步") }
    var history: String { choose(en: "History", zh: "历史记录") }
    var historySubtitle: String { choose(en: "Recent wake-lock sessions and trigger events", zh: "最近的防休眠会话和触发事件") }
    var lidLimit: String { choose(en: "Lid close depends on macOS, power, and display setup.", zh: "合盖行为取决于 macOS、电源和显示器设置。") }
    var lidLimitMenu: String { choose(en: "Lid close depends on macOS power/display policy", zh: "合盖行为取决于 macOS 电源/显示器策略") }
    var keepDisplayAwake: String { choose(en: "Keep display awake", zh: "保持屏幕常亮") }
    var keepDisplayAwakeSubtitle: String { choose(en: "Prevents the screen from dimming or turning off", zh: "防止屏幕变暗或关闭") }
    var allowBatteryLongSessions: String { choose(en: "Allow long sessions on battery", zh: "允许电池供电时长时间运行") }
    var allowBatteryLongSessionsSubtitle: String { choose(en: "Skip the safety timeout when running on battery power", zh: "使用电池供电时跳过安全时长限制") }
    var manualControl: String { choose(en: "Manual control", zh: "手动控制") }
    var manualControlSubtitle: String { choose(en: "Pick a duration or stop the current wake lock", zh: "选择持续时间，或停止当前防休眠") }
    var enableNotifications: String { choose(en: "Enable notifications", zh: "启用通知") }
    var enableNotificationsSubtitle: String { choose(en: "Notify when Caff starts or stops", zh: "Caff 开始或停止时发送通知") }
    var agentActivityHook: String { choose(en: "Agent Activity Hook", zh: "Agent 活动 Hook") }
    var agentActivityHookSubtitle: String { choose(en: "Refreshes Caff when Codex or Claude hook events arrive", zh: "Codex 或 Claude hook 事件到达时刷新 Caff") }
    var installHooks: String { choose(en: "Install Hooks", zh: "安装 Hooks") }
    var removeHooks: String { choose(en: "Remove Hooks", zh: "删除 Hooks") }
    var clearHistory: String { choose(en: "Clear History", zh: "清空历史") }
    var readyStandby: String { choose(en: "READY - STANDBY", zh: "就绪 - 待命") }
    var caffeinatedAwake: String { choose(en: "CAFFEINATED - AWAKE", zh: "防休眠中 - 醒着") }
    var needsAttention: String { choose(en: "NEEDS ATTENTION", zh: "需要处理") }
    var readyTitle: String { choose(en: "Ready to keep awake", zh: "已准备好防休眠") }
    var readyMeta: String { choose(en: "No active power assertion - choose a duration or use agent hooks", zh: "当前没有电源断言 - 请选择时长或使用 Agent hooks") }
    var noActiveAssertion: String { choose(en: "No active power assertion", zh: "当前没有电源断言") }
    var displayWillStayOn: String { choose(en: "Display will stay on", zh: "屏幕将保持常亮") }
    var macWillStayAwake: String { choose(en: "Mac will stay awake", zh: "Mac 将保持醒着") }
    var wakeLockNeedsAttention: String { choose(en: "Wake lock needs attention", zh: "防休眠需要处理") }
    var defaultReason: String { choose(en: "Caff is keeping this Mac awake", zh: "Caff 正在保持这台 Mac 醒着") }
    var caffStarted: String { choose(en: "Caff started", zh: "Caff 已开始") }
    var caffStopped: String { choose(en: "Caff stopped", zh: "Caff 已停止") }
    var caffStoppedByPolicy: String { choose(en: "Caff stopped by policy", zh: "Caff 已按策略停止") }
    var caffError: String { choose(en: "Caff error", zh: "Caff 错误") }
    var updateSessionFailed: String { choose(en: "Caff could not update the wake session", zh: "Caff 无法更新防休眠会话") }
    var hooksNotInstalled: String { choose(en: "Hooks: Not installed by Caff", zh: "Hooks：尚未由 Caff 安装") }
    var hooksAlreadyCurrent: String { choose(en: "Hooks: Already current", zh: "Hooks：已是最新") }
    var hooksInstallFailed: String { choose(en: "Hooks: Install failed", zh: "Hooks：安装失败") }
    var hooksRemoveFailed: String { choose(en: "Hooks: Remove failed", zh: "Hooks：删除失败") }
    var hooksInstalledTitle: String { choose(en: "Agent hooks installed", zh: "Agent hooks 已安装") }
    var hooksRemovedTitle: String { choose(en: "Agent hooks removed", zh: "Agent hooks 已删除") }
    var settings: String { choose(en: "Settings", zh: "设置") }
    var settingsSubtitle: String { choose(en: "Interface preferences", zh: "界面偏好") }
    var languageLabel: String { choose(en: "Language", zh: "语言") }
    var languageSubtitle: String { choose(en: "Controls Caff text without changing macOS language", zh: "切换 Caff 文本，不影响 macOS 系统语言") }

    func choose(en: String, zh: String) -> String {
        language == .simplifiedChinese ? zh : en
    }

    func label(_ key: String, _ value: String) -> String {
        language == .simplifiedChinese ? "\(key)：\(value)" : "\(key): \(value)"
    }

    func sourceLabel(_ source: SessionSource) -> String {
        switch (language, source) {
        case (.english, _):
            return source.label
        case (.simplifiedChinese, .manual):
            return "手动"
        case (.simplifiedChinese, .agent):
            return "Agent"
        case (.simplifiedChinese, .cli):
            return "CLI"
        case (.simplifiedChinese, .url):
            return "URL"
        }
    }

    func durationLabel(_ duration: SessionDuration) -> String {
        guard language == .simplifiedChinese else {
            return duration.label
        }
        guard let minutes = duration.minutes else {
            return "无限期"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60) 小时"
        }
        return "\(minutes) 分钟"
    }

    func menuBarModeLabel(_ mode: MenuBarDisplayMode) -> String {
        guard language == .simplifiedChinese else {
            return mode.label
        }
        switch mode {
        case .iconOnly:
            return "图标"
        case .title:
            return "CAFF"
        case .countdown:
            return "倒计时"
        case .source:
            return "来源"
        }
    }

    func languageModeLabel(_ mode: AppLanguageMode) -> String {
        switch (language, mode) {
        case (.english, .system):
            return "System"
        case (.english, .english):
            return "English"
        case (.english, .simplifiedChinese):
            return "Simplified Chinese"
        case (.simplifiedChinese, .system):
            return "跟随系统"
        case (.simplifiedChinese, .english):
            return "English"
        case (.simplifiedChinese, .simplifiedChinese):
            return "简体中文"
        }
    }

    func assertionSummary(_ summary: String) -> String {
        guard language == .simplifiedChinese else {
            return summary
        }
        return summary == "None" ? none : summary
    }

    func safetySummary(_ policy: SafetyPolicy) -> String {
        guard language == .simplifiedChinese else {
            return policy.summary
        }
        let battery = policy.allowLongSessionsOnBattery ? "允许长时间电池运行" : "禁止长时间电池运行"
        return "最长 \(SafetyPolicy.formatMinutes(policy.maximumSessionMinutes))，\(battery)"
    }

    func localizedSafetyNotes(_ notes: [String]) -> String {
        guard language == .simplifiedChinese else {
            return notes.joined(separator: ", ")
        }
        return notes.map(localizedStatus).joined(separator: "，")
    }

    func localizedStatus(_ value: String) -> String {
        guard language == .simplifiedChinese else {
            return value
        }

        let replacements = [
            ("Agent activity idle", "Agent 活动空闲"),
            ("Agent activity", "Agent 活动"),
            ("sleep allowed in", "允许休眠倒计时"),
            ("Last touch", "最近触发"),
            ("History: Empty", "历史记录：空"),
            ("History", "历史记录"),
            ("Safety", "安全策略"),
            ("Running", "运行中"),
            ("Last error", "最近错误"),
            ("Source", "来源"),
            ("Assertions", "断言"),
            ("Reason", "原因"),
            ("Started", "开始"),
            ("Error", "错误"),
            ("None", "无"),
            ("Max", "最长"),
            ("Grace", "宽限"),
            ("Power", "电源"),
            ("Indefinite is capped", "无限期会被限制"),
            ("Duration is capped", "时长会被限制"),
            ("Long battery allowed", "允许长时间电池运行"),
            ("Long battery blocked", "禁止长时间电池运行")
        ]

        var result = value
        for (source, replacement) in replacements {
            result = result.replacingOccurrences(of: source, with: replacement)
        }
        return result.replacingOccurrences(of: ": ", with: "：")
    }

    func localizedReason(_ value: String) -> String {
        if value == "Caff is keeping this Mac awake" {
            return defaultReason
        }
        return localizedStatus(value)
    }

    func triggeredMeta(for session: WakeSession) -> String {
        if language == .simplifiedChinese {
            return "\(session.compactStatus()) - 由\(sourceLabel(session.source))触发 - \(assertionSummary(session.assertionSummary))"
        }
        return "\(session.compactStatus()) - triggered by \(session.sourceLabel.lowercased()) - \(session.assertionSummary)"
    }

    func hooksUpdated(_ targets: [String]) -> String {
        if targets.isEmpty {
            return hooksAlreadyCurrent
        }
        return choose(en: "Hooks: Updated \(targets.joined(separator: ", "))", zh: "Hooks：已更新 \(targets.joined(separator: ", "))")
    }

    func hookChangeSummary(_ change: AgentHookChange) -> String {
        guard language == .simplifiedChinese else {
            return change.summary
        }
        let action = change.changed ? "已更新" : "已是最新"
        return "\(change.target.label) hooks \(action)：\(change.configPath)"
    }
}
