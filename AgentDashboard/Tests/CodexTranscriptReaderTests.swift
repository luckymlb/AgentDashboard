import XCTest
@testable import AgentDashboard

final class CodexTranscriptReaderTests: XCTestCase {

    private struct StubExecPolicyEvaluator: CodexExecPolicyEvaluating {
        let result: CodexExecPolicyDecision

        func decision(for shellCommand: String, cwd: String?) -> CodexExecPolicyDecision {
            result
        }
    }

    private func makeReader(
        policyDecision: CodexExecPolicyDecision = .noMatch
    ) -> CodexTranscriptReader {
        CodexTranscriptReader(
            approvalEvaluator: StubExecPolicyEvaluator(result: policyDecision)
        )
    }

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
        var data = Data(#"{"timestamp":"2026-07-11T11:06:21.000Z","type":"session_meta","payload":{"session_id":"codex-session-1","cwd":"/tmp/宣传"},"tail":""#.utf8)
        data.append(0xE4) // first byte of a truncated three-byte UTF-8 character

        let metadata = CodexTranscriptReader.sessionMetadata(from: data)
        XCTAssertEqual(metadata?.sessionId, "codex-session-1")
        XCTAssertEqual(metadata?.cwd, "/tmp/宣传")
        XCTAssertNotNil(metadata?.startedAt)
    }

    func testReadStateCarriesStableSessionId() throws {
        let state = try readInlineState([
            #"{"timestamp":"2026-07-16T01:00:00.000Z","type":"session_meta","payload":{"session_id":"codex-session-2","cwd":"/tmp"}}"#,
            #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:00:02.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
        ])

        XCTAssertEqual(state.sessionId, "codex-session-2")
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

    private func readInlineState(
        _ records: [String], policyDecision: CodexExecPolicyDecision = .noMatch
    ) throws -> CodexTranscriptReader.CodexState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-state-\(UUID().uuidString).jsonl")
        try (records.joined(separator: "\n") + "\n").write(
            to: url, atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: url) }
        return try XCTUnwrap(
            makeReader(policyDecision: policyDecision).readState(transcriptPath: url.path)
        )
    }

    func testReadStateConfirming() {
        let s = makeReader().readState(transcriptPath: fixture("confirming"))
        XCTAssertEqual(s?.status, .confirming)
        XCTAssertNotNil(s?.turnStart)
    }

    /// Current Codex custom_tool_call stores tool JSON in payload.input, not arguments.
    func testReadStateConfirmingFromCustomToolInput() {
        let s = makeReader().readState(transcriptPath: fixture("confirming_custom"))
        XCTAssertEqual(s?.status, .confirming)
        XCTAssertNotNil(s?.turnStart)
    }

    func testReadStateConfirmingFromGeneratedJavaScriptInput() {
        let s = makeReader().readState(transcriptPath: fixture("confirming_custom_javascript"))
        XCTAssertEqual(s?.status, .confirming)
        XCTAssertNotNil(s?.turnStart)
    }

    func testReadStateConfirmingWhileRequestUserInputIsPending() {
        let s = makeReader().readState(transcriptPath: fixture("confirming_user_input"))
        XCTAssertEqual(s?.status, .confirming)
        XCTAssertNotNil(s?.turnStart)
    }

    func testRequestUserInputOutputClearsConfirming() {
        let s = makeReader().readState(transcriptPath: fixture("confirming_user_input_completed"))
        XCTAssertNotEqual(s?.status, .confirming)
    }

    func testReadStateConfirmingWhilePluginInstallChoiceIsPending() {
        let s = makeReader().readState(transcriptPath: fixture("confirming_plugin_install"))
        XCTAssertEqual(s?.status, .confirming)
    }

    func testUserConfirmationClassifierUsesExplicitInteractiveToolSet() {
        XCTAssertTrue(CodexTranscriptReader.isInteractiveTool("request_user_input"))
        XCTAssertTrue(CodexTranscriptReader.isInteractiveTool("request_plugin_install"))
        XCTAssertFalse(CodexTranscriptReader.isInteractiveTool("request_status"))
    }

    func testRequiresEscalationFromUnquotedJavaScriptProperty() {
        let input = #"const r = await tools.exec_command({ cmd: "ps", sandbox_permissions: "require_escalated" });"#
        XCTAssertTrue(CodexTranscriptReader.requiresEscalation(input))
    }

    func testRequiresEscalationFromQuotedJavaScriptProperty() {
        let input = #"const r = await tools.exec_command({ "cmd": "ps", "sandbox_permissions": "require_escalated" });"#
        XCTAssertTrue(CodexTranscriptReader.requiresEscalation(input))
    }

    func testRequiresEscalationIgnoresCommandText() {
        let input = #"const r = await tools.exec_command({ cmd: "rg 'sandbox_permissions: \"require_escalated\"'" });"#
        XCTAssertFalse(CodexTranscriptReader.requiresEscalation(input))
    }

    func testRequiresEscalationIgnoresComments() {
        let input = #"const r = await tools.exec_command({ cmd: "true" /* sandbox_permissions: "require_escalated" */ });"#
        XCTAssertFalse(CodexTranscriptReader.requiresEscalation(input))
    }

    func testEscalationRequestExtractsCommandFromGeneratedJavaScript() {
        let input = #"const r = await tools.exec_command({ cmd: "/usr/bin/log show --last 2m", sandbox_permissions: "require_escalated" });"#
        XCTAssertEqual(
            CodexTranscriptReader.escalationRequest(from: input)?.command,
            "/usr/bin/log show --last 2m"
        )
    }

    func testEscalationRequestsAssociateEachPermissionWithItsOwnCommand() {
        let input = #"const results = await Promise.all([tools.exec_command({ cmd: "ordinary", sandbox_permissions: "use_default" }), tools.exec_command({ cmd: "allowed log", sandbox_permissions: "require_escalated" }), tools.exec_command({ cmd: "needs approval", sandbox_permissions: "require_escalated" })]);"#

        XCTAssertEqual(
            CodexTranscriptReader.escalationRequests(from: input).map(\.command),
            ["allowed log", "needs approval"]
        )
    }

    func testEscalationRequestIgnoresNestedLookalikeProperty() {
        let input = #"await tools.exec_command({ cmd: "ordinary", metadata: { sandbox_permissions: "require_escalated" } });"#
        XCTAssertTrue(CodexTranscriptReader.escalationRequests(from: input).isEmpty)
    }

    func testAllowedLogEscalationReadsWithoutConfirming() throws {
        let state = try readInlineState([
            #"{"timestamp":"2026-07-16T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"turn_context","payload":{"approval_policy":"on-request","approvals_reviewer":"user","cwd":"/tmp"}}"#,
            #"{"timestamp":"2026-07-16T01:00:02.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.exec_command({ cmd: '/usr/bin/log show --last 2m', sandbox_permissions: 'require_escalated' });","call_id":"call-allowed"}}"#,
        ], policyDecision: .allow)

        XCTAssertEqual(state.status, .reading)
    }

    func testUnmatchedEscalationStillConfirms() throws {
        let state = try readInlineState([
            #"{"timestamp":"2026-07-16T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"turn_context","payload":{"approval_policy":"on-request","approvals_reviewer":"user","cwd":"/tmp"}}"#,
            #"{"timestamp":"2026-07-16T01:00:02.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.exec_command({ cmd: 'pwd', sandbox_permissions: 'require_escalated' });","call_id":"call-prompt"}}"#,
        ], policyDecision: .noMatch)

        XCTAssertEqual(state.status, .confirming)
    }

    func testUnavailablePolicyDoesNotCreateFalseConfirming() throws {
        let state = try readInlineState([
            #"{"timestamp":"2026-07-16T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"turn_context","payload":{"approval_policy":"on-request","approvals_reviewer":"user","cwd":"/tmp"}}"#,
            #"{"timestamp":"2026-07-16T01:00:02.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.exec_command({ cmd: 'pwd', sandbox_permissions: 'require_escalated' });","call_id":"call-unknown"}}"#,
        ], policyDecision: .unavailable)

        XCTAssertEqual(state.status, .running)
    }

    func testNeverApprovalPolicyDoesNotCreateConfirming() throws {
        let state = try readInlineState([
            #"{"timestamp":"2026-07-16T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"turn_context","payload":{"approval_policy":"never","approvals_reviewer":"user","cwd":"/tmp"}}"#,
            #"{"timestamp":"2026-07-16T01:00:02.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.exec_command({ cmd: 'pwd', sandbox_permissions: 'require_escalated' });","call_id":"call-never"}}"#,
        ], policyDecision: .noMatch)

        XCTAssertEqual(state.status, .running)
    }

    func testAutoReviewDoesNotPretendToWaitForUser() throws {
        let state = try readInlineState([
            #"{"timestamp":"2026-07-16T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"turn_context","payload":{"approval_policy":"on-request","approvals_reviewer":"auto_review","cwd":"/tmp"}}"#,
            #"{"timestamp":"2026-07-16T01:00:02.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.exec_command({ cmd: 'pwd', sandbox_permissions: 'require_escalated' });","call_id":"call-auto"}}"#,
        ], policyDecision: .noMatch)

        XCTAssertEqual(state.status, .running)
    }

    func testNewTurnDoesNotReusePreviousApprovalPolicy() throws {
        let state = try readInlineState([
            #"{"timestamp":"2026-07-16T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"turn_context","payload":{"approval_policy":"never","approvals_reviewer":"user","cwd":"/tmp"}}"#,
            #"{"timestamp":"2026-07-16T01:00:02.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
            #"{"timestamp":"2026-07-16T01:00:03.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:00:04.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.exec_command({ cmd: 'pwd', sandbox_permissions: 'require_escalated' });","call_id":"call-new-turn"}}"#,
        ], policyDecision: .noMatch)

        XCTAssertEqual(state.status, .confirming)
    }

    func testActivityClassifierUsesHighConfidenceToolIdentity() {
        XCTAssertEqual(CodexTranscriptReader.activityStatus(
            toolName: "exec", input: #"await tools.apply_patch(patch);"#
        ), .editing)
        XCTAssertEqual(CodexTranscriptReader.activityStatus(
            toolName: "exec", input: #"await tools.web__run({ search_query: [] });"#
        ), .searching)
        XCTAssertEqual(CodexTranscriptReader.activityStatus(
            toolName: "exec", input: #"await tools.read_mcp_resource({});"#
        ), .reading)
        XCTAssertEqual(CodexTranscriptReader.activityStatus(
            toolName: "exec", input: #"await collaboration.spawn_agent({});"#
        ), .processing)
        XCTAssertEqual(CodexTranscriptReader.activityStatus(
            toolName: "exec", input: #"await tools.exec_command({ cmd: "rg test" });"#
        ), .running)
        XCTAssertEqual(CodexTranscriptReader.activityStatus(
            toolName: "exec",
            input: #"await tools.exec_command({ cmd: "/usr/bin/log show --last 2m | tail -n 20" });"#
        ), .reading)
        XCTAssertEqual(CodexTranscriptReader.activityStatus(
            toolName: "exec",
            input: #"await tools.exec_command({ cmd: "/usr/bin/log show --last 2m && rm /tmp/example" });"#
        ), .running)
        XCTAssertEqual(CodexTranscriptReader.activityStatus(
            toolName: "future_tool", input: "{}"
        ), .busy)
    }

    func testActivityClassifierIgnoresToolNamesInsideStringsAndComments() {
        let input = #"await tools.exec_command({ cmd: "echo 'tools.apply_patch(patch)'" }); /* tools.web__run({}) */"#
        XCTAssertEqual(CodexTranscriptReader.activityStatus(toolName: "exec", input: input), .running)
    }

    func testActivityClassifierUsesLastNestedOperation() {
        let input = #"await tools.update_plan({}); await tools.exec_command({ cmd: "swift build" });"#
        XCTAssertEqual(CodexTranscriptReader.activityStatus(toolName: "exec", input: input), .running)
    }

    func testPendingCustomToolProducesEditingState() throws {
        let state = try readInlineState([
            #"{"timestamp":"2026-07-16T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"event_msg","payload":{"type":"user_message"}}"#,
            #"{"timestamp":"2026-07-16T01:00:02.000Z","type":"event_msg","payload":{"type":"agent_message"}}"#,
            #"{"timestamp":"2026-07-16T01:00:03.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const patch = 'x'; await tools.apply_patch(patch);","call_id":"call-edit"}}"#,
        ])

        XCTAssertEqual(state.status, .editing)
        XCTAssertNotNil(state.turnStart)
    }

    func testMatchingToolOutputRestoresCraftingState() throws {
        let state = try readInlineState([
            #"{"timestamp":"2026-07-16T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"event_msg","payload":{"type":"user_message"}}"#,
            #"{"timestamp":"2026-07-16T01:00:02.000Z","type":"event_msg","payload":{"type":"agent_message"}}"#,
            #"{"timestamp":"2026-07-16T01:00:03.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.apply_patch('x');","call_id":"call-edit"}}"#,
            #"{"timestamp":"2026-07-16T01:00:04.000Z","type":"event_msg","payload":{"type":"patch_apply_end"}}"#,
            #"{"timestamp":"2026-07-16T01:00:05.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-edit","output":"done"}}"#,
            #"{"timestamp":"2026-07-16T01:00:06.000Z","type":"event_msg","payload":{"type":"token_count","info":{}}}"#,
        ])

        XCTAssertEqual(state.status, .crafting)
    }

    func testUnrelatedOutputDoesNotClearNewerParallelTool() throws {
        let state = try readInlineState([
            #"{"timestamp":"2026-07-16T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"event_msg","payload":{"type":"agent_message"}}"#,
            #"{"timestamp":"2026-07-16T01:00:03.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.exec_command({});","call_id":"call-run"}}"#,
            #"{"timestamp":"2026-07-16T01:00:04.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.web__run({});","call_id":"call-search"}}"#,
            #"{"timestamp":"2026-07-16T01:00:05.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-run","output":"done"}}"#,
        ])

        XCTAssertEqual(state.status, .searching)
    }

    func testCompletingLatestParallelToolFallsBackToOlderTool() throws {
        let state = try readInlineState([
            #"{"timestamp":"2026-07-16T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"event_msg","payload":{"type":"agent_message"}}"#,
            #"{"timestamp":"2026-07-16T01:00:02.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.exec_command({});","call_id":"call-run"}}"#,
            #"{"timestamp":"2026-07-16T01:00:03.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.web__run({});","call_id":"call-search"}}"#,
            #"{"timestamp":"2026-07-16T01:00:04.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-search","output":"done"}}"#,
        ])

        XCTAssertEqual(state.status, .running)
    }

    func testConfirmationOverridesOrdinaryActiveTool() throws {
        let state = try readInlineState([
            #"{"timestamp":"2026-07-16T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.apply_patch('x');","call_id":"call-edit"}}"#,
            #"{"timestamp":"2026-07-16T01:00:02.000Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{}","call_id":"call-question"}}"#,
        ])

        XCTAssertEqual(state.status, .confirming)
    }

    func testTaskCompleteClearsOrdinaryActiveTools() throws {
        let state = try readInlineState([
            #"{"timestamp":"2026-07-16T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.apply_patch('x');","call_id":"call-edit"}}"#,
            #"{"timestamp":"2026-07-16T01:00:02.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
        ])

        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.turnOutcome, .completed)
    }

    func testTurnAbortedClearsOrdinaryActiveTools() throws {
        let state = try readInlineState([
            #"{"timestamp":"2026-07-16T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.web__run({});","call_id":"call-search"}}"#,
            #"{"timestamp":"2026-07-16T01:00:02.000Z","type":"event_msg","payload":{"type":"turn_aborted"}}"#,
        ])

        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.turnOutcome, .aborted)
    }

    func testPreviousTurnToolDoesNotLeakIntoNewTurn() throws {
        let state = try readInlineState([
            #"{"timestamp":"2026-07-16T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.apply_patch('x');","call_id":"call-old"}}"#,
            #"{"timestamp":"2026-07-16T01:00:02.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
            #"{"timestamp":"2026-07-16T01:01:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:01:01.000Z","type":"event_msg","payload":{"type":"user_message"}}"#,
        ])

        XCTAssertEqual(state.status, .thinking)
        XCTAssertNil(state.turnOutcome)
    }

    func testUnknownPendingToolUsesBusyFallback() throws {
        let state = try readInlineState([
            #"{"timestamp":"2026-07-16T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"response_item","payload":{"type":"function_call","name":"future_tool","arguments":"{}","call_id":"call-future"}}"#,
        ])

        XCTAssertEqual(state.status, .busy)
    }

    func testTokenCountDoesNotOverrideActiveToolStatus() throws {
        let state = try readInlineState([
            #"{"timestamp":"2026-07-16T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.web__run({});","call_id":"call-search"}}"#,
            #"{"timestamp":"2026-07-16T01:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{}}}"#,
        ])

        XCTAssertEqual(state.status, .searching)
    }

    func testSubAgentActivityUsesProcessingFallback() throws {
        let state = try readInlineState([
            #"{"timestamp":"2026-07-16T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"event_msg","payload":{"type":"sub_agent_activity","kind":"started"}}"#,
        ])

        XCTAssertEqual(state.status, .processing)
    }

    func testUnrelatedOutputDoesNotClearConfirming() {
        let s = makeReader().readState(transcriptPath: fixture("confirming_custom_unrelated_output"))
        XCTAssertEqual(s?.status, .confirming)
    }

    func testMatchingOutputClearsConfirming() {
        let s = makeReader().readState(transcriptPath: fixture("confirming_custom_completed"))
        XCTAssertNotEqual(s?.status, .confirming)
    }

    func testPreviousTurnApprovalDoesNotLeakIntoNewTurn() {
        let s = makeReader().readState(transcriptPath: fixture("confirming_stale_previous_turn"))
        XCTAssertEqual(s?.status, .thinking)
    }

    func testReadStateIdleWithToken() {
        let s = makeReader().readState(transcriptPath: fixture("idle"))
        XCTAssertEqual(s?.status, .idle)
        XCTAssertNil(s?.turnStart)
        XCTAssertEqual(s?.turnOutcome, .completed)
        XCTAssertEqual(s?.tokenUsage?.inputTokens, 800)
        XCTAssertEqual(s?.tokenUsage?.outputTokens, 60)
    }

    func testTurnAbortedEndsTurnAndIgnoresThreadRollback() {
        let s = makeReader().readState(transcriptPath: fixture("aborted"))
        XCTAssertEqual(s?.status, .idle)
        XCTAssertNil(s?.turnStart)
        XCTAssertEqual(s?.turnOutcome, .aborted)
    }

    func testTurnAbortedClearsPendingConfirmation() {
        let s = makeReader().readState(transcriptPath: fixture("aborted_confirming"))
        XCTAssertEqual(s?.status, .idle)
        XCTAssertNil(s?.turnStart)
        XCTAssertEqual(s?.turnOutcome, .aborted)
    }

    func testNewTurnAfterAbortResetsOutcome() {
        let s = makeReader().readState(transcriptPath: fixture("aborted_then_new_turn"))
        XCTAssertEqual(s?.status, .thinking)
        XCTAssertNotNil(s?.turnStart)
        XCTAssertNil(s?.turnOutcome)
    }

    func testReadStateRunning() {
        let s = makeReader().readState(transcriptPath: fixture("running"))
        XCTAssertEqual(s?.status, .running)
        XCTAssertNotNil(s?.turnStart)
    }

    /// 长 turn(task_started 被挤出 64KB)→ readState 渐进扩大窗口找回 task_started → running。
    func testReadStateLongTurn() {
        let s = makeReader().readState(transcriptPath: fixture("longturn"))
        XCTAssertEqual(s?.status, .running)
        XCTAssertNotNil(s?.turnStart)
    }
}
