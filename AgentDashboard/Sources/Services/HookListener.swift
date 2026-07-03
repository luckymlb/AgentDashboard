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
    /// session → pending 工具名(PreToolUse 设,PostToolUse 清)。
    /// 用于 Notification 触发时区分「权限确认」(有 pending 工具)与「空闲等待」(无)。
    private var pendingTools: [String: String] = [:]
    private let staleTTL: TimeInterval = 30
    /// confirming 不受 staleTTL 限制:应持续到 PostToolUse/Stop/UserPromptSubmit 等事件清除。
    /// 这里给一个很长的兜底 TTL,仅防止 statusMap 因异常漏事件而无限残留。
    private let confirmingTTL: TimeInterval = 3600

    func handleEvent(_ event: HookEvent) {
        lastEventMap[event.sessionId] = event.timestamp

        if event.hookType == .userPromptSubmit {
            turnStartMap[event.sessionId] = event.timestamp
        } else if event.hookType == .stop {
            turnStartMap.removeValue(forKey: event.sessionId)
        } else if turnStartMap[event.sessionId] == nil {
            turnStartMap[event.sessionId] = event.timestamp
        }

        // pending 工具配对,用于 Notification 区分「权限确认」(有 pending 工具)与「空闲等待」(无)。
        switch event.hookType {
        case .preToolUse:
            pendingTools[event.sessionId] = event.toolName ?? ""
        case .postToolUse, .postToolUseFailure:
            pendingTools.removeValue(forKey: event.sessionId)
            // 工具执行完成 → 若此前在等确认,清除 confirming(让 transcript 重新接管状态)。
            if statusMap[event.sessionId]?.status == .confirming {
                statusMap.removeValue(forKey: event.sessionId)
                return
            }
        case .notification:
            if let pendingTool = pendingTools[event.sessionId] {
                statusMap[event.sessionId] = StatusEntry(status: .confirming, timestamp: event.timestamp)
                logger.debug("Notification → confirming: session=\(event.sessionId) pendingTool=\(pendingTool)")
            } else {
                logger.debug("Notification → ignored (idle, no pending tool): session=\(event.sessionId) msg=\(event.message ?? "-")")
            }
            return
        case .stop, .userPromptSubmit:
            pendingTools.removeValue(forKey: event.sessionId)
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
        statusMap = statusMap.filter { entry in
            let ttl = entry.value.status == .confirming ? confirmingTTL : staleTTL * 3
            return now.timeIntervalSince(entry.value.timestamp) <= ttl
        }
    }

    func snapshot() -> [String: AgentStatus] {
        let now = Date()
        var result: [String: AgentStatus] = [:]
        for (sessionId, entry) in statusMap {
            let ttl = entry.status == .confirming ? confirmingTTL : staleTTL
            if now.timeIntervalSince(entry.timestamp) <= ttl {
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

        case .notification:
            return nil  // 在 handleEvent 中单独处理(依赖 pendingTools)

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
