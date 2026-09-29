import CaffCore
import Foundation

enum SessionHistoryFailureStatus: Equatable {
    case none
    case movedAside
    case leftInPlace
}

struct SessionHistoryLoadResult {
    let entries: [SessionHistoryEntry]
    let failureStatus: SessionHistoryFailureStatus
    let persistsUpdates: Bool
}

final class SessionHistoryStore {
    private let fileURL: URL
    private let maximumEntries: Int
    private(set) var persistsUpdates = true

    convenience init(maximumEntries: Int = 100) {
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Caff", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Caff", isDirectory: true)
        self.init(
            fileURL: supportURL.appendingPathComponent("history.json"),
            maximumEntries: maximumEntries
        )
    }

    internal init(fileURL: URL, maximumEntries: Int = 100) {
        self.fileURL = fileURL
        self.maximumEntries = maximumEntries
    }

    func load() -> SessionHistoryLoadResult {
        do {
            let data = try Data(contentsOf: fileURL)
            let entries = try JSONDecoder().decode([SessionHistoryEntry].self, from: data)
            return loaded(entries)
        } catch CocoaError.fileReadNoSuchFile {
            return loaded([])
        } catch {
            fputs("Caff failed to load history: \(error)\n", stderr)
            return quarantineUnreadableFile()
        }
    }

    func append(_ entry: SessionHistoryEntry, to entries: [SessionHistoryEntry]) -> [SessionHistoryEntry] {
        guard persistsUpdates else {
            return entries
        }
        let next = Array(([entry] + entries).prefix(maximumEntries))
        save(next)
        return next
    }

    func clear() {
        guard persistsUpdates else {
            return
        }
        save([])
    }

    private func loaded(_ entries: [SessionHistoryEntry]) -> SessionHistoryLoadResult {
        persistsUpdates = true
        return SessionHistoryLoadResult(entries: entries, failureStatus: .none, persistsUpdates: true)
    }

    private func quarantineUnreadableFile() -> SessionHistoryLoadResult {
        do {
            let destination = try moveUnreadableFileAside()
            persistsUpdates = true
            fputs("Caff moved unreadable history aside to \(destination.path)\n", stderr)
            return SessionHistoryLoadResult(entries: [], failureStatus: .movedAside, persistsUpdates: true)
        } catch {
            persistsUpdates = false
            fputs("Caff left unreadable history in place at \(fileURL.path): \(error)\n", stderr)
            return SessionHistoryLoadResult(entries: [], failureStatus: .leftInPlace, persistsUpdates: false)
        }
    }

    private func moveUnreadableFileAside() throws -> URL {
        for index in 0..<10_000 {
            let destination = quarantineURL(index: index)
            if FileManager.default.fileExists(atPath: destination.path) {
                continue
            }
            try FileManager.default.moveItem(at: fileURL, to: destination)
            return destination
        }
        throw CocoaError(.fileWriteFileExists)
    }

    private func quarantineURL(index: Int) -> URL {
        let base = fileURL.lastPathComponent
        let name = index == 0 ? "\(base).bad" : "\(base).bad-\(index)"
        return fileURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    private func save(_ entries: [SessionHistoryEntry]) {
        guard persistsUpdates else {
            return
        }
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
