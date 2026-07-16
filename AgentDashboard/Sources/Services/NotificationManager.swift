import Foundation
import UserNotifications
import os

private let logger = Logger(subsystem: "com.lucky.AgentDashboard", category: "Notifications")

/// agent 状态变化时弹系统通知,点击跳转对应终端。
/// 触发:进入 confirming(等待授权)、active→idle 且本轮 turn>30s(任务完成)。
/// 去重:confirming 用状态机(持续期间不重发,离开清横幅),completed 用 30s 防抖。
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    enum NotifyKind {
        case needsConfirmation   // 进入 confirming
        case completed           // active → idle 且本轮 turn > 30s
    }

    /// 已发过 confirming 通知的 agent:id -> identifier。
    /// 存在即"已发",持续 confirming 期间命中直接 return;离开 confirming 移除并清横幅。
    private var confirmingNotified: [String: String] = [:]

    /// completed 防抖:id -> 上次发通知时间。窗口内同 agent 不重发。
    private var lastCompletedAt: [String: Date] = [:]
    private let completedDebounce: TimeInterval = 30

    /// 进程退出时清理该 Agent 在本次 App 生命周期内创建的所有通知。
    private var notificationIdentifiersByAgent: [String: Set<String>] = [:]

    private var authorized = false

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                if let error { logger.error("通知授权失败: \(error.localizedDescription, privacy: .public)") }
                self?.authorized = granted
                logger.info("通知授权 authorized=\(granted)")
            }
        }
    }

    func notify(agent: AgentInfo, kind: NotifyKind) {
        guard authorized else { return }
        let id = agent.id

        switch kind {
        case .needsConfirmation:
            // 调用方已保证只对真实等待用户的信号（Codex 的审批策略+规则判定，
            // Claude PermissionRequest、permission_prompt 或 AskUserQuestion）触发；
            // 这里只防持续 confirming 重复发。即时通知,不延迟。
            guard confirmingNotified[id] == nil else { return }
            // 同一个固定 identifier 会被 macOS 当作旧通知更新，后续确认不再展示
            // banner。每个 confirming episode 使用唯一 id，持续期间仍由内存映射去重。
            let identifier = Self.confirmationIdentifier(agentId: id)
            confirmingNotified[id] = identifier
            track(identifier: identifier, agentId: id)
            deliver(
                identifier: identifier,
                title: "\(agent.type.rawValue) 等确认",
                body: body(for: agent),
                userInfo: userInfo(for: agent)
            )

        case .completed:
            if let last = lastCompletedAt[id],
               Date().timeIntervalSince(last) < completedDebounce { return }
            lastCompletedAt[id] = Date()
            // 带时间戳允许多条历史共存;debounce 已拦短时重复
            let identifier = "completed-\(id)-\(Int(Date().timeIntervalSince1970))"
            track(identifier: identifier, agentId: id)
            deliver(
                identifier: identifier,
                title: "\(agent.type.rawValue) 任务完成",
                body: body(for: agent),
                userInfo: userInfo(for: agent)
            )
        }
    }

    /// agent 离开 confirming:清掉已发横幅,允许下次再进入时重发。
    func clearConfirming(agentId: String) {
        if let identifier = confirmingNotified.removeValue(forKey: agentId) {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            untrack(identifier: identifier, agentId: agentId)
        }
    }

    /// agent 进程退出:清理该 agent 全部通知状态与已发横幅。
    func purge(agentId: String) {
        var identifiers = notificationIdentifiersByAgent.removeValue(forKey: agentId) ?? []
        if let confirmingIdentifier = confirmingNotified.removeValue(forKey: agentId) {
            identifiers.insert(confirmingIdentifier)
        }
        // 兼容映射尚未建立或 App 升级前创建的固定确认通知。
        identifiers.insert("confirm-\(agentId)")

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: Array(identifiers))
        center.removeDeliveredNotifications(withIdentifiers: Array(identifiers))
        lastCompletedAt.removeValue(forKey: agentId)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let identifier = response.notification.request.identifier

        guard let target = NotificationTarget(userInfo: info) else {
            logger.warning("拒绝旧格式通知跳转 identifier=\(identifier, privacy: .public)")
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            completionHandler()
            return
        }

        let resolution = NotificationTargetResolver.resolve(target)
        Task { @MainActor in
            switch resolution {
            case let .destination(tty, terminalApp):
                logger.info("通知目标验证通过 pid=\(target.pid) tty=\(tty, privacy: .public) app=\(terminalApp.rawValue, privacy: .public)")
                TerminalBridge.activate(tty: tty, app: terminalApp)
            case let .rejected(reason):
                logger.warning("拒绝失效通知跳转 pid=\(target.pid) reason=\(reason.rawValue, privacy: .public)")
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - private

    private func deliver(identifier: String, title: String, body: String, userInfo: [AnyHashable: Any]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error { logger.error("发送通知失败: \(error.localizedDescription)") }
        }
    }

    private func userInfo(for agent: AgentInfo) -> [AnyHashable: Any] {
        NotificationTarget(agent: agent).userInfo
    }

    private func track(identifier: String, agentId: String) {
        notificationIdentifiersByAgent[agentId, default: []].insert(identifier)
    }

    private func untrack(identifier: String, agentId: String) {
        notificationIdentifiersByAgent[agentId]?.remove(identifier)
        if notificationIdentifiersByAgent[agentId]?.isEmpty == true {
            notificationIdentifiersByAgent.removeValue(forKey: agentId)
        }
    }

    private func body(for agent: AgentInfo) -> String {
        agent.projectName
    }

    nonisolated static func confirmationIdentifier(agentId: String) -> String {
        "confirm-\(agentId)-\(UUID().uuidString)"
    }
}
