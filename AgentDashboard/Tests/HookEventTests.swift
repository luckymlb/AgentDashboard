import XCTest
@testable import AgentDashboard

final class HookEventTests: XCTestCase {

    func testParsesPermissionRequest() {
        let event = HookEvent(queryType: "PermissionRequest", json: [
            "session_id": "session-1",
            "tool_name": "Bash"
        ])

        XCTAssertEqual(event?.hookType, .permissionRequest)
        XCTAssertEqual(event?.sessionId, "session-1")
        XCTAssertEqual(event?.toolName, "Bash")
    }

    func testParsesNotificationType() {
        let event = HookEvent(queryType: "Notification", json: [
            "session_id": "session-1",
            "message": "Claude needs your permission",
            "notification_type": "permission_prompt"
        ])

        XCTAssertEqual(event?.hookType, .notification)
        XCTAssertEqual(event?.notificationType, "permission_prompt")
    }
}
