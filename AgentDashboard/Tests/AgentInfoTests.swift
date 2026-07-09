import XCTest
@testable import AgentDashboard

final class AgentInfoTests: XCTestCase {

    func testParseElapsedTime() {
        // 输入来自 formatSeconds 的输出(空格分隔:"30s"/"2m 30s"/"1h 2m"/"1d 2h"),
        // 非空格连续串(如 "2m30s")解析不出。
        XCTAssertEqual(AgentInfo.parseElapsedTime("30s"), 30)
        XCTAssertEqual(AgentInfo.parseElapsedTime("2m 30s"), 150)
        XCTAssertEqual(AgentInfo.parseElapsedTime("1h 2m"), 3720)        // formatSeconds 丢秒
        XCTAssertEqual(AgentInfo.parseElapsedTime("1d 2h"), 93600)
        XCTAssertEqual(AgentInfo.parseElapsedTime("0s"), 0)
        XCTAssertEqual(AgentInfo.parseElapsedTime(""), 0)
    }
}
