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
    /// session → PreToolUse 时间(PostToolUse 清)。仅用于兼容旧版
    /// 不含 notification_type 的 Notification payload。
    private var pendingSince: [String: Date] = [:]
    /// 收到确定权限信号的 session。confirming(UI 图标 + 通知)
    /// 只对此集触发,避免慢工具被误判为等授权。
    private var explicitConfirming: Set<String> = []
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

        switch event.hookType {
        case .preToolUse:
            // 新工具调用证明上一个权限对话框已经结束。
            explicitConfirming.remove(event.sessionId)
            pendingSince[event.sessionId] = event.timestamp
        case .permissionRequest:
            statusMap[event.sessionId] = StatusEntry(status: .confirming, timestamp: event.timestamp)
            explicitConfirming.insert(event.sessionId)
            logger.debug("PermissionRequest → confirming: session=\(event.sessionId) tool=\(event.toolName ?? "-")")
            return
        case .postToolUse, .postToolUseFailure:
            pendingSince.removeValue(forKey: event.sessionId)
            explicitConfirming.remove(event.sessionId)
            // 工具执行完成 → 若此前在等确认,清除 confirming(让 transcript 重新接管状态)。
            if statusMap[event.sessionId]?.status == .confirming {
                statusMap.removeValue(forKey: event.sessionId)
                return
            }
        case .notification:
            // 新版 payload 直接标注 permission_prompt。旧版缺失该字段时，
            // 才回退到 PreToolUse 尚未完成的推断。
            let isPermissionPrompt = event.notificationType == "permission_prompt"
                || (event.notificationType == nil && pendingSince[event.sessionId] != nil)
            if isPermissionPrompt {
                statusMap[event.sessionId] = StatusEntry(status: .confirming, timestamp: event.timestamp)
                explicitConfirming.insert(event.sessionId)
                logger.debug("Notification → confirming: session=\(event.sessionId)")
            } else {
                logger.debug("Notification → ignored (idle): session=\(event.sessionId) msg=\(event.message ?? "-")")
            }
            return
        case .stop, .userPromptSubmit:
            pendingSince.removeValue(forKey: event.sessionId)
            explicitConfirming.remove(event.sessionId)
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
        explicitConfirming.remove(sessionId)
    }

    func clearStaleEntries() {
        let now = Date()
        let kept = statusMap.filter { entry in
            let ttl = entry.value.status == .confirming ? confirmingTTL : staleTTL * 3
            return now.timeIntervalSince(entry.value.timestamp) <= ttl
        }
        let removed = Set(statusMap.keys).subtracting(Set(kept.keys))
        explicitConfirming.subtract(removed)
        statusMap = kept
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

    /// 当前收到 Notification hook(真·等授权)的 session 集。通知只对此集的 confirming 发。
    func explicitConfirmingSnapshot() -> Set<String> {
        explicitConfirming
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

        case .permissionRequest:
            return .confirming

        case .postToolUse, .postToolUseFailure:
            return nil

        case .notification:
            return nil  // 在 handleEvent 中单独处理(依赖 pendingSince)

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
