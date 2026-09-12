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

@Test func remoteCommandAuthSignsWithoutBroadcastingToken() throws {
    let directory = try temporaryAuthDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let auth = RemoteCommandAuth(directoryURL: directory)
    let signed = try auth.sign([
        "action": "stop",
        RemoteCommandAuth.PayloadKey.token: "should-be-stripped",
    ])

    #expect(signed[RemoteCommandAuth.PayloadKey.token] == nil)
    #expect(signed[RemoteCommandAuth.PayloadKey.mac]?.isEmpty == false)
    #expect(signed[RemoteCommandAuth.PayloadKey.nonce]?.isEmpty == false)
    #expect(signed[RemoteCommandAuth.PayloadKey.timestamp]?.isEmpty == false)
    try auth.authenticate(signed)
}

@Test func remoteCommandAuthRejectsTamperedOrExpiredSignature() throws {
    let directory = try temporaryAuthDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let auth = RemoteCommandAuth(directoryURL: directory, now: { fixedNow })
    var signed = try auth.sign(["action": "start"])

    signed["action"] = "stop"
    let tampered = #expect(throws: RemoteCommandAuthError.self) {
        try auth.verifySignedPayload(signed)
    }
    #expect(tampered == .invalidToken)

    let expiredAuth = RemoteCommandAuth(
        directoryURL: directory,
        now: { fixedNow.addingTimeInterval(RemoteCommandAuth.signatureMaxAgeSeconds + 1) }
    )
    let fresh = try auth.sign(["action": "start"])
    let expired = #expect(throws: RemoteCommandAuthError.self) {
        try expiredAuth.verifySignedPayload(fresh)
    }
    #expect(expired == .invalidToken)
}

@Test func remoteCommandAuthConcurrentCreateConverges() throws {
    let directory = try temporaryAuthDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let authA = RemoteCommandAuth(directoryURL: directory)
    let authB = RemoteCommandAuth(directoryURL: directory)

    var first: String?
    var second: String?
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        first = try? authA.loadOrCreateToken()
        group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
        second = try? authB.loadOrCreateToken()
        group.leave()
    }
    #expect(group.wait(timeout: .now() + 5) == .success)
    #expect(first != nil)
    #expect(first == second)
}

@Test func remoteCommandAuthRejectsReplayedNonce() throws {
    let directory = try temporaryAuthDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let fixedNow = Date(timeIntervalSince1970: 1_700_000_100)
    let auth = RemoteCommandAuth(directoryURL: directory, now: { fixedNow })
    let signed = try auth.sign(["action": "stop"])

    try auth.verifySignedPayload(signed)
    let replayed = #expect(throws: RemoteCommandAuthError.self) {
        try auth.verifySignedPayload(signed)
    }
    #expect(replayed == .invalidToken)
}

@Test func remoteCommandAuthRecoversEmptyTokenFile() throws {
    let directory = try temporaryAuthDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let auth = RemoteCommandAuth(directoryURL: directory)
    try Data().write(to: auth.tokenFileURL)

    let token = try auth.loadOrCreateToken()
    #expect(token.count == RemoteCommandAuth.tokenByteCount * 2)
    #expect(try String(contentsOf: auth.tokenFileURL, encoding: .utf8) == token)
}

@Test func remoteCommandAuthDoesNotDeletePublishedTokenDuringEmptyRecovery() throws {
    let directory = try temporaryAuthDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let auth = RemoteCommandAuth(directoryURL: directory)
    // Leave an empty placeholder, then atomically replace it with a published token
    // the way a concurrent winner would (unlink empty + link/write complete).
    try Data().write(to: auth.tokenFileURL)
    let published = String(repeating: "a", count: RemoteCommandAuth.tokenByteCount * 2)
    try FileManager.default.removeItem(at: auth.tokenFileURL)
    try published.data(using: .utf8)!.write(to: auth.tokenFileURL, options: .atomic)

    let loaded = try auth.loadOrCreateToken()
    #expect(loaded == published)
    #expect(try String(contentsOf: auth.tokenFileURL, encoding: .utf8) == published)
}
