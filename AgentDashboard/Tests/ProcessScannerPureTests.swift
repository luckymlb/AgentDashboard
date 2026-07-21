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

    func testResolveTranscriptPathPrefersHookAbsolutePath() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-transcript-\(UUID().uuidString).jsonl")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 中文/空格 cwd 反推必然失配,但 hook 提供的绝对路径应直接命中——这正是本改动的目的。
        let path = ProcessScanner.resolveTranscriptPath(
            sessionId: "any",
            cwd: "/Users/某人/代码 脚本",
            transcriptReader: TranscriptTailReader(),
            hookTranscriptPaths: ["any": tmp.path]
        )

        XCTAssertEqual(path, tmp.path)
    }

    func testResolveTranscriptPathFallsBackWhenHookFileMissing() {
        // hook 路径不存在且无缓存,.cwd 无法反推到真实 projects 目录 → 退化返回 nil。
        let path = ProcessScanner.resolveTranscriptPath(
            sessionId: "definitely-nonexistent-\(UUID().uuidString)",
            cwd: "/tmp/no-such-project",
            transcriptReader: TranscriptTailReader(),
            hookTranscriptPaths: [:]
        )

        XCTAssertNil(path)
    }

    func testClaudeLastActivePrefersStopHook() {
        let stop = Date(timeIntervalSince1970: 4_000)

        XCTAssertEqual(ProcessScanner.claudeLastActiveAt(
            stopHookAt: stop,
            statusUpdatedAt: 3_000_000,
            updatedAt: 2_000_000,
            sessionFileModifiedAt: Date(timeIntervalSince1970: 1_000)
        ), 4_000_000)
    }

    func testClaudeLastActiveRestoresFromStatusTimestampAfterRestart() {
        XCTAssertEqual(ProcessScanner.claudeLastActiveAt(
            stopHookAt: nil,
            statusUpdatedAt: 3_000_000,
            updatedAt: 2_000_000,
            sessionFileModifiedAt: Date(timeIntervalSince1970: 1_000)
        ), 3_000_000)
    }

    func testClaudeLastActiveFallsBackWithoutStatusTimestamp() {
        XCTAssertEqual(ProcessScanner.claudeLastActiveAt(
            stopHookAt: nil,
            statusUpdatedAt: 0,
            updatedAt: 2_000_000,
            sessionFileModifiedAt: Date(timeIntervalSince1970: 1_000)
        ), 2_000_000)

        XCTAssertEqual(ProcessScanner.claudeLastActiveAt(
            stopHookAt: nil,
            statusUpdatedAt: 0,
            updatedAt: 0,
            sessionFileModifiedAt: Date(timeIntervalSince1970: 1_000)
        ), 1_000_000)
    }

    func testApplyingCodexStateUpdatesOnlyRolloutDerivedFields() {
        let original = AgentInfo(
            pid: 42,
            processStartedAt: Date(timeIntervalSince1970: 1_000),
            type: .codex,
            tty: "ttys009",
            workingDirectory: "/tmp/project",
            elapsedTime: "2s",
            status: .thinking,
            sessionName: "original",
            sessionId: "session-1",
            lastActiveAt: 100,
            hasUnread: true,
            terminalApp: .iTerm2,
            tokenUsage: TokenUsage(
                inputTokens: 1, cacheCreationTokens: 0,
                cacheReadTokens: 2, outputTokens: 3, model: nil
            )
        )
        let turnStart = Date(timeIntervalSince1970: 1_990)
        let signature = CodexTranscriptReader.FileSignature(
            size: 123, modificationDate: Date(timeIntervalSince1970: 1_995)
        )
        let state = CodexTranscriptReader.CodexState(
            sessionId: "session-1",
            status: .searching,
            tokenUsage: nil,
            turnStart: turnStart,
            turnOutcome: nil
        )

        let refreshed = ProcessScanner.applyingCodexState(
            state, signature: signature, to: original,
            now: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(refreshed.pid, original.pid)
        XCTAssertEqual(refreshed.processStartedAt, original.processStartedAt)
        XCTAssertEqual(refreshed.tty, original.tty)
        XCTAssertEqual(refreshed.workingDirectory, original.workingDirectory)
        XCTAssertEqual(refreshed.terminalApp, original.terminalApp)
        XCTAssertEqual(refreshed.status, .searching)
        XCTAssertEqual(refreshed.elapsedTime, "10s")
        XCTAssertEqual(refreshed.lastActiveAt, 1_995_000)
        XCTAssertEqual(refreshed.tokenUsage, original.tokenUsage)
    }

    func testHiddenDashboardDoesNotPublishCodexTelemetryOnlyChange() {
        let old = agent(
            status: .running,
            elapsedTime: "10s",
            tokenUsage: TokenUsage(
                inputTokens: 10, cacheCreationTokens: 0,
                cacheReadTokens: 0, outputTokens: 1, model: nil
            )
        )
        let telemetryOnly = agent(
            status: .running,
            elapsedTime: "11s",
            tokenUsage: TokenUsage(
                inputTokens: 11, cacheCreationTokens: 0,
                cacheReadTokens: 0, outputTokens: 2, model: nil
            )
        )

        XCTAssertFalse(ProcessScanner.shouldPublishCodexRefresh(
            oldAgent: old, newAgent: telemetryOnly, dashboardVisible: false
        ))
        XCTAssertTrue(ProcessScanner.shouldPublishCodexRefresh(
            oldAgent: old, newAgent: telemetryOnly, dashboardVisible: true
        ))
    }

    func testHiddenDashboardStillPublishesCodexStatusChange() {
        let old = agent(status: .running)
        let confirming = agent(status: .confirming)

        XCTAssertTrue(ProcessScanner.shouldPublishCodexRefresh(
            oldAgent: old, newAgent: confirming, dashboardVisible: false
        ))
    }

    private func agent(
        type: AgentType = .codex,
        status: AgentStatus,
        elapsedTime: String = "",
        turnOutcome: AgentTurnOutcome? = nil,
        sessionId: String? = nil,
        tokenUsage: TokenUsage? = nil
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
            turnOutcome: turnOutcome,
            tokenUsage: tokenUsage
        )
    }
}
