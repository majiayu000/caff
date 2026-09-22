import Darwin
import Foundation
import Security

public enum RemoteCommandTokenError: Error, CustomStringConvertible, Equatable, Sendable {
    case tokenUnavailable
    case invalidStoredToken

    public var description: String {
        switch self {
        case .tokenUnavailable:
            return "Caff remote command token is unavailable"
        case .invalidStoredToken:
            return "Caff remote command token file is unreadable"
        }
    }
}

public enum RemoteCommandAuthenticator {
    public static let fileName = "remote-command.token"
    private static let tokenByteCount = 32

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return support.appendingPathComponent("Caff", isDirectory: true)
    }

    public static func loadOrCreate() throws -> String {
        try loadOrCreate(in: defaultDirectory())
    }

    public static func loadOrCreate(in directory: URL) throws -> String {
        try prepareDirectory(directory)
        let destination = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            return try readExistingToken(at: destination)
        }

        let token = try makeToken()
        let temporary = directory.appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else {
            throw RemoteCommandTokenError.tokenUnavailable
        }

        do {
            guard fchmod(descriptor, 0o600) == 0 else {
                throw RemoteCommandTokenError.tokenUnavailable
            }
            try writeAll(descriptor: descriptor, data: Data(token.utf8))
        } catch {
            close(descriptor)
            unlink(temporary.path)
            throw error
        }
        close(descriptor)

        if link(temporary.path, destination.path) == 0 {
            unlink(temporary.path)
            return token
        }
        let linkError = errno
        unlink(temporary.path)
        if linkError == EEXIST {
            return try readExistingToken(at: destination)
        }
        throw RemoteCommandTokenError.tokenUnavailable
    }

    public static func accepts(presented: String?, expected: String) -> Bool {
        guard let presented else {
            return false
        }
        let left = Array(presented.utf8)
        let right = Array(expected.utf8)
        guard !left.isEmpty, left.count == right.count else {
            return false
        }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    private static func prepareDirectory(_ directory: URL) throws {
        let path = directory.path
        if mkdir(path, 0o700) != 0 {
            guard errno == EEXIST else {
                throw RemoteCommandTokenError.tokenUnavailable
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw RemoteCommandTokenError.tokenUnavailable
            }
        }
        guard chmod(path, 0o700) == 0 else {
            throw RemoteCommandTokenError.tokenUnavailable
        }
    }

    private static func writeAll(descriptor: Int32, data: Data) throws {
        var remaining = data
        while !remaining.isEmpty {
            let wrote = remaining.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else {
                    return -1
                }
                return Darwin.write(descriptor, base, raw.count)
            }
            if wrote < 0 {
                if errno == EINTR {
                    continue
                }
                throw RemoteCommandTokenError.tokenUnavailable
            }
            if wrote == 0 {
                throw RemoteCommandTokenError.tokenUnavailable
            }
            remaining.removeFirst(wrote)
        }
    }

    private static func readExistingToken(at url: URL) throws -> String {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw RemoteCommandTokenError.invalidStoredToken
        }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isStoredToken(token) else {
            throw RemoteCommandTokenError.invalidStoredToken
        }
        _ = chmod(url.path, 0o600)
        return token
    }

    private static func isStoredToken(_ token: String) -> Bool {
        guard token.count == tokenByteCount * 2 else {
            return false
        }
        return token.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
        }
    }

    private static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: tokenByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw RemoteCommandTokenError.tokenUnavailable
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
