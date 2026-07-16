import Foundation
import XCTest
@testable import AgentDashboard

final class NotificationTargetResolverTests: XCTestCase {
    func testConfirmationIdentifiersAreUniquePerEpisode() {
        let first = NotificationManager.confirmationIdentifier(agentId: "123-ttys001")
        let second = NotificationManager.confirmationIdentifier(agentId: "123-ttys001")

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasPrefix("confirm-123-ttys001-"))
        XCTAssertTrue(second.hasPrefix("confirm-123-ttys001-"))
    }

    private let start = Date(timeIntervalSince1970: 1_000)

    func testPayloadRoundTripPreservesStableIdentity() {
        let agent = AgentInfo(
            pid: 42,
            processStartedAt: start,
            type: .codex,
            tty: "ttys008",
            workingDirectory: "/tmp/project",
            elapsedTime: "",
            status: .idle,
            sessionName: nil,
            sessionId: "session-1",
            terminalApp: .iTerm2
        )

        let target = NotificationTarget(agent: agent)
        XCTAssertEqual(NotificationTarget(userInfo: target.userInfo), target)
    }

    func testPayloadSurvivesPropertyListSerialization() throws {
        let target = makeTarget()
        let data = try PropertyListSerialization.data(
            fromPropertyList: target.userInfo,
            format: .binary,
            options: 0
        )
        let decoded = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [AnyHashable: Any]
        )

        XCTAssertEqual(NotificationTarget(userInfo: decoded), target)
    }

    func testLegacyPayloadIsRejected() {
        XCTAssertNil(NotificationTarget(userInfo: [
            "tty": "ttys008",
            "terminalApp": TerminalApp.iTerm2.rawValue,
        ]))
    }

    func testLiveOriginalProcessUsesFreshDestination() {
        let target = makeTarget(tty: "ttys001", terminalApp: .iTerm2)
        let live = makeLive(tty: "ttys009", terminalApp: .terminal)

        XCTAssertEqual(
            NotificationTargetResolver.validate(target, liveProcess: live),
            .destination(tty: "ttys009", terminalApp: .terminal)
        )
    }

    func testExitedProcessIsRejectedInsteadOfUsingStaleTTY() {
        XCTAssertEqual(
            NotificationTargetResolver.validate(makeTarget(), liveProcess: nil),
            .rejected(.processMissing)
        )
    }

    func testReusedPIDIsRejectedEvenWhenTTYMatches() {
        let reused = makeLive(
            processStartedAt: start.addingTimeInterval(60),
            tty: "ttys001"
        )

        XCTAssertEqual(
            NotificationTargetResolver.validate(makeTarget(), liveProcess: reused),
            .rejected(.pidReused)
        )
    }

    func testDifferentAgentTypeIsRejected() {
        XCTAssertEqual(
            NotificationTargetResolver.validate(
                makeTarget(agentType: .codex),
                liveProcess: makeLive(agentType: .claude)
            ),
            .rejected(.agentTypeChanged)
        )
    }

    func testUnknownLiveTerminalIsRejected() {
        XCTAssertEqual(
            NotificationTargetResolver.validate(
                makeTarget(),
                liveProcess: makeLive(terminalApp: .unknown)
            ),
            .rejected(.terminalUnknown)
        )
    }

    func testProcessLineParsesIdentity() {
        let now = Date(timeIntervalSince1970: 2_000)
        let process = NotificationTargetResolver.parseProcessLine(
            "42 ttys008 01:00 codex",
            now: now,
            terminalApp: .iTerm2
        )

        XCTAssertEqual(process?.pid, 42)
        XCTAssertEqual(process?.processStartedAt, Date(timeIntervalSince1970: 1_940))
        XCTAssertEqual(process?.agentType, .codex)
        XCTAssertEqual(process?.tty, "ttys008")
        XCTAssertEqual(process?.terminalApp, .iTerm2)
    }

    func testNonAgentProcessLineIsRejected() {
        XCTAssertNil(NotificationTargetResolver.parseProcessLine(
            "42 ttys008 01:00 zsh",
            now: start,
            terminalApp: .iTerm2
        ))
    }

    private func makeTarget(
        agentType: AgentType = .codex,
        tty: String = "ttys001",
        terminalApp: TerminalApp = .iTerm2
    ) -> NotificationTarget {
        NotificationTarget(agent: AgentInfo(
            pid: 42,
            processStartedAt: start,
            type: agentType,
            tty: tty,
            workingDirectory: "/tmp/project",
            elapsedTime: "",
            status: .idle,
            sessionName: nil,
            sessionId: "session-1",
            terminalApp: terminalApp
        ))
    }

    private func makeLive(
        processStartedAt: Date? = nil,
        agentType: AgentType = .codex,
        tty: String = "ttys001",
        terminalApp: TerminalApp = .iTerm2
    ) -> LiveAgentProcess {
        LiveAgentProcess(
            pid: 42,
            processStartedAt: processStartedAt ?? start,
            agentType: agentType,
            tty: tty,
            terminalApp: terminalApp
        )
    }
}
