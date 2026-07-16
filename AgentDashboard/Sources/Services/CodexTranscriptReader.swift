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
    private let approvalResolver: CodexApprovalResolver

    init(approvalEvaluator: any CodexExecPolicyEvaluating = CodexExecPolicyEvaluator()) {
        approvalResolver = CodexApprovalResolver(evaluator: approvalEvaluator)
    }

    struct CodexState {
        /// rollout 首行 session_meta 中的稳定会话身份。
        let sessionId: String?
        let status: AgentStatus
        let tokenUsage: TokenUsage?
        /// 当前轮起始时间;nil 表示轮已结束或无法判定 → 不显示运行时间。
        let turnStart: Date?
        /// 最近一轮的结束原因；active turn 为 nil。
        let turnOutcome: AgentTurnOutcome?
    }

    struct SessionCandidate {
        let path: String
        let startedAt: Date
        let mtime: Date
    }

    struct SessionMetadata {
        let sessionId: String?
        let cwd: String
        let startedAt: Date?
    }

    /// 尚未收到对应 output 的普通工具调用。sequence 用于并行调用时稳定选择
    /// 最近启动的前台动作；不能只保存一个状态，否则较早调用的 output 会误清掉
    /// 仍在运行的较新调用。
    private struct ActiveToolCall {
        let status: AgentStatus
        let sequence: Int
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

    private static let sessionIdRegex = try! NSRegularExpression(
        pattern: #"\"session_id\"\s*:\s*\"([^\"]+)\""#
    )

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

        var sessionId: String?
        if let match = Self.sessionIdRegex.firstMatch(in: str, range: range),
           let idRange = Range(match.range(at: 1), in: str) {
            sessionId = Self.unescapeJSONString(String(str[idRange]))
        }

        var startedAt: Date?
        if let match = Self.timestampRegex.firstMatch(in: str, range: range),
           let tsRange = Range(match.range(at: 1), in: str) {
            startedAt = Self.isoFormatter.date(from: String(str[tsRange]))
        }
        return SessionMetadata(sessionId: sessionId, cwd: cwd, startedAt: startedAt)
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

        fileHandle.seek(toFileOffset: 0)
        let sessionId = Self.sessionMetadata(
            from: fileHandle.readData(ofLength: 4096)
        )?.sessionId
        let fileSize = fileHandle.seekToEndOfFile()
        guard fileSize > 0 else { return nil }

        let steps: [UInt64] = [65_536, 262_144, 1_048_576, 4_194_304]
        var state: CodexState?
        for size in steps {
            let readSize = min(size, fileSize)
            let r = Self.parseTail(
                fileHandle: fileHandle, fileSize: fileSize, readSize: readSize,
                approvalResolver: approvalResolver, sessionId: sessionId
            )
            state = r.state
            if r.complete || readSize >= fileSize { break }
        }
        if state == nil {
            state = Self.parseTail(
                fileHandle: fileHandle, fileSize: fileSize, readSize: fileSize,
                approvalResolver: approvalResolver, sessionId: sessionId
            ).state
        }
        logger.debug("READSTATE status=\(state?.status.label ?? "nil", privacy: .public) token=\(state?.tokenUsage?.total.description ?? "-", privacy: .public) turnStart=\(state?.turnStart != nil, privacy: .public)")
        return state
    }

    /// 读尾部 readSize 字节解析。complete = 状态完整(idle,或 active 且拿到本轮 task_started);
    /// false = 范围不够(缺 event_msg 或 task_started),调用方应扩大窗口重试。
    private static func parseTail(
        fileHandle: FileHandle,
        fileSize: UInt64,
        readSize: UInt64,
        approvalResolver: CodexApprovalResolver,
        sessionId: String?
    ) -> (state: CodexState?, complete: Bool) {
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
        /// 最后一个 task_started 之后是否已正常完成或被中断。
        var endedAfterLastStarted = false
        var turnOutcome: AgentTurnOutcome?
        var lastTokenUsage: TokenUsage?
        /// 尚未收到对应 output、正在等待用户操作的工具调用。
        /// 包括权限批准与显式问题/安装选择，不把普通工具调用视为 confirming。
        var pendingConfirmationCallIds: Set<String> = []
        var hasPendingConfirmationWithoutCallId = false
        /// 普通工具必须按 call_id 独立追踪，支持并行调用和乱序完成。
        var activeToolCalls: [String: ActiveToolCall] = [:]
        var activeToolWithoutCallId: ActiveToolCall?
        var nextToolSequence = 0
        var approvalContext = CodexApprovalContext.legacyDefault

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = json["type"] as? String
            let payload = json["payload"] as? [String: Any]
            let ts = (json["timestamp"] as? String).flatMap { Self.isoFormatter.date(from: $0) }

            if type == "turn_context", let payload {
                approvalContext = CodexApprovalContext.parse(payload)
            }

            if type == "response_item", let pt = payload?["type"] as? String {
                if pt == "function_call" || pt == "custom_tool_call" {
                    // Legacy function_call stores JSON in `arguments`; current
                    // custom_tool_call stores the same tool input in `input`.
                    let input = (payload?["arguments"] as? String)
                        ?? (payload?["input"] as? String)
                        ?? ""
                    let toolName = payload?["name"] as? String
                    let callId = payload?["call_id"] as? String
                    nextToolSequence += 1
                    let escalationRequests = Self.escalationRequests(from: input)
                    let confirmationDecision = approvalResolver.decision(
                        isInteractiveTool: Self.isInteractiveTool(toolName),
                        escalationCommands: escalationRequests.map(\.command),
                        context: approvalContext
                    )
                    if confirmationDecision == .required {
                        if let callId, !callId.isEmpty {
                            pendingConfirmationCallIds.insert(callId)
                        } else {
                            hasPendingConfirmationWithoutCallId = true
                        }
                    } else {
                        if confirmationDecision == .unknown,
                           !escalationRequests.isEmpty {
                            logger.warning("审批规则无法证明需要用户操作，降级为普通活动 tool=\(toolName ?? "-", privacy: .public)")
                        }
                        let call = ActiveToolCall(
                            status: Self.activityStatus(toolName: toolName, input: input),
                            sequence: nextToolSequence
                        )
                        if let callId, !callId.isEmpty {
                            activeToolCalls[callId] = call
                        } else {
                            // 旧格式没有 call_id，只能保留最近一个并由无 id output 清除。
                            activeToolWithoutCallId = call
                        }
                    }
                } else if pt == "function_call_output" || pt == "custom_tool_call_output" {
                    if let callId = payload?["call_id"] as? String, !callId.isEmpty {
                        pendingConfirmationCallIds.remove(callId)
                        activeToolCalls.removeValue(forKey: callId)
                    } else {
                        hasPendingConfirmationWithoutCallId = false
                        activeToolWithoutCallId = nil
                    }
                }
            }

            guard type == "event_msg" else { continue }
            let pt = payload?["type"] as? String
            guard let pt else { continue }

            // thread_rolled_back 是 turn_aborted 后的历史回滚记录，不代表新的活动状态，
            // 不能覆盖刚刚确定的 aborted 终态。
            // token_count 只是遥测，工具专用的 *_end 紧跟在 response_item output
            // 附近；它们都不应覆盖最后一个语义事件。否则工具刚结束会短暂回跳
            // Running，而不是恢复到模型生成状态。
            if !Self.nonSemanticEventTypes.contains(pt) {
                lastEventMsgType = pt
            }

            switch pt {
            case "task_started":
                lastTaskStartedTime = ts
                endedAfterLastStarted = false
                turnOutcome = nil
                approvalContext = .legacyDefault
                pendingConfirmationCallIds.removeAll()
                hasPendingConfirmationWithoutCallId = false
                activeToolCalls.removeAll()
                activeToolWithoutCallId = nil
            case "task_complete":
                if lastTaskStartedTime != nil { endedAfterLastStarted = true }
                turnOutcome = .completed
                pendingConfirmationCallIds.removeAll()
                hasPendingConfirmationWithoutCallId = false
                activeToolCalls.removeAll()
                activeToolWithoutCallId = nil
            case "turn_aborted":
                endedAfterLastStarted = true
                turnOutcome = .aborted
                pendingConfirmationCallIds.removeAll()
                hasPendingConfirmationWithoutCallId = false
                activeToolCalls.removeAll()
                activeToolWithoutCallId = nil
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
        let isConfirming = !pendingConfirmationCallIds.isEmpty || hasPendingConfirmationWithoutCallId
        let latestActiveTool = (Array(activeToolCalls.values) + [activeToolWithoutCallId].compactMap { $0 })
            .max { $0.sequence < $1.sequence }
        if turnOutcome != nil {
            status = .idle
        } else if isConfirming {
            status = .confirming
        } else if let latestActiveTool {
            status = latestActiveTool.status
        } else {
            switch lastType {
            case "task_complete":                  status = .idle
            case "user_message":                   status = .thinking
            case "agent_message":                  status = .crafting
            case "sub_agent_activity":             status = .processing
            default:                               status = .running   // task_started / turn_context 等
            }
        }

        let turnStart: Date?
        if status == .idle || endedAfterLastStarted {
            turnStart = nil
        } else {
            turnStart = lastTaskStartedTime
        }

        let complete = (status == .idle) || (turnStart != nil)
        return (
            CodexState(
                sessionId: sessionId,
                status: status,
                tokenUsage: lastTokenUsage,
                turnStart: turnStart,
                turnOutcome: turnOutcome
            ),
            complete
        )
    }

    /// Codex 只有两类工具调用会阻塞等待用户：
    /// 1. 工具输入显式请求沙箱外权限；
    /// 2. Codex 客户端提供的用户交互工具（问题选择、插件安装确认）。
    ///
    /// 交互工具使用明确白名单，避免按 `request_*` 前缀误判普通工具。
    private static let interactiveToolNames: Set<String> = [
        "request_user_input",
        "request_plugin_install",
    ]

    private static let nonSemanticEventTypes: Set<String> = [
        "thread_rolled_back", "token_count", "patch_apply_end",
        "web_search_end", "mcp_tool_call_end",
    ]

    static func isInteractiveTool(_ toolName: String?) -> Bool {
        guard let toolName else { return false }
        return interactiveToolNames.contains(toolName)
    }

    /// 将 Codex 工具调用映射为细粒度状态。优先使用工具身份本身能够证明的语义；
    /// shell 仅对白名单内、完整 argv 可证明的只读日志命令细分为 Reading。
    ///
    /// 当前 custom_tool_call 的外层 name 通常只是 `exec`，真实工具名位于生成的
    /// JavaScript 中，因此优先使用词法分析得到的最后一个嵌套工具调用。
    static func activityStatus(toolName: String?, input: String) -> AgentStatus {
        let nestedToolNames = calledToolNames(inJavaScript: input)
        if nestedToolNames.last == "exec_command",
           let command = shellCommands(from: input).last,
           let shellStatus = shellActivityStatus(command) {
            return shellStatus
        }
        if let nestedStatus = nestedToolNames.compactMap(toolStatus(for:)).last {
            return nestedStatus
        }
        if let toolName, ["exec_command", "shell"].contains(toolName),
           let command = shellCommands(from: input).last,
           let shellStatus = shellActivityStatus(command) {
            return shellStatus
        }
        if let toolName, let directStatus = toolStatus(for: toolName) {
            return directStatus
        }
        return .busy
    }

    private static func toolStatus(for toolName: String) -> AgentStatus? {
        switch toolName {
        case "apply_patch":
            return .editing
        case "web__run", "tool_search":
            return .searching
        case "view_image", "read_mcp_resource", "list_mcp_resources",
             "list_mcp_resource_templates":
            return .reading
        case "create_goal", "get_goal", "update_goal", "update_plan",
             "image_gen__imagegen", "spawn_agent", "followup_task", "send_message",
             "interrupt_agent", "list_agents", "wait_agent":
            return .processing
        case "exec", "exec_command", "write_stdin", "wait", "shell":
            return .running
        default:
            return nil
        }
    }

    /// 只对能由 argv 高置信证明的只读日志命令细分 Reading。无法解析、包含
    /// 非只读 segment 或其他 shell 语义时返回 nil，由上层保守显示 Running。
    private static func shellActivityStatus(_ command: String, depth: Int = 0) -> AgentStatus? {
        guard depth < 2,
              let segments = CodexShellCommandParser.parse(command),
              !segments.isEmpty else { return nil }

        if segments.count == 1,
           segments[0].tokens.count == 3,
           ["/bin/zsh", "/bin/bash", "zsh", "bash"].contains(segments[0].tokens[0]),
           segments[0].tokens[1] == "-lc" {
            return shellActivityStatus(segments[0].tokens[2], depth: depth + 1)
        }

        var foundLogReader = false
        for segment in segments {
            guard let executable = segment.tokens.first else { return nil }
            let basename = URL(fileURLWithPath: executable).lastPathComponent
            if basename == "log", segment.tokens.count >= 2,
               ["show", "stream"].contains(segment.tokens[1]) {
                foundLogReader = true
                continue
            }
            guard ["tail", "head", "rg", "grep", "wc", "cut"].contains(basename) else {
                return nil
            }
        }
        return foundLogReader ? .reading : nil
    }

    /// Legacy calls contain a JSON argument object. Current custom calls may contain
    /// generated JavaScript source with either quoted or unquoted property names.
    /// Tokenizing the source avoids treating the same text inside `cmd`/comments as approval.
    static func requiresEscalation(_ raw: String) -> Bool {
        !escalationRequests(from: raw).isEmpty
    }

    struct EscalationRequest: Sendable, Equatable {
        let command: String?
    }

    static func escalationRequest(from raw: String) -> EscalationRequest? {
        escalationRequests(from: raw).first
    }

    /// 一个 unified custom_tool_call 内可能包含 Promise.all 和多条 exec_command。
    /// 每条命令必须在自己的参数对象内关联 sandbox_permissions；不能拿整段代码
    /// 中出现的第一条 cmd，否则会用 A 命令的规则判断 B 命令的确认状态。
    static func escalationRequests(from raw: String) -> [EscalationRequest] {
        if let data = raw.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            guard (dict["sandbox_permissions"] as? String) == "require_escalated" else {
                return []
            }
            return [EscalationRequest(command: commandString(from: dict))]
        }

        let tokens = tokenizeJavaScript(raw)
        var requests: [EscalationRequest] = []
        for range in execCommandObjectRanges(tokens: tokens) {
            guard objectStringProperty(
                named: "sandbox_permissions", tokens: tokens, range: range
            ) == "require_escalated" else { continue }
            requests.append(EscalationRequest(
                command: objectStringProperty(
                    named: "cmd", tokens: tokens, range: range
                ) ?? objectStringProperty(
                    named: "command", tokens: tokens, range: range
                )
            ))
        }
        return requests
    }

    private static func shellCommands(from raw: String) -> [String] {
        if let data = raw.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return commandString(from: dict).map { [$0] } ?? []
        }

        let tokens = tokenizeJavaScript(raw)
        return execCommandObjectRanges(tokens: tokens).compactMap { range in
            objectStringProperty(named: "cmd", tokens: tokens, range: range)
                ?? objectStringProperty(named: "command", tokens: tokens, range: range)
        }
    }

    private enum JavaScriptToken: Equatable {
        case word(String)
        case string(String)
        case symbol(UInt8)
    }

    private static func commandString(from dictionary: [String: Any]) -> String? {
        if let command = dictionary["cmd"] as? String { return command }
        if let command = dictionary["command"] as? String { return command }
        if let command = dictionary["command"] as? [String] {
            return command.map(shellQuote).joined(separator: " ")
        }
        return nil
    }

    private static func shellQuote(_ token: String) -> String {
        if token.range(of: #"^[A-Za-z0-9_./:@%+=,-]+$"#, options: .regularExpression) != nil {
            return token
        }
        return "'\(token.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func execCommandObjectRanges(
        tokens: [JavaScriptToken]
    ) -> [ClosedRange<Int>] {
        guard tokens.count >= 6 else { return [] }
        var ranges: [ClosedRange<Int>] = []

        for index in 0...(tokens.count - 6) {
            guard tokens[index] == .word("tools"),
                  tokens[index + 1] == .symbol(0x2E), // .
                  tokens[index + 2] == .word("exec_command"),
                  tokens[index + 3] == .symbol(0x28), // (
                  tokens[index + 4] == .symbol(0x7B) else { continue } // {

            var depth = 0
            for end in (index + 4)..<tokens.count {
                if tokens[end] == .symbol(0x7B) { depth += 1 }
                if tokens[end] == .symbol(0x7D) { // }
                    depth -= 1
                    if depth == 0 {
                        ranges.append((index + 4)...end)
                        break
                    }
                }
            }
        }
        return ranges
    }

    /// 只读取参数对象的第一层字符串属性；嵌套对象中的同名字段不属于
    /// exec_command 本身，必须忽略。
    private static func objectStringProperty(
        named name: String,
        tokens: [JavaScriptToken],
        range: ClosedRange<Int>
    ) -> String? {
        guard range.count >= 4 else { return nil }
        var braceDepth = 0
        var bracketDepth = 0
        var index = range.lowerBound

        while index <= range.upperBound {
            switch tokens[index] {
            case .symbol(0x7B): braceDepth += 1 // {
            case .symbol(0x7D): braceDepth -= 1 // }
            case .symbol(0x5B): bracketDepth += 1 // [
            case .symbol(0x5D): bracketDepth -= 1 // ]
            default: break
            }

            if braceDepth == 1, bracketDepth == 0, index + 2 <= range.upperBound {
                let key: String?
                switch tokens[index] {
                case let .word(value), let .string(value): key = value
                default: key = nil
                }
                let memberStart = index == range.lowerBound + 1
                    || tokens[index - 1] == .symbol(0x2C) // ,
                if memberStart, key == name,
                   tokens[index + 1] == .symbol(0x3A), // :
                   case let .string(value) = tokens[index + 2] {
                    return value
                }
            }
            index += 1
        }
        return nil
    }

    /// 提取生成代码中的 `tools.name(...)` / `collaboration.name(...)` 调用。
    /// tokenizer 会把字符串作为单个 token 并跳过注释，所以命令文本里的伪调用
    /// 不会参与状态判断。
    private static func calledToolNames(inJavaScript source: String) -> [String] {
        let tokens = tokenizeJavaScript(source)
        guard tokens.count >= 4 else { return [] }

        var names: [String] = []
        for index in 0...(tokens.count - 4) {
            let isToolNamespace = tokens[index] == .word("tools")
                || tokens[index] == .word("collaboration")
            guard isToolNamespace,
                  tokens[index + 1] == .symbol(0x2E), // .
                  case let .word(name) = tokens[index + 2],
                  tokens[index + 3] == .symbol(0x28) else { continue } // (
            names.append(name)
        }
        return names
    }

    /// Minimal lexer for generated tool-call JavaScript. String contents and comments are
    /// emitted/skipped as a unit, so property-looking text inside a shell command cannot match.
    private static func tokenizeJavaScript(_ source: String) -> [JavaScriptToken] {
        let bytes = Array(source.utf8)
        var tokens: [JavaScriptToken] = []
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]

            if isASCIIWhitespace(byte) {
                index += 1
                continue
            }

            if byte == 0x2F, index + 1 < bytes.count { // /
                if bytes[index + 1] == 0x2F { // line comment
                    index += 2
                    while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D {
                        index += 1
                    }
                    continue
                }
                if bytes[index + 1] == 0x2A { // block comment
                    index += 2
                    while index + 1 < bytes.count,
                          !(bytes[index] == 0x2A && bytes[index + 1] == 0x2F) {
                        index += 1
                    }
                    index = min(bytes.count, index + 2)
                    continue
                }
            }

            if byte == 0x22 || byte == 0x27 || byte == 0x60 { // " ' `
                let quote = byte
                index += 1
                var value: [UInt8] = []
                while index < bytes.count {
                    let current = bytes[index]
                    if current == 0x5C, index + 1 < bytes.count { // escaped byte
                        let escaped = bytes[index + 1]
                        switch escaped {
                        case 0x6E: value.append(0x0A) // n
                        case 0x72: value.append(0x0D) // r
                        case 0x74: value.append(0x09) // t
                        case 0x62: value.append(0x08) // b
                        case 0x66: value.append(0x0C) // f
                        default: value.append(escaped)
                        }
                        index += 2
                    } else if current == quote {
                        index += 1
                        break
                    } else {
                        value.append(current)
                        index += 1
                    }
                }
                tokens.append(.string(String(decoding: value, as: UTF8.self)))
                continue
            }

            if isJavaScriptIdentifierStart(byte) {
                let start = index
                index += 1
                while index < bytes.count, isJavaScriptIdentifierPart(bytes[index]) {
                    index += 1
                }
                tokens.append(.word(String(decoding: bytes[start..<index], as: UTF8.self)))
                continue
            }

            tokens.append(.symbol(byte))
            index += 1
        }

        return tokens
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isJavaScriptIdentifierStart(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
            || byte == 0x5F
            || byte == 0x24
    }

    private static func isJavaScriptIdentifierPart(_ byte: UInt8) -> Bool {
        isJavaScriptIdentifierStart(byte) || (byte >= 0x30 && byte <= 0x39)
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
