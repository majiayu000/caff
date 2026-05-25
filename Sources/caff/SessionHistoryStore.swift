import CaffCore
import Foundation

final class SessionHistoryStore {
    private let fileURL: URL
    private let maximumEntries: Int

    init(maximumEntries: Int = 100) {
        self.maximumEntries = maximumEntries
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Caff", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Caff", isDirectory: true)
        self.fileURL = supportURL.appendingPathComponent("history.json")
    }

    func load() -> [SessionHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }

        return (try? JSONDecoder().decode([SessionHistoryEntry].self, from: data)) ?? []
    }

    func append(_ entry: SessionHistoryEntry, to entries: [SessionHistoryEntry]) -> [SessionHistoryEntry] {
        let next = Array(([entry] + entries).prefix(maximumEntries))
        save(next)
        return next
    }

    func clear() {
        save([])
    }

    private func save(_ entries: [SessionHistoryEntry]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            fputs("Caff failed to save history: \(error)\n", stderr)
        }
    }
}
