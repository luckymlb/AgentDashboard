import Foundation
import SwiftUI

enum AgentType: String, CaseIterable, Sendable {
    case claude = "Claude"
    case codex = "Codex"
}

/// 最新一轮任务如何结束。它不是当前 UI 状态，只用于区分正常完成和用户中断，
/// 避免把 aborted 的 Active → Idle 错报为“任务完成”。
enum AgentTurnOutcome: Sendable, Equatable {
    case completed
    case aborted
}

/// Which terminal emulator hosts this agent's session.
/// Drives click-to-jump routing; detected by walking the process tree.
enum TerminalApp: String, Sendable {
    case iTerm2 = "iTerm2"
    case terminal = "terminal"
    case unknown = "unknown"
}

enum AgentStatus {
    case confirming
    case thinking
    case crafting
    case running
    case reading
    case editing
    case writing
    case searching
    case processing
    case busy
    case waiting
    case idle

    var label: String {
        switch self {
        case .confirming: return "Confirming"
        case .thinking:   return "Thinking"
        case .crafting:   return "Crafting"
        case .running:    return "Running"
        case .reading:    return "Reading"
        case .editing:    return "Editing"
        case .writing:    return "Writing"
        case .searching:  return "Searching"
        case .processing: return "Processing"
        case .busy:       return "Busy"
        case .waiting:    return "Waiting"
        case .idle:       return "Idle"
        }
    }

    var isActive: Bool {
        self != .idle && self != .waiting
    }

    var sortPriority: Int {
        switch self {
        case .confirming: return -1
        case .thinking:   return 0
        case .crafting:   return 1
        case .running:    return 2
        case .reading:    return 3
        case .editing:    return 4
        case .writing:    return 5
        case .searching:  return 6
        case .processing: return 7
        case .busy:       return 8
        case .waiting:    return 9
        case .idle:       return 10
        }
    }

    var color: Color {
        switch self {
        case .confirming:        return .orange
        case .thinking:          return .purple
        case .crafting:          return .blue
        case .running, .busy:    return .green
        case .reading:           return .cyan
        case .editing, .writing: return .orange
        case .searching:         return .yellow
        case .processing:        return .mint
        case .waiting, .idle:    return .gray
        }
    }
}

extension AgentStatus: Comparable {
    static func < (lhs: AgentStatus, rhs: AgentStatus) -> Bool {
        lhs.sortPriority < rhs.sortPriority
    }
}

struct AgentInfo: Identifiable {
    let id: String
    let pid: Int
    /// 进程身份的一部分。PID 会复用，通知点击时必须同时核对启动时间。
    let processStartedAt: Date
    let type: AgentType
    let tty: String
    let workingDirectory: String
    let projectName: String
    let status: AgentStatus
    let elapsedTime: String
    let elapsedSeconds: Int
    let sessionName: String?
    let sessionId: String?
    let lastActiveAt: Double
    let hasUnread: Bool
    let terminalApp: TerminalApp
    let turnOutcome: AgentTurnOutcome?
    /// Claude 会话累计 token 用量;Codex 或无 sessionId 时为 nil。
    let tokenUsage: TokenUsage?

    init(pid: Int, processStartedAt: Date, type: AgentType, tty: String, workingDirectory: String,
         elapsedTime: String, status: AgentStatus,
         sessionName: String?, sessionId: String?, lastActiveAt: Double = 0,
         hasUnread: Bool = false, terminalApp: TerminalApp = .unknown,
         turnOutcome: AgentTurnOutcome? = nil,
         tokenUsage: TokenUsage? = nil) {
        self.id = "\(pid)-\(tty)"
        self.pid = pid
        self.processStartedAt = processStartedAt
        self.type = type
        self.tty = tty
        self.workingDirectory = workingDirectory
        self.projectName = URL(fileURLWithPath: workingDirectory).lastPathComponent
        self.elapsedTime = elapsedTime
        self.elapsedSeconds = AgentInfo.parseElapsedTime(elapsedTime)
        self.status = status
        self.sessionName = sessionName
        self.sessionId = sessionId
        self.lastActiveAt = lastActiveAt
        self.hasUnread = hasUnread
        self.terminalApp = terminalApp
        self.turnOutcome = turnOutcome
        self.tokenUsage = tokenUsage
    }

    func withHasUnread(_ hasUnread: Bool) -> AgentInfo {
        AgentInfo(
            pid: pid, processStartedAt: processStartedAt, type: type, tty: tty,
            workingDirectory: workingDirectory, elapsedTime: elapsedTime, status: status,
            sessionName: sessionName, sessionId: sessionId, lastActiveAt: lastActiveAt,
            hasUnread: hasUnread, terminalApp: terminalApp, turnOutcome: turnOutcome,
            tokenUsage: tokenUsage
        )
    }

    static func parseElapsedTime(_ str: String) -> Int {
        var total = 0
        let scanner = str.lowercased()
        let parts = scanner.components(separatedBy: " ")
        for part in parts {
            if part.hasSuffix("d") {
                total += (Int(part.dropLast()) ?? 0) * 86400
            } else if part.hasSuffix("h") {
                total += (Int(part.dropLast()) ?? 0) * 3600
            } else if part.hasSuffix("m") {
                total += (Int(part.dropLast()) ?? 0) * 60
            } else if part.hasSuffix("s") {
                total += Int(part.dropLast()) ?? 0
            }
        }
        return total
    }
}
