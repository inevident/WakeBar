import Foundation
import XCTest
@testable import WakeBar

@MainActor
final class SleepControlModelTests: XCTestCase {
    func testDefaultPolicyIsAutomaticAndInvalidPreferenceFallsBackSafely() {
        let (preferences, suite) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("not-a-mode", forKey: SleepControlModel.policyPreferenceKey)

        let model = makeModel(
            service: StubPMSetService(currentValue: false),
            preferences: preferences
        )

        XCTAssertEqual(model.policyMode, .automatic)
        XCTAssertEqual(model.menuBarText, "AUTO")
    }

    func testLifetimeWakeSessionCountLoadsAndClampsNegativeValues() {
        let (seededPreferences, seededSuite) = makePreferences(
            lifetimeWakeSessionCount: 27
        )
        defer { seededPreferences.removePersistentDomain(forName: seededSuite) }

        let seededModel = makeModel(
            service: StubPMSetService(currentValue: false),
            preferences: seededPreferences
        )

        XCTAssertEqual(seededModel.lifetimeWakeSessionCount, 27)

        let (negativePreferences, negativeSuite) = makePreferences(
            lifetimeWakeSessionCount: -3
        )
        defer { negativePreferences.removePersistentDomain(forName: negativeSuite) }

        let clampedModel = makeModel(
            service: StubPMSetService(currentValue: false),
            preferences: negativePreferences
        )

        XCTAssertEqual(clampedModel.lifetimeWakeSessionCount, 0)
        XCTAssertEqual(
            negativePreferences.integer(
                forKey: SleepControlModel.lifetimeWakeSessionPreferenceKey
            ),
            0
        )
    }

    func testRefreshPublishesStatePowerAndAuthorization() async {
        let service = StubPMSetService(
            currentValue: false,
            configured: true,
            powerSnapshot: PowerSnapshot(source: .powerAdapter, batteryPercentage: 91)
        )
        let model = makeModel(service: service)

        await model.refresh()

        XCTAssertEqual(model.state, .disabled)
        XCTAssertEqual(model.instantControlState, .ready)
        XCTAssertEqual(
            model.powerSnapshot,
            PowerSnapshot(source: .powerAdapter, batteryPercentage: 91)
        )
        XCTAssertNil(model.notice)
    }

    func testPersistedOffCorrectsAnEnabledSystemAtLaunch() async {
        let (preferences, suite) = makePreferences(mode: .off)
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = StubPMSetService(currentValue: true, configured: true)
        let model = makeModel(service: service, preferences: preferences)

        await model.refresh()

        XCTAssertEqual(model.policyMode, .off)
        XCTAssertEqual(model.state, .disabled)
        await assertWrites([false], from: service)
    }

    func testOffWithActiveAgentsWarnsWithoutOverridingTheSelectedMode() async {
        let (preferences, suite) = makePreferences(mode: .off)
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = StubPMSetService(currentValue: false, configured: true)
        let detector = SequenceAgentDetector([
            .healthy([
                makeActivity(id: "codex:one"),
                makeActivity(id: "claude:two", runtime: .claude)
            ])
        ])
        let model = makeModel(
            service: service,
            detector: detector,
            preferences: preferences
        )

        await model.refresh()
        await model.pollAgentActivity(now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(model.policyMode, .off)
        XCTAssertEqual(model.state, .disabled)
        XCTAssertTrue(model.hasAgentsWhileOff)
        XCTAssertEqual(model.menuBarText, "OFF · 2")
        XCTAssertEqual(model.menuBarSymbol, "exclamationmark.triangle.fill")
        XCTAssertEqual(
            model.menuBarAccessibilityLabel,
            "WakeBar off, 2 active agents are unprotected and macOS may sleep"
        )
        await assertWrites([], from: service)
    }

    func testPersistedOnCorrectsADisabledSystemAtLaunch() async {
        let (preferences, suite) = makePreferences(mode: .on)
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = StubPMSetService(currentValue: false, configured: true)
        let model = makeModel(service: service, preferences: preferences)

        await model.refresh()

        XCTAssertEqual(model.policyMode, .on)
        XCTAssertEqual(model.state, .enabled)
        XCTAssertEqual(model.lifetimeWakeSessionCount, 0)
        await assertWrites([true], from: service)
    }

    func testAutomaticEngagesImmediatelyForActiveLocalWork() async {
        let service = StubPMSetService(currentValue: false, configured: true)
        let detector = SequenceAgentDetector([
            .healthy([makeActivity(id: "codex:one")])
        ])
        let model = makeModel(service: service, detector: detector)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        await model.refresh()
        await model.pollAgentActivity(now: now)

        XCTAssertEqual(model.policyMode, .automatic)
        XCTAssertEqual(model.activeAgentCount, 1)
        XCTAssertEqual(model.state, .enabled)
        XCTAssertEqual(model.menuBarText, "AUTO · 1")
        XCTAssertEqual(model.lifetimeWakeSessionCount, 0)
        await assertWrites([true], from: service)
    }

    func testAutomaticWakeSessionCountPersistsWithoutDoubleCounting() async {
        let (preferences, suite) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = StubPMSetService(currentValue: false, configured: true)
        let detector = SequenceAgentDetector([
            .healthy([makeActivity(id: "codex:one")])
        ])
        let lidAngleSensor = SequenceLidAngleSensor([120, 0, 0, 0])
        let model = makeModel(
            service: service,
            detector: detector,
            lidAngleSensor: lidAngleSensor,
            preferences: preferences
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await model.refresh()
        await model.pollAgentActivity(now: start)
        await model.pollLidAngle()
        await model.pollLidAngle()
        await model.pollLidAngle()
        await model.pollLidAngle()

        XCTAssertEqual(model.lifetimeWakeSessionCount, 1)
        XCTAssertEqual(
            preferences.integer(
                forKey: SleepControlModel.lifetimeWakeSessionPreferenceKey
            ),
            1
        )

        let relaunchedModel = makeModel(
            service: service,
            detector: SequenceAgentDetector([
                .healthy([makeActivity(id: "codex:one")])
            ]),
            lidAngleSensor: SequenceLidAngleSensor([0, 0]),
            preferences: preferences
        )
        await relaunchedModel.refresh()
        await relaunchedModel.pollAgentActivity(now: start.addingTimeInterval(10))
        await relaunchedModel.pollLidAngle()
        await relaunchedModel.pollLidAngle()

        XCTAssertEqual(relaunchedModel.lifetimeWakeSessionCount, 1)
        await assertWrites([true], from: service)
    }

    func testAutomaticProtectedLidClosureCountsOnce() async {
        let service = StubPMSetService(currentValue: false, configured: true)
        let detector = SequenceAgentDetector([
            .healthy([makeActivity(id: "codex:one")])
        ])
        let model = makeModel(
            service: service,
            detector: detector,
            lidAngleSensor: SequenceLidAngleSensor([120, 4, 0, 0])
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        await model.refresh()
        await model.pollAgentActivity(now: now)
        await model.pollLidAngle()
        await model.pollLidAngle()
        await model.pollLidAngle()
        await model.pollLidAngle()

        XCTAssertEqual(model.state, .enabled)
        XCTAssertEqual(model.lifetimeWakeSessionCount, 1)
        await assertWrites([true], from: service)
    }

    func testLidClosedIndicatorUsesConfirmedPositionAndReopenHysteresis() async {
        let model = makeModel(
            service: StubPMSetService(currentValue: false, configured: true),
            detector: SequenceAgentDetector([.healthy([])]),
            lidAngleSensor: SequenceLidAngleSensor([120, 0, 0, 7, 12])
        )

        await model.pollLidAngle()
        XCTAssertFalse(model.isLidClosed)

        await model.pollLidAngle()
        XCTAssertFalse(model.isLidClosed)

        await model.pollLidAngle()
        XCTAssertTrue(model.isLidClosed)

        await model.pollLidAngle()
        XCTAssertTrue(model.isLidClosed)

        await model.pollLidAngle()
        XCTAssertFalse(model.isLidClosed)
    }

    func testLeavingAutomaticModeClearsLidClosedIndicator() async {
        let model = makeModel(
            service: StubPMSetService(currentValue: false, configured: true),
            detector: SequenceAgentDetector([.healthy([])]),
            lidAngleSensor: SequenceLidAngleSensor([0, 0, 0])
        )

        await model.pollLidAngle()
        await model.pollLidAngle()
        XCTAssertTrue(model.isLidClosed)

        await model.applyPolicyMode(.on)
        XCTAssertFalse(model.isLidClosed)

        await model.pollLidAngle()
        XCTAssertFalse(model.isLidClosed)
    }

    func testExternalDisableImmediatelyBeforeClosureDoesNotCount() async {
        let service = StubPMSetService(currentValue: false, configured: true)
        let detector = SequenceAgentDetector([
            .healthy([makeActivity(id: "codex:one")])
        ])
        let model = makeModel(
            service: service,
            detector: detector,
            lidAngleSensor: SequenceLidAngleSensor([120, 0, 0])
        )

        await model.refresh()
        await model.pollAgentActivity()
        await model.pollLidAngle()
        await service.setExternalState(false)
        await model.pollLidAngle()
        await model.pollLidAngle()

        XCTAssertEqual(model.state, .disabled)
        XCTAssertEqual(model.lifetimeWakeSessionCount, 0)
        await assertWrites([true], from: service)
    }

    func testOnModeLidClosureDoesNotCount() async {
        let service = StubPMSetService(currentValue: false, configured: true)
        let detector = SequenceAgentDetector([
            .healthy([makeActivity(id: "codex:one")])
        ])
        let model = makeModel(
            service: service,
            detector: detector,
            lidAngleSensor: SequenceLidAngleSensor([120, 0, 0])
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        await model.refresh()
        await model.applyPolicyMode(.on)
        await model.pollAgentActivity(now: now)
        await model.pollLidAngle()
        await model.pollLidAngle()
        await model.pollLidAngle()

        XCTAssertEqual(model.state, .enabled)
        XCTAssertEqual(model.lifetimeWakeSessionCount, 0)
        await assertWrites([true], from: service)
    }

    func testLidMustFullyReopenBeforeAnotherClosureCounts() async {
        let service = StubPMSetService(currentValue: false, configured: true)
        let detector = SequenceAgentDetector([
            .healthy([makeActivity(id: "codex:one")])
        ])
        let sensor = SequenceLidAngleSensor([
            120, 0, 0, 0, 7, 0, 0, 12, 0, 0
        ])
        let model = makeModel(
            service: service,
            detector: detector,
            lidAngleSensor: sensor
        )

        await model.refresh()
        await model.pollAgentActivity()
        for _ in 0..<10 {
            await model.pollLidAngle()
        }

        XCTAssertEqual(model.state, .enabled)
        XCTAssertEqual(model.lifetimeWakeSessionCount, 2)
        await assertWrites([true], from: service)
    }

    func testClosureBeforeAgentStartsDoesNotCountLaterWhileStillClosed() async {
        let service = StubPMSetService(currentValue: false, configured: true)
        let detector = SequenceAgentDetector([
            .healthy([]),
            .healthy([makeActivity(id: "codex:one")])
        ])
        let model = makeModel(
            service: service,
            detector: detector,
            lidAngleSensor: SequenceLidAngleSensor([120, 0, 0, 0])
        )

        await model.refresh()
        await model.pollAgentActivity()
        await model.pollLidAngle()
        await model.pollLidAngle()
        await model.pollLidAngle()
        await model.pollAgentActivity()
        await model.pollLidAngle()

        XCTAssertEqual(model.state, .enabled)
        XCTAssertEqual(model.lifetimeWakeSessionCount, 0)
        await assertWrites([true], from: service)
    }

    func testGraceOnlyLidClosureDoesNotCount() async {
        let service = StubPMSetService(currentValue: false, configured: true)
        let detector = SequenceAgentDetector([
            .healthy([makeActivity(id: "codex:one")]),
            .healthy([])
        ])
        let model = makeModel(
            service: service,
            detector: detector,
            lidAngleSensor: SequenceLidAngleSensor([120, 0, 0]),
            releaseGracePeriod: 90
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await model.refresh()
        await model.pollAgentActivity(now: start)
        await model.pollLidAngle()
        await model.pollAgentActivity(now: start.addingTimeInterval(1))
        await model.pollLidAngle()
        await model.pollLidAngle()

        XCTAssertTrue(model.isHoldingAutoGrace)
        XCTAssertEqual(model.state, .enabled)
        XCTAssertEqual(model.lifetimeWakeSessionCount, 0)
    }

    func testLifetimeWakeSessionCountSaturatesAtIntMax() async {
        let (preferences, suite) = makePreferences(
            lifetimeWakeSessionCount: .max
        )
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = StubPMSetService(currentValue: false, configured: true)
        let detector = SequenceAgentDetector([
            .healthy([makeActivity(id: "codex:one")])
        ])
        let model = makeModel(
            service: service,
            detector: detector,
            lidAngleSensor: SequenceLidAngleSensor([120, 0, 0]),
            preferences: preferences
        )

        await model.refresh()
        await model.pollAgentActivity()
        await model.pollLidAngle()
        await model.pollLidAngle()
        await model.pollLidAngle()

        XCTAssertEqual(model.state, .enabled)
        XCTAssertEqual(model.lifetimeWakeSessionCount, .max)
        XCTAssertEqual(
            preferences.integer(
                forKey: SleepControlModel.lifetimeWakeSessionPreferenceKey
            ),
            .max
        )
        await assertWrites([true], from: service)
    }

    func testClosedLidDoesNotCountWithoutVerifiedAutomaticProtection() async {
        let service = StubPMSetService(currentValue: false, configured: false)
        let detector = SequenceAgentDetector([
            .healthy([makeActivity(id: "codex:one")])
        ])
        let model = makeModel(
            service: service,
            detector: detector,
            lidAngleSensor: SequenceLidAngleSensor([120, 0, 0])
        )

        await model.refresh()
        await model.pollAgentActivity()
        await model.pollLidAngle()
        await model.pollLidAngle()
        await model.pollLidAngle()

        XCTAssertEqual(model.state, .disabled)
        XCTAssertEqual(model.lifetimeWakeSessionCount, 0)
        await assertWrites([], from: service)
    }

    func testAutomaticHoldsGraceThenReleasesAtBoundary() async {
        let service = StubPMSetService(currentValue: false, configured: true)
        let detector = SequenceAgentDetector([
            .healthy([makeActivity(id: "codex:one")]),
            .healthy([]),
            .healthy([])
        ])
        let model = makeModel(
            service: service,
            detector: detector,
            releaseGracePeriod: 90
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await model.refresh()
        await model.pollAgentActivity(now: start)
        await model.pollAgentActivity(now: start.addingTimeInterval(30))

        XCTAssertTrue(model.isHoldingAutoGrace)
        XCTAssertEqual(model.activeAgentCount, 0)
        XCTAssertEqual(model.state, .enabled)
        XCTAssertEqual(model.menuBarText, "AUTO")
        XCTAssertEqual(model.menuBarSymbol, "hourglass")
        XCTAssertFalse(model.menuBarAccessibilityLabel.contains("0 active"))

        await model.pollAgentActivity(now: start.addingTimeInterval(90))

        XCTAssertFalse(model.isHoldingAutoGrace)
        XCTAssertEqual(model.state, .disabled)
        XCTAssertEqual(model.menuBarSymbol, "eye.fill")
        await assertWrites([true, false], from: service)
    }

    func testNewActivityCancelsReleaseGrace() async {
        let service = StubPMSetService(currentValue: false, configured: true)
        let detector = SequenceAgentDetector([
            .healthy([makeActivity(id: "codex:one")]),
            .healthy([]),
            .healthy([makeActivity(id: "claude:two", runtime: .claude)])
        ])
        let model = makeModel(service: service, detector: detector)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await model.refresh()
        await model.pollAgentActivity(now: start)
        await model.pollAgentActivity(now: start.addingTimeInterval(30))
        await model.pollAgentActivity(now: start.addingTimeInterval(45))

        XCTAssertFalse(model.isHoldingAutoGrace)
        XCTAssertEqual(model.agentActivities.map(\.id), ["claude:two"])
        XCTAssertEqual(model.state, .enabled)
        await assertWrites([true], from: service)
    }

    func testFailedScanNeverReleasesAutomaticLock() async {
        let service = StubPMSetService(currentValue: false, configured: true)
        let detector = SequenceAgentDetector([
            .healthy([makeActivity(id: "codex:one")]),
            .failed
        ])
        let model = makeModel(service: service, detector: detector)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await model.refresh()
        await model.pollAgentActivity(now: start)
        await model.pollAgentActivity(now: start.addingTimeInterval(120))

        XCTAssertFalse(model.agentDetectorAvailable)
        XCTAssertEqual(model.state, .enabled)
        await assertWrites([true], from: service)
    }

    func testFailedScanRepairsDisabledDriftUsingLastPositiveEvidence() async {
        let service = StubPMSetService(currentValue: false, configured: true)
        let detector = SequenceAgentDetector([
            .healthy([makeActivity(id: "codex:one")]),
            .failed
        ])
        let model = makeModel(service: service, detector: detector)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await model.refresh()
        await model.pollAgentActivity(now: start)
        await service.setExternalState(false)
        await model.pollAgentActivity(now: start.addingTimeInterval(21))

        XCTAssertEqual(model.state, .enabled)
        XCTAssertFalse(model.agentDetectorAvailable)
        await assertWrites([true, true], from: service)
    }

    func testDegradedEmptyScanNeverReleasesAutomaticLock() async {
        let service = StubPMSetService(currentValue: false, configured: true)
        let detector = SequenceAgentDetector([
            .healthy([makeActivity(id: "codex:one")]),
            .degraded([])
        ])
        let model = makeModel(service: service, detector: detector)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await model.refresh()
        await model.pollAgentActivity(now: start)
        await model.pollAgentActivity(now: start.addingTimeInterval(120))

        XCTAssertTrue(model.agentDetectorAvailable)
        XCTAssertFalse(model.agentScanConclusive)
        XCTAssertEqual(model.state, .enabled)
        await assertWrites([true], from: service)
    }

    func testDegradedPositiveEvidenceStillEngagesAutomaticLock() async {
        let service = StubPMSetService(currentValue: false, configured: true)
        let detector = SequenceAgentDetector([
            .degraded([makeActivity(id: "codex:one")])
        ])
        let model = makeModel(service: service, detector: detector)

        await model.refresh()
        await model.pollAgentActivity(now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(model.state, .enabled)
        XCTAssertEqual(model.activeAgentCount, 1)
        XCTAssertFalse(model.agentScanConclusive)
        await assertWrites([true], from: service)
    }

    func testBackgroundAutomaticDetectionNeverPromptsForSetup() async {
        let service = StubPMSetService(currentValue: false, configured: false)
        let detector = SequenceAgentDetector([
            .healthy([makeActivity(id: "codex:one")])
        ])
        let model = makeModel(service: service, detector: detector)

        await model.refresh()
        await model.pollAgentActivity(now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(model.state, .disabled)
        XCTAssertEqual(model.instantControlState, .setupRequired)
        await assertInstallations(0, from: service)
        await assertWrites([], from: service)
        XCTAssertFalse(model.policyMatchesSystemState)
        XCTAssertEqual(model.menuBarSymbol, "exclamationmark.shield.fill")
        XCTAssertNil(model.notice)
    }

    func testExplicitAutomaticSelectionInstallsOnceWhileIdle() async {
        let (preferences, suite) = makePreferences(mode: .off)
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = StubPMSetService(currentValue: false, configured: false)
        let model = makeModel(service: service, preferences: preferences)

        await model.refresh()
        await model.applyPolicyMode(.automatic)

        XCTAssertEqual(model.policyMode, .automatic)
        XCTAssertEqual(model.instantControlState, .ready)
        await assertInstallations(1, from: service)
        await assertWrites([], from: service)
    }

    func testMissingAuthorizationInstallsOnceThenRetriesPendingOnChange() async {
        let (preferences, suite) = makePreferences(mode: .off)
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = StubPMSetService(
            currentValue: false,
            configured: false,
            writeErrors: [.instantAuthorizationRequired]
        )
        let model = makeModel(service: service, preferences: preferences)

        await model.refresh()
        await model.applyPolicyMode(.on)

        XCTAssertEqual(model.state, .enabled)
        XCTAssertEqual(model.instantControlState, .ready)
        await assertInstallations(1, from: service)
        await assertWrites([true, true], from: service)
    }

    func testCancelledOneTimeSetupPreservesPhysicalState() async {
        let (preferences, suite) = makePreferences(mode: .off)
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = StubPMSetService(
            currentValue: false,
            configured: false,
            writeErrors: [.instantAuthorizationRequired],
            installError: .authorizationCancelled
        )
        let model = makeModel(service: service, preferences: preferences)

        await model.refresh()
        await model.applyPolicyMode(.on)

        XCTAssertEqual(model.state, .disabled)
        XCTAssertEqual(model.instantControlState, .setupRequired)
        XCTAssertEqual(model.notice, .cancelled)
        await assertInstallations(1, from: service)
    }

    func testMismatchedVerificationIsReported() async {
        let (preferences, suite) = makePreferences(mode: .off)
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = StubPMSetService(
            currentValue: false,
            configured: true,
            appliesWrites: false
        )
        let model = makeModel(service: service, preferences: preferences)

        await model.refresh()
        await model.applyPolicyMode(.on)

        XCTAssertEqual(model.state, .disabled)
        XCTAssertEqual(model.lifetimeWakeSessionCount, 0)
        guard case let .failure(message) = model.notice else {
            return XCTFail("Expected a verification failure")
        }
        XCTAssertTrue(message.contains("did not apply"))
    }

    func testAutomaticRepairsExternalDisableDrift() async {
        let service = StubPMSetService(currentValue: false, configured: true)
        let detector = SequenceAgentDetector([
            .healthy([makeActivity(id: "codex:one")]),
            .healthy([makeActivity(id: "codex:one")])
        ])
        let model = makeModel(service: service, detector: detector)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await model.refresh()
        await model.pollAgentActivity(now: start)
        XCTAssertEqual(model.lifetimeWakeSessionCount, 0)
        await service.setExternalState(false)
        await model.pollAgentActivity(now: start.addingTimeInterval(21))

        XCTAssertEqual(model.state, .enabled)
        XCTAssertEqual(model.lifetimeWakeSessionCount, 0)
        await assertWrites([true, true], from: service)
    }

    func testExistingOnLockAndItsDriftRepairDoNotChangeLidClosureCount() async {
        let (preferences, suite) = makePreferences(
            mode: .on,
            lifetimeWakeSessionCount: 8
        )
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = StubPMSetService(currentValue: true, configured: true)
        let model = makeModel(service: service, preferences: preferences)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        await model.refresh()
        XCTAssertEqual(model.lifetimeWakeSessionCount, 8)

        await service.setExternalState(false)
        await model.pollAgentActivity(now: now)

        XCTAssertEqual(model.state, .enabled)
        XCTAssertEqual(model.lifetimeWakeSessionCount, 8)
        await assertWrites([true], from: service)
    }

    func testAutomaticRepairsExternalEnableDriftWhileIdle() async {
        let service = StubPMSetService(currentValue: false, configured: true)
        let detector = SequenceAgentDetector([.healthy([]), .healthy([])])
        let model = makeModel(service: service, detector: detector)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await model.refresh()
        await model.pollAgentActivity(now: start)
        await service.setExternalState(true)
        await model.pollAgentActivity(now: start.addingTimeInterval(21))

        XCTAssertEqual(model.state, .disabled)
        await assertWrites([false], from: service)
    }

    func testRapidSecondModeRequestCannotReplaceAnOperationInFlight() async {
        let (preferences, suite) = makePreferences(mode: .off)
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = StubPMSetService(currentValue: false, configured: true)
        let model = makeModel(service: service, preferences: preferences)
        await model.refresh()

        model.requestPolicyMode(.on)
        model.requestPolicyMode(.off)
        await waitForOperationToFinish(model)

        XCTAssertEqual(model.policyMode, .on)
        XCTAssertEqual(model.state, .enabled)
        await assertWrites([true], from: service)
    }

    private func makeModel(
        service: StubPMSetService,
        detector: SequenceAgentDetector = SequenceAgentDetector([.healthy([])]),
        lidAngleSensor: any LidAngleSensing = SequenceLidAngleSensor([]),
        preferences: UserDefaults? = nil,
        releaseGracePeriod: TimeInterval = 90
    ) -> SleepControlModel {
        SleepControlModel(
            service: service,
            agentDetector: detector,
            lidAngleSensor: lidAngleSensor,
            preferences: preferences ?? makePreferences().0,
            releaseGracePeriod: releaseGracePeriod,
            systemVerificationInterval: 20,
            refreshOnInit: false,
            startMonitoring: false
        )
    }

    private func makePreferences(
        mode: WakePolicyMode? = nil,
        lifetimeWakeSessionCount: Int? = nil
    ) -> (UserDefaults, String) {
        let suite = "WakeBarTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.removePersistentDomain(forName: suite)
        if let mode {
            preferences.set(mode.rawValue, forKey: SleepControlModel.policyPreferenceKey)
        }
        if let lifetimeWakeSessionCount {
            preferences.set(
                lifetimeWakeSessionCount,
                forKey: SleepControlModel.lifetimeWakeSessionPreferenceKey
            )
        }
        return (preferences, suite)
    }

    private func makeActivity(
        id: String,
        runtime: AgentRuntime = .codex
    ) -> AgentActivity {
        AgentActivity(
            id: id,
            runtime: runtime,
            projectName: "wakebar",
            processID: 42,
            evidence: .lifecycle,
            lastActivityAt: nil
        )
    }

    private func waitForOperationToFinish(_ model: SleepControlModel) async {
        for _ in 0..<100 where model.isChanging {
            await Task.yield()
        }
        XCTAssertFalse(model.isChanging)
    }

    private func assertWrites(
        _ expected: [Bool],
        from service: StubPMSetService,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let actual = await service.recordedWrites()
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func assertInstallations(
        _ expected: Int,
        from service: StubPMSetService,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let actual = await service.installationCount()
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

private struct DetectorResult: Sendable {
    let activities: [AgentActivity]
    let processScanSucceeded: Bool
    let scanWasConclusive: Bool

    static func healthy(_ activities: [AgentActivity]) -> DetectorResult {
        DetectorResult(
            activities: activities,
            processScanSucceeded: true,
            scanWasConclusive: true
        )
    }

    static func degraded(_ activities: [AgentActivity]) -> DetectorResult {
        DetectorResult(
            activities: activities,
            processScanSucceeded: true,
            scanWasConclusive: false
        )
    }

    static let failed = DetectorResult(
        activities: [],
        processScanSucceeded: false,
        scanWasConclusive: false
    )
}

private actor SequenceAgentDetector: AgentActivityDetecting {
    private var results: [DetectorResult]
    private var lastResult: DetectorResult

    init(_ results: [DetectorResult]) {
        let fallback = results.last ?? .healthy([])
        self.results = results
        self.lastResult = fallback
    }

    func scan(now: Date) async -> AgentActivitySnapshot {
        if !results.isEmpty {
            lastResult = results.removeFirst()
        }

        return AgentActivitySnapshot(
            activities: lastResult.activities,
            scannedAt: now,
            processScanSucceeded: lastResult.processScanSucceeded,
            scanWasConclusive: lastResult.scanWasConclusive
        )
    }
}

private actor SequenceLidAngleSensor: LidAngleSensing {
    private var readings: [Double?]
    private var lastReading: Double?

    init(_ readings: [Double?]) {
        self.readings = readings
        self.lastReading = readings.last ?? nil
    }

    func currentAngle() -> Double? {
        if !readings.isEmpty {
            lastReading = readings.removeFirst()
        }
        return lastReading
    }
}

private actor StubPMSetService: PMSetServicing {
    private var currentValue: Bool
    private var configured: Bool
    private let powerSnapshot: PowerSnapshot
    private var writeErrors: [PMSetError]
    private let installError: PMSetError?
    private let removeError: PMSetError?
    private let appliesWrites: Bool
    private var writes: [Bool] = []
    private var installs = 0

    init(
        currentValue: Bool,
        configured: Bool = true,
        powerSnapshot: PowerSnapshot = .unknown,
        writeErrors: [PMSetError] = [],
        installError: PMSetError? = nil,
        removeError: PMSetError? = nil,
        appliesWrites: Bool = true
    ) {
        self.currentValue = currentValue
        self.configured = configured
        self.powerSnapshot = powerSnapshot
        self.writeErrors = writeErrors
        self.installError = installError
        self.removeError = removeError
        self.appliesWrites = appliesWrites
    }

    func currentSleepPreventionState() async throws -> Bool {
        currentValue
    }

    func currentPowerSnapshot() async throws -> PowerSnapshot {
        powerSnapshot
    }

    func instantControlConfigured() async -> Bool {
        configured
    }

    func installInstantControl() async throws {
        installs += 1

        if let installError {
            throw installError
        }

        configured = true
    }

    func removeInstantControl() async throws {
        if let removeError {
            throw removeError
        }

        configured = false
        currentValue = false
    }

    func setSleepPrevention(enabled: Bool) async throws {
        writes.append(enabled)

        if !writeErrors.isEmpty {
            throw writeErrors.removeFirst()
        }

        if appliesWrites {
            currentValue = enabled
        }
    }

    func installationCount() -> Int {
        installs
    }

    func recordedWrites() -> [Bool] {
        writes
    }

    func setExternalState(_ enabled: Bool) {
        currentValue = enabled
    }
}
