import XCTest
@testable import AgentDashboard

final class ScanRevisionGateTests: XCTestCase {

    func testAcceptsLatestRequestedRevision() {
        var gate = ScanRevisionGate()

        let revision = gate.registerRequest()

        XCTAssertTrue(gate.accepts(revision))
    }

    func testRejectsResultAfterNewerRequest() {
        var gate = ScanRevisionGate()
        let staleRevision = gate.registerRequest()
        let latestRevision = gate.registerRequest()

        XCTAssertFalse(gate.accepts(staleRevision))
        XCTAssertTrue(gate.accepts(latestRevision))
    }
}
