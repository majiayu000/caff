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
/// Production persists the map in the login Keychain (same ACL as the install
/// secret) so same-UID peers cannot truncate/delete Application Support state and
/// replay a captured payload. Test/isolation directories keep a file store whose
/// contents are HMAC-bound to the install token so rewrite/truncation fails closed.
private final class AcceptedNonceStore: @unchecked Sendable {
    private enum Backend {
        case file(URL)
        case keychain
    }

    /// Shared across store instances in-process; paired with a flock for cross-process races.
    private static let processLock = NSLock()

    private let backend: Backend
    private let lockFileURL: URL

    init(directoryURL: URL, usesKeychain: Bool) {
        if usesKeychain {
            self.backend = .keychain
        } else {
            self.backend = .file(
                directoryURL.appendingPathComponent(RemoteCommandAuth.nonceFileName, isDirectory: false)
            )
        }
        self.lockFileURL = directoryURL.appendingPathComponent(
            RemoteCommandAuth.nonceLockFileName,
            isDirectory: false
        )
    }

    /// Returns `true` when `nonce` is newly recorded; `false` when it was already consumed.
    func consume(_ nonce: String, expiresAt: TimeInterval, now: TimeInterval, integrityKey: String) throws -> Bool {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        return try withCrossProcessLock {
            var expiresAtByNonce = try loadMap(integrityKey: integrityKey)
            expiresAtByNonce = expiresAtByNonce.filter { $0.value > now }
            if expiresAtByNonce[nonce] != nil {
                try saveMap(expiresAtByNonce, integrityKey: integrityKey)
                return false
            }
            expiresAtByNonce[nonce] = expiresAt
            try saveMap(expiresAtByNonce, integrityKey: integrityKey)
            return true
        }
    }

    private func withCrossProcessLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: lockFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(lockFileURL.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw RemoteCommandAuthError.storageFailed("nonce lock open failed (\(errno))")
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw RemoteCommandAuthError.storageFailed("nonce lock flock failed (\(errno))")
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    private func loadMap(integrityKey: String) throws -> [String: TimeInterval] {
        switch backend {
        case let .file(fileURL):
            return try loadFileMap(fileURL: fileURL, integrityKey: integrityKey)
        case .keychain:
            return try loadKeychainMap()
        }
    }

    private func saveMap(_ map: [String: TimeInterval], integrityKey: String) throws {
        switch backend {
        case let .file(fileURL):
            try saveFileMap(map, fileURL: fileURL, integrityKey: integrityKey)
        case .keychain:
            try saveKeychainMap(map)
        }
    }

    private func loadFileMap(fileURL: URL, integrityKey: String) throws -> [String: TimeInterval] {
        do {
            let data = try Data(contentsOf: fileURL)
            guard
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let mac = root["mac"] as? String,
                !mac.isEmpty
            else {
                throw RemoteCommandAuthError.storageFailed("nonce cache missing integrity mac")
            }
            let noncesObject = root["nonces"] as? [String: Any] ?? [:]
            let map = Self.decodeNonceMap(noncesObject)
            let expected = RemoteCommandAuth.hmacHex(
                key: integrityKey,
                message: Self.canonicalNonceMessage(map)
            )
            guard RemoteCommandAuth.constantTimeEquals(mac, expected) else {
                throw RemoteCommandAuthError.storageFailed("nonce cache integrity check failed")
            }
            return map
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return [:]
        } catch let error as RemoteCommandAuthError {
            throw error
        } catch {
            throw RemoteCommandAuthError.storageFailed("nonce cache read failed: \(error.localizedDescription)")
        }
    }

    private func saveFileMap(
        _ map: [String: TimeInterval],
        fileURL: URL,
        integrityKey: String
    ) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let mac = RemoteCommandAuth.hmacHex(
                key: integrityKey,
                message: Self.canonicalNonceMessage(map)
            )
            let payload: [String: Any] = [
                "nonces": map.mapValues { $0 as Any },
                "mac": mac,
            ]
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

    private func loadKeychainMap() throws -> [String: TimeInterval] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: RemoteCommandAuth.keychainService,
            kSecAttrAccount as String: RemoteCommandAuth.keychainNonceAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return [:]
        }
        guard status == errSecSuccess else {
            throw RemoteCommandAuthError.storageFailed("nonce keychain read failed (\(status))")
        }
        guard let data = item as? Data else {
            throw RemoteCommandAuthError.storageFailed("nonce keychain item is not data")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteCommandAuthError.storageFailed("nonce keychain JSON is invalid")
        }
        return Self.decodeNonceMap(root)
    }

    private func saveKeychainMap(_ map: [String: TimeInterval]) throws {
        let payload = map.mapValues { $0 as Any }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        } catch {
            throw RemoteCommandAuthError.storageFailed(
                "nonce keychain encode failed: \(error.localizedDescription)"
            )
        }

        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: RemoteCommandAuth.keychainService,
            kSecAttrAccount as String: RemoteCommandAuth.keychainNonceAccount,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw RemoteCommandAuthError.storageFailed("nonce keychain update failed (\(updateStatus))")
        }

        // First write — add with the same executable-scoped ACL as the install token.
        // Never delete-then-add: concurrent creators must not wipe each other's item.
        let access = try RemoteCommandAuth.makeExecutableScopedAccess(
            descriptor: "Caff remote command nonce cache"
        )
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: RemoteCommandAuth.keychainService,
            kSecAttrAccount as String: RemoteCommandAuth.keychainNonceAccount,
            kSecAttrLabel as String: "Caff remote command nonce cache",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccess as String: access,
            kSecValueData as String: data,
        ]
        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecParam {
            addQuery.removeValue(forKey: kSecAttrAccessible as String)
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        if status == errSecDuplicateItem {
            let retry = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
            guard retry == errSecSuccess else {
                throw RemoteCommandAuthError.storageFailed(
                    "nonce keychain duplicate-update failed (\(retry))"
                )
            }
            return
        }
        guard status == errSecSuccess else {
            throw RemoteCommandAuthError.storageFailed("nonce keychain write failed (\(status))")
        }
    }

    private static func decodeNonceMap(_ root: [String: Any]) -> [String: TimeInterval] {
        var result: [String: TimeInterval] = [:]
        for (key, value) in root {
            if let number = value as? NSNumber {
                result[key] = number.doubleValue
            } else if let double = value as? Double {
                result[key] = double
            }
        }
        return result
    }

    private static func canonicalNonceMessage(_ map: [String: TimeInterval]) -> String {
        map.keys.sorted().map { key in
            "\(key)=\(map[key] ?? 0)"
        }.joined(separator: "\n")
    }
}

/// Per-install shared secret for authenticating local remote-control commands.
///
/// Production installs store the secret and accepted-nonce map in the login Keychain
/// with an ACL limited to this executable (code-identity gate), not as same-UID-writable
/// files under Application Support. Explicit `directoryURL` (tests) keeps the legacy
/// file store with HMAC-bound nonce persistence. CLI/DNC callers never broadcast the
/// reusable secret; they attach a short-lived HMAC instead. URL callers may still pass
/// `token=` after obtaining it via the authorized `caff remote-token` command (Keychain
/// ACL prevents silent in-process reads by other executables).
public struct RemoteCommandAuth: Sendable {
    public static let tokenFileName = "remote-command.token"
    public static let nonceFileName = "remote-command.nonces"
    public static let nonceLockFileName = "remote-command.nonces.lock"
    public static let tokenByteCount = 32
    public static let signatureMaxAgeSeconds: TimeInterval = 120
    public static let keychainService = "local.caff.remote-command"
    public static let keychainAccount = "install-token"
    public static let keychainNonceAccount = "accepted-nonces"
    /// Prefix baked into secrets Caff mints. A preplanted generic-password under the
    /// public account name that lacks this prefix is rejected and rotated.
    public static let provisionedTokenPrefix = "caff-v1:"

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
        self.nonceStore = AcceptedNonceStore(directoryURL: self.directoryURL, usesKeychain: self.usesKeychain)
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
        guard try nonceStore.consume(nonce, expiresAt: expiresAt, now: current, integrityKey: secret) else {
            throw RemoteCommandAuthError.invalidToken
        }
    }

    // MARK: - Keychain-backed production store

    private func loadOrCreateKeychainToken() throws -> String {
        if let existing = try readKeychainToken(), Self.isProvisionedToken(existing) {
            return existing
        }
        // Never adopt a same-UID-preplanted Keychain secret. Public service/account
        // items without our provisioned prefix are deleted (delete must succeed) and
        // replaced with a Caff-minted value.
        if try readKeychainToken() != nil {
            try deleteKeychainAccount(Self.keychainAccount, context: "preplant token remove")
            try deleteKeychainAccount(Self.keychainNonceAccount, context: "preplant nonce remove")
        }
        try removeLegacyTokenFileIfPresent()

        let token = Self.provisionedTokenPrefix + (try Self.generateToken())
        do {
            try writeKeychainToken(token)
            return token
        } catch {
            // Lost a create race — return the winner's provisioned secret, never ours.
            if let existing = try readKeychainToken(), Self.isProvisionedToken(existing) {
                return existing
            }
            throw error
        }
    }

    private static func isProvisionedToken(_ token: String) -> Bool {
        token.hasPrefix(provisionedTokenPrefix)
            && token.count == provisionedTokenPrefix.count + tokenByteCount * 2
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
        // Ad-hoc codesign identities change across upgrades, so the previous executable-
        // scoped ACL may reject the replacement binary. Rotate rather than hang on an
        // interactive Keychain prompt that breaks unattended CLI/hooks.
        if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            try deleteKeychainAccount(Self.keychainAccount, context: "token ACL rotate")
            try deleteKeychainAccount(Self.keychainNonceAccount, context: "nonce ACL rotate")
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

    private func deleteKeychainAccount(_ account: String, context: String) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteCommandAuthError.storageFailed("\(context) failed (\(status))")
        }
    }

    private func writeKeychainToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw RemoteCommandAuthError.storageFailed("token is not valid UTF-8")
        }

        // Add-only: never SecItemDelete then Add. Concurrent first-run creators must
        // not invalidate each other's returned secret by wiping a just-published item.
        // Preplant cleanup happens before minting when an unprefixed item is present.
        let access = try Self.makeExecutableScopedAccess(descriptor: "Caff remote command token")

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
            // Signal the caller to reread the winner instead of returning our token.
            throw RemoteCommandAuthError.storageFailed("keychain token already exists")
        }
        guard status == errSecSuccess else {
            throw RemoteCommandAuthError.storageFailed("keychain write failed (\(status))")
        }
    }

    public static func makeExecutableScopedAccess(descriptor: String) throws -> SecAccess {
        var trustedApp: SecTrustedApplication?
        let trustedStatus = SecTrustedApplicationCreateFromPath(nil, &trustedApp)
        guard trustedStatus == errSecSuccess, let trustedApp else {
            throw RemoteCommandAuthError.storageFailed(
                "SecTrustedApplicationCreateFromPath failed (\(trustedStatus))"
            )
        }

        var access: SecAccess?
        let accessStatus = SecAccessCreate(
            descriptor as CFString,
            [trustedApp] as CFArray,
            &access
        )
        guard accessStatus == errSecSuccess, let access else {
            throw RemoteCommandAuthError.storageFailed("SecAccessCreate failed (\(accessStatus))")
        }
        return access
    }

    private func removeLegacyTokenFileIfPresent() throws {
        let path = tokenFileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: tokenFileURL)
        } catch CocoaError.fileNoSuchFile {
            // Concurrent cleaner already removed it — treat as success.
            return
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            return
        } catch {
            throw RemoteCommandAuthError.storageFailed(
                "failed to remove legacy token file: \(error.localizedDescription)"
            )
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

    /// Length-aware JSON encoding so values containing `=` / newlines cannot be
    /// repartitioned into adjacent keys without changing the MAC input.
    static func canonicalMessage(_ userInfo: [String: String]) -> String {
        let object = userInfo as [String: Any]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let encoded = String(data: data, encoding: .utf8)
        else {
            // Extremely defensive fallback — still length-prefixed per field.
            return userInfo.keys.sorted().map { key in
                let value = userInfo[key] ?? ""
                return "\(key.utf8.count):\(key)=\(value.utf8.count):\(value)"
            }.joined(separator: "\n")
        }
        return encoded
    }

    static func hmacHex(key: String, message: String) -> String {
        let symmetricKey = SymmetricKey(data: Data(key.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symmetricKey)
        return Data(digest).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
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
