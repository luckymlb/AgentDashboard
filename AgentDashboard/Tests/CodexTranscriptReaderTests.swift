import XCTest
@testable import AgentDashboard

final class CodexTranscriptReaderTests: XCTestCase {

    /// codex total_token_usage → TokenUsage:input 拆 cached,reasoning 折进 output。
    func testUsageMapping() {
        let d: [String: Any] = [
            "input_tokens": 1000,
            "cached_input_tokens": 200,
            "output_tokens": 50,
            "reasoning_output_tokens": 10,
        ]
        let u = CodexTranscriptReader.usage(from: d)
        XCTAssertEqual(u.inputTokens, 800)       // 1000 - 200
        XCTAssertEqual(u.cacheReadTokens, 200)
        XCTAssertEqual(u.cacheCreationTokens, 0)
        XCTAssertEqual(u.outputTokens, 60)       // 50 + 10
    }

    func testUnescapeJSONString() {
        XCTAssertEqual(CodexTranscriptReader.unescapeJSONString(#"a\/b\\c\"d"#), #"a/b\c"d"#)
    }

    func testSessionMetadataHandlesChineseCwdAndTruncatedUTF8Tail() {
        var data = Data(#"{"timestamp":"2026-07-11T11:06:21.000Z","payload":{"cwd":"/tmp/宣传"},"tail":""#.utf8)
        data.append(0xE4) // first byte of a truncated three-byte UTF-8 character

        let metadata = CodexTranscriptReader.sessionMetadata(from: data)
        XCTAssertEqual(metadata?.cwd, "/tmp/宣传")
        XCTAssertNotNil(metadata?.startedAt)
    }

    func testSelectSessionPathUsesProcessStartAndExcludesAssignedPath() {
        let processStart = Date(timeIntervalSince1970: 1_000)
        let candidates = [
            CodexTranscriptReader.SessionCandidate(
                path: "/old", startedAt: Date(timeIntervalSince1970: 900), mtime: processStart
            ),
            CodexTranscriptReader.SessionCandidate(
                path: "/current", startedAt: Date(timeIntervalSince1970: 995), mtime: processStart
            ),
        ]

        XCTAssertEqual(
            CodexTranscriptReader.selectSessionPath(
                candidates: candidates, processStartedAt: processStart, excluding: []
            ),
            "/current"
        )
        XCTAssertEqual(
            CodexTranscriptReader.selectSessionPath(
                candidates: candidates, processStartedAt: processStart, excluding: ["/current"]
            ),
            "/old"
        )
    }

    func testSelectSessionPathRejectsStaleSession() {
        let processStart = Date(timeIntervalSince1970: 10_000)
        let candidates = [CodexTranscriptReader.SessionCandidate(
            path: "/stale", startedAt: Date(timeIntervalSince1970: 1_000), mtime: processStart
        )]
        XCTAssertNil(CodexTranscriptReader.selectSessionPath(
            candidates: candidates, processStartedAt: processStart, excluding: []
        ))
    }

    private func fixture(_ name: String) -> String {
        let url = Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/codex")
        XCTAssertNotNil(url, "missing fixture: \(name)")
        return url!.path
    }

    func testReadStateConfirming() {
        let s = CodexTranscriptReader().readState(transcriptPath: fixture("confirming"))
        XCTAssertEqual(s?.status, .confirming)
        XCTAssertNotNil(s?.turnStart)
    }

    /// Current Codex custom_tool_call stores tool JSON in payload.input, not arguments.
    func testReadStateConfirmingFromCustomToolInput() {
        let s = CodexTranscriptReader().readState(transcriptPath: fixture("confirming_custom"))
        XCTAssertEqual(s?.status, .confirming)
        XCTAssertNotNil(s?.turnStart)
    }

    func testRequiresEscalationIgnoresCommandText() {
        let input = #"const r = await tools.exec_command({"cmd":"rg require_escalated"});"#
        XCTAssertFalse(CodexTranscriptReader.requiresEscalation(input))
    }

    func testUnrelatedOutputDoesNotClearConfirming() {
        let s = CodexTranscriptReader().readState(transcriptPath: fixture("confirming_custom_unrelated_output"))
        XCTAssertEqual(s?.status, .confirming)
    }

    func testMatchingOutputClearsConfirming() {
        let s = CodexTranscriptReader().readState(transcriptPath: fixture("confirming_custom_completed"))
        XCTAssertNotEqual(s?.status, .confirming)
    }

    func testPreviousTurnApprovalDoesNotLeakIntoNewTurn() {
        let s = CodexTranscriptReader().readState(transcriptPath: fixture("confirming_stale_previous_turn"))
        XCTAssertEqual(s?.status, .thinking)
    }

    func testReadStateIdleWithToken() {
        let s = CodexTranscriptReader().readState(transcriptPath: fixture("idle"))
        XCTAssertEqual(s?.status, .idle)
        XCTAssertNil(s?.turnStart)
        XCTAssertEqual(s?.tokenUsage?.inputTokens, 800)
        XCTAssertEqual(s?.tokenUsage?.outputTokens, 60)
    }

    func testReadStateRunning() {
        let s = CodexTranscriptReader().readState(transcriptPath: fixture("running"))
        XCTAssertEqual(s?.status, .running)
        XCTAssertNotNil(s?.turnStart)
    }

    /// 长 turn(task_started 被挤出 64KB)→ readState 渐进扩大窗口找回 task_started → running。
    func testReadStateLongTurn() {
        let s = CodexTranscriptReader().readState(transcriptPath: fixture("longturn"))
        XCTAssertEqual(s?.status, .running)
        XCTAssertNotNil(s?.turnStart)
    }
}
