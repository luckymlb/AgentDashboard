import XCTest
@testable import AgentDashboard

/// ProcessScanner 的纯函数(解析/判定)。nonisolated static,无需 actor。
final class ProcessScannerPureTests: XCTestCase {

    func testParseEtimeSeconds() {
        XCTAssertEqual(ProcessScanner.parseEtimeSeconds("20"), 20)
        XCTAssertEqual(ProcessScanner.parseEtimeSeconds("1:20"), 80)
        XCTAssertEqual(ProcessScanner.parseEtimeSeconds("1:02:03"), 3723)
        XCTAssertEqual(ProcessScanner.parseEtimeSeconds("1-02:03:04"), 1 * 86400 + 2 * 3600 + 3 * 60 + 4)
        XCTAssertEqual(ProcessScanner.parseEtimeSeconds(""), 0)
        XCTAssertEqual(ProcessScanner.parseEtimeSeconds("garbage"), 0)
    }

    func testIsClaudeLine() {
        XCTAssertTrue(ProcessScanner.isClaudeLine("12345 ttys001 S 0.0 00:00 claude"))
        XCTAssertTrue(ProcessScanner.isClaudeLine("12345 ttys001 S 0.0 00:00 claude --resume abc"))
        XCTAssertFalse(ProcessScanner.isClaudeLine("12345 ttys001 S 0.0 00:00 claude --output-format stream-json"))
        XCTAssertFalse(ProcessScanner.isClaudeLine("12345 ttys001 S 0.0 00:00 claude bypassPermissions"))
        XCTAssertFalse(ProcessScanner.isClaudeLine("12345 ttys001 S 0.0 00:00 codex"))
    }

    func testIsCodexLine() {
        XCTAssertTrue(ProcessScanner.isCodexLine("12345 ttys001 S 0.0 00:00 codex"))
        XCTAssertTrue(ProcessScanner.isCodexLine("12345 ttys001 S 0.0 00:00 codex test"))
        XCTAssertTrue(ProcessScanner.isCodexLine("12345 ttys001 S 0.0 00:00 node /usr/local/bin/codex"))
        XCTAssertFalse(ProcessScanner.isCodexLine("12345 ttys001 S 0.0 00:00 codex app-server --listen stdio"))
        XCTAssertFalse(ProcessScanner.isCodexLine("12345 ttys001 S 0.0 00:00 node_repl"))
        XCTAssertFalse(ProcessScanner.isCodexLine("12345 ttys001 S 0.0 00:00 claude"))
    }

    func testCpuFallbackStatus() {
        XCTAssertEqual(ProcessScanner.cpuFallbackStatus(cpu: 0, stat: "S"), .idle)
        XCTAssertEqual(ProcessScanner.cpuFallbackStatus(cpu: 5, stat: "S"), .busy)
        XCTAssertEqual(ProcessScanner.cpuFallbackStatus(cpu: 0, stat: "R"), .running)
        XCTAssertEqual(ProcessScanner.cpuFallbackStatus(cpu: 50, stat: "S"), .running)
    }

    func testAbortedTurnDoesNotNotifyCompletion() {
        let old = agent(status: .running, elapsedTime: "31s")
        let aborted = agent(status: .idle, turnOutcome: .aborted)

        XCTAssertFalse(ProcessScanner.shouldNotifyCompletion(oldAgent: old, newAgent: aborted))
    }

    func testCompletedTurnStillNotifiesCompletion() {
        let old = agent(status: .running, elapsedTime: "31s")
        let completed = agent(status: .idle, turnOutcome: .completed)

        XCTAssertTrue(ProcessScanner.shouldNotifyCompletion(oldAgent: old, newAgent: completed))
    }

    func testClaudeCompletionWithoutCodexOutcomeStillNotifies() {
        let old = agent(type: .claude, status: .running, elapsedTime: "31s")
        let completed = agent(type: .claude, status: .idle)

        XCTAssertTrue(ProcessScanner.shouldNotifyCompletion(oldAgent: old, newAgent: completed))
    }

    func testCodexCompletedTurnBecomesUnread() {
        let old = agent(status: .running, sessionId: "codex-session")
        let completed = agent(
            status: .idle, turnOutcome: .completed, sessionId: "codex-session"
        )

        XCTAssertTrue(ProcessScanner.shouldMarkUnreadCompletion(
            oldAgent: old, newAgent: completed
        ))
    }

    func testCodexAbortedTurnDoesNotBecomeUnread() {
        let old = agent(status: .running, sessionId: "codex-session")
        let aborted = agent(
            status: .idle, turnOutcome: .aborted, sessionId: "codex-session"
        )

        XCTAssertFalse(ProcessScanner.shouldMarkUnreadCompletion(
            oldAgent: old, newAgent: aborted
        ))
    }

    func testClaudeCompletedTurnStillBecomesUnread() {
        let old = agent(type: .claude, status: .running, sessionId: "claude-session")
        let completed = agent(type: .claude, status: .idle, sessionId: "claude-session")

        XCTAssertTrue(ProcessScanner.shouldMarkUnreadCompletion(
            oldAgent: old, newAgent: completed
        ))
    }

    func testDifferentSessionDoesNotInheritUnread() {
        let old = agent(status: .running, sessionId: "old-session")
        let completed = agent(
            status: .idle, turnOutcome: .completed, sessionId: "new-session"
        )

        XCTAssertFalse(ProcessScanner.shouldMarkUnreadCompletion(
            oldAgent: old, newAgent: completed
        ))
    }

    private func agent(
        type: AgentType = .codex,
        status: AgentStatus,
        elapsedTime: String = "",
        turnOutcome: AgentTurnOutcome? = nil,
        sessionId: String? = nil
    ) -> AgentInfo {
        AgentInfo(
            pid: 1,
            processStartedAt: Date(timeIntervalSince1970: 1_000),
            type: type,
            tty: "ttys001",
            workingDirectory: "/tmp/project",
            elapsedTime: elapsedTime,
            status: status,
            sessionName: nil,
            sessionId: sessionId,
            turnOutcome: turnOutcome
        )
    }
}
