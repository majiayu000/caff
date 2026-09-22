import CaffCore
import Foundation
import Testing

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("caff-remote-token-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func posixMode(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    if let mode = attributes[.posixPermissions] as? Int {
        return mode & 0o777
    }
    if let mode = attributes[.posixPermissions] as? NSNumber {
        return mode.intValue & 0o777
    }
    Issue.record("missing posix permissions for \(url.path)")
    return -1
}

@Test func remoteCommandTokenDefaultDirectoryEndsInCaffApplicationSupport() {
    let directory = RemoteCommandAuthenticator.defaultDirectory()
    #expect(directory.lastPathComponent == "Caff")
    #expect(directory.deletingLastPathComponent().lastPathComponent == "Application Support")
}

@Test func remoteCommandTokenLoadOrCreateWritesStableOwnerOnlyFile() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let created = try RemoteCommandAuthenticator.loadOrCreate(in: directory)
    let loaded = try RemoteCommandAuthenticator.loadOrCreate(in: directory)
    let file = directory.appendingPathComponent(RemoteCommandAuthenticator.fileName)

    #expect(created == loaded)
    #expect(created.count == 64)
    #expect(created.allSatisfy { character in
        character.isNumber || ("a"..."f").contains(String(character))
    })
    #expect(try String(contentsOf: file, encoding: .utf8) == created)
    #expect(try posixMode(at: directory) == 0o700)
    #expect(try posixMode(at: file) == 0o600)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(names == [RemoteCommandAuthenticator.fileName])
}

@Test func remoteCommandTokenReusesTrimmedFileAndTightensPermissions() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let token = String(repeating: "ab", count: 32)
    let file = directory.appendingPathComponent(RemoteCommandAuthenticator.fileName)
    try Data("\(token)\n".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

    let loaded = try RemoteCommandAuthenticator.loadOrCreate(in: directory)

    #expect(loaded == token)
    #expect(try posixMode(at: file) == 0o600)
}

@Test func remoteCommandTokenLeavesInvalidFileUntouched() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent(RemoteCommandAuthenticator.fileName)
    try Data("nope".utf8).write(to: file)

    let error = #expect(throws: RemoteCommandTokenError.self) {
        _ = try RemoteCommandAuthenticator.loadOrCreate(in: directory)
    }
    #expect(error == .invalidStoredToken)
    #expect(String(describing: error).contains("nope") == false)
    #expect(try String(contentsOf: file, encoding: .utf8) == "nope")
}

@Test func remoteCommandTokenAcceptsOnlyExactMatch() {
    let expected = String(repeating: "cd", count: 32)
    #expect(RemoteCommandAuthenticator.accepts(presented: expected, expected: expected))
    #expect(RemoteCommandAuthenticator.accepts(presented: nil, expected: expected) == false)
    #expect(RemoteCommandAuthenticator.accepts(presented: "", expected: expected) == false)
    #expect(RemoteCommandAuthenticator.accepts(presented: String(expected.dropLast()), expected: expected) == false)
    var mismatch = expected
    mismatch.replaceSubrange(mismatch.startIndex...mismatch.startIndex, with: "e")
    #expect(RemoteCommandAuthenticator.accepts(presented: mismatch, expected: expected) == false)
}
