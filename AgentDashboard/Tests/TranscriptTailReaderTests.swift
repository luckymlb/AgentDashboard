import XCTest
@testable import AgentDashboard

final class TranscriptTailReaderTests: XCTestCase {

    private func writeTranscript(_ events: [[String: Any]]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-dashboard-transcript-\(UUID().uuidString).jsonl")
        var transcript = Data()
        for event in events {
            transcript.append(try JSONSerialization.data(withJSONObject: event))
            transcript.append(Data("\n".utf8))
        }
        try transcript.write(to: url)
        return url
    }

    private func askEvent(id: String = "tool-1") -> [String: Any] {
        [
            "type": "assistant",
            "message": [
                "content": [[
                    "type": "tool_use",
                    "name": "AskUserQuestion",
                    "id": id,
                    "input": ["question": "Continue?"]
                ]]
            ]
        ]
    }

    private func toolResultEvent(id: String) -> [String: Any] {
        [
            "type": "user",
            "message": [
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": "Yes"
                ]]
            ]
        ]
    }

    func testUnansweredAskUserQuestionIsConfirming() throws {
        let url = try writeTranscript([askEvent()])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(TranscriptTailReader().inferActivity(transcriptPath: url.path), .confirming)
    }

    func testAnsweredAskUserQuestionIsProcessing() throws {
        let url = try writeTranscript([askEvent(), toolResultEvent(id: "tool-1")])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(TranscriptTailReader().inferActivity(transcriptPath: url.path), .processing)
    }

    func testUnrelatedToolResultDoesNotResolveQuestion() throws {
        let url = try writeTranscript([askEvent(), toolResultEvent(id: "another-tool")])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(TranscriptTailReader().inferActivity(transcriptPath: url.path), .confirming)
    }
}
