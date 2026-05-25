import CaffCore
import Foundation

struct CaffStatusSnapshot: Codable, Equatable {
    let appPID: Int32
    let isRunning: Bool
    let source: String
    let assertions: String
    let reason: String
    let startedAt: Date?
    let endDate: Date?
    let keepDisplayAwake: Bool
    let errorMessage: String?
    let updatedAt: Date

    static func snapshot(session: WakeSession?, errorMessage: String?) -> CaffStatusSnapshot {
        CaffStatusSnapshot(
            appPID: getpid(),
            isRunning: session != nil,
            source: session?.sourceLabel ?? "None",
            assertions: session?.assertionSummary ?? "None",
            reason: session?.reason ?? "None",
            startedAt: session?.startedAt,
            endDate: session?.endDate,
            keepDisplayAwake: session?.keepDisplayAwake ?? false,
            errorMessage: errorMessage,
            updatedAt: Date()
        )
    }

    var cliDescription: String {
        [
            "running: \(isRunning)",
            "source: \(source)",
            "assertions: \(assertions)",
            "reason: \(reason)",
            "startedAt: \(startedAt.map(Self.formatISODate) ?? "none")",
            "endDate: \(endDate.map(Self.formatISODate) ?? "none")",
            "displayAwake: \(keepDisplayAwake)",
            "error: \(errorMessage ?? "none")"
        ].joined(separator: "\n")
    }

    private static func formatISODate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

final class CaffStatusStore {
    private let fileURL: URL

    init() {
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Caff", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Caff", isDirectory: true)
        self.fileURL = supportURL.appendingPathComponent("status.json")
    }

    func read() -> CaffStatusSnapshot? {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(CaffStatusSnapshot.self, from: data)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            fputs("Caff failed to read status: \(error)\n", stderr)
            return nil
        }
    }

    func write(_ snapshot: CaffStatusSnapshot) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            fputs("Caff failed to save status: \(error)\n", stderr)
        }
    }
}
