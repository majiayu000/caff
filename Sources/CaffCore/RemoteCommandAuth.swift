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

/// Per-install shared secret for authenticating local remote-control commands.
///
/// The token lives under Application Support/Caff so the CLI and agent-touch hooks
/// can attach it automatically while forged DNC/`caff://` payloads without it are rejected.
public struct RemoteCommandAuth: Sendable {
    public static let tokenFileName = "remote-command.token"
    public static let tokenByteCount = 32

    private let directoryURL: URL

    public init(directoryURL: URL? = nil) {
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
        let token = try Self.generateToken()
        try persist(token)
        return token
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

    private func persist(_ token: String) throws {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            guard let data = token.data(using: .utf8) else {
                throw RemoteCommandAuthError.storageFailed("token is not valid UTF-8")
            }
            try data.write(to: tokenFileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tokenFileURL.path
            )
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
