import Foundation
import Darwin
import CryptoKit
import os

private let runtimeLogger = Logger(subsystem: "com.lucky.AgentDashboard", category: "CodexRuntime")

struct CodexRuntimeThread: Sendable {
    let id: String
    let path: String?
    let cwd: String
    let name: String?
    let createdAt: Date
    let updatedAt: Double
    let runtimeStatus: String
    let flags: [String]
    let socketPath: String
    let originator: String?

    static func parse(_ json: [String: Any], socketPath: String) -> CodexRuntimeThread? {
        guard let id = json["id"] as? String, UUID(uuidString: id) != nil,
              let cwd = json["cwd"] as? String,
              let status = json["status"] as? [String: Any],
              let kind = status["type"] as? String,
              ["active", "idle", "systemError"].contains(kind) else { return nil }
        // 子 Agent 是父会话的内部工作，不冒充独立桌面或终端会话。
        guard json["parentThreadId"] is NSNull || json["parentThreadId"] == nil,
              !(json["source"] is [String: Any]),
              !(json["source"] as? String ?? "").lowercased().contains("subagent") else { return nil }
        return CodexRuntimeThread(
            id: id, path: json["path"] as? String, cwd: cwd,
            name: json["name"] as? String,
            createdAt: Date(timeIntervalSince1970: (json["createdAt"] as? NSNumber)?.doubleValue ?? 0),
            updatedAt: ((json["updatedAt"] as? NSNumber)?.doubleValue ?? 0) * 1000,
            runtimeStatus: kind, flags: status["activeFlags"] as? [String] ?? [], socketPath: socketPath, originator: json["originator"] as? String
        )
    }

    func status(transcript: CodexTranscriptReader.CodexState?) -> AgentStatus {
        if runtimeStatus == "idle" { return .idle }
        if runtimeStatus == "systemError" { return .unknown }
        if flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput") { return .confirming }
        // 运行时证明仍在执行时，不采用旧 rollout 的已结束状态。
        if let transcript, transcript.status.isActive { return transcript.status }
        return .busy
    }
}

/// 连接现有服务，只调用 loaded/list 与 read；不启动服务、不恢复会话、不答复审批。
enum CodexRuntimeClient {
    static var codexHome: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static var socketPaths: [String] {
        var paths = [codexHome.appendingPathComponent("app-server-control/app-server-control.sock").path]
        if let custom = ProcessInfo.processInfo.environment["AGENTDASHBOARD_CODEX_SOCKET"] {
            paths.insert(custom, at: 0)
        }
        return Array(Set(paths)).sorted()
    }

    static func loadedThreads() -> [CodexRuntimeThread] {
        var threads: [String: CodexRuntimeThread] = [:]
        for path in socketPaths where FileManager.default.fileExists(atPath: path) {
            do {
                let connection = try CodexSocketConnection(path: path)
                var cursor: String?
                repeat {
                    var params: [String: Any] = ["limit": 100]
                    if let cursor { params["cursor"] = cursor }
                    let page = try connection.request("thread/loaded/list", params: params)
                    for id in page["data"] as? [String] ?? [] {
                        let result = try connection.request("thread/read", params: ["threadId": id, "includeTurns": false])
                        if let raw = result["thread"] as? [String: Any],
                           let thread = CodexRuntimeThread.parse(raw, socketPath: path) { threads[id] = thread }
                    }
                    cursor = page["nextCursor"] as? String
                } while cursor != nil
            } catch {
                runtimeLogger.debug("无法读取 Codex 服务: \(error.localizedDescription, privacy: .public)")
            }
        }
        return threads.values.sorted { $0.id < $1.id }
    }

    static func readThread(id: String, socketPath: String) -> CodexRuntimeThread? {
        do {
            let connection = try CodexSocketConnection(path: socketPath)
            let result = try connection.request("thread/read", params: ["threadId": id, "includeTurns": false])
            return (result["thread"] as? [String: Any]).flatMap { CodexRuntimeThread.parse($0, socketPath: socketPath) }
        } catch { return nil }
    }

    static func threadURL(id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return URL(string: "codex://threads/\(id)")
    }
}

/// 有总时限和帧大小限制的本地 Unix WebSocket。实例只在单个后台任务中使用。
private final class CodexSocketConnection {
    private enum Failure: Error { case transport, protocolError, rpc }
    private var fd: Int32 = -1
    private let deadline = Date().addingTimeInterval(5)
    private var nextID = 0

    init(path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.transport }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.transport }
        do {
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { throw Failure.transport }
            let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            try write(Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
            var header = Data()
            while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
                guard header.count < 16384 else { throw Failure.protocolError }
                header.append(try read(1))
            }
            let text = String(decoding: header, as: UTF8.self)
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            guard text.hasPrefix("HTTP/1.1 101 "), text.contains(accept) else { throw Failure.protocolError }
            _ = try request("initialize", params: ["clientInfo": ["name": "agentdashboard", "version": "1.0"], "capabilities": ["experimentalApi": true]])
            try send(["method": "initialized"])
        } catch {
            Darwin.close(fd)
            fd = -1
            throw error
        }
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        nextID += 1
        let id = nextID
        try send(["id": id, "method": method, "params": params])
        while Date() < deadline {
            let message = try receive()
            guard (message["id"] as? Int) == id else { continue }
            guard message["error"] == nil, let result = message["result"] as? [String: Any] else { throw Failure.rpc }
            return result
        }
        throw Failure.transport
    }

    private func send(_ message: [String: Any]) throws {
        try frame(opcode: 1, payload: JSONSerialization.data(withJSONObject: message))
    }

    private func frame(opcode: UInt8, payload: Data) throws {
        var data = Data([0x80 | opcode])
        if payload.count < 126 { data.append(0x80 | UInt8(payload.count)) }
        else if payload.count <= 65535 {
            data.append(0xFE)
            data.append(UInt8(payload.count >> 8)); data.append(UInt8(payload.count & 255))
        } else { throw Failure.protocolError }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        data.append(contentsOf: mask)
        data.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try write(data)
    }

    private func receive() throws -> [String: Any] {
        var accumulated = Data()
        var isText = false
        while true {
            let header = [UInt8](try read(2))
            let opcode = header[0] & 15
            var length = UInt64(header[1] & 127)
            if length == 126 { length = try read(2).reduce(0) { ($0 << 8) | UInt64($1) } }
            else if length == 127 { length = try read(8).reduce(0) { ($0 << 8) | UInt64($1) } }
            guard length <= 8_388_608, header[1] & 128 == 0 else { throw Failure.protocolError }
            let payload = try read(Int(length))
            if opcode == 8 { throw Failure.transport }
            if opcode == 9 { try frame(opcode: 10, payload: payload); continue }
            if opcode == 10 { continue }
            if opcode == 1 { isText = true }
            else if opcode != 0 || !isText { throw Failure.protocolError }
            accumulated.append(payload)
            guard accumulated.count <= 8_388_608 else { throw Failure.protocolError }
            if header[0] & 128 != 0 {
                guard let result = try JSONSerialization.jsonObject(with: accumulated) as? [String: Any] else { throw Failure.protocolError }
                return result
            }
        }
    }

    private func read(_ count: Int) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                guard Date() < deadline else { throw Failure.transport }
                let n = Darwin.recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw Failure.transport }
                offset += n
            }
        }
        return result
    }

    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                guard Date() < deadline else { throw Failure.transport }
                let n = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw Failure.transport }
                offset += n
            }
        }
    }
}
