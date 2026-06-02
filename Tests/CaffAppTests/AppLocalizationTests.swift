import Testing
@testable import caff

@Test func agentActivitySummaryIsLocalizedFromCanonicalEnglish() {
    let english = AppText(language: .english)
    let chinese = AppText(language: .simplifiedChinese)
    let summary = "Agent activity idle"

    #expect(english.localizedStatus(summary) == "Agent activity idle")
    #expect(chinese.localizedStatus(summary) == "Agent 活动空闲")
    #expect(english.localizedReason("Caff is keeping this Mac awake") == "Caff is keeping this Mac awake")
    #expect(chinese.localizedReason("Caff is keeping this Mac awake") == "Caff 正在保持这台 Mac 醒着")
}

@Test func hookManagementStatusRendersInSelectedLanguage() {
    let english = AppText(language: .english)
    let chinese = AppText(language: .simplifiedChinese)
    let status = HookManagementDisplayStatus.notInstalled

    #expect(status.localizedText(english) == "Hooks: Not installed by Caff")
    #expect(status.localizedText(chinese) == "Hooks：尚未由 Caff 安装")
}
