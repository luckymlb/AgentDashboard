import Foundation
import SwiftUI

enum AgentType: String, CaseIterable {
    case claude = "Claude"
    case codex = "Codex"
}

enum AgentStatus {
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
    let type: AgentType
    let tty: String
    let workingDirectory: String
    let projectName: String
    let status: AgentStatus
    let elapsedTime: String
    let sessionName: String?
    let sessionId: String?

    init(pid: Int, type: AgentType, tty: String, workingDirectory: String,
         elapsedTime: String, status: AgentStatus,
         sessionName: String?, sessionId: String?) {
        self.id = "\(pid)-\(tty)"
        self.pid = pid
        self.type = type
        self.tty = tty
        self.workingDirectory = workingDirectory
        self.projectName = URL(fileURLWithPath: workingDirectory).lastPathComponent
        self.elapsedTime = elapsedTime
        self.status = status
        self.sessionName = sessionName
        self.sessionId = sessionId
    }
}
