import Foundation
import os

private let logger = Logger(subsystem: "com.lucky.AgentDashboard", category: "CodexTranscriptReader")

/// 读取 codex CLI 的 session rollout 文件,推断状态 / token / 当前轮起始时间。
///
/// codex 无 Claude Code 的 hook 系统,所有信息都在
/// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` 的 JSONL 里:
/// - `session_meta`(首行)含 cwd,用于匹配进程
/// - 每个 turn 由 `task_started` / `task_complete` 成对包裹
/// - `token_count` 事件含累计 `total_token_usage`(取最后一条即可)
///
/// 无实例可变状态,可安全跨 actor 使用;状态解析采用 tail 读取。
final class CodexTranscriptReader: Sendable {
    struct CodexState {
        let status: AgentStatus
        let tokenUsage: TokenUsage?
        /// 当前轮起始时间;nil 表示轮已结束或无法判定 → 不显示运行时间。
        let turnStart: Date?
    }

    struct SessionCandidate {
        let path: String
        let startedAt: Date
        let mtime: Date
    }

    struct SessionMetadata {
        let cwd: String
        let startedAt: Date?
    }

    /// codex timestamp 为 ISO8601 UTC(如 "2026-07-08T03:30:05.287Z")。
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 按 cwd + 进程启动时间匹配 rollout。同 cwd 多实例通过 excluding 保证一对一分配。
    /// 扫最近 7 天并额外包含进程启动日,支持长期存活的 Codex。
    func findSessionPath(cwd: String, processStartedAt: Date, excluding: Set<String>) -> String? {
        let cal = Calendar.current
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [SessionCandidate] = []
        var totalRollouts = 0
        var directories: Set<String> = []

        let recentDays = (0..<7).compactMap { cal.date(byAdding: .day, value: -$0, to: Date()) }
        for day in recentDays + [processStartedAt] {
            let comps = cal.dateComponents([.year, .month, .day], from: day)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { continue }
            let dir = String(format: "%@/.codex/sessions/%04d/%02d/%02d", home, y, m, d)
            guard directories.insert(dir).inserted else { continue }
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            let rollouts = entries.filter { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
            totalRollouts += rollouts.count

            for name in rollouts {
                let path = "\(dir)/\(name)"
                guard let metadata = readSessionMetadata(path: path), metadata.cwd == cwd else { continue }
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                let mtime = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
                let startedAt = metadata.startedAt
                    ?? (attrs?[.creationDate] as? Date)
                    ?? mtime
                candidates.append(SessionCandidate(path: path, startedAt: startedAt, mtime: mtime))
            }
        }

        let selected = Self.selectSessionPath(
            candidates: candidates, processStartedAt: processStartedAt, excluding: excluding
        )
        logger.debug("FINDSESSION cwd=\(cwd, privacy: .public) rollouts=\(totalRollouts) matched=\(candidates.count) -> \(selected ?? "nil", privacy: .public)")
        return selected
    }

    /// 选择启动时间最接近进程的 rollout。超过 10 分钟视为旧会话,等待新文件出现。
    static func selectSessionPath(
        candidates: [SessionCandidate], processStartedAt: Date, excluding: Set<String>
    ) -> String? {
        let available = candidates.filter { !excluding.contains($0.path) }
        guard let best = available.min(by: {
            let lhsDelta = abs($0.startedAt.timeIntervalSince(processStartedAt))
            let rhsDelta = abs($1.startedAt.timeIntervalSince(processStartedAt))
            if lhsDelta != rhsDelta { return lhsDelta < rhsDelta }
            return $0.mtime > $1.mtime
        }) else { return nil }
        guard abs(best.startedAt.timeIntervalSince(processStartedAt)) <= 10 * 60 else { return nil }
        return best.path
    }

    /// 读 session 文件首行 session_meta 的 cwd 与启动时间。
    /// session_meta 行含巨大的 base_instructions(整行可达数十 KB),不能整行 JSON 解析;
    /// 目标字段在 payload 开头,所以只读 4KB 用正则提取。String(decoding:) 容忍
    /// 4KB 边界截断 UTF-8 字符,避免中文内容导致整段解码失败。
    private static let cwdRegex: NSRegularExpression = {
        // 匹配 "cwd":"<value>",value 支持转义字符。
        try! NSRegularExpression(pattern: #"\"cwd\"\s*:\s*\"((?:\\.|[^\"\\])*)\""#)
    }()

    private static let timestampRegex = try! NSRegularExpression(
        pattern: #"\"timestamp\"\s*:\s*\"([^\"]+)\""#
    )

    private func readSessionMetadata(path: String) -> SessionMetadata? {
        guard let fileHandle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { fileHandle.closeFile() }
        let head = fileHandle.readData(ofLength: 4096)
        return Self.sessionMetadata(from: head)
    }

    static func sessionMetadata(from head: Data) -> SessionMetadata? {
        let str = String(decoding: head, as: UTF8.self)
        let range = NSRange(str.startIndex..., in: str)
        guard let m = Self.cwdRegex.firstMatch(in: str, range: range),
              let r = Range(m.range(at: 1), in: str) else { return nil }
        let cwd = Self.unescapeJSONString(String(str[r]))

        var startedAt: Date?
        if let match = Self.timestampRegex.firstMatch(in: str, range: range),
           let tsRange = Range(match.range(at: 1), in: str) {
            startedAt = Self.isoFormatter.date(from: String(str[tsRange]))
        }
        return SessionMetadata(cwd: cwd, startedAt: startedAt)
    }

    /// 简易 JSON 字符串反转义(macOS 路径常见 \" \\ \/,其余Unicode原样保留)。
    static func unescapeJSONString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\\"", with: "\"")
         .replacingOccurrences(of: "\\\\", with: "\\")
         .replacingOccurrences(of: "\\/", with: "/")
    }

    /// 读 session,推断 状态 + token + 轮起始时间。
    /// 渐进扩大读取窗口:多数 turn 在 64KB 内一次搞定;单 turn 超大(连续工具/大输出)时
    /// 逐步扩大到含本轮 task_started —— 之前只读固定 64KB,长 turn 的 task_started 被挤出
    /// 会导致状态判错/turnStart 丢失。
    func readState(transcriptPath: String) -> CodexState? {
        guard let fileHandle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: transcriptPath)) else { return nil }
        defer { fileHandle.closeFile() }
        let fileSize = fileHandle.seekToEndOfFile()
        guard fileSize > 0 else { return nil }

        let steps: [UInt64] = [65_536, 262_144, 1_048_576, 4_194_304]
        var state: CodexState?
        for size in steps {
            let readSize = min(size, fileSize)
            let r = Self.parseTail(fileHandle: fileHandle, fileSize: fileSize, readSize: readSize)
            state = r.state
            if r.complete || readSize >= fileSize { break }
        }
        if state == nil {
            state = Self.parseTail(fileHandle: fileHandle, fileSize: fileSize, readSize: fileSize).state
        }
        logger.debug("READSTATE status=\(state?.status.label ?? "nil", privacy: .public) token=\(state?.tokenUsage?.total.description ?? "-", privacy: .public) turnStart=\(state?.turnStart != nil, privacy: .public)")
        return state
    }

    /// 读尾部 readSize 字节解析。complete = 状态完整(idle,或 active 且拿到本轮 task_started);
    /// false = 范围不够(缺 event_msg 或 task_started),调用方应扩大窗口重试。
    private static func parseTail(fileHandle: FileHandle, fileSize: UInt64, readSize: UInt64) -> (state: CodexState?, complete: Bool) {
        let offset = fileSize - readSize
        fileHandle.seek(toFileOffset: offset)
        let tailData = fileHandle.readDataToEndOfFile()

        // 若从中间起读,跳到第一个完整行,避免半行 JSON。
        let validData: Data
        if offset > 0, let newlineIndex = tailData.firstIndex(of: 0x0A) {
            validData = tailData[tailData.index(after: newlineIndex)...]
        } else {
            validData = tailData
        }
        guard let tailString = String(data: validData, encoding: .utf8) else { return (nil, false) }
        let lines = tailString.components(separatedBy: "\n").filter { !$0.isEmpty }

        var lastEventMsgType: String?
        var lastTaskStartedTime: Date?
        /// 最后一个 task_started 之后是否出现过 task_complete(决定本轮是否还活跃)。
        var completedAfterLastStarted = false
        var lastTokenUsage: TokenUsage?
        /// 尚未收到对应 output 的 require_escalated 工具调用。
        var pendingApprovalCallIds: Set<String> = []
        var hasPendingApprovalWithoutCallId = false

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = json["type"] as? String
            let payload = json["payload"] as? [String: Any]
            let ts = (json["timestamp"] as? String).flatMap { Self.isoFormatter.date(from: $0) }

            if type == "response_item", let pt = payload?["type"] as? String {
                if pt == "function_call" || pt == "custom_tool_call" {
                    // Legacy function_call stores JSON in `arguments`; current
                    // custom_tool_call stores the same tool input in `input`.
                    let args = (payload?["arguments"] as? String)
                        ?? (payload?["input"] as? String)
                        ?? ""
                    if Self.requiresEscalation(args) {
                        if let callId = payload?["call_id"] as? String, !callId.isEmpty {
                            pendingApprovalCallIds.insert(callId)
                        } else {
                            hasPendingApprovalWithoutCallId = true
                        }
                    }
                } else if pt == "function_call_output" || pt == "custom_tool_call_output" {
                    if let callId = payload?["call_id"] as? String, !callId.isEmpty {
                        pendingApprovalCallIds.remove(callId)
                    } else {
                        hasPendingApprovalWithoutCallId = false
                    }
                }
            }

            guard type == "event_msg" else { continue }
            let pt = payload?["type"] as? String
            guard let pt else { continue }
            lastEventMsgType = pt

            switch pt {
            case "task_started":
                lastTaskStartedTime = ts
                completedAfterLastStarted = false
                pendingApprovalCallIds.removeAll()
                hasPendingApprovalWithoutCallId = false
            case "task_complete":
                if lastTaskStartedTime != nil { completedAfterLastStarted = true }
                pendingApprovalCallIds.removeAll()
                hasPendingApprovalWithoutCallId = false
            case "token_count":
                if let info = payload?["info"] as? [String: Any],
                   let usage = info["total_token_usage"] as? [String: Any] {
                    lastTokenUsage = Self.usage(from: usage)
                }
            default:
                break
            }
        }

        guard let lastType = lastEventMsgType else { return (nil, false) }

        let status: AgentStatus
        let isConfirming = !pendingApprovalCallIds.isEmpty || hasPendingApprovalWithoutCallId
        if isConfirming {
            status = .confirming
        } else {
            switch lastType {
            case "task_complete":                  status = .idle
            case "user_message":                   status = .thinking
            case "agent_message", "token_count":   status = .crafting
            default:                               status = .running   // task_started / turn_context 等
            }
        }

        let turnStart: Date?
        if status == .idle || completedAfterLastStarted {
            turnStart = nil
        } else {
            turnStart = lastTaskStartedTime
        }

        let complete = (status == .idle) || (turnStart != nil)
        return (CodexState(status: status, tokenUsage: lastTokenUsage, turnStart: turnStart), complete)
    }

    /// Legacy calls contain a JSON argument object. Current custom calls contain
    /// generated JavaScript source, where property quotes inside command strings
    /// are escaped; matching the unescaped property avoids command-text false positives.
    static func requiresEscalation(_ raw: String) -> Bool {
        if let data = raw.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (dict["sandbox_permissions"] as? String) == "require_escalated"
        }
        return raw.contains(#""sandbox_permissions":"require_escalated""#)
    }

    /// codex total_token_usage → TokenUsage。
    /// 保证 total == codex total_tokens:input 拆出 cached 部分,reasoning 折进 output。
    static func usage(from d: [String: Any]) -> TokenUsage {
        let input = intField(d, "input_tokens")
        let cached = intField(d, "cached_input_tokens")
        let output = intField(d, "output_tokens")
        let reasoning = intField(d, "reasoning_output_tokens")
        return TokenUsage(
            inputTokens: max(0, input - cached),
            cacheCreationTokens: 0,
            cacheReadTokens: cached,
            outputTokens: output + reasoning,
            model: "codex"
        )
    }

    private static func intField(_ d: [String: Any], _ key: String) -> Int {
        if let n = d[key] as? Int { return n }
        if let n = d[key] as? NSNumber { return n.intValue }
        return 0
    }
}
