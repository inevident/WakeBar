import XCTest
@testable import WakeBar

final class LidAngleSensorTests: XCTestCase {
    func testReportDecoderReadsLittleEndianAngleAndRejectsInvalidReports() {
        XCTAssertEqual(
            MacBookLidAngleSensor.decodeAngle(
                report: [0, 42, 0, 0, 0, 0, 0, 0],
                length: 8
            ),
            42
        )
        XCTAssertEqual(
            MacBookLidAngleSensor.decodeAngle(
                report: [0, 179, 0, 0, 0, 0, 0, 0],
                length: 3
            ),
            179
        )
        XCTAssertNil(
            MacBookLidAngleSensor.decodeAngle(
                report: [0, 0],
                length: 2
            )
        )
        XCTAssertNil(
            MacBookLidAngleSensor.decodeAngle(
                report: [0, 181, 0, 0, 0, 0, 0, 0],
                length: 8
            )
        )
    }

    func testStartingClosedSeedsDetectorWithoutEmittingAClosure() {
        var detector = LidClosureDetector()

        XCTAssertFalse(detector.observe(angle: 0))
        XCTAssertFalse(detector.observe(angle: 0))
        XCTAssertFalse(detector.observe(angle: 0))
    }

    func testOpenToClosedTransitionRequiresTwoSamplesAndEmitsOnce() {
        var detector = LidClosureDetector()

        XCTAssertFalse(detector.observe(angle: 120))
        XCTAssertFalse(detector.isClosed)
        XCTAssertFalse(detector.observe(angle: 4))
        XCTAssertFalse(detector.isClosed)
        XCTAssertTrue(detector.observe(angle: 0))
        XCTAssertTrue(detector.isClosed)
        XCTAssertFalse(detector.observe(angle: 0))
        XCTAssertTrue(detector.isClosed)
    }

    func testInvalidSampleBreaksConsecutiveClosedConfirmation() {
        var detector = LidClosureDetector()

        XCTAssertFalse(detector.observe(angle: 120))
        XCTAssertFalse(detector.observe(angle: 0))
        XCTAssertFalse(detector.observe(angle: nil))
        XCTAssertFalse(detector.observe(angle: 0))
        XCTAssertTrue(detector.observe(angle: 0))
    }

    func testHysteresisRequiresFullReopenBeforeAnotherClosure() {
        var detector = LidClosureDetector()

        XCTAssertFalse(detector.observe(angle: 120))
        XCTAssertFalse(detector.observe(angle: 0))
        XCTAssertTrue(detector.observe(angle: 0))
        XCTAssertFalse(detector.observe(angle: 7))
        XCTAssertTrue(detector.isClosed)
        XCTAssertFalse(detector.observe(angle: 0))
        XCTAssertFalse(detector.observe(angle: 0))
        XCTAssertFalse(detector.observe(angle: 10))
        XCTAssertFalse(detector.isClosed)
        XCTAssertFalse(detector.observe(angle: 0))
        XCTAssertTrue(detector.observe(angle: 0))
    }

    func testInvalidReadingGapReseedsWithoutInventingAClosure() {
        var detector = LidClosureDetector()

        XCTAssertFalse(detector.observe(angle: 120))
        for _ in 0..<LidClosureDetector.invalidSamplesBeforeReset {
            XCTAssertFalse(detector.observe(angle: nil))
        }
        XCTAssertFalse(detector.observe(angle: 0))
        XCTAssertFalse(detector.observe(angle: 0))
    }
}
