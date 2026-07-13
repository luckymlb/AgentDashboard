import Foundation

enum HookType: String, Sendable {
    case preToolUse = "PreToolUse"
    case permissionRequest = "PermissionRequest"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case stop = "Stop"
    case userPromptSubmit = "UserPromptSubmit"
    case notification = "Notification"
}

struct HookEvent: Sendable {
    let hookType: HookType
    let sessionId: String
    let toolName: String?
    let message: String?
    let notificationType: String?
    let timestamp: Date

    /// 直接构造(测试用)。
    init(
        hookType: HookType,
        sessionId: String,
        toolName: String? = nil,
        message: String? = nil,
        notificationType: String? = nil,
        timestamp: Date = Date()
    ) {
        self.hookType = hookType
        self.sessionId = sessionId
        self.toolName = toolName
        self.message = message
        self.notificationType = notificationType
        self.timestamp = timestamp
    }

    init?(queryType: String, json: [String: Any]) {
        guard let hookType = HookType(rawValue: queryType) else { return nil }
        self.hookType = hookType
        self.timestamp = Date()

        self.sessionId = json["session_id"] as? String ?? ""
        guard !self.sessionId.isEmpty else { return nil }

        self.toolName = json["tool_name"] as? String
        self.message = json["message"] as? String
        self.notificationType = json["notification_type"] as? String
    }
}
