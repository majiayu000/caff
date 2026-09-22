import Darwin
import Foundation
import Security

enum RemoteCommandChannelError: Error, CustomStringConvertible {
    case unavailable
    case rejected

    var description: String {
        switch self {
        case .unavailable:
            return "Caff remote command channel is unavailable"
        case .rejected:
            return "Caff rejected a remote command"
        }
    }
}

enum RemoteCommandSocket {
    static let maximumFrameBytes = 16 * 1024

    static func withAddress<T>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        guard path.utf8.count < 104 else {
            return nil
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        return withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                body(socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func fileURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return support
            .appendingPathComponent("Caff", isDirectory: true)
            .appendingPathComponent("remote.sock")
    }

    static func prepareDirectory(fileManager: FileManager = .default) throws -> URL {
        let url = fileURL(fileManager: fileManager)
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let leftoverToken = directory.appendingPathComponent("remote-command.token")
        if fileManager.fileExists(atPath: leftoverToken.path) {
            try? fileManager.removeItem(at: leftoverToken)
        }
        return url
    }
}

enum RemoteCommandSigning {
    static func designatedRequirement() throws -> SecRequirement {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw RemoteCommandChannelError.unavailable
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw RemoteCommandChannelError.unavailable
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else {
            throw RemoteCommandChannelError.unavailable
        }
        return requirement
    }

    static func peerMatches(_ descriptor: Int32, requirement: SecRequirement) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        let status = withUnsafeMutablePointer(to: &token) { tokenPointer in
            getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, tokenPointer, &length)
        }
        guard status == 0 else {
            return false
        }
        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit as String: tokenData] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else {
            return false
        }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }
}

final class RemoteCommandServer {
    private let perform: ([String: String]) -> Bool
    private let requirement: SecRequirement
    private let listenDescriptor: Int32
    private let queue = DispatchQueue(label: "com.starlight.caff.remote-command")
    private let stateLock = NSLock()
    private var stopped = false

    init(perform: @escaping ([String: String]) -> Bool) throws {
        self.perform = perform
        requirement = try RemoteCommandSigning.designatedRequirement()
        let url = try RemoteCommandSocket.prepareDirectory()
        let path = url.path
        guard path.utf8.count < 104 else {
            throw RemoteCommandChannelError.unavailable
        }
        if unlink(path) != 0 && errno != ENOENT {
            throw RemoteCommandChannelError.unavailable
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw RemoteCommandChannelError.unavailable
        }
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let bound = RemoteCommandSocket.withAddress(path: path) { socketAddress, length in
            bind(descriptor, socketAddress, length)
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            close(descriptor)
            throw RemoteCommandChannelError.unavailable
        }
        _ = chmod(path, 0o600)
        listenDescriptor = descriptor
        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
        close(listenDescriptor)
        unlink(RemoteCommandSocket.fileURL().path)
    }

    private func isStopped() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func acceptLoop() {
        while !isStopped() {
            let client = accept(listenDescriptor, nil, nil)
            if client < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        guard RemoteCommandSigning.peerMatches(client, requirement: requirement),
              let userInfo = try? RemoteCommandFraming.read(client) else {
            RemoteCommandFraming.writeReply(false, to: client)
            return
        }
        let accepted = DispatchQueue.main.sync {
            perform(userInfo)
        }
        RemoteCommandFraming.writeReply(accepted, to: client)
    }
}

enum RemoteCommandClient {
    static func send(_ userInfo: [String: String]) throws {
        let requirement = try RemoteCommandSigning.designatedRequirement()
        let deadline = Date().addingTimeInterval(5)
        var lastError: Error = RemoteCommandChannelError.unavailable
        while Date() < deadline {
            do {
                try sendOnce(userInfo, requirement: requirement)
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        throw lastError
    }

    private static func sendOnce(_ userInfo: [String: String], requirement: SecRequirement) throws {
        let path = RemoteCommandSocket.fileURL().path
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw RemoteCommandChannelError.unavailable
        }
        defer { close(descriptor) }
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let connected = RemoteCommandSocket.withAddress(path: path) { socketAddress, length in
            connect(descriptor, socketAddress, length)
        }
        guard connected == 0 else {
            throw RemoteCommandChannelError.unavailable
        }
        guard RemoteCommandSigning.peerMatches(descriptor, requirement: requirement) else {
            throw RemoteCommandChannelError.rejected
        }
        try RemoteCommandFraming.write(userInfo, to: descriptor)
        guard RemoteCommandFraming.readReply(descriptor) else {
            throw RemoteCommandChannelError.rejected
        }
    }
}

private enum RemoteCommandFraming {
    static func write(_ userInfo: [String: String], to descriptor: Int32) throws {
        let payload = try JSONSerialization.data(withJSONObject: userInfo)
        guard payload.count <= RemoteCommandSocket.maximumFrameBytes else {
            throw RemoteCommandChannelError.unavailable
        }
        var length = UInt32(payload.count).bigEndian
        try writeAll(Data(bytes: &length, count: 4), to: descriptor)
        try writeAll(payload, to: descriptor)
    }

    static func read(_ descriptor: Int32) throws -> [String: String] {
        let lengthData = try readExact(4, from: descriptor)
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length > 0, length <= RemoteCommandSocket.maximumFrameBytes else {
            throw RemoteCommandChannelError.rejected
        }
        let payload = try readExact(Int(length), from: descriptor)
        guard let userInfo = try JSONSerialization.jsonObject(with: payload) as? [String: String] else {
            throw RemoteCommandChannelError.rejected
        }
        return userInfo
    }

    static func writeReply(_ accepted: Bool, to descriptor: Int32) {
        var byte: UInt8 = accepted ? 1 : 0
        _ = Darwin.write(descriptor, &byte, 1)
    }

    static func readReply(_ descriptor: Int32) -> Bool {
        var byte: UInt8 = 0
        let count = Darwin.read(descriptor, &byte, 1)
        return count == 1 && byte == 1
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
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
                throw RemoteCommandChannelError.unavailable
            }
            if wrote == 0 {
                throw RemoteCommandChannelError.unavailable
            }
            remaining.removeFirst(wrote)
        }
    }

    private static func readExact(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            var buffer = [UInt8](repeating: 0, count: count - data.count)
            let readCount = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else {
                    return -1
                }
                return Darwin.read(descriptor, base, raw.count)
            }
            if readCount < 0 {
                if errno == EINTR {
                    continue
                }
                throw RemoteCommandChannelError.unavailable
            }
            if readCount == 0 {
                throw RemoteCommandChannelError.unavailable
            }
            data.append(contentsOf: buffer.prefix(readCount))
        }
        return data
    }
}
