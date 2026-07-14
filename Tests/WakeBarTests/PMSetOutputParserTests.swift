import XCTest
@testable import WakeBar

final class PMSetOutputParserTests: XCTestCase {
    func testParsesEnabledSystemWideSetting() {
        let output = """
        System-wide power settings:
         SleepDisabled        1
        Currently in use:
         sleep                0
        """

        XCTAssertEqual(PMSetOutputParser.sleepPreventionEnabled(in: output), true)
    }

    func testParsesDisabledSystemWideSetting() {
        let output = """
        System-wide power settings:
         SleepDisabled\t\t0
        Currently in use:
         sleep                1
        """

        XCTAssertEqual(PMSetOutputParser.sleepPreventionEnabled(in: output), false)
    }

    func testDoesNotConfuseSleepTimerWithSleepDisabled() {
        let output = """
        Currently in use:
         sleep                0 (sleep prevented by sharingd)
        """

        XCTAssertNil(PMSetOutputParser.sleepPreventionEnabled(in: output))
    }

    func testRejectsUnknownValue() {
        XCTAssertNil(
            PMSetOutputParser.sleepPreventionEnabled(
                in: "SleepDisabled 2"
            )
        )
    }

    func testIsCaseInsensitive() {
        XCTAssertEqual(
            PMSetOutputParser.sleepPreventionEnabled(
                in: "sleepdisabled 1"
            ),
            true
        )
    }

    func testParsesConnectedPowerAndBatteryPercentage() {
        let output = """
        Now drawing from 'AC Power'
         -InternalBattery-0 (id=123)\t100%; charged; 0:00 remaining present: true
        """

        XCTAssertEqual(
            PMSetOutputParser.powerSnapshot(in: output),
            PowerSnapshot(source: .powerAdapter, batteryPercentage: 100)
        )
    }

    func testParsesBatteryPower() {
        let output = """
        Now drawing from 'Battery Power'
         -InternalBattery-0 (id=123)\t73%; discharging; 4:12 remaining present: true
        """

        XCTAssertEqual(
            PMSetOutputParser.powerSnapshot(in: output),
            PowerSnapshot(source: .battery, batteryPercentage: 73)
        )
    }

    func testUnknownPowerOutputFailsCalmly() {
        XCTAssertEqual(
            PMSetOutputParser.powerSnapshot(in: "No batteries found"),
            .unknown
        )
    }
}
