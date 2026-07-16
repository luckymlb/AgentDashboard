import XCTest
@testable import AgentDashboard

final class CodexApprovalResolverTests: XCTestCase {
    private struct StubEvaluator: CodexExecPolicyEvaluating {
        let result: CodexExecPolicyDecision

        func decision(for shellCommand: String, cwd: String?) -> CodexExecPolicyDecision {
            result
        }
    }

    func testInteractiveToolAlwaysRequiresUser() {
        let resolver = CodexApprovalResolver(evaluator: StubEvaluator(result: .allow))
        let context = CodexApprovalContext(
            sandboxApproval: .disabled, ruleApproval: .disabled,
            reviewer: .autoReview, cwd: "/tmp"
        )

        XCTAssertEqual(resolver.decision(
            isInteractiveTool: true, escalationCommands: [], context: context
        ), .required)
    }

    func testAllowedEscalationDoesNotRequireUser() {
        XCTAssertEqual(decision(policyResult: .allow), .notRequired)
    }

    func testUnmatchedAndPromptRulesRequireUser() {
        XCTAssertEqual(decision(policyResult: .noMatch), .required)
        XCTAssertEqual(decision(policyResult: .prompt), .required)
    }

    func testForbiddenRuleDoesNotPretendToWaitForUser() {
        XCTAssertEqual(decision(policyResult: .forbidden), .notRequired)
    }

    func testUnavailablePolicyDoesNotCreateUnprovenConfirmation() {
        XCTAssertEqual(decision(policyResult: .unavailable), .unknown)
    }

    func testNeverAndAutoReviewPoliciesDoNotWaitForUser() {
        let never = CodexApprovalContext(
            sandboxApproval: .disabled, ruleApproval: .disabled,
            reviewer: .user, cwd: nil
        )
        let auto = CodexApprovalContext(
            sandboxApproval: .enabled, ruleApproval: .enabled,
            reviewer: .autoReview, cwd: nil
        )
        let resolver = CodexApprovalResolver(evaluator: StubEvaluator(result: .noMatch))

        XCTAssertEqual(resolver.decision(
            isInteractiveTool: false, escalationCommands: ["pwd"], context: never
        ), .notRequired)
        XCTAssertEqual(resolver.decision(
            isInteractiveTool: false, escalationCommands: ["pwd"], context: auto
        ), .notRequired)
    }

    func testAnyPromptingCommandMakesParallelCallConfirming() {
        struct CommandEvaluator: CodexExecPolicyEvaluating {
            func decision(for shellCommand: String, cwd: String?) -> CodexExecPolicyDecision {
                shellCommand == "allowed" ? .allow : .noMatch
            }
        }
        let resolver = CodexApprovalResolver(evaluator: CommandEvaluator())
        let context = CodexApprovalContext(
            sandboxApproval: .enabled, ruleApproval: .enabled,
            reviewer: .user, cwd: "/tmp"
        )

        XCTAssertEqual(resolver.decision(
            isInteractiveTool: false,
            escalationCommands: ["allowed", "needs approval"],
            context: context
        ), .required)
    }

    func testMissingCommandIsUnknownInsteadOfSilentlyAllowed() {
        let resolver = CodexApprovalResolver(evaluator: StubEvaluator(result: .allow))
        XCTAssertEqual(resolver.decision(
            isInteractiveTool: false,
            escalationCommands: [nil],
            context: CodexApprovalContext(
                sandboxApproval: .enabled, ruleApproval: .enabled,
                reviewer: .user, cwd: "/tmp"
            )
        ), .unknown)
    }

    func testTurnContextParsesGranularSandboxPolicy() {
        let disabled = CodexApprovalContext.parse([
            "approval_policy": ["granular": ["sandbox_approval": false]],
            "approvals_reviewer": "user",
            "cwd": "/tmp/project",
        ])
        XCTAssertEqual(disabled.sandboxApproval, .disabled)
        XCTAssertEqual(disabled.ruleApproval, .unknown)
        XCTAssertEqual(disabled.reviewer, .user)
        XCTAssertEqual(disabled.cwd, "/tmp/project")
    }

    func testGranularRulePromptCanBeRejectedWithoutUserWait() {
        let context = CodexApprovalContext.parse([
            "approval_policy": ["granular": [
                "sandbox_approval": true,
                "rules": false,
            ]],
            "approvals_reviewer": "user",
        ])
        let resolver = CodexApprovalResolver(evaluator: StubEvaluator(result: .prompt))

        XCTAssertEqual(resolver.decision(
            isInteractiveTool: false,
            escalationCommands: ["command"],
            context: context
        ), .notRequired)
    }

    func testGranularSandboxPromptCanBeRejectedWithoutUserWait() {
        let context = CodexApprovalContext.parse([
            "approval_policy": ["granular": [
                "sandbox_approval": false,
                "rules": true,
            ]],
            "approvals_reviewer": "user",
        ])
        let resolver = CodexApprovalResolver(evaluator: StubEvaluator(result: .noMatch))

        XCTAssertEqual(resolver.decision(
            isInteractiveTool: false,
            escalationCommands: ["command"],
            context: context
        ), .notRequired)
    }

    func testShellParserSplitsSafeLinearCommandChain() {
        XCTAssertEqual(CodexShellCommandParser.parse(
            #"git status --short && /usr/bin/log show --last 2m | tail -n 5"#
        ), [
            .init(tokens: ["git", "status", "--short"]),
            .init(tokens: ["/usr/bin/log", "show", "--last", "2m"]),
            .init(tokens: ["tail", "-n", "5"]),
        ])
    }

    func testShellParserPreservesQuotedArguments() {
        XCTAssertEqual(CodexShellCommandParser.parse(
            #"/usr/bin/log show --predicate 'subsystem == "com.lucky.AgentDashboard"'"#
        ), [
            .init(
                tokens: [
                    "/usr/bin/log", "show", "--predicate",
                    #"subsystem == "com.lucky.AgentDashboard""#,
                ]
            ),
        ])
    }

    func testShellParserRejectsUnsafeTopLevelSyntax() {
        XCTAssertNil(CodexShellCommandParser.parse("echo $HOME"))
        XCTAssertNil(CodexShellCommandParser.parse("echo ok > /tmp/out"))
        XCTAssertNil(CodexShellCommandParser.parse("for x in a; do echo $x; done"))
        XCTAssertNil(CodexShellCommandParser.parse("echo $(whoami)"))
    }

    func testShellParserKeepsQuotedWrapperAsSingleArgument() {
        XCTAssertEqual(CodexShellCommandParser.parse(
            #"/bin/zsh -lc "echo $HOME""#
        ), [
            .init(tokens: ["/bin/zsh", "-lc", "echo $HOME"]),
        ])
    }

    private func decision(
        policyResult: CodexExecPolicyDecision
    ) -> CodexUserConfirmationDecision {
        let resolver = CodexApprovalResolver(evaluator: StubEvaluator(result: policyResult))
        return resolver.decision(
            isInteractiveTool: false,
            escalationCommands: ["/usr/bin/log show --last 2m"],
            context: CodexApprovalContext(
                sandboxApproval: .enabled, ruleApproval: .enabled,
                reviewer: .user, cwd: "/tmp"
            )
        )
    }
}
