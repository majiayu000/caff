import CaffCore
import Foundation
import Testing

@Test func agentHookManagerInstallsAndRemovesHooksWithoutDroppingExistingConfig() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("caff-hook-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let codexURL = home.appendingPathComponent(".codex/hooks.json")
    try FileManager.default.createDirectory(at: codexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("""
    {
      "hooks": {
        "Stop": [
          {
            "hooks": [
              {
                "command": "echo keep-me",
                "timeout": 3,
                "type": "command"
              }
            ]
          }
        ]
      },
      "other": true
    }
    """.utf8).write(to: codexURL)

    let manager = AgentHookManager(
        homeDirectory: home,
        executablePath: "/Applications/Caff.app/Contents/MacOS/Caff",
        cooldownSeconds: 60
    )

    let installChanges = try manager.install(targets: [.codex, .claude])
    #expect(installChanges.allSatisfy { $0.changed })

    let codexConfig = try readJSON(codexURL)
    let codexHooks = try #require(codexConfig["hooks"] as? [String: Any])
    #expect(codexHooks["UserPromptSubmit"] != nil)
    #expect(codexHooks["SessionStart"] != nil)
    #expect(codexHooks["Stop"] != nil)
    #expect(codexConfig["other"] as? Bool == true)
    #expect(commands(in: codexHooks["Stop"]).contains("echo keep-me"))
    #expect(commands(in: codexHooks["Stop"]).contains {
        $0.contains("agent-touch --source codex --cooldown-seconds 60")
    })

    let secondInstall = try manager.install(targets: [.codex])
    #expect(secondInstall.first?.changed == false)

    let removeChanges = try manager.remove(targets: [.codex])
    #expect(removeChanges.first?.changed == true)
    let removedCodexConfig = try readJSON(codexURL)
    let removedCodexHooks = try #require(removedCodexConfig["hooks"] as? [String: Any])
    #expect(commands(in: removedCodexHooks["Stop"]).contains("echo keep-me"))
    #expect(!commands(in: removedCodexHooks["Stop"]).contains { $0.contains("agent-touch") })

    let claudeURL = home.appendingPathComponent(".claude/settings.json")
    let claudeConfig = try readJSON(claudeURL)
    let claudeHooks = try #require(claudeConfig["hooks"] as? [String: Any])
    #expect(claudeHooks["SessionStart"] == nil)
    let claudePromptEntries = try #require(claudeHooks["UserPromptSubmit"] as? [[String: Any]])
    #expect(claudePromptEntries.first?["matcher"] as? String == "*")
}

private func readJSON(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func commands(in eventValue: Any?) -> [String] {
    guard let entries = eventValue as? [[String: Any]] else {
        return []
    }
    return entries.flatMap { entry -> [String] in
        guard let hooks = entry["hooks"] as? [[String: Any]] else {
            return []
        }
        return hooks.compactMap { $0["command"] as? String }
    }
}
