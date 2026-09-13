import CryptoKit
import Darwin
import Foundation
import Security

public enum RemoteCommandAuthError: Error, CustomStringConvertible, Equatable, Sendable {
    case missingToken
    case invalidToken
    case storageFailed(String)

    public var description: String {
        switch self {
        case .missingToken:
            return "Missing remote command token"
        case .invalidToken:
            return "Invalid remote command token"
        case let .storageFailed(message):
            return "Remote command token storage failed: \(message)"
        }
    }
}

/// Durable cache of accepted signed-payload nonces until their timestamps expire.
///
/// Survives process restarts by persisting under the auth directory so a captured
/// payload cannot be replayed after the app relaunches inside the validity window.
private final class AcceptedNonceStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    init(directoryURL: URL) {
        self.fileURL = directoryURL.appendingPathComponent(RemoteCommandAuth.nonceFileName, isDirectory: false)
    }

    /// Returns `true` when `nonce` is newly recorded; `false` when it was already consumed.
    func consume(_ nonce: String, expiresAt: TimeInterval, now: TimeInterval) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        var expiresAtByNonce = try loadMap()
        expiresAtByNonce = expiresAtByNonce.filter { $0.value > now }
        if expiresAtByNonce[nonce] != nil {
            try saveMap(expiresAtByNonce)
            return false
        }
        expiresAtByNonce[nonce] = expiresAt
        try saveMap(expiresAtByNonce)
        return true
    }

    private func loadMap() throws -> [String: TimeInterval] {
        do {
            let data = try Data(contentsOf: fileURL)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [:]
            }
            var result: [String: TimeInterval] = [:]
            for (key, value) in root {
                if let number = value as? NSNumber {
                    result[key] = number.doubleValue
                } else if let double = value as? Double {
                    result[key] = double
                }
            }
            return result
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return [:]
        } catch {
            throw RemoteCommandAuthError.storageFailed("nonce cache read failed: \(error.localizedDescription)")
        }
    }

    private func saveMap(_ map: [String: TimeInterval]) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload = map.mapValues { $0 as Any }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let tempURL = fileURL.deletingLastPathComponent().appendingPathComponent(
                ".\(RemoteCommandAuth.nonceFileName).\(UUID().uuidString).tmp",
                isDirectory: false
            )
            try data.write(to: tempURL, options: .atomic)
            let status = chmod(tempURL.path, 0o600)
            if status != 0 {
                try? FileManager.default.removeItem(at: tempURL)
                throw RemoteCommandAuthError.storageFailed("nonce cache chmod failed (\(errno))")
            }
            // Replace atomically when possible.
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: fileURL)
            }
        } catch let error as RemoteCommandAuthError {
            throw error
        } catch {
            throw RemoteCommandAuthError.storageFailed("nonce cache write failed: \(error.localizedDescription)")
        }
    }
}

/// Per-install shared secret for authenticating local remote-control commands.
///
/// Production installs store the secret in the login Keychain with an ACL limited
/// to this executable (code-identity gate), not as a same-UID-readable file under
/// Application Support. Explicit `directoryURL` (tests) keeps the legacy file store.
/// CLI/DNC callers never broadcast the reusable secret; they attach a short-lived
/// HMAC instead. URL callers may still pass `token=` after reading the secret via
/// `loadOrCreateToken()` / Keychain.
public struct RemoteCommandAuth: Sendable {
    public static let tokenFileName = "remote-command.token"
    public static let nonceFileName = "remote-command.nonces"
    public static let tokenByteCount = 32
    public static let signatureMaxAgeSeconds: TimeInterval = 120
    public static let keychainService = "local.caff.remote-command"
    public static let keychainAccount = "install-token"

    public enum PayloadKey {
        public static let token = "token"
        public static let mac = "mac"
        public static let nonce = "nonce"
        public static let timestamp = "ts"
    }

    private let directoryURL: URL
    private let usesKeychain: Bool
    private let nonceStore: AcceptedNonceStore
    private let now: @Sendable () -> Date

    public init(directoryURL: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        // Custom directories are for tests/isolation and keep the file-backed store.
        self.usesKeychain = directoryURL == nil
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.directoryURL = supportRoot.appendingPathComponent("Caff", isDirectory: true)
        }
        self.nonceStore = AcceptedNonceStore(directoryURL: self.directoryURL)
    }

    public var tokenFileURL: URL {
        directoryURL.appendingPathComponent(Self.tokenFileName, isDirectory: false)
    }

    public var nonceFileURL: URL {
        directoryURL.appendingPathComponent(Self.nonceFileName, isDirectory: false)
    }

    /// Loads the existing install token, creating one if missing.
    public func loadOrCreateToken() throws -> String {
        if usesKeychain {
            return try loadOrCreateKeychainToken()
        }
        return try loadOrCreateFileToken()
    }

    /// Returns true when `provided` matches the install token (creating the token if needed).
    public func isValid(_ provided: String?) -> Bool {
        (try? verify(provided)) != nil
    }

    /// Verifies `provided` against the install token.
    public func verify(_ provided: String?) throws {
        guard let provided, !provided.isEmpty else {
            throw RemoteCommandAuthError.missingToken
        }
        let expected = try loadOrCreateToken()
        guard Self.constantTimeEquals(provided, expected) else {
            throw RemoteCommandAuthError.invalidToken
        }
    }

    /// Authenticates a remote-control payload.
    ///
    /// Prefers a signed MAC (`mac`/`nonce`/`ts`) so DistributedNotificationCenter
    /// never needs the reusable bearer token. Falls back to `token=` for URL callers.
    public func authenticate(_ userInfo: [String: String]) throws {
        if let mac = userInfo[PayloadKey.mac], !mac.isEmpty {
            try verifySignedPayload(userInfo)
            return
        }
        try verify(userInfo[PayloadKey.token])
    }

    /// Signs `userInfo` with a short-lived HMAC, never embedding the reusable token.
    public func sign(_ userInfo: [String: String]) throws -> [String: String] {
        var payload = userInfo
        payload.removeValue(forKey: PayloadKey.token)
        payload.removeValue(forKey: PayloadKey.mac)
        payload[PayloadKey.nonce] = UUID().uuidString
        payload[PayloadKey.timestamp] = String(Int(now().timeIntervalSince1970))
        let secret = try loadOrCreateToken()
        payload[PayloadKey.mac] = Self.hmacHex(key: secret, message: Self.canonicalMessage(payload))
        return payload
    }

    /// Verifies a MAC-signed payload without requiring the reusable token in transit.
    public func verifySignedPayload(_ userInfo: [String: String]) throws {
        guard let mac = userInfo[PayloadKey.mac], !mac.isEmpty else {
            throw RemoteCommandAuthError.missingToken
        }
        guard
            let tsRaw = userInfo[PayloadKey.timestamp],
            let timestamp = TimeInterval(tsRaw),
            let nonce = userInfo[PayloadKey.nonce],
            !nonce.isEmpty
        else {
            throw RemoteCommandAuthError.invalidToken
        }
        let current = now().timeIntervalSince1970
        let age = abs(current - timestamp)
        guard age <= Self.signatureMaxAgeSeconds else {
            throw RemoteCommandAuthError.invalidToken
        }

        let secret = try loadOrCreateToken()
        var unsigned = userInfo
        unsigned.removeValue(forKey: PayloadKey.mac)
        unsigned.removeValue(forKey: PayloadKey.token)
        let expected = Self.hmacHex(key: secret, message: Self.canonicalMessage(unsigned))
        guard Self.constantTimeEquals(mac, expected) else {
            throw RemoteCommandAuthError.invalidToken
        }

        // Record after MAC verification so forged payloads cannot burn valid nonces.
        let expiresAt = timestamp + Self.signatureMaxAgeSeconds
        guard try nonceStore.consume(nonce, expiresAt: expiresAt, now: current) else {
            throw RemoteCommandAuthError.invalidToken
        }
    }

    // MARK: - Keychain-backed production store

    private func loadOrCreateKeychainToken() throws -> String {
        if let existing = try readKeychainToken() {
            return existing
        }
        // Migrate a legacy Application Support token into the Keychain once, then
        // delete the same-UID-readable file so peer processes cannot scrape it.
        if let legacy = try readTokenIfPresent() {
            try writeKeychainToken(legacy)
            try removeLegacyTokenFileIfPresent()
            return legacy
        }
        let token = try Self.generateToken()
        do {
            try writeKeychainToken(token)
            try removeLegacyTokenFileIfPresent()
            return token
        } catch {
            if let existing = try readKeychainToken() {
                return existing
            }
            throw error
        }
    }

    private func readKeychainToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw RemoteCommandAuthError.storageFailed("keychain read failed (\(status))")
        }
        guard
            let data = item as? Data,
            let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            throw RemoteCommandAuthError.storageFailed("keychain token is empty or not UTF-8")
        }
        return token
    }

    private func writeKeychainToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw RemoteCommandAuthError.storageFailed("token is not valid UTF-8")
        }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var trustedApp: SecTrustedApplication?
        let trustedStatus = SecTrustedApplicationCreateFromPath(nil, &trustedApp)
        guard trustedStatus == errSecSuccess, let trustedApp else {
            throw RemoteCommandAuthError.storageFailed(
                "SecTrustedApplicationCreateFromPath failed (\(trustedStatus))"
            )
        }

        var access: SecAccess?
        let accessStatus = SecAccessCreate(
            "Caff remote command token" as CFString,
            [trustedApp] as CFArray,
            &access
        )
        guard accessStatus == errSecSuccess, let access else {
            throw RemoteCommandAuthError.storageFailed("SecAccessCreate failed (\(accessStatus))")
        }

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecAttrLabel as String: "Caff remote command token",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccess as String: access,
            kSecValueData as String: data,
        ]

        // Prefer the classic ACL attribute; some hosts reject mixing it with
        // modern access-control flags, so fall back without kSecAttrAccessible.
        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecParam {
            addQuery.removeValue(forKey: kSecAttrAccessible as String)
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        if status == errSecDuplicateItem {
            // Lost a create race — caller will reread.
            return
        }
        guard status == errSecSuccess else {
            throw RemoteCommandAuthError.storageFailed("keychain write failed (\(status))")
        }
    }

    private func removeLegacyTokenFileIfPresent() throws {
        let path = tokenFileURL.path
        if FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.removeItem(at: tokenFileURL)
            } catch {
                throw RemoteCommandAuthError.storageFailed(
                    "failed to remove legacy token file: \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - File-backed store (tests / explicit directory)

    private func loadOrCreateFileToken() throws -> String {
        if let existing = try readTokenIfPresent() {
            return existing
        }
        // Recover empty/incomplete token paths left by a crashed exclusive create.
        // Removal is conditional on the empty inode still being present so a
        // concurrently published complete token is never deleted (TOCTOU).
        try removeIncompleteTokenIfPresent()
        if let existing = try readTokenIfPresent() {
            return existing
        }
        let token = try Self.generateToken()
        do {
            try persistExclusively(token)
            return token
        } catch {
            // Another process may have won the create race — reread the winner.
            if let existing = try readTokenIfPresent() {
                return existing
            }
            throw error
        }
    }

    private func readTokenIfPresent() throws -> String? {
        do {
            let data = try Data(contentsOf: tokenFileURL)
            let token = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch {
            throw RemoteCommandAuthError.storageFailed(error.localizedDescription)
        }
    }

    /// Removes a leftover empty token path from a crashed create.
    ///
    /// Only unlinks when the directory entry still names the same empty inode we
    /// opened. If another process published a complete token via `link` (new inode)
    /// between our initial miss and recovery, we leave their winner intact.
    private func removeIncompleteTokenIfPresent() throws {
        let path = tokenFileURL.path
        let fd = open(path, O_RDONLY)
        if fd < 0 {
            // Missing or unreadable — create/reread paths handle the outcome.
            return
        }
        defer { close(fd) }

        var opened = stat()
        guard fstat(fd, &opened) == 0 else {
            return
        }

        let byteCount = max(Int(opened.st_size), 0)
        var buffer = [UInt8](repeating: 0, count: max(byteCount, 1))
        let readCount = byteCount == 0 ? 0 : read(fd, &buffer, byteCount)
        let data = readCount > 0 ? Data(buffer.prefix(readCount)) : Data()
        let token = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.isEmpty else {
            // A complete token is present — never delete it.
            return
        }

        var current = stat()
        guard lstat(path, &current) == 0 else {
            return
        }
        // Path now points at a different inode ⇒ concurrent publish won.
        guard current.st_ino == opened.st_ino, current.st_dev == opened.st_dev else {
            return
        }
        _ = unlink(path)
    }

    /// Writes the token to a private temp file, syncs it, then atomically publishes via `link`.
    private func persistExclusively(_ token: String) throws {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            guard let data = token.data(using: .utf8) else {
                throw RemoteCommandAuthError.storageFailed("token is not valid UTF-8")
            }

            let finalPath = tokenFileURL.path
            let tempURL = directoryURL.appendingPathComponent(
                ".\(Self.tokenFileName).\(UUID().uuidString).tmp",
                isDirectory: false
            )
            let tempPath = tempURL.path

            let fd = open(tempPath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd < 0 {
                throw RemoteCommandAuthError.storageFailed("open(temp O_EXCL) failed (\(errno))")
            }

            let cleanupTemp = {
                close(fd)
                unlink(tempPath)
            }

            let written: Int = data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return -1 }
                return write(fd, base, buffer.count)
            }
            guard written == data.count else {
                cleanupTemp()
                throw RemoteCommandAuthError.storageFailed("short write while creating token")
            }
            if fsync(fd) != 0 {
                let code = errno
                cleanupTemp()
                throw RemoteCommandAuthError.storageFailed("fsync failed (\(code))")
            }
            close(fd)

            if link(tempPath, finalPath) != 0 {
                let code = errno
                unlink(tempPath)
                if code == EEXIST {
                    throw RemoteCommandAuthError.storageFailed("token file already exists")
                }
                throw RemoteCommandAuthError.storageFailed("link publish failed (\(code))")
            }
            unlink(tempPath)
        } catch let error as RemoteCommandAuthError {
            throw error
        } catch {
            throw RemoteCommandAuthError.storageFailed(error.localizedDescription)
        }
    }

    private static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: tokenByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw RemoteCommandAuthError.storageFailed("SecRandomCopyBytes failed (\(status))")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalMessage(_ userInfo: [String: String]) -> String {
        userInfo.keys.sorted().map { key in
            "\(key)=\(userInfo[key] ?? "")"
        }.joined(separator: "\n")
    }

    static func hmacHex(key: String, message: String) -> String {
        let symmetricKey = SymmetricKey(data: Data(key.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symmetricKey)
        return Data(digest).map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else {
            return false
        }
        var diff: UInt8 = 0
        for index in left.indices {
            diff |= left[index] ^ right[index]
        }
        return diff == 0
    }
}
