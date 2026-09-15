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
public final class AcceptedNonceStore: @unchecked Sendable {
    private enum Backend {
        case file(URL)
        case keychain
    }

    /// Shared across store instances in-process; paired with Keychain (production)
    /// or file flock (tests) coordination for cross-process races.
    private static let processLock = NSLock()

    private let backend: Backend
    private let lockFileURL: URL
    private let keychainAccountProvider: (() throws -> String)?

    public init(
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
    public func consume(_ nonce: String, expiresAt: TimeInterval, now: TimeInterval, integrityKey: String) throws -> Bool {
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
    public func provisionEmpty(integrityKey: String) throws {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        try withCrossProcessLock {
            try saveMap([:], integrityKey: integrityKey)
        }
    }

    /// Best-effort snapshot of accepted nonces for remint migration.
    public func exportMap(integrityKey: String) throws -> [String: TimeInterval] {
        try withExclusiveAccess { access in
            try access.exportMap(integrityKey: integrityKey)
        }
    }

    /// Publishes `map` under `integrityKey`, pruning entries that already expired.
    ///
    /// Used when a lease-validated remint retires the prior secret so replay state
    /// survives rotation (retired MACs still check the live map via the new key).
    public func provisionMap(_ map: [String: TimeInterval], integrityKey: String, now: TimeInterval) throws {
        try withExclusiveAccess { access in
            try access.provisionMap(map, integrityKey: integrityKey, now: now)
        }
    }

    /// Holds process + cross-process nonce locks for the full remint migration window.
    ///
    /// Lease-validated remint must snapshot, rotate the live secret, and publish the
    /// rebound map without releasing this lock — otherwise a concurrent old-key
    /// consume can land after the snapshot and be dropped from the migrated map
    /// while the retired key remains accepted.
    public func withExclusiveAccess<T>(_ body: (ExclusiveAccess) throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        return try withCrossProcessLock {
            try body(ExclusiveAccess(store: self))
        }
    }

    /// Unlocked map helpers valid only inside `withExclusiveAccess`.
    public struct ExclusiveAccess {
        fileprivate let store: AcceptedNonceStore

        public func exportMap(integrityKey: String) throws -> [String: TimeInterval] {
            try store.loadMap(integrityKey: integrityKey)
        }

        public func provisionMap(
            _ map: [String: TimeInterval],
            integrityKey: String,
            now: TimeInterval
        ) throws {
            try store.saveMap(map.filter { $0.value > now }, integrityKey: integrityKey)
        }

        public func provisionEmpty(integrityKey: String) throws {
            try store.saveMap([:], integrityKey: integrityKey)
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
        switch backend {
        case .keychain:
            // Application Support flock paths are same-UID replaceable (unlink +
            // recreate yields a different inode). Coordinate via an exclusive
            // Keychain lock item instead so replay consumption is serialized in
            // the protected backing store.
            return try withKeychainCoordinationLock(body)
        case .file:
            return try withFileCoordinationLock(body)
        }
    }

    private func withKeychainCoordinationLock<T>(_ body: () throws -> T) throws -> T {
        let nonceAccount = try resolveKeychainAccount()
        let lockAccount = "nonce-lock.\(nonceAccount)"
        try RemoteCommandAuth.acquireKeychainLock(account: lockAccount, label: "Caff nonce consume lock")
        defer {
            try? RemoteCommandAuth.releaseKeychainLock(account: lockAccount)
        }
        return try body()
    }

    private func withFileCoordinationLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: lockFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Test/isolation only. Prefer an existing inode so peers cannot trivially
        // force two consumers onto different lock files during one race window;
        // production Keychain mode never uses this path.
        var fd = open(lockFileURL.path, O_RDWR | O_EXCL | O_CREAT, 0o600)
        if fd < 0 && errno == EEXIST {
            fd = open(lockFileURL.path, O_RDWR, 0o600)
        }
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

        // Never SecItemUpdate in place: a peer can recreate the predictable nonce
        // account after we scrub it and keep their ACL across an update. Delete any
        // pre-existing item, then recreate exclusively with our executable ACL.
        let deleteStatus = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: RemoteCommandAuth.keychainService,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw RemoteCommandAuthError.storageFailed(
                "nonce keychain replace-delete failed (\(deleteStatus))"
            )
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
            // Race: peer recreated between delete and add — remove again and retry once.
            let retryDelete = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: RemoteCommandAuth.keychainService,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
            guard retryDelete == errSecSuccess || retryDelete == errSecItemNotFound else {
                throw RemoteCommandAuthError.storageFailed(
                    "nonce keychain duplicate replace-delete failed (\(retryDelete))"
                )
            }
            status = SecItemAdd(addQuery as CFDictionary, nil)
            if status == errSecParam {
                addQuery.removeValue(forKey: kSecAttrAccessible as String)
                status = SecItemAdd(addQuery as CFDictionary, nil)
            }
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
    /// Historical HMAC mint-seal accounts — scrubbed on remint/mint; never trusted
    /// for adopt (seal = HMAC(token) is peer-forgeable before first remint).
    private static let slotMintSealAccountPrefix = "slot-mint-seal.v1."
    /// Prior install secret retained for `signatureMaxAgeSeconds` so a concurrent
    /// remint cannot invalidate an in-flight signed DNC/URL payload.
    private static let retiredTokenAccountPrefix = "retired-token.v1."
    /// Well-known plantable account — scrubbed on bootstrap, never used as provenance.
    /// Historical `slot-trust.v1` markers are rejected; user attestation gates adopt.
    public static let slotTrustMarkerAccount = "slot-trust.v1"
    /// Cross-process lock held while publishing token + claim + nonce together.
    public static let slotProvisioningLockAccount = "slot-provisioning.v1"

    /// Optional user-presence gate invoked when a pre-existing slot claim must be
    /// rotated. App/CLI set this to LocalAuthentication; tests leave it nil
    /// (fail closed → remint without prompting).
    public static var slotClaimAttestationHandler: (() throws -> Void)?

    /// Process-local set of claim keys this launch already sealed (after our mint)
    /// so repeated loads do not re-prompt or remint.
    private static let attestedClaimLock = NSLock()
    private static var attestedClaimKeys: Set<String> = []

    /// Receiver credential sealed after this process provisioned or adopted a slot.
    /// MAC verification consults this instead of blindly trusting a replaceable
    /// public slot pointer + token a same-UID peer can delete and recreate.
    private static let attestedVerificationLock = NSLock()
    private static var attestedVerificationToken: String?
    private static var attestedVerificationSlot: String?
    /// Upper bound on unexpired retired secrets retained for the signature window.
    private static let maxRetiredVerificationSecrets = 16

    /// Tokens whose HMAC-bound signing lease was verified this process. A valid
    /// lease proves prior user presence for remint (skip LocalAuthentication) but
    /// does *not* prove token provenance — peers who plant a token can also plant
    /// a matching lease.
    private static let leaseValidatedLock = NSLock()
    private static var leaseValidatedTokens: Set<String> = []

    /// Set after LocalAuthentication in the CLI/app authorization path so the
    /// subsequent remint under the provisioning lock does not re-prompt.
    private static let recentPresenceLock = NSLock()
    private static var recentUserPresence = false

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

    /// Best-effort read of an already-provisioned Keychain token without claim
    /// attestation or remint. Used for lease MAC verification so a valid lease can
    /// skip LocalAuthentication during remint without a chicken-and-egg prompt.
    public func peekProvisionedKeychainToken() throws -> String? {
        guard usesKeychain else { return nil }
        guard let slot = try Self.readKeychainSlotAccountValue() else { return nil }
        guard let token = try readKeychainToken(account: slot), Self.isProvisionedToken(token) else {
            return nil
        }
        return token
    }

    /// Reads an already-provisioned secret for MAC/ticket verification without reminting.
    private func readProvisionedTokenForVerification() throws -> String? {
        if usesKeychain {
            return try attestedOrLegitimateRemintTokenForVerification()
        }
        return try readTokenIfPresent()
    }

    /// Prefers the process-local attested receiver secret. A peer-replaced slot
    /// pointer/token is ignored unless the attested secret appears in the retired
    /// set for the same slot (legitimate CLI remint within the signature window).
    private func attestedOrLegitimateRemintTokenForVerification() throws -> String? {
        Self.attestedVerificationLock.lock()
        let attestedToken = Self.attestedVerificationToken
        let attestedSlot = Self.attestedVerificationSlot
        Self.attestedVerificationLock.unlock()

        guard let attestedToken,
              let attestedSlot,
              Self.isProvisionedToken(attestedToken)
        else {
            // No in-process attestation yet — never verify against a replaceable peek.
            return nil
        }

        guard let liveSlot = try Self.readKeychainSlotAccountValue() else {
            return attestedToken
        }
        guard liveSlot == attestedSlot else {
            // Public pointer redirected to a different private account — keep ours.
            return attestedToken
        }
        guard let live = try readKeychainToken(account: liveSlot),
              Self.isProvisionedToken(live)
        else {
            return attestedToken
        }
        if Self.constantTimeEquals(live, attestedToken) {
            return live
        }
        let retired = try readRetiredTokens(forSlot: liveSlot, bindingKey: live)
        if retired.contains(where: { Self.constantTimeEquals($0, attestedToken) }) {
            Self.rememberAttestedVerificationSecret(live, slotAccount: liveSlot)
            return live
        }
        // Unauthenticated live-secret replacement — keep verifying with attested.
        return attestedToken
    }

    /// Live secret first, then every still-unexpired retired prior secret (Keychain)
    /// whose record authenticates under the live/primary secret.
    private func verificationSecrets(primary: String) throws -> [String] {
        var secrets = [primary]
        guard usesKeychain else { return secrets }
        guard let slot = try Self.readKeychainSlotAccountValue() else { return secrets }
        for retired in try readRetiredTokens(forSlot: slot, bindingKey: primary) {
            if secrets.contains(where: { Self.constantTimeEquals($0, retired) }) {
                continue
            }
            secrets.append(retired)
        }
        return secrets
    }

    private static func rememberAttestedVerificationSecret(_ token: String, slotAccount: String) {
        attestedVerificationLock.lock()
        attestedVerificationToken = token
        attestedVerificationSlot = slotAccount
        attestedVerificationLock.unlock()
    }

    /// Records that `token` was authenticated by an HMAC-valid signing lease.
    /// Callers may remint without re-prompting; they must not adopt the secret
    /// solely on this signal (leases are plantable with a planted token).
    public static func noteLeaseValidatedToken(_ token: String) {
        leaseValidatedLock.lock()
        leaseValidatedTokens.insert(token)
        leaseValidatedLock.unlock()
    }

    /// Records that LocalAuthentication just succeeded so the following remint
    /// does not re-prompt under the provisioning lock.
    public static func noteRecentUserPresence() {
        recentPresenceLock.lock()
        recentUserPresence = true
        recentPresenceLock.unlock()
    }

    /// Returns whether recent user presence was noted, optionally clearing it.
    public static func hasRecentUserPresence(consume: Bool = false) -> Bool {
        recentPresenceLock.lock()
        let value = recentUserPresence
        if consume {
            recentUserPresence = false
        }
        recentPresenceLock.unlock()
        return value
    }

    private static func isLeaseValidatedToken(_ token: String) -> Bool {
        leaseValidatedLock.lock()
        defer { leaseValidatedLock.unlock() }
        return leaseValidatedTokens.contains(token)
    }

    private static func leaseValidatedTokenSnapshot() -> Set<String> {
        leaseValidatedLock.lock()
        defer { leaseValidatedLock.unlock() }
        return leaseValidatedTokens
    }

    private static func sealAttestedClaimKey(_ key: String) {
        attestedClaimLock.lock()
        attestedClaimKeys.insert(key)
        attestedClaimLock.unlock()
    }

    private static func hasAttestedClaimKey(_ key: String) -> Bool {
        attestedClaimLock.lock()
        defer { attestedClaimLock.unlock() }
        return attestedClaimKeys.contains(key)
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

        guard let secret = try readProvisionedTokenForVerification() else {
            throw RemoteCommandAuthError.missingToken
        }
        var messageFields = Self.urlTicketBoundFields(from: command)
        messageFields["purpose"] = "url-ticket"
        messageFields[PayloadKey.nonce] = nonce
        messageFields[PayloadKey.timestamp] = tsRaw
        let candidates = try verificationSecrets(primary: secret)
        guard let matched = candidates.first(where: { candidate in
            let expected = Self.hmacHex(key: candidate, message: Self.canonicalMessage(messageFields))
            return Self.constantTimeEquals(mac, expected)
        }) else {
            throw RemoteCommandAuthError.invalidToken
        }

        let expiresAt = timestamp + Self.signatureMaxAgeSeconds
        // Live secret owns the rebound nonce map after remint migration; fall back
        // to the matched key only if the live candidate list is somehow empty.
        let integrityKey = candidates.first ?? matched
        guard try nonceStore.consume(nonce, expiresAt: expiresAt, now: current, integrityKey: integrityKey) else {
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

        // Peek/read only: verification must not remint, or a concurrent CLI signer
        // that just rotated under a lease would fail MAC checks against a newer secret.
        guard let secret = try readProvisionedTokenForVerification() else {
            throw RemoteCommandAuthError.missingToken
        }
        var unsigned = userInfo
        unsigned.removeValue(forKey: PayloadKey.mac)
        unsigned.removeValue(forKey: PayloadKey.token)
        unsigned.removeValue(forKey: PayloadKey.ticket)
        let candidates = try verificationSecrets(primary: secret)
        guard let matched = candidates.first(where: { candidate in
            let expected = Self.hmacHex(key: candidate, message: Self.canonicalMessage(unsigned))
            return Self.constantTimeEquals(mac, expected)
        }) else {
            throw RemoteCommandAuthError.invalidToken
        }

        // Record after MAC verification so forged payloads cannot burn valid nonces.
        let expiresAt = timestamp + Self.signatureMaxAgeSeconds
        let integrityKey = candidates.first ?? matched
        guard try nonceStore.consume(nonce, expiresAt: expiresAt, now: current, integrityKey: integrityKey) else {
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
        // Historical plantable trust markers are never provenance — scrub on bootstrap.
        try deleteKeychainAccount(Self.slotTrustMarkerAccount, context: "legacy slot trust marker scrub")

        // Slot pointer + created flag must be observed under the same provisioning
        // lock as token/claim/nonce publish so a stale created==true cannot scrub a
        // concurrent winner's claim/nonce. LocalAuthentication runs outside the lock
        // so a killed prompt cannot leave a permanent Keychain lock.
        for _ in 0..<4 {
            let outcome = try withSlotProvisioningLock { () -> SlotProvisioningOutcome in
                let slot = try loadOrCreateKeychainSlotAccount()
                let nonceAccount = Self.nonceAccount(forSlot: slot.account)
                let claimAccount = Self.slotClaimAccount(forSlot: slot.account)
                do {
                    let token = try loadOrCreateKeychainTokenLocked(
                        slot: slot,
                        nonceAccount: nonceAccount,
                        claimAccount: claimAccount
                    )
                    return .token(token)
                } catch is SlotClaimAttestationRequired {
                    return .needsAttestation
                } catch is SlotPointerRotated {
                    // Token ACL recovery deleted the slot pointer mid-transaction —
                    // resolve/create a fresh slot on the next locked pass.
                    return .restartSlot
                }
            }
            switch outcome {
            case let .token(token):
                if let slot = try Self.readKeychainSlotAccountValue() {
                    Self.rememberAttestedVerificationSecret(token, slotAccount: slot)
                }
                return token
            case .restartSlot:
                continue
            case .needsAttestation:
                guard let attest = Self.slotClaimAttestationHandler else {
                    // No handler: next locked pass remints fail-closed.
                    Self.noteRecentUserPresence()
                    continue
                }
                try attest()
                Self.noteRecentUserPresence()
            }
        }
        throw RemoteCommandAuthError.storageFailed("slot claim attestation retry exhausted")
    }

    private enum SlotProvisioningOutcome {
        case token(String)
        case needsAttestation
        case restartSlot
    }

    private struct SlotClaimAttestationRequired: Error {}
    private struct SlotPointerRotated: Error {}

    private func loadOrCreateKeychainTokenLocked(
        slot: (account: String, created: Bool),
        nonceAccount: String,
        claimAccount: String
    ) throws -> String {
        func rotateRemintingToken(
            _ token: String,
            preserveInFlightSignatures: Bool,
            context: String
        ) throws -> String? {
            if preserveInFlightSignatures {
                // Snapshot, delete, mint, rebind nonces, and retire under one nonce
                // lock so concurrent old-key consumes cannot be lost from the migrated
                // map. Returns the replacement secret when successful.
                return try atomicLeaseValidatedRemint(
                    oldToken: token,
                    slotAccount: slot.account,
                    nonceAccount: nonceAccount,
                    claimAccount: claimAccount,
                    context: context
                )
            }
            try deleteKeychainTokenIfMatches(
                account: slot.account,
                expected: token,
                context: context,
                retirePrior: false
            )
            try deleteKeychainNonceIfTokenGoneOrMatches(
                nonceAccount: nonceAccount,
                tokenAccount: slot.account,
                expectedToken: token,
                context: "\(context) nonce"
            )
            try scrubMintSeal(forClaimAccount: claimAccount, context: "\(context) mint seal")
            return nil
        }

        if !slot.created {
            let observed = try readKeychainToken(account: slot.account)
            if let existing = observed, Self.isProvisionedToken(existing) {
                switch try claimSlotOwnership(claimAccount: claimAccount, token: existing) {
                case .adopt:
                    do {
                        try ensureNonceStore(forToken: existing, nonceAccount: nonceAccount)
                        return existing
                    } catch {
                        // Nonce map missing/corrupt under an otherwise adopted token.
                        // Rotate without retiring: replay state is already gone, and
                        // accepting retired MACs against an empty map would allow replay.
                        Self.noteRecentUserPresence()
                        try deleteKeychainTokenIfMatches(
                            account: slot.account,
                            expected: existing,
                            context: "established token nonce-store remint",
                            retirePrior: false
                        )
                        try deleteKeychainAccount(claimAccount, context: "claim scrub on nonce remint")
                        try scrubMintSeal(forClaimAccount: claimAccount, context: "mint seal scrub on nonce remint")
                    }
                case .remint(let preserveInFlightSignatures):
                    if let replaced = try rotateRemintingToken(
                        existing,
                        preserveInFlightSignatures: preserveInFlightSignatures,
                        context: preserveInFlightSignatures
                            ? "lease-validated slot token rotate"
                            : "preplant slot token rotate"
                    ) {
                        return replaced
                    }
                }
            } else if let corrupt = observed {
                try deleteKeychainTokenIfMatches(
                    account: slot.account,
                    expected: corrupt,
                    context: "corrupt slot token remove",
                    retirePrior: false
                )
                try deleteKeychainAccount(claimAccount, context: "claim scrub on corrupt token")
                try scrubMintSeal(forClaimAccount: claimAccount, context: "mint seal scrub on corrupt token")
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
                        Self.noteRecentUserPresence()
                        try deleteKeychainTokenIfMatches(
                            account: slot.account,
                            expected: winner,
                            context: "winner token nonce-store remint",
                            retirePrior: false
                        )
                        try deleteKeychainAccount(claimAccount, context: "claim scrub on winner remint")
                        try scrubMintSeal(forClaimAccount: claimAccount, context: "mint seal scrub on winner remint")
                    }
                case .remint(let preserveInFlightSignatures):
                    if let replaced = try rotateRemintingToken(
                        winner,
                        preserveInFlightSignatures: preserveInFlightSignatures,
                        context: preserveInFlightSignatures
                            ? "lease-validated winner token rotate"
                            : "winner preplant token rotate"
                    ) {
                        return replaced
                    }
                }
            }

            // No valid claimed token remains — clear nonce only when the slot token is
            // still absent/unprovisioned. A concurrent winner may have published token +
            // nonce + claim after our stale reads; unconditional delete would wipe them.
            if let leftover = try readKeychainToken(account: slot.account),
               Self.isProvisionedToken(leftover) {
                switch try claimSlotOwnership(claimAccount: claimAccount, token: leftover) {
                case .adopt:
                    try ensureNonceStore(forToken: leftover, nonceAccount: nonceAccount)
                    return leftover
                case .remint(let preserveInFlightSignatures):
                    if let replaced = try rotateRemintingToken(
                        leftover,
                        preserveInFlightSignatures: preserveInFlightSignatures,
                        context: preserveInFlightSignatures
                            ? "lease-validated late winner token rotate"
                            : "late winner preplant token rotate"
                    ) {
                        return replaced
                    }
                }
            } else {
                try deleteKeychainAccount(nonceAccount, context: "corrupt slot nonce remove")
            }
        } else {
            // Brand-new private account name: peers could not have addressed it before
            // this exclusive create. Clear any stale nonce/claim before minting.
            try deleteKeychainAccount(nonceAccount, context: "fresh slot nonce scrub")
            try deleteKeychainAccount(claimAccount, context: "fresh slot claim scrub")
            try scrubMintSeal(forClaimAccount: claimAccount, context: "fresh slot mint seal scrub")
        }

        let token = Self.provisionedTokenPrefix + (try Self.generateToken())
        do {
            // Publish token, claim, and nonce under the provisioning lock so peers
            // cannot observe a token without its claim (or claim a half-published mint).
            try writeKeychainToken(token, account: slot.account)
            try writeSlotClaim(claimAccount: claimAccount, token: token)
            try nonceStore.provisionEmpty(integrityKey: token)
            // Do not publish an HMAC mint seal: peers who plant the token can forge
            // HMAC(token). Cross-process adopt relies on process-local seals; fresh
            // CLI processes remint under a validated lease and rebind that lease.
            try scrubMintSeal(forClaimAccount: claimAccount, context: "mint seal scrub on fresh mint")
            // Seal this process's attestation cache so subsequent loads adopt the
            // claim we just published without rotating again.
            let sealedKey = claimAccount + "|" + Self.slotClaimValue(forToken: token)
            Self.sealAttestedClaimKey(sealedKey)
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

    /// Lease-validated remint that holds the nonce lock across snapshot → rotation →
    /// publication, and only retires the prior secret after the rebound map is saved.
    private func atomicLeaseValidatedRemint(
        oldToken: String,
        slotAccount: String,
        nonceAccount: String,
        claimAccount: String,
        context: String
    ) throws -> String {
        try nonceStore.withExclusiveAccess { access in
            let migrated: [String: TimeInterval]
            do {
                migrated = try access.exportMap(integrityKey: oldToken)
            } catch {
                // Replay state already gone — rotate without retiring so we never
                // accept old-key MACs against an empty rebound map.
                try deleteKeychainTokenIfMatches(
                    account: slotAccount,
                    expected: oldToken,
                    context: "\(context) map-missing rotate",
                    retirePrior: false
                )
                try deleteKeychainNonceIfTokenGoneOrMatches(
                    nonceAccount: nonceAccount,
                    tokenAccount: slotAccount,
                    expectedToken: oldToken,
                    context: "\(context) map-missing nonce"
                )
                try scrubMintSeal(forClaimAccount: claimAccount, context: "\(context) map-missing mint seal")
                let replacement = Self.provisionedTokenPrefix + (try Self.generateToken())
                try writeKeychainToken(replacement, account: slotAccount)
                try writeSlotClaim(claimAccount: claimAccount, token: replacement)
                try access.provisionEmpty(integrityKey: replacement)
                try scrubMintSeal(forClaimAccount: claimAccount, context: "\(context) map-missing seal scrub")
                let sealedKey = claimAccount + "|" + Self.slotClaimValue(forToken: replacement)
                Self.sealAttestedClaimKey(sealedKey)
                return replacement
            }

            // Delete without retiring yet — retirement happens only after migration.
            try deleteKeychainTokenIfMatches(
                account: slotAccount,
                expected: oldToken,
                context: context,
                retirePrior: false
            )
            try deleteKeychainNonceIfTokenGoneOrMatches(
                nonceAccount: nonceAccount,
                tokenAccount: slotAccount,
                expectedToken: oldToken,
                context: "\(context) nonce"
            )
            try scrubMintSeal(forClaimAccount: claimAccount, context: "\(context) mint seal")

            let replacement = Self.provisionedTokenPrefix + (try Self.generateToken())
            try writeKeychainToken(replacement, account: slotAccount)
            try writeSlotClaim(claimAccount: claimAccount, token: replacement)
            try access.provisionMap(
                migrated,
                integrityKey: replacement,
                now: now().timeIntervalSince1970
            )
            // Retire only after the rebound map is durable under the new secret.
            // Read prior retirements under the old live key, then re-bind under the
            // replacement so the attestation-chain anchor survives remint churn.
            try rememberRetiredToken(
                oldToken,
                slotAccount: slotAccount,
                readBindingKey: oldToken,
                bindingKey: replacement
            )
            try scrubMintSeal(forClaimAccount: claimAccount, context: "\(context) seal scrub")
            let sealedKey = claimAccount + "|" + Self.slotClaimValue(forToken: replacement)
            Self.sealAttestedClaimKey(sealedKey)
            return replacement
        }
    }

    private enum SlotClaimResult {
        case adopt
        /// Rotate the live secret. When `preserveInFlightSignatures` is true (lease-
        /// validated remint), retire the prior secret for the signature window and
        /// migrate accepted nonces so replay rejection survives the rotation.
        case remint(preserveInFlightSignatures: Bool)
    }

    /// First successful claim under the public slot pointer owns the secret.
    ///
    /// A same-UID peer can preplant `keychain-slot`, a matching token, claim HMAC,
    /// an HMAC mint seal (seal = HMAC(token)), and even an HMAC-valid signing lease.
    /// Pre-existing claim/lease/seal material is therefore *not* proof of Caff
    /// provenance. Provenance is: exclusive create of the per-slot claim by a live
    /// process (then remint), or a process-local seal after our mint. Cross-process
    /// continuity uses lease-validated remint + peek-based MAC verify rather than
    /// trusting a durable mint seal. LocalAuthentication / a verified lease prove
    /// user presence for remint but never authorize adopting a possibly
    /// attacker-known secret.
    private func claimSlotOwnership(claimAccount: String, token: String) throws -> SlotClaimResult {
        let expected = Self.slotClaimValue(forToken: token)
        let attestationKey = claimAccount + "|" + expected

        // Prefer exclusive create without trusting a pre-read match (peers can plant HMAC).
        if try readSlotClaimValue(claimAccount: claimAccount) == nil {
            do {
                try writeSlotClaim(claimAccount: claimAccount, token: token, allowUpdate: false)
                // We created the claim against a possibly preplanted token — remint.
                try scrubMintSeal(forClaimAccount: claimAccount, context: "mint seal scrub on claim create remint")
                return .remint(preserveInFlightSignatures: false)
            } catch {
                // Lost the claim create race. A peer can SecItemAdd a matching claim
                // for a planted token in that window — do not treat the race as provenance.
                try scrubMintSeal(forClaimAccount: claimAccount, context: "mint seal scrub on claim race remint")
                return .remint(preserveInFlightSignatures: false)
            }
        }

        // Same-process seal after our mint — reuse without rotating again.
        if Self.hasAttestedClaimKey(attestationKey) {
            return .adopt
        }

        // Scrub any peer-forgeable HMAC mint seal. Matching seals are not provenance:
        // peers who plant the token can also plant HMAC(token) under an ACL Caff can read.
        try scrubMintSeal(forClaimAccount: claimAccount, context: "mint seal scrub forgeable cross-process")

        // Lease-validated tokens skip LocalAuthentication but still remint: peers who
        // plant the token can also plant a matching lease. Callers rebind the lease to
        // the reminted secret and verify MACs via peek (plus a short-lived retired
        // prior secret) so CLI→app auth stays coherent across concurrent remints.
        let presenceProven = Self.hasRecentUserPresence(consume: false)
            || Self.isLeaseValidatedToken(token)
        if presenceProven {
            guard let existingClaim = try readSlotClaimValue(claimAccount: claimAccount),
                  Self.constantTimeEquals(existingClaim, expected)
            else {
                try deleteKeychainAccount(claimAccount, context: "slot claim mismatch remove")
                return .remint(preserveInFlightSignatures: false)
            }
            // Keep presence noted so the caller can record a lease for the reminted secret.
            if Self.isLeaseValidatedToken(token) {
                Self.noteRecentUserPresence()
            }
            try deleteKeychainAccount(claimAccount, context: "preplant claim rotate after attestation")
            return .remint(preserveInFlightSignatures: true)
        }

        // A validated lease for a different token cannot authenticate this
        // replacement: a same-UID peer can plant both token and matching claim.
        // Require fresh attestation and remint instead of adopting that material.

        if Self.slotClaimAttestationHandler == nil {
            try deleteKeychainAccount(claimAccount, context: "preplant claim rotate without attestation")
            return .remint(preserveInFlightSignatures: false)
        }
        throw SlotClaimAttestationRequired()
    }

    /// Holds an exclusive Keychain lock around slot provisioning / claim races so
    /// token and claim publication cannot interleave across processes.
    private func withSlotProvisioningLock<T>(_ body: () throws -> T) throws -> T {
        try Self.acquireKeychainLock(
            account: Self.slotProvisioningLockAccount,
            label: "Caff remote command slot provisioning"
        )
        defer {
            try? Self.releaseKeychainLock(account: Self.slotProvisioningLockAccount)
        }
        return try body()
    }

    /// Lock payload: owner PID + process-start identity + wall-clock fencing hint.
    /// Abandoned locks left by a *dead* holder (or a reused PID whose start time no
    /// longer matches) are reclaimed; a still-living owner is never preempted on
    /// expiry alone (sleep/suspend must not allow overlapping successors).
    private static let keychainLockTTL: TimeInterval = 600

    fileprivate static func acquireKeychainLock(account: String, label: String) throws {
        let access = try makeExecutableScopedAccess(descriptor: label)
        var lastStatus: OSStatus = errSecSuccess
        // Bounded spin: another live Caff process may hold the lock briefly.
        for _ in 0..<400 {
            let payload = keychainLockPayload(expiresAt: Date().timeIntervalSince1970 + keychainLockTTL)
            guard let data = payload.data(using: .utf8) else {
                throw RemoteCommandAuthError.storageFailed("keychain lock payload is not UTF-8")
            }
            var addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: account,
                kSecAttrLabel as String: label,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecAttrAccess as String: access,
                kSecValueData as String: data,
            ]
            var status = SecItemAdd(addQuery as CFDictionary, nil)
            if status == errSecParam {
                addQuery.removeValue(forKey: kSecAttrAccessible as String)
                status = SecItemAdd(addQuery as CFDictionary, nil)
            }
            if status == errSecSuccess {
                return
            }
            lastStatus = status
            if status != errSecDuplicateItem {
                throw RemoteCommandAuthError.storageFailed("keychain lock acquire failed (\(status))")
            }
            if try reclaimStaleKeychainLockIfNeeded(account: account) {
                continue
            }
            usleep(5_000)
        }
        throw RemoteCommandAuthError.storageFailed("keychain lock acquire timed out (\(lastStatus))")
    }

    private static func keychainLockPayload(expiresAt: TimeInterval) -> String {
        let start = currentProcessStartTime()
        return "v2:\(getpid()):\(start.sec):\(start.usec):\(Int(expiresAt))"
    }

    private static func parseKeychainLockPayload(
        _ raw: String
    ) -> (pid: pid_t, startSec: Int64, startUsec: Int32, expiresAt: TimeInterval)? {
        if raw.hasPrefix("v2:") {
            let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
            // v2:pid:startSec:startUsec:expiresAt
            guard parts.count == 5,
                  let pid = pid_t(parts[1]),
                  let startSec = Int64(parts[2]),
                  let startUsec = Int32(parts[3]),
                  let expiresAt = TimeInterval(parts[4])
            else {
                return nil
            }
            return (pid, startSec, startUsec, expiresAt)
        }
        // Legacy v1:pid:expiresAt — treat missing start identity as unknown (0,0)
        // so reclaim still requires a dead PID (start-time mismatch cannot help).
        guard raw.hasPrefix("v1:"),
              let pidSplit = raw.dropFirst(3).firstIndex(of: ":")
        else {
            return nil
        }
        let pidRaw = String(raw[raw.index(raw.startIndex, offsetBy: 3)..<pidSplit])
        let expiryRaw = String(raw[raw.index(after: pidSplit)...])
        guard let pid = pid_t(pidRaw), let expiresAt = TimeInterval(expiryRaw) else {
            return nil
        }
        return (pid, 0, 0, expiresAt)
    }

    private static func currentProcessStartTime() -> (sec: Int64, usec: Int32) {
        processStartTime(getpid()) ?? (0, 0)
    }

    private static func processStartTime(_ pid: pid_t) -> (sec: Int64, usec: Int32)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size >= MemoryLayout<kinfo_proc>.stride else {
            return nil
        }
        let tv = info.kp_proc.p_starttime
        return (Int64(tv.tv_sec), Int32(tv.tv_usec))
    }

    private static func reclaimStaleKeychainLockIfNeeded(account: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return true
        }
        if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            try forceReleaseKeychainLock(account: account, expectedPayload: nil)
            return true
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let raw = String(data: data, encoding: .utf8)
        else {
            return false
        }

        // Legacy UUID-only locks (no owner metadata) are treated as reclaimable so
        // a killed holder cannot permanently wedge provisioning.
        guard let parsed = parseKeychainLockPayload(raw) else {
            try forceReleaseKeychainLock(account: account, expectedPayload: raw)
            return true
        }

        // Reclaim when the owner is dead, or when the PID was reused by a different
        // process (start time no longer matches the lock's recorded identity).
        if isProcessAlive(parsed.pid) {
            if parsed.startSec != 0 || parsed.startUsec != 0,
               let liveStart = processStartTime(parsed.pid),
               liveStart.sec == parsed.startSec,
               liveStart.usec == parsed.startUsec {
                return false
            }
            if parsed.startSec == 0 && parsed.startUsec == 0 {
                // Legacy v1 locks: PID still alive — do not reclaim on expiry alone.
                return false
            }
            // PID alive but start identity mismatch → reused PID; reclaim.
        }
        try forceReleaseKeychainLock(account: account, expectedPayload: raw)
        return true
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        if pid <= 0 { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Owner-matched release: a deferred unlock must not delete a successor's lock
    /// if this process outlived its TTL and another process reclaimed+reacquired.
    fileprivate static func releaseKeychainLock(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return
        }
        if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            return
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let raw = String(data: data, encoding: .utf8)
        else {
            return
        }
        // Legacy UUID locks have no owner metadata — only the creator should clear
        // them, and we cannot prove ownership; leave them for dead-owner reclaim.
        guard let parsed = parseKeychainLockPayload(raw) else {
            return
        }
        guard parsed.pid == getpid() else {
            return
        }
        if let start = processStartTime(getpid()),
           (parsed.startSec != 0 || parsed.startUsec != 0),
           (start.sec != parsed.startSec || start.usec != parsed.startUsec) {
            return
        }
        try forceReleaseKeychainLock(account: account, expectedPayload: raw)
    }

    /// Deletes a lock item, optionally only when it still contains `expectedPayload`.
    ///
    /// Stale reclaim must not erase a successor's lock after a concurrent recoverer
    /// already deleted the inspected payload and acquired a replacement. Exclusive
    /// reclaim fences keyed by the inspected payload serialize recoverers so only
    /// one may delete that generation.
    private static func forceReleaseKeychainLock(account: String, expectedPayload: String? = nil) throws {
        if let expectedPayload {
            let fenceAccount = reclaimFenceAccount(for: account, expectedPayload: expectedPayload)
            guard try tryAcquireReclaimFence(account: fenceAccount) else {
                // Another recoverer owns (or already finished) this payload reclaim.
                return
            }
            defer { try? releaseReclaimFence(account: fenceAccount) }

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound {
                return
            }
            if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
                // Unreadable ACL — fall through to unconditional delete below.
            } else {
                guard status == errSecSuccess,
                      let data = item as? Data,
                      let raw = String(data: data, encoding: .utf8),
                      raw == expectedPayload
                else {
                    return
                }
            }
        }
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteCommandAuthError.storageFailed("keychain lock release failed (\(status))")
        }
    }

    /// Fence account unique to `(lock account, inspected payload)` so concurrent
    /// recoverers of the same dead lock serialize, and a recoverer of payload P
    /// cannot delete successor lock Q.
    private static func reclaimFenceAccount(for account: String, expectedPayload: String) -> String {
        let digest = SHA256.hash(data: Data(expectedPayload.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(account).reclaim.\(hex)"
    }

    /// Exclusive create of a reclaim fence. Returns false when another live reclaim
    /// already holds the fence for this payload generation.
    private static func tryAcquireReclaimFence(account: String) throws -> Bool {
        let access = try makeExecutableScopedAccess(descriptor: "Caff keychain lock reclaim fence")
        let payload = keychainLockPayload(expiresAt: Date().timeIntervalSince1970 + keychainLockTTL)
        guard let data = payload.data(using: .utf8) else {
            throw RemoteCommandAuthError.storageFailed("reclaim fence payload is not UTF-8")
        }
        for _ in 0..<8 {
            var addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: account,
                kSecAttrLabel as String: "Caff keychain lock reclaim fence",
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecAttrAccess as String: access,
                kSecValueData as String: data,
            ]
            var status = SecItemAdd(addQuery as CFDictionary, nil)
            if status == errSecParam {
                addQuery.removeValue(forKey: kSecAttrAccessible as String)
                status = SecItemAdd(addQuery as CFDictionary, nil)
            }
            if status == errSecSuccess {
                return true
            }
            if status != errSecDuplicateItem {
                throw RemoteCommandAuthError.storageFailed("reclaim fence acquire failed (\(status))")
            }
            // Dead fence holder — reclaim without taking another fence, then retry.
            if try reclaimStaleReclaimFenceIfNeeded(account: account) {
                continue
            }
            return false
        }
        return false
    }

    private static func reclaimStaleReclaimFenceIfNeeded(account: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return true
        }
        if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            try forceReleaseKeychainLockUnfenced(account: account)
            return true
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let raw = String(data: data, encoding: .utf8)
        else {
            return false
        }
        guard let parsed = parseKeychainLockPayload(raw) else {
            try forceReleaseKeychainLockUnfenced(account: account)
            return true
        }
        if isProcessAlive(parsed.pid) {
            if parsed.startSec != 0 || parsed.startUsec != 0,
               let liveStart = processStartTime(parsed.pid),
               liveStart.sec == parsed.startSec,
               liveStart.usec == parsed.startUsec {
                return false
            }
            if parsed.startSec == 0 && parsed.startUsec == 0 {
                return false
            }
        }
        try forceReleaseKeychainLockUnfenced(account: account)
        return true
    }

    private static func releaseReclaimFence(account: String) throws {
        try forceReleaseKeychainLockUnfenced(account: account)
    }

    /// Unconditional delete used for reclaim fences (must not take another fence).
    private static func forceReleaseKeychainLockUnfenced(account: String) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteCommandAuthError.storageFailed("keychain lock release failed (\(status))")
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

    private static func slotMintSealAccount(forSlot slotAccount: String) -> String {
        slotMintSealAccountPrefix + slotAccount
    }

    private static func slotAccount(fromClaimAccount claimAccount: String) -> String? {
        guard claimAccount.hasPrefix(slotClaimAccountPrefix) else { return nil }
        let slot = String(claimAccount.dropFirst(slotClaimAccountPrefix.count))
        return slot.isEmpty ? nil : slot
    }

    private func scrubMintSeal(forClaimAccount claimAccount: String, context: String) throws {
        guard let slot = Self.slotAccount(fromClaimAccount: claimAccount) else { return }
        try deleteKeychainAccount(Self.slotMintSealAccount(forSlot: slot), context: context)
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
            // Pointer is gone — caller must resolve/create a new slot instead of
            // continuing provisioning against the previously resolved account.
            throw SlotPointerRotated()
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
    ///
    /// Retirement of in-flight secrets is handled separately by
    /// `atomicLeaseValidatedRemint` after the rebound nonce map is durable —
    /// retiring before migration would accept old-key MACs against an empty map.
    private func deleteKeychainTokenIfMatches(
        account: String,
        expected: String,
        context: String,
        retirePrior: Bool = false
    ) throws {
        guard let current = try readKeychainToken(account: account) else {
            return
        }
        guard current == expected else {
            return
        }
        // `retirePrior` is retained for call-site clarity but intentionally unused:
        // callers that preserve in-flight signatures go through atomic remint.
        _ = retirePrior
        try deleteKeychainAccount(account, context: context)
    }

    private static func retiredTokenAccount(forSlot slotAccount: String) -> String {
        retiredTokenAccountPrefix + slotAccount
    }

    private static func retiredTokenMacMessage(expiresAt: Int, token: String) -> String {
        "retired-token.v3|\(expiresAt)|\(token)"
    }

    /// Retains `token` for the signature window so verification can accept in-flight
    /// MACs after a lease-validated remint rotates the live secret. Keeps a bounded
    /// set of still-unexpired priors so T0→T1→T2→T3 does not drop T1 while it is live.
    ///
    /// Entries are HMAC-bound to `bindingKey` (the post-remint live secret) so a
    /// same-UID peer who knows the slot cannot plant an attacker-known retired
    /// secret and have `verificationSecrets` accept it. Prior entries are loaded
    /// under `readBindingKey` (the pre-remint live secret) then re-signed.
    private func rememberRetiredToken(
        _ token: String,
        slotAccount: String,
        readBindingKey: String,
        bindingKey: String
    ) throws {
        let expiresAt = Int(now().timeIntervalSince1970 + Self.signatureMaxAgeSeconds)
        var entries = try loadRetiredTokenEntries(forSlot: slotAccount, bindingKey: readBindingKey)
        let nowTs = now().timeIntervalSince1970
        entries = entries.filter { TimeInterval($0.expiresAt) > nowTs }
        entries.removeAll { Self.constantTimeEquals($0.token, token) }
        entries.append((expiresAt: expiresAt, token: token))
        if entries.count > Self.maxRetiredVerificationSecrets {
            // Keep the oldest unexpired entry as the attestation-chain anchor so a
            // long-lived receiver's process-local attested secret is not dropped while
            // short-lived CLI remints churn the tail of the list.
            let anchor = entries[0]
            let tail = Array(entries.dropFirst().suffix(Self.maxRetiredVerificationSecrets - 1))
            entries = [anchor] + tail
        }
        try saveRetiredTokenEntries(entries, forSlot: slotAccount, bindingKey: bindingKey)
    }

    private func readRetiredTokens(forSlot slotAccount: String, bindingKey: String) throws -> [String] {
        let nowTs = now().timeIntervalSince1970
        let all = try loadRetiredTokenEntries(forSlot: slotAccount, bindingKey: bindingKey)
        let live = all.filter { TimeInterval($0.expiresAt) > nowTs }
        if live.count != all.count {
            try? saveRetiredTokenEntries(live, forSlot: slotAccount, bindingKey: bindingKey)
        }
        return live.map(\.token)
    }

    /// Decode the outer fields; provisioned tokens themselves contain a colon.
    static func parseRetiredTokenEntry(_ line: String) -> (expiresAt: Int, token: String, mac: String)? {
        guard let first = line.firstIndex(of: ":"),
              let last = line.lastIndex(of: ":"), first != last,
              let expiresAt = Int(line[..<first])
        else { return nil }
        let token = String(line[line.index(after: first)..<last])
        let mac = String(line[line.index(after: last)...])
        guard isProvisionedToken(token), !mac.isEmpty else { return nil }
        return (expiresAt, token, mac)
    }

    private func loadRetiredTokenEntries(
        forSlot slotAccount: String,
        bindingKey: String
    ) throws -> [(expiresAt: Int, token: String)] {
        let account = Self.retiredTokenAccount(forSlot: slotAccount)
        guard let raw = try readRetiredTokenRaw(account: account) else {
            return []
        }
        if raw.hasPrefix("v3\n") {
            var entries: [(expiresAt: Int, token: String)] = []
            for line in raw.dropFirst(3).split(separator: "\n", omittingEmptySubsequences: true) {
                guard let entry = Self.parseRetiredTokenEntry(String(line)) else {
                    continue
                }
                let (expiresAt, token, mac) = entry
                let expected = Self.hmacHex(
                    key: bindingKey,
                    message: Self.retiredTokenMacMessage(expiresAt: expiresAt, token: token)
                )
                guard Self.constantTimeEquals(mac, expected) else {
                    // Peer-planted or rebound under a different live secret — ignore.
                    continue
                }
                entries.append((expiresAt: expiresAt, token: token))
            }
            return entries
        }
        // Legacy v1/v2 payloads are format-only and peer-plantable — never trust them
        // as verification secrets. Scrub so a planted record cannot linger.
        try deleteKeychainAccount(account, context: "retired token unauthenticated remove")
        return []
    }

    private func saveRetiredTokenEntries(
        _ entries: [(expiresAt: Int, token: String)],
        forSlot slotAccount: String,
        bindingKey: String
    ) throws {
        let account = Self.retiredTokenAccount(forSlot: slotAccount)
        if entries.isEmpty {
            try deleteKeychainAccount(account, context: "retired token clear")
            return
        }
        let body = entries.map { entry in
            let mac = Self.hmacHex(
                key: bindingKey,
                message: Self.retiredTokenMacMessage(expiresAt: entry.expiresAt, token: entry.token)
            )
            return "\(entry.expiresAt):\(entry.token):\(mac)"
        }.joined(separator: "\n")
        let payload = "v3\n\(body)"
        guard let data = payload.data(using: .utf8) else {
            throw RemoteCommandAuthError.storageFailed("retired token payload is not UTF-8")
        }
        try deleteKeychainAccount(account, context: "retired token replace")
        let access = try Self.makeExecutableScopedAccess(descriptor: "Caff remote command retired token")
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Caff remote command retired token",
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
            try deleteKeychainAccount(account, context: "retired token duplicate replace")
            status = SecItemAdd(addQuery as CFDictionary, nil)
            if status == errSecParam {
                addQuery.removeValue(forKey: kSecAttrAccessible as String)
                status = SecItemAdd(addQuery as CFDictionary, nil)
            }
        }
        guard status == errSecSuccess else {
            throw RemoteCommandAuthError.storageFailed("retired token write failed (\(status))")
        }
    }

    private func readRetiredTokenRaw(account: String) throws -> String? {
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
        if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            try deleteKeychainAccount(account, context: "retired token ACL rotate")
            return nil
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let raw = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return raw
    }

    /// Removes a nonce map only when the associated token is gone or still the
    /// observed value we are rotating. Avoids wiping a concurrent winner's map.
    private func deleteKeychainNonceIfTokenGoneOrMatches(
        nonceAccount: String,
        tokenAccount: String,
        expectedToken: String,
        context: String
    ) throws {
        if let current = try readKeychainToken(account: tokenAccount) {
            guard current == expectedToken else {
                return
            }
        }
        try deleteKeychainAccount(nonceAccount, context: context)
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
