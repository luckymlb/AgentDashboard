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
/// 镜像 TranscriptTailReader / TokenStatsReader 的风格:
/// @unchecked Sendable + serial DispatchQueue 缓存 + tail 读取 + os.Logger。
final class CodexTranscriptReader: @unchecked Sendable {
    struct CodexState {
        let status: AgentStatus
        let tokenUsage: TokenUsage?
        /// 当前轮起始时间;nil 表示轮已结束或无法判定 → 不显示运行时间。
        let turnStart: Date?
    }

    private let queue = DispatchQueue(label: "com.lucky.AgentDashboard.codexCache")
    /// cwd → sessionPath(进程 cwd 稳定,可长期复用;文件消失则失效)
    private var pathCache: [String: String] = [:]

    /// codex timestamp 为 ISO8601 UTC(如 "2026-07-08T03:30:05.287Z")。
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 按 cwd 匹配 session 文件,取 mtime 最新的。扫最近 7 天目录
    /// (~/.codex/sessions/YYYY/MM/DD/),覆盖跨天存活的 codex 进程——
    /// 其 session 文件在启动那天目录,只扫「今天」会漏。
    func findSessionPath(cwd: String) -> String? {
        let cached: String? = queue.sync { pathCache[cwd] }
        if let cached = cached, FileManager.default.fileExists(atPath: cached) {
            return cached
        }

        let cal = Calendar.current
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var best: (path: String, mtime: Date)?
        var totalRollouts = 0
        var matched = 0

        for daysAgo in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: -daysAgo, to: Date()) else { continue }
            let comps = cal.dateComponents([.year, .month, .day], from: day)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { continue }
            let dir = String(format: "%@/.codex/sessions/%04d/%02d/%02d", home, y, m, d)
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            let rollouts = entries.filter { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
            totalRollouts += rollouts.count

            for name in rollouts {
                let path = "\(dir)/\(name)"
                guard let cwdInFile = readSessionCwd(path: path), cwdInFile == cwd else { continue }
                matched += 1
                let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
                    ?? Date.distantPast
                if best == nil || mtime > best!.mtime {
                    best = (path, mtime)
                }
            }
        }
        logger.debug("FINDSESSION cwd=\(cwd, privacy: .public) days=7 rollouts=\(totalRollouts) matched=\(matched) -> \(best?.path ?? "nil", privacy: .public)")

        if let best = best {
            queue.sync { pathCache[cwd] = best.path }
            return best.path
        }
        queue.sync { pathCache.removeValue(forKey: cwd) }
        return nil
    }

    /// 读 session 文件首行 session_meta 的 cwd。
    /// session_meta 行含巨大的 base_instructions(整行可达数十 KB),不能整行 JSON 解析;
    /// 而 cwd 字段在 payload 开头(前几百字节内),所以只读 4KB 用正则提取即可。
    private static let cwdRegex: NSRegularExpression = {
        // 匹配 "cwd":"<value>",value 支持转义字符。
        try! NSRegularExpression(pattern: #"\"cwd\"\s*:\s*\"((?:\\.|[^\"\\])*)\""#)
    }()

    private func readSessionCwd(path: String) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { fileHandle.closeFile() }
        let head = fileHandle.readData(ofLength: 4096)
        guard let str = String(data: head, encoding: .utf8) else { return nil }
        let range = NSRange(str.startIndex..., in: str)
        guard let m = Self.cwdRegex.firstMatch(in: str, range: range),
              let r = Range(m.range(at: 1), in: str) else { return nil }
        return Self.unescapeJSONString(String(str[r]))
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
        /// 最后一个工具调用是否需要用户授权(require_escalated)且尚未产出结果。
        var lastCallNeedsApproval = false
        var hasOutputAfterLastCall = false

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
                    lastCallNeedsApproval = args.contains("require_escalated")
                    hasOutputAfterLastCall = false
                } else if pt == "function_call_output" || pt == "custom_tool_call_output" {
                    hasOutputAfterLastCall = true
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
            case "task_complete":
                if lastTaskStartedTime != nil { completedAfterLastStarted = true }
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
        let isConfirming = lastCallNeedsApproval && !hasOutputAfterLastCall
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
