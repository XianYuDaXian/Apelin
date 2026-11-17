import XCTest
@testable import ApelinProtocol

final class AgentReasoningEffortTests: XCTestCase {
    func testCustomRawValueSurvivesCoding() throws {
        let effort = AgentReasoningEffort(rawValue: "Ultra-High")

        let data = try JSONEncoder().encode(effort)
        let decoded = try JSONDecoder().decode(AgentReasoningEffort.self, from: data)

        XCTAssertEqual(decoded, effort)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"Ultra-High\"")
        XCTAssertTrue(effort.isCustom)
    }

    func testBuiltInCasesKeepTheirWireValues() {
        XCTAssertEqual(
            AgentReasoningEffort.knownCases.map { $0.rawValue },
            ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
        )
        XCTAssertFalse(AgentReasoningEffort.high.isCustom)
    }

    func testOrderingCanPlaceCustomValuesFirst() {
        let ordered = AgentReasoningEffort.ordered(
            [.off, AgentReasoningEffort(rawValue: "deep-think"), .high, AgentReasoningEffort(rawValue: "deep-think")],
            customFirst: true,
        )

        XCTAssertEqual(
            ordered.map { $0.rawValue },
            ["deep-think", "off", "high"],
        )
    }

    func testOrderingDefaultsToPlacingCustomValuesLast() {
        let ordered = AgentReasoningEffort.ordered(
            [AgentReasoningEffort(rawValue: "deep-think"), .off, .high],
            customFirst: false,
        )

        XCTAssertEqual(
            ordered.map { $0.rawValue },
            ["off", "high", "deep-think"],
        )
    }
}
