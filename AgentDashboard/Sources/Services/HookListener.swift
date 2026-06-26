import Foundation
import os

private let logger = Logger(subsystem: "com.lucky.AgentDashboard", category: "HookListener")

@MainActor
class HookListener {
    private struct StatusEntry {
        let status: AgentStatus
        let timestamp: Date
    }

    private var statusMap: [String: StatusEntry] = [:]
    private var turnStartMap: [String: Date] = [:]
    private var lastEventMap: [String: Date] = [:]
    private let staleTTL: TimeInterval = 30

    func handleEvent(_ event: HookEvent) {
        lastEventMap[event.sessionId] = event.timestamp

        if event.hookType == .userPromptSubmit {
            turnStartMap[event.sessionId] = event.timestamp
        } else if event.hookType == .stop {
            turnStartMap.removeValue(forKey: event.sessionId)
        }

        guard let status = mapEventToStatus(event) else {
            if let existing = statusMap[event.sessionId] {
                statusMap[event.sessionId] = StatusEntry(status: existing.status, timestamp: event.timestamp)
            }
            return
        }
        statusMap[event.sessionId] = StatusEntry(status: status, timestamp: event.timestamp)
        logger.debug("Hook: \(event.hookType.rawValue) session=\(event.sessionId) tool=\(event.toolName ?? "-") → \(status.label)")
    }

    func status(for sessionId: String) -> AgentStatus? {
        guard let entry = statusMap[sessionId] else { return nil }
        if Date().timeIntervalSince(entry.timestamp) > staleTTL {
            return nil
        }
        return entry.status
    }

    func clearSession(_ sessionId: String) {
        statusMap.removeValue(forKey: sessionId)
    }

    func clearStaleEntries() {
        let now = Date()
        statusMap = statusMap.filter { now.timeIntervalSince($0.value.timestamp) <= staleTTL * 3 }
    }

    func snapshot() -> [String: AgentStatus] {
        let now = Date()
        var result: [String: AgentStatus] = [:]
        for (sessionId, entry) in statusMap {
            if now.timeIntervalSince(entry.timestamp) <= staleTTL {
                result[sessionId] = entry.status
            }
        }
        return result
    }

    func turnStartSnapshot() -> [String: Date] {
        return turnStartMap
    }

    func lastEventSnapshot() -> [String: Date] {
        return lastEventMap
    }

    private func mapEventToStatus(_ event: HookEvent) -> AgentStatus? {
        switch event.hookType {
        case .userPromptSubmit:
            return .thinking

        case .preToolUse:
            guard let tool = event.toolName else { return .busy }
            return mapToolToStatus(tool)

        case .postToolUse, .postToolUseFailure:
            return nil

        case .stop:
            return .idle
        }
    }

    private func mapToolToStatus(_ toolName: String) -> AgentStatus {
        switch toolName {
        case "Read":
            return .reading
        case "Bash", "Monitor":
            return .running
        case "Edit", "NotebookEdit":
            return .editing
        case "Write":
            return .writing
        case "WebSearch", "WebFetch", "Grep", "Glob":
            return .searching
        case "Agent", "Workflow", "TaskCreate", "SendMessage":
            return .processing
        default:
            if toolName.contains("search") || toolName.contains("Search") {
                return .searching
            }
            return .busy
        }
    }
}
