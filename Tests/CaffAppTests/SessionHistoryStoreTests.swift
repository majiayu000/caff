import CaffCore
import Foundation
import Testing
@testable import caff

@Test("SessionHistoryStore missing file yields an empty persistable history")
func SessionHistoryStoreMissingFileYieldsEmptyPersistableHistory() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let historyURL = directory.appendingPathComponent("history.json")
    let store = SessionHistoryStore(fileURL: historyURL)
    let loaded = store.load()

    #expect(loaded.entries.isEmpty)
    #expect(loaded.failureStatus == .none)
    #expect(loaded.persistsUpdates)
    #expect(store.persistsUpdates)
    #expect(FileManager.default.fileExists(atPath: historyURL.path) == false)

    let entry = makeHistoryEntry()
    let appended = store.append(entry, to: loaded.entries)
    #expect(appended == [entry])
    #expect(try decodedHistory(historyURL) == [entry])
    #expect(try namesContainingBad(in: directory).isEmpty)
}

@Test("SessionHistoryStore loads valid and legacy entries without quarantine and honors the cap")
func SessionHistoryStoreLoadsValidAndLegacyEntriesWithoutQuarantine() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let historyURL = directory.appendingPathComponent("history.json")
    let validID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    let payload = Data("""
    [
      \(historyObject(id: validID.uuidString, result: "timedOut", reason: "valid")),
      \(historyObject(id: legacyID.uuidString, result: "exited", reason: "legacy"))
    ]
    """.utf8)
    try payload.write(to: historyURL)

    let store = SessionHistoryStore(fileURL: historyURL, maximumEntries: 2)
    let loaded = store.load()

    #expect(loaded.persistsUpdates)
    #expect(loaded.failureStatus == .none)
    #expect(loaded.entries.map(\.id) == [validID, legacyID])
    #expect(loaded.entries.map(\.result) == [.timedOut, .stopped])
    #expect(loaded.entries.map(\.reason) == ["valid", "legacy"])
    #expect(try Data(contentsOf: historyURL) == payload)
    #expect(try namesContainingBad(in: directory).isEmpty)

    let entry = makeHistoryEntry(reason: "new")
    let appended = store.append(entry, to: loaded.entries)
    #expect(appended.map(\.id) == [entry.id, validID])
    #expect(try decodedHistory(historyURL).map(\.id) == [entry.id, validID])
    #expect(try namesContainingBad(in: directory).isEmpty)
}

@Test("SessionHistoryStore empty array loads as success and append writes only the new entry")
func SessionHistoryStoreEmptyArrayLoadsAsSuccess() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let historyURL = directory.appendingPathComponent("history.json")
    let payload = Data("[]".utf8)
    try payload.write(to: historyURL)

    let store = SessionHistoryStore(fileURL: historyURL)
    let loaded = store.load()
    #expect(loaded.entries.isEmpty)
    #expect(loaded.failureStatus == .none)
    #expect(loaded.persistsUpdates)
    #expect(store.persistsUpdates)
    #expect(try Data(contentsOf: historyURL) == payload)
    #expect(try namesContainingBad(in: directory).isEmpty)

    let entry = makeHistoryEntry()
    let appended = store.append(entry, to: loaded.entries)
    #expect(appended == [entry])
    #expect(try decodedHistory(historyURL) == [entry])
}

@Test("SessionHistoryStore quarantines truncated and unknown result bytes")
func SessionHistoryStoreQuarantinesTruncatedAndUnknownResultBytes() throws {
    try expectUnreadablePayloadQuarantined(Data("{".utf8))
    try expectUnreadablePayloadQuarantined(explodedHistoryPayload())
}

@Test("SessionHistoryStore keeps a preexisting bad file and uses the next free name")
func SessionHistoryStoreKeepsPreexistingBadFileAndUsesNextFreeName() throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let historyURL = directory.appendingPathComponent("history.json")
    let badURL = directory.appendingPathComponent("history.json.bad")
    let occupiedURL = directory.appendingPathComponent("history.json.bad-2")
    let nextURL = directory.appendingPathComponent("history.json.bad-1")
    let preexisting = Data("keep-bad".utf8)
    let occupied = Data("keep-bad-2".utf8)
    let payload = Data("{".utf8)
    try preexisting.write(to: badURL)
    try occupied.write(to: occupiedURL)
    try payload.write(to: historyURL)

    let store = SessionHistoryStore(fileURL: historyURL)
    let loaded = store.load()

    #expect(loaded.entries.isEmpty)
    #expect(loaded.failureStatus == .movedAside)
    #expect(loaded.persistsUpdates)
    #expect(store.persistsUpdates)
    #expect(FileManager.default.fileExists(atPath: historyURL.path) == false)
    #expect(try Data(contentsOf: badURL) == preexisting)
    #expect(try Data(contentsOf: occupiedURL) == occupied)
    #expect(try Data(contentsOf: nextURL) == payload)

    let entry = makeHistoryEntry()
    _ = store.append(entry, to: loaded.entries)
    #expect(try decodedHistory(historyURL) == [entry])
    #expect(try Data(contentsOf: badURL) == preexisting)
    #expect(try Data(contentsOf: occupiedURL) == occupied)
    #expect(try Data(contentsOf: nextURL) == payload)
}

@Test("SessionHistoryStore unwritable directory leaves the file and disables persistence")
func SessionHistoryStoreUnwritableDirectoryLeavesFileAndDisablesPersistence() throws {
    let directory = try makeHistoryDirectory()
    let locked = directory.appendingPathComponent("locked", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    let historyURL = locked.appendingPathComponent("history.json")
    let payload = Data("{".utf8)
    try payload.write(to: historyURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)

    let store = SessionHistoryStore(fileURL: historyURL)
    let loaded = store.load()
    #expect(loaded.entries.isEmpty)
    #expect(loaded.failureStatus == .leftInPlace)
    #expect(loaded.persistsUpdates == false)
    #expect(store.persistsUpdates == false)
    #expect(try Data(contentsOf: historyURL) == payload)
    #expect(try namesContainingBad(in: locked).isEmpty)

    let previous = [makeHistoryEntry(reason: "previous")]
    let appended = store.append(makeHistoryEntry(reason: "new"), to: previous)
    #expect(appended == previous)
    store.clear()
    #expect(try Data(contentsOf: historyURL) == payload)
    #expect(try namesContainingBad(in: locked).isEmpty)
}

@Test("SessionHistoryStore status line reports quarantine, empty success, and the latest entry")
func SessionHistoryStoreStatusLineReportsQuarantineEmptySuccessAndLatestEntry() {
    let english = AppText(language: .english)
    let chinese = AppText(language: .simplifiedChinese)
    let entry = makeHistoryEntry(result: .timedOut)
    let latest = english.label(english.history, english.localizedStatus(entry.summary))
    let latestChinese = chinese.label(chinese.history, chinese.localizedStatus(entry.summary))

    #expect(
        historyStatusLine(entries: [], failureStatus: .movedAside, persistsUpdates: true, text: english)
            == "History: Unreadable file moved aside"
    )
    #expect(
        historyStatusLine(entries: [], failureStatus: .movedAside, persistsUpdates: true, text: chinese)
            == "历史记录：无法读取的文件已移到一旁"
    )
    #expect(
        historyStatusLine(entries: [], failureStatus: .leftInPlace, persistsUpdates: false, text: english)
            == "History: Unreadable file left in place"
    )
    #expect(
        historyStatusLine(entries: [entry], failureStatus: .movedAside, persistsUpdates: false, text: english)
            == "History: Unreadable file left in place"
    )
    #expect(
        historyStatusLine(entries: [entry], failureStatus: .leftInPlace, persistsUpdates: false, text: chinese)
            == "历史记录：无法读取的文件仍留在原处"
    )
    #expect(
        historyStatusLine(entries: [], failureStatus: .none, persistsUpdates: true, text: english)
            == "History: Empty"
    )
    #expect(
        historyStatusLine(entries: [], failureStatus: .none, persistsUpdates: true, text: chinese)
            == "历史记录：空"
    )
    #expect(
        historyStatusLine(entries: [entry], failureStatus: .none, persistsUpdates: true, text: english)
            == latest
    )
    #expect(
        historyStatusLine(entries: [entry], failureStatus: .movedAside, persistsUpdates: true, text: english)
            == latest
    )
    #expect(
        historyStatusLine(entries: [entry], failureStatus: .none, persistsUpdates: true, text: chinese)
            == latestChinese
    )
}

private func expectUnreadablePayloadQuarantined(_ payload: Data) throws {
    let directory = try makeHistoryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let historyURL = directory.appendingPathComponent("history.json")
    let quarantineURL = directory.appendingPathComponent("history.json.bad")
    try payload.write(to: historyURL)

    let store = SessionHistoryStore(fileURL: historyURL)
    let loaded = store.load()
    #expect(loaded.entries.isEmpty)
    #expect(loaded.failureStatus == .movedAside)
    #expect(loaded.persistsUpdates)
    #expect(store.persistsUpdates)
    #expect(FileManager.default.fileExists(atPath: historyURL.path) == false)
    #expect(try Data(contentsOf: quarantineURL) == payload)

    let entry = makeHistoryEntry()
    let appended = store.append(entry, to: loaded.entries)
    #expect(appended == [entry])
    #expect(try decodedHistory(historyURL) == [entry])
    #expect(try Data(contentsOf: quarantineURL) == payload)
}

private func explodedHistoryPayload() -> Data {
    Data("""
    [{"id":"00000000-0000-0000-0000-000000000001","startedAt":1000,"endedAt":1120,"source":"Manual","reason":"test","durationLabel":"1 Hour","assertionKinds":["PreventUserIdleSystemSleep"],"result":"exploded"}]
    """.utf8)
}

private func historyObject(id: String, result: String, reason: String) -> String {
    """
    {"id":"\(id)","startedAt":1000,"endedAt":1120,"source":"Manual","reason":"\(reason)","durationLabel":"1 Hour","assertionKinds":["PreventUserIdleSystemSleep"],"result":"\(result)"}
    """
}

private func makeHistoryEntry(
    reason: String = "test reason",
    result: SessionHistoryResult = .stopped
) -> SessionHistoryEntry {
    SessionHistoryEntry(
        startedAt: Date(timeIntervalSince1970: 1_000),
        endedAt: Date(timeIntervalSince1970: 1_120),
        source: "Manual",
        reason: reason,
        durationLabel: "1 Hour",
        assertionKinds: ["PreventUserIdleSystemSleep"],
        result: result
    )
}

private func makeHistoryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SessionHistoryStore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func decodedHistory(_ url: URL) throws -> [SessionHistoryEntry] {
    try JSONDecoder().decode([SessionHistoryEntry].self, from: Data(contentsOf: url))
}

private func namesContainingBad(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .map(\.lastPathComponent)
        .filter { $0.contains(".bad") }
}
