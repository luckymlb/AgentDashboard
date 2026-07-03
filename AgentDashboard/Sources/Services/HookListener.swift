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
    /// session → PreToolUse 时间(PostToolUse 清)。
    /// 用途:① Notification 触发时区分「权限确认」(有 pending)与「空闲等待」(无);
    ///       ② 降级:pending 超过 preToolConfirmDelay 仍未 PostToolUse → 视为确认中
    ///          (Notification 有内置 debounce 会延迟,这条让提示更快)。
    private var pendingSince: [String: Date] = [:]
    private let staleTTL: TimeInterval = 30
    /// confirming 不受 staleTTL 限制:应持续到 PostToolUse/Stop/UserPromptSubmit 等事件清除。
    /// 这里给一个很长的兜底 TTL,仅防止 statusMap 因异常漏事件而无限残留。
    private let confirmingTTL: TimeInterval = 3600
    /// PreToolUse 后超过该时长仍未 PostToolUse → 视为确认(Notification debounce 延迟的降级)。
    /// 代价:执行慢(>该值)的工具会短暂误判为 confirming,PostToolUse 来了即消除。
    private let preToolConfirmDelay: TimeInterval = 1.5
    /// 降级判定 confirming 时触发,通知 ProcessScanner 立即 scan 刷新 UI(不等周期)。
    var onPendingTimeout: ((String) -> Void)?

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
            pendingSince[event.sessionId] = event.timestamp
            scheduleConfirmingFallback(sessionId: event.sessionId)
        case .postToolUse, .postToolUseFailure:
            pendingSince.removeValue(forKey: event.sessionId)
            // 工具执行完成 → 若此前在等确认,清除 confirming(让 transcript 重新接管状态)。
            if statusMap[event.sessionId]?.status == .confirming {
                statusMap.removeValue(forKey: event.sessionId)
                return
            }
        case .notification:
            // Notification 是 Claude Code 的"需用户注意"信号。结合 pending 工具判定:
            // 有 pending 工具 → 权限确认;无 → 空闲等待(忽略)。
            if pendingSince[event.sessionId] != nil {
                statusMap[event.sessionId] = StatusEntry(status: .confirming, timestamp: event.timestamp)
                logger.debug("Notification → confirming: session=\(event.sessionId)")
            } else {
                logger.debug("Notification → ignored (idle): session=\(event.sessionId) msg=\(event.message ?? "-")")
            }
            return
        case .stop, .userPromptSubmit:
            pendingSince.removeValue(forKey: event.sessionId)
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

    /// PreToolUse 后 preToolConfirmDelay 仍未 PostToolUse → 视为确认中。
    private func scheduleConfirmingFallback(sessionId: String) {
        let delay = preToolConfirmDelay
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard self.pendingSince[sessionId] != nil,          // 仍 pending(未 PostToolUse)
                      self.statusMap[sessionId]?.status != .confirming else { return }
                self.statusMap[sessionId] = StatusEntry(status: .confirming, timestamp: Date())
                logger.debug("PreToolUse timeout → confirming: session=\(sessionId)")
                self.onPendingTimeout?(sessionId)
            }
        }
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
