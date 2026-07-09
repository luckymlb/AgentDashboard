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

    /// 长 turn(尾部 64KB 无 event_msg)→ readState 返回 nil。已知边界,测试守护防止静默改变。
    func testReadStateLongTurnReturnsNil() {
        let s = CodexTranscriptReader().readState(transcriptPath: fixture("longturn"))
        XCTAssertNil(s)
    }
}
