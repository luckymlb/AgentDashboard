import XCTest
@testable import AgentDashboard

/// HookListener 状态机:hook 事件序列 → AgentStatus + explicit confirming 集。
/// 这是通知"只认真信号"的根,最该有测试守护。
@MainActor
final class HookListenerTests: XCTestCase {

    private func event(
        _ type: HookType,
        _ sid: String = "s1",
        tool: String? = nil,
        msg: String? = nil,
        notificationType: String? = nil
    ) -> HookEvent {
        HookEvent(
            hookType: type,
            sessionId: sid,
            toolName: tool,
            message: msg,
            notificationType: notificationType
        )
    }

    func testPreToolUseMapsToolToStatus() {
        let h = HookListener()
        h.handleEvent(event(.preToolUse, tool: "Read"))
        XCTAssertEqual(h.snapshot()["s1"], .reading)
        h.handleEvent(event(.preToolUse, tool: "Bash"))
        XCTAssertEqual(h.snapshot()["s1"], .running)
    }

    func testNotificationAfterPreToolUseIsExplicitConfirming() {
        let h = HookListener()
        h.handleEvent(event(.preToolUse, tool: "Bash"))
        h.handleEvent(event(.notification, msg: "need approval"))
        XCTAssertEqual(h.snapshot()["s1"], .confirming)
        XCTAssertTrue(h.explicitConfirmingSnapshot().contains("s1"))
    }

    func testPermissionRequestIsExplicitConfirmingWithoutPreToolUse() {
        let h = HookListener()
        h.handleEvent(event(.permissionRequest, tool: "Bash"))
        XCTAssertEqual(h.snapshot()["s1"], .confirming)
        XCTAssertTrue(h.explicitConfirmingSnapshot().contains("s1"))
    }

    func testPostToolUseFailureClearsPermissionRequest() {
        let h = HookListener()
        h.handleEvent(event(.permissionRequest, tool: "Bash"))
        h.handleEvent(event(.postToolUseFailure, tool: "Bash"))
        XCTAssertNil(h.snapshot()["s1"])
        XCTAssertFalse(h.explicitConfirmingSnapshot().contains("s1"))
    }

    func testPermissionPromptNotificationIsExplicitConfirmingWithoutPreToolUse() {
        let h = HookListener()
        h.handleEvent(event(.notification, notificationType: "permission_prompt"))
        XCTAssertEqual(h.snapshot()["s1"], .confirming)
        XCTAssertTrue(h.explicitConfirmingSnapshot().contains("s1"))
    }

    func testIdleNotificationDoesNotConfirmPendingTool() {
        let h = HookListener()
        h.handleEvent(event(.preToolUse, tool: "Bash"))
        h.handleEvent(event(.notification, notificationType: "idle_prompt"))
        XCTAssertEqual(h.snapshot()["s1"], .running)
        XCTAssertFalse(h.explicitConfirmingSnapshot().contains("s1"))
    }

    func testNotificationWithoutPendingToolIsIgnored() {
        let h = HookListener()
        h.handleEvent(event(.notification, msg: "idle nudge"))
        XCTAssertNil(h.snapshot()["s1"])
        XCTAssertFalse(h.explicitConfirmingSnapshot().contains("s1"))
    }

    func testPostToolUseClearsConfirmingAndExplicit() {
        let h = HookListener()
        h.handleEvent(event(.preToolUse, tool: "Bash"))
        h.handleEvent(event(.notification, msg: nil))
        h.handleEvent(event(.postToolUse))
        XCTAssertNil(h.snapshot()["s1"])
        XCTAssertFalse(h.explicitConfirmingSnapshot().contains("s1"))
    }

    func testStopClearsExplicit() {
        let h = HookListener()
        h.handleEvent(event(.preToolUse, tool: "Bash"))
        h.handleEvent(event(.notification, msg: nil))
        h.handleEvent(event(.stop))
        XCTAssertFalse(h.explicitConfirmingSnapshot().contains("s1"))
    }

    func testNextToolUseClearsDeniedPermissionRequest() {
        let h = HookListener()
        h.handleEvent(event(.permissionRequest, tool: "Bash"))
        h.handleEvent(event(.preToolUse, tool: "Read"))
        XCTAssertEqual(h.snapshot()["s1"], .reading)
        XCTAssertFalse(h.explicitConfirmingSnapshot().contains("s1"))
    }
}
