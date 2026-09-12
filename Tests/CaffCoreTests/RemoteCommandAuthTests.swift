import CaffCore
import Foundation
import Testing

private func temporaryAuthDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("caff-remote-auth-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func remoteCommandAuthCreatesTokenOnFirstLoad() throws {
    let directory = try temporaryAuthDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let auth = RemoteCommandAuth(directoryURL: directory)
    let token = try auth.loadOrCreateToken()

    #expect(token.count == RemoteCommandAuth.tokenByteCount * 2)
    #expect(FileManager.default.fileExists(atPath: auth.tokenFileURL.path))
}

@Test func remoteCommandAuthReusesExistingToken() throws {
    let directory = try temporaryAuthDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let auth = RemoteCommandAuth(directoryURL: directory)
    let first = try auth.loadOrCreateToken()
    let second = try auth.loadOrCreateToken()

    #expect(first == second)
}

@Test func remoteCommandAuthRejectsMissingToken() throws {
    let directory = try temporaryAuthDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let auth = RemoteCommandAuth(directoryURL: directory)
    _ = try auth.loadOrCreateToken()

    let error = #expect(throws: RemoteCommandAuthError.self) {
        try auth.verify(nil)
    }
    #expect(error == .missingToken)

    let emptyError = #expect(throws: RemoteCommandAuthError.self) {
        try auth.verify("")
    }
    #expect(emptyError == .missingToken)
}

@Test func remoteCommandAuthRejectsWrongToken() throws {
    let directory = try temporaryAuthDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let auth = RemoteCommandAuth(directoryURL: directory)
    _ = try auth.loadOrCreateToken()

    let error = #expect(throws: RemoteCommandAuthError.self) {
        try auth.verify("definitely-not-the-install-token")
    }
    #expect(error == .invalidToken)
    #expect(!auth.isValid("definitely-not-the-install-token"))
}

@Test func remoteCommandAuthAcceptsMatchingToken() throws {
    let directory = try temporaryAuthDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let auth = RemoteCommandAuth(directoryURL: directory)
    let token = try auth.loadOrCreateToken()

    try auth.verify(token)
    #expect(auth.isValid(token))
}

@Test func remoteCommandAuthWritesRestrictedPermissions() throws {
    let directory = try temporaryAuthDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let auth = RemoteCommandAuth(directoryURL: directory)
    _ = try auth.loadOrCreateToken()

    let attributes = try FileManager.default.attributesOfItem(atPath: auth.tokenFileURL.path)
    let permissions = attributes[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
}
