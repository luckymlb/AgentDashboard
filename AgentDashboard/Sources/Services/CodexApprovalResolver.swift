import Foundation
import os

private let approvalLogger = Logger(
    subsystem: "com.lucky.AgentDashboard", category: "CodexApprovalResolver"
)

/// Codex 当前轮次的审批策略。它来自 rollout 的 `turn_context`，比工具输入
/// 中的 `sandbox_permissions` 更接近“是否会停下来等用户”的真实语义。
struct CodexApprovalContext: Sendable, Equatable {
    enum PromptPolicy: Sendable, Equatable {
        case enabled
        case disabled
        case unknown
    }

    enum Reviewer: Sendable, Equatable {
        case user
        case autoReview
        case unknown
    }

    var sandboxApproval: PromptPolicy
    var ruleApproval: PromptPolicy
    var reviewer: Reviewer
    var cwd: String?

    /// 兼容旧 rollout：旧格式没有 turn_context，但当时默认仍是用户审批。
    static let legacyDefault = CodexApprovalContext(
        sandboxApproval: .enabled, ruleApproval: .enabled,
        reviewer: .user, cwd: nil
    )

    static func parse(_ payload: [String: Any]) -> CodexApprovalContext {
        let sandboxApproval: PromptPolicy
        let ruleApproval: PromptPolicy
        if let raw = payload["approval_policy"] as? String {
            let promptPolicy: PromptPolicy = raw == "never" ? .disabled : .enabled
            sandboxApproval = promptPolicy
            ruleApproval = promptPolicy
        } else if let policyObject = payload["approval_policy"] as? [String: Any],
                  let granular = policyObject["granular"] as? [String: Any] {
            sandboxApproval = promptPolicy(granular["sandbox_approval"])
            ruleApproval = promptPolicy(granular["rules"])
        } else if payload["approval_policy"] == nil {
            // approvals_reviewer 引入前的 rollout 没有完整 turn_context 字段，
            // 当时交互审批是默认行为。
            sandboxApproval = .enabled
            ruleApproval = .enabled
        } else {
            sandboxApproval = .unknown
            ruleApproval = .unknown
        }

        let reviewer: Reviewer
        switch payload["approvals_reviewer"] as? String {
        case "user": reviewer = .user
        case "auto_review": reviewer = .autoReview
        case nil: reviewer = .user
        default: reviewer = .unknown
        }

        return CodexApprovalContext(
            sandboxApproval: sandboxApproval,
            ruleApproval: ruleApproval,
            reviewer: reviewer,
            cwd: payload["cwd"] as? String
        )
    }

    private static func promptPolicy(_ value: Any?) -> PromptPolicy {
        guard let enabled = value as? Bool else { return .unknown }
        return enabled ? .enabled : .disabled
    }
}

enum CodexExecPolicyDecision: Sendable, Equatable {
    case allow
    case prompt
    case forbidden
    case noMatch
    case unavailable
}

protocol CodexExecPolicyEvaluating: Sendable {
    func decision(for shellCommand: String, cwd: String?) -> CodexExecPolicyDecision
}

/// 用户阻塞必须有正证据。`unknown` 不得触发通知；调用方将它作为普通活动处理。
enum CodexUserConfirmationDecision: Sendable, Equatable {
    case required
    case notRequired
    case unknown
}

final class CodexApprovalResolver: Sendable {
    private let evaluator: any CodexExecPolicyEvaluating

    init(evaluator: any CodexExecPolicyEvaluating = CodexExecPolicyEvaluator()) {
        self.evaluator = evaluator
    }

    func decision(
        isInteractiveTool: Bool,
        escalationCommands: [String?],
        context: CodexApprovalContext
    ) -> CodexUserConfirmationDecision {
        if isInteractiveTool {
            return .required
        }
        guard !escalationCommands.isEmpty else {
            return .notRequired
        }

        guard context.reviewer != .autoReview else {
            return .notRequired
        }
        guard context.reviewer == .user else {
            return .unknown
        }

        var hasUnknown = false
        for command in escalationCommands {
            guard let command, !command.isEmpty else {
                hasUnknown = true
                continue
            }
            switch evaluator.decision(for: command, cwd: context.cwd) {
            case .prompt:
                // 同一个 custom_tool_call 可能并行发起多条命令；只要一条
                // 确实等待用户，整个调用就仍处于 Confirming。
                switch context.ruleApproval {
                case .enabled: return .required
                case .unknown: hasUnknown = true
                case .disabled: break
                }
            case .noMatch:
                switch context.sandboxApproval {
                case .enabled: return .required
                case .unknown: hasUnknown = true
                case .disabled: break
                }
            case .unavailable:
                hasUnknown = true
            case .allow, .forbidden:
                break
            }
        }
        return hasUnknown ? .unknown : .notRequired
    }
}

/// 使用 Codex 自带的 execpolicy 引擎检查活动 `.rules`，避免在 Dashboard 中
/// 重写 Starlark 规则语义。这里只做策略检查，不执行目标命令。
final class CodexExecPolicyEvaluator: @unchecked Sendable, CodexExecPolicyEvaluating {
    private struct CacheKey: Hashable {
        let command: String
        let cwd: String
        let rulesSignature: String
    }

    private let lock = NSLock()
    private var cache: [CacheKey: CodexExecPolicyDecision] = [:]
    private var unavailableUntil: Date?

    func decision(for shellCommand: String, cwd: String?) -> CodexExecPolicyDecision {
        guard let executable = Self.codexExecutable() else {
            return .unavailable
        }
        let segments = CodexShellCommandParser.parse(shellCommand)
            ?? [.init(tokens: ["/bin/zsh", "-lc", shellCommand])]
        guard !segments.isEmpty else { return .unavailable }

        let rulePaths = Self.activeRulePaths(cwd: cwd)
        // execpolicy CLI 要求至少一个 --rules 参数；没有任何活动规则时，
        // 语义就是“未命中”，而不是引擎不可用。
        guard !rulePaths.isEmpty else { return .noMatch }
        let signature = Self.rulesSignature(rulePaths)
        let key = CacheKey(command: shellCommand, cwd: cwd ?? "", rulesSignature: signature)

        lock.lock()
        if let unavailableUntil, unavailableUntil > Date() {
            lock.unlock()
            return .unavailable
        }
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var combined: CodexExecPolicyDecision = .allow
        for segment in segments {
            let result = Self.evaluate(
                segment: segment, executable: executable, rulePaths: rulePaths
            )
            switch result {
            case .forbidden:
                combined = .forbidden
            case .prompt:
                if combined != .forbidden { combined = .prompt }
            case .noMatch:
                if combined != .forbidden && combined != .prompt { combined = .noMatch }
            case .unavailable:
                combined = .unavailable
            case .allow:
                break
            }
            if combined == .forbidden || combined == .unavailable { break }
        }

        // 暂时性 CLI/解析失败不能永久缓存，否则一次故障会让真实确认一直漏报。
        if combined != .unavailable {
            lock.lock()
            unavailableUntil = nil
            cache[key] = combined
            // rulesSignature 变化会自然失效旧 key；限制体积避免长期会话无限增长。
            if cache.count > 256 {
                cache = [key: combined]
            }
            lock.unlock()
        } else {
            // CLI 故障时给整个 evaluator 一个短冷却窗口，避免 Promise.all 中
            // 多条命令各自等待超时，拖慢整轮进程扫描。
            lock.lock()
            unavailableUntil = Date().addingTimeInterval(2)
            lock.unlock()
        }
        return combined
    }

    private static func evaluate(
        segment: CodexShellCommandParser.Segment,
        executable: String,
        rulePaths: [String]
    ) -> CodexExecPolicyDecision {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        var arguments = ["execpolicy", "check", "--pretty"]
        for path in rulePaths {
            arguments.append(contentsOf: ["--rules", path])
        }
        arguments.append("--")
        arguments.append(contentsOf: segment.tokens)
        process.arguments = arguments

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            approvalLogger.warning("execpolicy 启动失败: \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }

        // 状态扫描不能被外部 CLI 无限阻塞。execpolicy 是纯本地检查，正常应在
        // 数十毫秒内完成；超时后本轮返回 unknown，下次扫描会重试。
        if finished.wait(timeout: .now() + 2) == .timedOut {
            process.terminate()
            approvalLogger.warning("execpolicy 检查超时")
            return .unavailable
        }

        guard process.terminationStatus == 0 else { return .unavailable }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unavailable
        }

        let rawDecision = json["decision"] as? String
        if rawDecision == "forbidden" { return .forbidden }
        if rawDecision == "prompt" { return .prompt }
        guard rawDecision == "allow" else { return .noMatch }

        return .allow
    }

    private static func codexExecutable() -> String? {
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        if let fixed = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) {
            return fixed
        }
        return ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map { String($0) + "/codex" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func activeRulePaths(cwd: String?) -> [String] {
        var directories: [URL] = []
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        directories.append(home.appendingPathComponent("rules"))

        if let cwd,
           let projectRoot = trustedProjectRoot(cwd: cwd, codexHome: home) {
            var url = URL(fileURLWithPath: cwd).standardizedFileURL
            while url.path.hasPrefix(projectRoot.path) {
                directories.append(url.appendingPathComponent(".codex/rules"))
                if url.path == projectRoot.path { break }
                url.deleteLastPathComponent()
            }
        }

        var paths: Set<String> = []
        for directory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ) else { continue }
            for entry in entries where entry.pathExtension == "rules" {
                paths.insert(entry.path)
            }
        }
        return paths.sorted()
    }

    /// project-local rules 只有在 Codex 配置把该项目标为 trusted 时才生效。
    /// 这里选择包含 cwd 的最具体项目配置，避免把未受信任目录中的 allow 规则
    /// 错当作当前会话已经加载的规则。
    private static func trustedProjectRoot(cwd: String, codexHome: URL) -> URL? {
        let configURL = codexHome.appendingPathComponent("config.toml")
        guard let source = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }

        let headerPattern = #"^\s*\[projects\.\"((?:\\.|[^\"\\])*)\"\]\s*$"#
        guard let headerRegex = try? NSRegularExpression(pattern: headerPattern) else {
            return nil
        }
        let trustPattern = #"^\s*trust_level\s*=\s*\"(trusted|untrusted)\"\s*$"#
        let trustRegex = try? NSRegularExpression(pattern: trustPattern)

        var currentPath: String?
        var currentTrust: Bool?
        var projects: [(path: String, trusted: Bool)] = []

        func finishSection() {
            if let currentPath, let currentTrust {
                projects.append((currentPath, currentTrust))
            }
        }

        for rawLine in source.components(separatedBy: .newlines) {
            let range = NSRange(rawLine.startIndex..., in: rawLine)
            if let match = headerRegex.firstMatch(in: rawLine, range: range),
               let valueRange = Range(match.range(at: 1), in: rawLine) {
                finishSection()
                currentPath = decodeQuotedTOMLString(String(rawLine[valueRange]))
                currentTrust = nil
                continue
            }
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                finishSection()
                currentPath = nil
                currentTrust = nil
                continue
            }
            if currentPath != nil,
               let trustRegex,
               let match = trustRegex.firstMatch(in: rawLine, range: range),
               let valueRange = Range(match.range(at: 1), in: rawLine) {
                currentTrust = rawLine[valueRange] == "trusted"
            }
        }
        finishSection()

        let cwdURL = URL(fileURLWithPath: cwd).standardizedFileURL
        let match = projects
            .filter { project in
                let root = URL(fileURLWithPath: project.path).standardizedFileURL.path
                return cwdURL.path == root || cwdURL.path.hasPrefix(root + "/")
            }
            .max { $0.path.count < $1.path.count }
        guard let match, match.trusted else { return nil }
        return URL(fileURLWithPath: match.path).standardizedFileURL
    }

    private static func decodeQuotedTOMLString(_ raw: String) -> String {
        guard let data = "\"\(raw)\"".data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? String else {
            return raw
        }
        return decoded
    }

    private static func rulesSignature(_ paths: [String]) -> String {
        paths.map { path in
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(path)|\(size)|\(mtime)"
        }.joined(separator: "\n")
    }
}

/// 保守解析 Codex exec_command 的 shell 字符串。安全的线性命令链会拆成独立
/// argv；无法可靠解释的控制流/重定向直接返回 nil，不用猜测规则结果。
enum CodexShellCommandParser {
    struct Segment: Sendable, Equatable {
        let tokens: [String]
    }

    private enum Quote {
        case none
        case single
        case double
    }

    static func parse(_ source: String) -> [Segment]? {
        let chars = Array(source)
        var quote: Quote = .none
        var current = ""
        var tokenStarted = false
        var tokens: [String] = []
        var segments: [Segment] = []
        var index = 0

        func appendToken() {
            guard tokenStarted else { return }
            tokens.append(current)
            current = ""
            tokenStarted = false
        }

        func appendSegment() -> Bool {
            appendToken()
            guard !tokens.isEmpty else { return false }
            if let first = tokens.first,
               first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#,
                           options: .regularExpression) != nil {
                return false
            }
            if let first = tokens.first,
               ["if", "for", "while", "until", "case", "function"].contains(first) {
                return false
            }
            segments.append(Segment(tokens: tokens))
            tokens = []
            return true
        }

        while index < chars.count {
            let char = chars[index]
            switch quote {
            case .single:
                if char == "'" {
                    quote = .none
                } else {
                    current.append(char)
                }
                tokenStarted = true

            case .double:
                if char == "\"" {
                    quote = .none
                } else if char == "\\" {
                    index += 1
                    guard index < chars.count else { return nil }
                    current.append(chars[index])
                } else {
                    current.append(char)
                }
                tokenStarted = true

            case .none:
                if char == "'" {
                    quote = .single
                    tokenStarted = true
                } else if char == "\"" {
                    quote = .double
                    tokenStarted = true
                } else if char == "\\" {
                    index += 1
                    guard index < chars.count else { return nil }
                    current.append(chars[index])
                    tokenStarted = true
                } else if char == "\n" || char == ";" {
                    guard appendSegment() else { return nil }
                } else if char == "&" || char == "|" {
                    let next = index + 1 < chars.count ? chars[index + 1] : nil
                    if char == "&", next != "&" { return nil }
                    appendToken()
                    guard appendSegment() else { return nil }
                    if next == char { index += 1 }
                } else if char == ">" || char == "<" || char == "(" || char == ")" {
                    return nil
                } else if char == "$" || char == "`" || char == "*" || char == "?" {
                    return nil
                } else if char.isWhitespace {
                    appendToken()
                } else {
                    current.append(char)
                    tokenStarted = true
                }
            }
            index += 1
        }

        guard quote == .none else { return nil }
        if tokenStarted || !tokens.isEmpty {
            guard appendSegment() else { return nil }
        }
        return segments
    }
}
