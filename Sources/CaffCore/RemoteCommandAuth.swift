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

/// Process-wide cache of accepted signed-payload nonces until their timestamps expire.
private final class AcceptedNonceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var expiresAtByNonce: [String: TimeInterval] = [:]

    /// Returns `true` when `nonce` is newly recorded; `false` when it was already consumed.
    func consume(_ nonce: String, expiresAt: TimeInterval, now: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        expiresAtByNonce = expiresAtByNonce.filter { $0.value > now }
        if expiresAtByNonce[nonce] != nil {
            return false
        }
        expiresAtByNonce[nonce] = expiresAt
        return true
    }
}

/// Per-install shared secret for authenticating local remote-control commands.
///
/// The token lives under Application Support/Caff. CLI/DNC callers never broadcast
/// the reusable secret; they attach a short-lived HMAC instead. URL callers may
/// still pass `token=` after reading the provisioned file.
public struct RemoteCommandAuth: Sendable {
    public static let tokenFileName = "remote-command.token"
    public static let tokenByteCount = 32
    public static let signatureMaxAgeSeconds: TimeInterval = 120

    public enum PayloadKey {
        public static let token = "token"
        public static let mac = "mac"
        public static let nonce = "nonce"
        public static let timestamp = "ts"
    }

    private static let acceptedNonces = AcceptedNonceCache()

    private let directoryURL: URL
    private let now: @Sendable () -> Date

    public init(directoryURL: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.directoryURL = supportRoot.appendingPathComponent("Caff", isDirectory: true)
        }
    }

    public var tokenFileURL: URL {
        directoryURL.appendingPathComponent(Self.tokenFileName, isDirectory: false)
    }

    /// Loads the existing install token, creating one if missing.
    public func loadOrCreateToken() throws -> String {
        if let existing = try readTokenIfPresent() {
            return existing
        }
        // Recover empty/incomplete token paths left by a crashed exclusive create.
        try removeIncompleteTokenIfPresent()
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
        guard Self.acceptedNonces.consume(nonce, expiresAt: expiresAt, now: current) else {
            throw RemoteCommandAuthError.invalidToken
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

    private func removeIncompleteTokenIfPresent() throws {
        guard FileManager.default.fileExists(atPath: tokenFileURL.path) else {
            return
        }
        // Caller already observed a missing/empty token; drop the incomplete path.
        do {
            try FileManager.default.removeItem(at: tokenFileURL)
        } catch {
            // Another writer may have replaced it; the reread path handles that.
        }
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
