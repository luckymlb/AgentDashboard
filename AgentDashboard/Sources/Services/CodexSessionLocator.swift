import Foundation

/// 会话身份优先于 cwd：resume UUID 和进程打开的 rollout 不受会话创建日期限制。
enum CodexSessionLocator {
    static func explicitThreadID(command: String) -> String? {
        let parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let resume = parts.firstIndex(of: "resume"), resume + 1 < parts.count else { return nil }
        return parts[(resume + 1)...].first { UUID(uuidString: $0) != nil }
    }

    static func openRollout(pid: Int) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", String(pid), "-Fn"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let paths = Set(output.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("n/"), line.hasSuffix(".jsonl"), line.contains("/rollout-") else { return nil }
            return String(line.dropFirst())
        })
        return paths.count == 1 ? paths.first : nil
    }

    static func path(threadID: String) -> String? {
        guard UUID(uuidString: threadID) != nil else { return nil }
        let root = CodexRuntimeClient.codexHome.appendingPathComponent("sessions")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in files where url.lastPathComponent.hasSuffix("\(threadID).jsonl") {
            return url.path
        }
        return nil
    }
}
