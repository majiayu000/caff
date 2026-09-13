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
/// Production persists the map in the login Keychain under a private account derived
/// from the install-token slot (same executable ACL), HMAC-bound to the install secret
/// so peers cannot preplant or rewrite the public `accepted-nonces` account. Missing
/// Keychain items fail closed after provisioning (deletion is treated as rollback, not
/// first use). Test/isolation directories keep a file store whose contents are
/// HMAC-bound to the install token so rewrite/truncation fails closed.
private final class AcceptedNonceStore: @unchecked Sendable {
    private enum Backend {
        case file(URL)
        case keychain
    }

    /// Shared across store instances in-process; paired with a flock for cross-process races.
    private static let processLock = NSLock()

    private let backend: Backend
    private let lockFileURL: URL
    private let keychainAccountProvider: (() throws -> String)?

    init(
        directoryURL: URL,
        usesKeychain: Bool,
        keychainAccountProvider: (() throws -> String)? = nil
    ) {
        if usesKeychain {
            self.backend = .keychain
            self.keychainAccountProvider = keychainAccountProvider
        } else {
            self.backend = .file(
                directoryURL.appendingPathComponent(RemoteCommandAuth.nonceFileName, isDirectory: false)
            )
            self.keychainAccountProvider = nil
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

    /// Creates an empty HMAC-bound nonce map during token provisioning.
    func provisionEmpty(integrityKey: String) throws {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        try withCrossProcessLock {
            try saveMap([:], integrityKey: integrityKey)
        }
    }

    /// Confirms a valid HMAC-bound nonce map already exists for `integrityKey`.
    ///
    /// Never remints an empty map here: wiping replay state under an established
    /// token would allow a deleted/corrupt nonce item to resurrect captured
    /// payloads inside the signature window. Empty maps are created only via
    /// `provisionEmpty` alongside a newly minted token.
    func ensureProvisioned(integrityKey: String) throws {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        try withCrossProcessLock {
            _ = try loadMap(integrityKey: integrityKey)
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
            return try loadKeychainMap(integrityKey: integrityKey)
        }
    }

    private func saveMap(_ map: [String: TimeInterval], integrityKey: String) throws {
        switch backend {
        case let .file(fileURL):
            try saveFileMap(map, fileURL: fileURL, integrityKey: integrityKey)
        case .keychain:
            try saveKeychainMap(map, integrityKey: integrityKey)
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

    private func resolveKeychainAccount() throws -> String {
        guard let keychainAccountProvider else {
            throw RemoteCommandAuthError.storageFailed("nonce keychain account provider missing")
        }
        return try keychainAccountProvider()
    }

    private func loadKeychainMap(integrityKey: String) throws -> [String: TimeInterval] {
        let account = try resolveKeychainAccount()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: RemoteCommandAuth.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            // After provisioning, a missing item is treated as rollback (peer delete),
            // not first use — otherwise captured payloads become replayable again.
            throw RemoteCommandAuthError.storageFailed(
                "nonce keychain item missing (possible rollback)"
            )
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
        guard let mac = root["mac"] as? String, !mac.isEmpty else {
            throw RemoteCommandAuthError.storageFailed("nonce keychain item missing integrity mac")
        }
        let noncesObject = root["nonces"] as? [String: Any] ?? [:]
        let map = Self.decodeNonceMap(noncesObject)
        let expected = RemoteCommandAuth.hmacHex(
            key: integrityKey,
            message: Self.canonicalNonceMessage(map)
        )
        guard RemoteCommandAuth.constantTimeEquals(mac, expected) else {
            throw RemoteCommandAuthError.storageFailed("nonce keychain integrity check failed")
        }
        return map
    }

    private func saveKeychainMap(_ map: [String: TimeInterval], integrityKey: String) throws {
        let account = try resolveKeychainAccount()
        let mac = RemoteCommandAuth.hmacHex(
            key: integrityKey,
            message: Self.canonicalNonceMessage(map)
        )
        let payload: [String: Any] = [
            "nonces": map.mapValues { $0 as Any },
            "mac": mac,
        ]
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
            kSecAttrAccount as String: account,
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

        let access = try RemoteCommandAuth.makeExecutableScopedAccess(
            descriptor: "Caff remote command nonce cache"
        )
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: RemoteCommandAuth.keychainService,
            kSecAttrAccount as String: account,
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
/// files under Application Support. The private Keychain account slot selector also lives
/// in Keychain (never an Application Support file) and is sealed by an exclusive first-
/// claimer item so a preplanted public pointer is rotated before the secret is adopted.
/// Explicit `directoryURL` (tests) keeps the legacy file store with HMAC-bound nonce
/// persistence. CLI/DNC callers never broadcast the reusable secret; they attach a
/// short-lived HMAC instead. URL callers use a short-lived single-use `ticket=` from
/// `caff remote-token` — the durable secret must not travel through non-exclusive custom
/// URL schemes.
public struct RemoteCommandAuth: Sendable {
    public static let tokenFileName = "remote-command.token"
    /// Legacy Application Support slot path — scrubbed only, never trusted as provenance.
    public static let keychainSlotFileName = "remote-command.keychain-slot"
    public static let nonceFileName = "remote-command.nonces"
    public static let nonceLockFileName = "remote-command.nonces.lock"
    public static let tokenByteCount = 32
    public static let signatureMaxAgeSeconds: TimeInterval = 120
    public static let keychainService = "local.caff.remote-command"
    /// Legacy public account name. Never adopted for reads — only scrubbed on bootstrap.
    public static let keychainAccount = "install-token"
    /// Keychain account that stores the private install-token slot name.
    public static let keychainSlotAccount = "keychain-slot"
    /// Legacy public nonce account. Never adopted — only scrubbed on bootstrap.
    public static let keychainNonceAccount = "accepted-nonces"
    /// Prefix baked into secrets Caff mints. Format only — not a trust/provenance signal.
    /// Provenance comes from an exclusively created private Keychain account slot,
    /// sealed by a first-claimer item so a preplanted public pointer+token is rotated
    /// before use.
    public static let provisionedTokenPrefix = "caff-v1:"
    private static let slotClaimAccountPrefix = "slot-claim.v1."
    private static let slotClaimMessagePrefix = "slot-claim-v1|"

    public enum PayloadKey {
        public static let token = "token"
        public static let ticket = "ticket"
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
        let supportDirectory = self.directoryURL
        self.nonceStore = AcceptedNonceStore(
            directoryURL: supportDirectory,
            usesKeychain: self.usesKeychain,
            keychainAccountProvider: self.usesKeychain
                ? { try RemoteCommandAuth.privateNonceAccountNameFromKeychain() }
                : nil
        )
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
    /// never needs the reusable bearer token. URL callers use a short-lived
    /// single-use `ticket=` — production Keychain mode rejects durable `token=`
    /// so the install secret never enters a non-exclusive custom URL scheme.
    public func authenticate(_ userInfo: [String: String]) throws {
        if let mac = userInfo[PayloadKey.mac], !mac.isEmpty {
            try verifySignedPayload(userInfo)
            return
        }
        if let ticket = userInfo[PayloadKey.ticket], !ticket.isEmpty {
            try verifyURLTicket(ticket, boundTo: userInfo)
            return
        }
        if usesKeychain {
            throw RemoteCommandAuthError.missingToken
        }
        try verify(userInfo[PayloadKey.token])
    }

    /// Issues a short-lived, single-use URL ticket bound to a specific command.
    ///
    /// The durable Keychain secret never appears in the ticket string — only a
    /// MAC over `(purpose, ts, nonce, command fields)` that is consumed like a
    /// signed DNC payload. Binding the command prevents a hijacked `caff://`
    /// handler from replaying the ticket with a different action or options.
    public func issueURLTicket(binding command: [String: String]) throws -> String {
        let secret = try loadOrCreateToken()
        let nonce = UUID().uuidString
        let timestamp = String(Int(now().timeIntervalSince1970))
        var messageFields = Self.urlTicketBoundFields(from: command)
        messageFields["purpose"] = "url-ticket"
        messageFields[PayloadKey.nonce] = nonce
        messageFields[PayloadKey.timestamp] = timestamp
        let mac = Self.hmacHex(key: secret, message: Self.canonicalMessage(messageFields))
        return "v1:\(timestamp):\(nonce):\(mac)"
    }

    /// Verifies and consumes a URL ticket issued by `issueURLTicket(binding:)`.
    public func verifyURLTicket(_ ticket: String, boundTo command: [String: String]) throws {
        let parts = ticket.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "v1" else {
            throw RemoteCommandAuthError.invalidToken
        }
        let tsRaw = String(parts[1])
        let nonce = String(parts[2])
        let mac = String(parts[3])
        guard let timestamp = TimeInterval(tsRaw), !nonce.isEmpty, !mac.isEmpty else {
            throw RemoteCommandAuthError.invalidToken
        }
        let current = now().timeIntervalSince1970
        guard abs(current - timestamp) <= Self.signatureMaxAgeSeconds else {
            throw RemoteCommandAuthError.invalidToken
        }

        let secret = try loadOrCreateToken()
        var messageFields = Self.urlTicketBoundFields(from: command)
        messageFields["purpose"] = "url-ticket"
        messageFields[PayloadKey.nonce] = nonce
        messageFields[PayloadKey.timestamp] = tsRaw
        let expected = Self.hmacHex(key: secret, message: Self.canonicalMessage(messageFields))
        guard Self.constantTimeEquals(mac, expected) else {
            throw RemoteCommandAuthError.invalidToken
        }

        let expiresAt = timestamp + Self.signatureMaxAgeSeconds
        guard try nonceStore.consume(nonce, expiresAt: expiresAt, now: current, integrityKey: secret) else {
            throw RemoteCommandAuthError.invalidToken
        }
    }

    /// Command fields covered by a URL ticket MAC (excludes auth envelope keys).
    public static func urlTicketBoundFields(from command: [String: String]) -> [String: String] {
        var fields = command
        fields.removeValue(forKey: PayloadKey.ticket)
        fields.removeValue(forKey: PayloadKey.token)
        fields.removeValue(forKey: PayloadKey.mac)
        fields.removeValue(forKey: PayloadKey.nonce)
        fields.removeValue(forKey: PayloadKey.timestamp)
        return fields
    }

    /// Signs `userInfo` with a short-lived HMAC, never embedding the reusable token.
    public func sign(_ userInfo: [String: String]) throws -> [String: String] {
        var payload = userInfo
        payload.removeValue(forKey: PayloadKey.token)
        payload.removeValue(forKey: PayloadKey.ticket)
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
        unsigned.removeValue(forKey: PayloadKey.ticket)
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
        try removeLegacyTokenFileIfPresent()
        try scrubLegacySlotFileIfPresent()
        // Always scrub legacy public accounts. Same-UID peers can preplant under
        // those well-known names; we never adopt them.
        try deleteKeychainAccount(Self.keychainAccount, context: "legacy public token scrub")
        try deleteKeychainAccount(Self.keychainNonceAccount, context: "legacy public nonce scrub")

        let slot = try loadOrCreateKeychainSlotAccount()
        let nonceAccount = Self.nonceAccount(forSlot: slot.account)
        let claimAccount = Self.slotClaimAccount(forSlot: slot.account)
        if !slot.created {
            let observed = try readKeychainToken(account: slot.account)
            if let existing = observed, Self.isProvisionedToken(existing) {
                switch try claimSlotOwnership(claimAccount: claimAccount, token: existing) {
                case .adopt:
                    do {
                        try ensureNonceStore(forToken: existing, nonceAccount: nonceAccount)
                        return existing
                    } catch {
                        try deleteKeychainTokenIfMatches(
                            account: slot.account,
                            expected: existing,
                            context: "established token nonce-store remint"
                        )
                        try deleteKeychainAccount(claimAccount, context: "claim scrub on nonce remint")
                    }
                case .remint:
                    // First Caff process to claim a pre-existing public pointer — discard
                    // any peer-chosen secret before minting under this slot.
                    try deleteKeychainTokenIfMatches(
                        account: slot.account,
                        expected: existing,
                        context: "preplant slot token rotate"
                    )
                    try deleteKeychainAccount(nonceAccount, context: "preplant slot nonce rotate")
                }
            } else if let corrupt = observed {
                try deleteKeychainTokenIfMatches(
                    account: slot.account,
                    expected: corrupt,
                    context: "corrupt slot token remove"
                )
                try deleteKeychainAccount(claimAccount, context: "claim scrub on corrupt token")
            }

            // After a miss/corrupt/remint path, adopt a concurrent winner if present
            // and already claimed.
            if let winner = try readKeychainToken(account: slot.account),
               Self.isProvisionedToken(winner) {
                switch try claimSlotOwnership(claimAccount: claimAccount, token: winner) {
                case .adopt:
                    do {
                        try ensureNonceStore(forToken: winner, nonceAccount: nonceAccount)
                        return winner
                    } catch {
                        try deleteKeychainTokenIfMatches(
                            account: slot.account,
                            expected: winner,
                            context: "winner token nonce-store remint"
                        )
                        try deleteKeychainAccount(claimAccount, context: "claim scrub on winner remint")
                    }
                case .remint:
                    try deleteKeychainTokenIfMatches(
                        account: slot.account,
                        expected: winner,
                        context: "winner preplant token rotate"
                    )
                    try deleteKeychainAccount(nonceAccount, context: "winner preplant nonce rotate")
                }
            }

            // No valid claimed token remains — clear nonce before minting a fresh pair.
            try deleteKeychainAccount(nonceAccount, context: "corrupt slot nonce remove")
        } else {
            // Brand-new private account name: peers could not have addressed it before
            // this exclusive create. Clear any stale nonce/claim before minting.
            try deleteKeychainAccount(nonceAccount, context: "fresh slot nonce scrub")
            try deleteKeychainAccount(claimAccount, context: "fresh slot claim scrub")
        }

        let token = Self.provisionedTokenPrefix + (try Self.generateToken())
        do {
            try writeKeychainToken(token, account: slot.account)
            try writeSlotClaim(claimAccount: claimAccount, token: token)
            try nonceStore.provisionEmpty(integrityKey: token)
            return token
        } catch {
            // Lost a create race — return the winner's provisioned secret, never ours.
            if let existing = try readKeychainToken(account: slot.account),
               Self.isProvisionedToken(existing) {
                switch try claimSlotOwnership(claimAccount: claimAccount, token: existing) {
                case .adopt:
                    try ensureNonceStore(forToken: existing, nonceAccount: nonceAccount)
                    return existing
                case .remint:
                    break
                }
            }
            throw error
        }
    }

    private enum SlotClaimResult {
        case adopt
        case remint
    }

    /// First successful claim under the public slot pointer owns the secret.
    ///
    /// A same-UID peer can preplant `keychain-slot` plus a matching token before
    /// Caff runs. The claim item is the non-preplantable boundary for that pointer:
    /// the first Caff process to exclusively create it rotates away any preplanted
    /// secret; later processes adopt only when the claim MAC matches the token.
    private func claimSlotOwnership(claimAccount: String, token: String) throws -> SlotClaimResult {
        let expected = Self.slotClaimValue(forToken: token)
        if let existingClaim = try readSlotClaimValue(claimAccount: claimAccount) {
            if Self.constantTimeEquals(existingClaim, expected) {
                return .adopt
            }
            try deleteKeychainAccount(claimAccount, context: "slot claim mismatch remove")
            return .remint
        }

        do {
            try writeSlotClaim(claimAccount: claimAccount, token: token, allowUpdate: false)
            // We created the claim against a possibly preplanted token — remint.
            return .remint
        } catch {
            // Lost the claim create race; adopt only if the winner matches this token.
            guard let winnerClaim = try readSlotClaimValue(claimAccount: claimAccount),
                  Self.constantTimeEquals(winnerClaim, expected)
            else {
                return .remint
            }
            return .adopt
        }
    }

    private func readSlotClaimValue(claimAccount: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: claimAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            try deleteKeychainAccount(claimAccount, context: "slot claim ACL rotate")
            return nil
        }
        guard status == errSecSuccess else {
            throw RemoteCommandAuthError.storageFailed("slot claim read failed (\(status))")
        }
        guard
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            throw RemoteCommandAuthError.storageFailed("slot claim is empty or not UTF-8")
        }
        return value
    }

    private func writeSlotClaim(claimAccount: String, token: String, allowUpdate: Bool = true) throws {
        guard let data = Self.slotClaimValue(forToken: token).data(using: .utf8) else {
            throw RemoteCommandAuthError.storageFailed("slot claim is not UTF-8")
        }
        let access = try Self.makeExecutableScopedAccess(descriptor: "Caff remote command slot claim")
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: claimAccount,
            kSecAttrLabel as String: "Caff remote command slot claim",
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
            guard allowUpdate else {
                throw RemoteCommandAuthError.storageFailed("slot claim already exists")
            }
            let update: [String: Any] = [kSecValueData as String: data]
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.keychainService,
                kSecAttrAccount as String: claimAccount,
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw RemoteCommandAuthError.storageFailed("slot claim update failed (\(updateStatus))")
            }
            return
        }
        guard status == errSecSuccess else {
            throw RemoteCommandAuthError.storageFailed("slot claim write failed (\(status))")
        }
    }

    private static func slotClaimAccount(forSlot slotAccount: String) -> String {
        slotClaimAccountPrefix + slotAccount
    }

    private static func slotClaimValue(forToken token: String) -> String {
        hmacHex(key: token, message: slotClaimMessagePrefix + token)
    }

    private func ensureNonceStore(forToken token: String, nonceAccount: String) throws {
        _ = nonceAccount
        try nonceStore.ensureProvisioned(integrityKey: token)
    }

    private static func isProvisionedToken(_ token: String) -> Bool {
        token.hasPrefix(provisionedTokenPrefix)
            && token.count == provisionedTokenPrefix.count + tokenByteCount * 2
    }

    private static func nonceAccount(forSlot slotAccount: String) -> String {
        "nonces.\(slotAccount)"
    }

    fileprivate static func privateNonceAccountNameFromKeychain() throws -> String {
        guard let slot = try readKeychainSlotAccountValue() else {
            throw RemoteCommandAuthError.storageFailed("keychain slot missing while resolving nonce account")
        }
        return nonceAccount(forSlot: slot)
    }

    /// Private Keychain account slot. The selector itself lives in Keychain under
    /// `keychainSlotAccount` so same-UID peers cannot redirect via an Application
    /// Support file. Legacy slot files are scrubbed and never trusted. Adoption of
    /// an existing selector requires a first-claimer seal (see `claimSlotOwnership`).
    private func loadOrCreateKeychainSlotAccount() throws -> (account: String, created: Bool) {
        try scrubLegacySlotFileIfPresent()

        if let existing = try Self.readKeychainSlotAccountValue() {
            if existing.hasPrefix("install-token-"), existing.count > "install-token-".count {
                return (existing, false)
            }
            try deleteKeychainAccount(Self.keychainSlotAccount, context: "corrupt slot pointer remove")
        }

        let account = "install-token-\(try Self.generateToken())"
        do {
            try writeKeychainSlotAccount(account)
            return (account, true)
        } catch {
            if let existing = try Self.readKeychainSlotAccountValue(),
               existing.hasPrefix("install-token-"),
               existing.count > "install-token-".count {
                return (existing, false)
            }
            throw error
        }
    }

    private static func readKeychainSlotAccountValue() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainSlotAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Unattended ACL recovery must not block on Keychain authorization UI.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            // Ad-hoc upgrade lost ACL recognition — drop pointer so we remint.
            let delete = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainSlotAccount,
            ] as CFDictionary)
            guard delete == errSecSuccess || delete == errSecItemNotFound else {
                throw RemoteCommandAuthError.storageFailed("slot pointer ACL rotate failed (\(delete))")
            }
            return nil
        }
        guard status == errSecSuccess else {
            throw RemoteCommandAuthError.storageFailed("keychain slot read failed (\(status))")
        }
        guard
            let data = item as? Data,
            let account = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !account.isEmpty
        else {
            throw RemoteCommandAuthError.storageFailed("keychain slot is empty or not UTF-8")
        }
        return account
    }

    private func writeKeychainSlotAccount(_ account: String) throws {
        guard let data = account.data(using: .utf8) else {
            throw RemoteCommandAuthError.storageFailed("slot account is not UTF-8")
        }
        let access = try Self.makeExecutableScopedAccess(descriptor: "Caff remote command keychain slot")
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainSlotAccount,
            kSecAttrLabel as String: "Caff remote command keychain slot",
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
            throw RemoteCommandAuthError.storageFailed("keychain slot already exists")
        }
        guard status == errSecSuccess else {
            throw RemoteCommandAuthError.storageFailed("keychain slot write failed (\(status))")
        }
    }

    private func scrubLegacySlotFileIfPresent() throws {
        let slotURL = directoryURL.appendingPathComponent(Self.keychainSlotFileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: slotURL.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: slotURL)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            return
        } catch {
            throw RemoteCommandAuthError.storageFailed(
                "failed to remove legacy keychain slot file: \(error.localizedDescription)"
            )
        }
    }

    private func readKeychainToken(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
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
            try deleteKeychainAccount(account, context: "token ACL rotate")
            try deleteKeychainAccount(Self.nonceAccount(forSlot: account), context: "nonce ACL rotate")
            try deleteKeychainAccount(Self.keychainSlotAccount, context: "slot ACL rotate")
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

    /// Deletes a Keychain token only when it still equals the value we observed.
    ///
    /// Prevents a recovery path from wiping a concurrently published provisioned
    /// token that appeared after our initial miss/corrupt read.
    private func deleteKeychainTokenIfMatches(
        account: String,
        expected: String,
        context: String
    ) throws {
        guard let current = try readKeychainToken(account: account) else {
            return
        }
        guard current == expected else {
            return
        }
        try deleteKeychainAccount(account, context: context)
    }

    private func writeKeychainToken(_ token: String, account: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw RemoteCommandAuthError.storageFailed("token is not valid UTF-8")
        }

        // Add-only: never SecItemDelete then Add. Concurrent first-run creators must
        // not invalidate each other's returned secret by wiping a just-published item.
        let access = try Self.makeExecutableScopedAccess(descriptor: "Caff remote command token")

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
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

    public static func hmacHex(key: String, message: String) -> String {
        let symmetricKey = SymmetricKey(data: Data(key.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symmetricKey)
        return Data(digest).map { String(format: "%02x", $0) }.joined()
    }

    /// Cross-module constant-time compare for lease/token authenticators.
    public static func constantTimeEqualsPublic(_ lhs: String, _ rhs: String) -> Bool {
        constantTimeEquals(lhs, rhs)
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
