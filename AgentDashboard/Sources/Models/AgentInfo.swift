import Foundation

enum AgentType: String, CaseIterable {
    case claude = "Claude"
    case codex = "Codex"
}

enum AgentStatus: Comparable {
    case thinking
    case crafting
    case running
    case reading
    case editing
    case writing
    case searching
    case processing
    case busy       // fallback when transcript unavailable
    case waiting    // blocked, waiting for user input
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
