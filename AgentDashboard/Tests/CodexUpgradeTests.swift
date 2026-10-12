import Foundation
import XCTest
@testable import AgentDashboard

final class CodexUpgradeTests: XCTestCase {
    private struct Policy: CodexExecPolicyEvaluating {
        func decision(for shellCommand: String, cwd: String?) -> CodexExecPolicyDecision { .noMatch }
    }
    private func state(_ records: [[String: Any]]) throws -> CodexTranscriptReader.CodexState {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return try XCTUnwrap(CodexTranscriptReader(approvalEvaluator: Policy()).readState(transcriptPath: url.path))
    }
    private let started: [String: Any] = ["timestamp": "2026-10-12T06:00:00.000Z", "type": "event_msg", "payload": ["type": "task_started"]]

    func testNewReasoningAndAgentMessageEvents() throws {
        for (item, expected) in [("Reasoning", AgentStatus.thinking), ("AgentMessage", .crafting)] {
            let result = try state([started, ["type": "event_msg", "payload": ["type": "item_completed", "item": ["type": item]]]])
            XCTAssertEqual(result.status, expected)
        }
        XCTAssertEqual(try state([started, ["type": "response_item", "payload": ["type": "reasoning"]]]).status, .thinking)
    }

    func testTelemetryAndSettingsDoNotOverrideCompletion() throws {
        let result = try state([started,
            ["type": "event_msg", "payload": ["type": "task_complete"]],
            ["type": "event_msg", "payload": ["type": "thread_settings_applied"]]
        ])
        XCTAssertEqual(result.status, .idle)
        XCTAssertEqual(result.turnOutcome, .completed)
    }

    func testRealTokenCountersDoNotDoubleCountReasoning() {
        let usage = CodexTranscriptReader.usage(from: ["input_tokens": 387741, "cached_input_tokens": 322048,
            "output_tokens": 2277, "reasoning_output_tokens": 245, "total_tokens": 390018])
        XCTAssertEqual(usage.total, 390018)
        XCTAssertEqual(usage.outputTokens, 2277)
    }

    func testResumeUsesExplicitIdentityRegardlessOfAge() {
        let id = "01a12ecb-4e6f-7b70-91a7-1ebfa3be4f62"
        XCTAssertEqual(CodexSessionLocator.explicitThreadID(command: "codex resume \(id)"), id)
        XCTAssertNil(CodexSessionLocator.explicitThreadID(command: "codex resume --last"))
        XCTAssertEqual(CodexRuntimeClient.threadURL(id: id)?.absoluteString, "codex://threads/\(id)")
        XCTAssertNil(CodexRuntimeClient.threadURL(id: "../settings"))
    }

    func testRuntimeIsAuthoritativeAndSubagentsAreExcluded() {
        var raw: [String: Any] = ["id": "01a12ecb-4e6f-7b70-91a7-1ebfa3be4f62", "cwd": "/tmp",
                                 "status": ["type": "idle"], "source": "vscode"]
        let thread = CodexRuntimeThread.parse(raw, socketPath: "/tmp/test.sock")!
        let stale = CodexTranscriptReader.CodexState(sessionId: thread.id, status: .running, tokenUsage: nil, turnStart: Date(), turnOutcome: nil)
        XCTAssertEqual(thread.status(transcript: stale), .idle)
        raw["parentThreadId"] = "parent"
        XCTAssertNil(CodexRuntimeThread.parse(raw, socketPath: "/tmp/test.sock"))
    }

    func testMetadataFallbackAndSourceIsolation() {
        let data = Data(#"{"type":"session_meta","payload":{"id":"test","cwd":"/tmp","source":{"subagent":{"parent_thread_id":"parent"}}}}"#.utf8)
        let metadata = CodexTranscriptReader.sessionMetadata(from: data)
        XCTAssertEqual(metadata?.sessionId, "test")
        XCTAssertEqual(metadata?.isSubagent, true)
    }
    func testAmbiguousSameDirectoryCandidatesAreNotAssigned() {
        let start = Date(timeIntervalSince1970: 1000)
        let candidates = [
            CodexTranscriptReader.SessionCandidate(path: "/one", startedAt: start, mtime: start),
            CodexTranscriptReader.SessionCandidate(path: "/two", startedAt: start, mtime: start)
        ]
        XCTAssertNil(CodexTranscriptReader.selectSessionPath(candidates: candidates, processStartedAt: start, excluding: []))
    }

    func testUnknownStateDoesNotNotifyCompletionOrClearUnread() {
        let start = Date(timeIntervalSince1970: 1000)
        func agent(_ status: AgentStatus) -> AgentInfo {
            AgentInfo(pid: 1, processStartedAt: start, type: .codex, tty: "ttys001", workingDirectory: "/tmp",
                      elapsedTime: "1m", status: status, sessionName: nil, sessionId: "session")
        }
        XCTAssertFalse(ProcessScanner.shouldNotifyCompletion(oldAgent: agent(.running), newAgent: agent(.unknown)))
        XCTAssertFalse(ProcessScanner.shouldMarkUnreadCompletion(oldAgent: agent(.running), newAgent: agent(.unknown)))
    }

    func testDesktopIdentitySurvivesNotificationAndUnreadUpdates() {
        let id = "01a12ecb-4e6f-7b70-91a7-1ebfa3be4f62"
        let desktop = AgentInfo(pid: 0, processStartedAt: Date(), type: .codex, tty: "", workingDirectory: "/tmp",
                                elapsedTime: "", status: .idle, sessionName: nil, sessionId: id,
                                codexSocketPath: "/tmp/test.sock", codexRolloutPath: "/tmp/rollout.jsonl")
        let target = NotificationTarget(agent: desktop)
        XCTAssertEqual(NotificationTarget(userInfo: target.userInfo), target)
        XCTAssertEqual(desktop.withHasUnread(true).codexRolloutPath, desktop.codexRolloutPath)
        XCTAssertEqual(desktop.withHasUnread(true).id, desktop.id)
    }

}
