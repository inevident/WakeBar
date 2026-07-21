import Foundation

enum SleepPreventionState: Equatable, Sendable {
    case loading
    case enabled
    case disabled
    case unavailable
}

enum WakePolicyMode: String, CaseIterable, Codable, Sendable {
    case off
    case automatic
    case on

    var title: String {
        switch self {
        case .off: return "OFF"
        case .automatic: return "AUTO"
        case .on: return "ON"
        }
    }
}

enum InstantControlState: Equatable, Sendable {
    case checking
    case setupRequired
    case installing
    case ready
}

enum InlineNotice: Equatable, Sendable {
    case cancelled
    case failure(String)

    var title: String {
        switch self {
        case .cancelled:
            return "Setup cancelled"
        case .failure:
            return "WakeBar needs attention"
        }
    }

    var message: String {
        switch self {
        case .cancelled:
            return "Nothing was changed."
        case let .failure(message):
            return message
        }
    }

    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

@MainActor
final class SleepControlModel: ObservableObject {
    static let policyPreferenceKey = "wakebar.policy-mode"
    static let lifetimeWakeSessionPreferenceKey = "wakebar.lifetime-protected-lid-closure-count"

    @Published private(set) var state: SleepPreventionState = .loading
    @Published private(set) var policyMode: WakePolicyMode
    @Published private(set) var lifetimeWakeSessionCount: Int
    @Published private(set) var isLidClosed = false
    @Published private(set) var instantControlState: InstantControlState = .checking
    @Published private(set) var powerSnapshot: PowerSnapshot = .unknown
    @Published private(set) var agentActivities: [AgentActivity] = []
    @Published private(set) var isHoldingAutoGrace = false
    @Published private(set) var agentDetectorAvailable = true
    @Published private(set) var agentScanConclusive = true
    @Published private(set) var lastAgentScanAt: Date?
    @Published private(set) var isChanging = false
    @Published private(set) var notice: InlineNotice?

    private let service: any PMSetServicing
    private let agentDetector: any AgentActivityDetecting
    private let lidAngleSensor: any LidAngleSensing
    private let preferences: UserDefaults
    private let releaseGracePeriod: TimeInterval
    private let monitorInterval: Duration
    private let lidMonitorInterval: Duration
    private let systemVerificationInterval: TimeInterval
    private let backgroundMonitoringEnabled: Bool
    private var operationTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var lidMonitorTask: Task<Void, Never>?
    private var lastActiveAt: Date?
    private var lastSystemVerificationAt: Date?
    private var operationRevision: UInt64 = 0
    private var lidClosureDetector = LidClosureDetector()

    init(
        service: any PMSetServicing = PMSetService(),
        agentDetector: any AgentActivityDetecting = LocalAgentActivityDetector(),
        lidAngleSensor: any LidAngleSensing = MacBookLidAngleSensor(),
        preferences: UserDefaults = .standard,
        releaseGracePeriod: TimeInterval = 90,
        monitorInterval: Duration = .seconds(5),
        lidMonitorInterval: Duration = .milliseconds(250),
        systemVerificationInterval: TimeInterval = 20,
        refreshOnInit: Bool = true,
        startMonitoring: Bool = true
    ) {
        self.service = service
        self.agentDetector = agentDetector
        self.lidAngleSensor = lidAngleSensor
        self.preferences = preferences
        self.releaseGracePeriod = releaseGracePeriod
        self.monitorInterval = monitorInterval
        self.lidMonitorInterval = lidMonitorInterval
        self.systemVerificationInterval = systemVerificationInterval
        self.backgroundMonitoringEnabled = startMonitoring
        let storedWakeSessionCount = preferences.integer(
            forKey: Self.lifetimeWakeSessionPreferenceKey
        )
        self.lifetimeWakeSessionCount = max(0, storedWakeSessionCount)
        if storedWakeSessionCount < 0 {
            preferences.set(0, forKey: Self.lifetimeWakeSessionPreferenceKey)
        }

        if let storedMode = preferences.string(forKey: Self.policyPreferenceKey),
           let mode = WakePolicyMode(rawValue: storedMode) {
            self.policyMode = mode
        } else {
            self.policyMode = .automatic
        }

        if startMonitoring {
            startLidMonitoringIfNeeded()
            let interval = monitorInterval
            monitorTask = Task { @MainActor [weak self] in
                if refreshOnInit {
                    await self?.refresh()
                }
                await self?.pollAgentActivity()

                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        break
                    }
                    guard !Task.isCancelled else { break }
                    await self?.pollAgentActivity()
                }
            }
        } else if refreshOnInit {
            Task { [weak self] in
                await self?.refresh()
                await self?.pollAgentActivity()
            }
        }
    }

    deinit {
        operationTask?.cancel()
        monitorTask?.cancel()
        lidMonitorTask?.cancel()
    }

    var isEnabled: Bool {
        state == .enabled
    }

    var canSelectMode: Bool {
        !isChanging && state != .loading
    }

    var effectiveAgentActivity: Bool {
        !agentActivities.isEmpty || isHoldingAutoGrace
    }

    var activeAgentCount: Int {
        agentActivities.count
    }

    var hasAgentsWhileOff: Bool {
        policyMode == .off && activeAgentCount > 0
    }

    var desiredSleepPrevention: Bool {
        switch policyMode {
        case .off:
            return false
        case .automatic:
            return effectiveAgentActivity
        case .on:
            return true
        }
    }

    var policyMatchesSystemState: Bool {
        switch state {
        case .enabled, .disabled:
            return desiredSleepPrevention == isEnabled
        case .loading, .unavailable:
            return false
        }
    }

    var menuBarText: String {
        switch policyMode {
        case .off:
            if activeAgentCount > 0 {
                return "OFF · \(activeAgentCount)"
            }
            return "OFF"
        case .on:
            return "ON"
        case .automatic:
            if activeAgentCount > 0 {
                return "AUTO · \(activeAgentCount)"
            }
            return "AUTO"
        }
    }

    var menuBarSymbol: String {
        if state != .loading,
           state != .unavailable,
           !policyMatchesSystemState {
            return "exclamationmark.shield.fill"
        }

        switch policyMode {
        case .off where hasAgentsWhileOff:
            return "exclamationmark.triangle.fill"
        case .off:
            return "moon.zzz.fill"
        case .on:
            return "bolt.shield.fill"
        case .automatic where !agentDetectorAvailable || !agentScanConclusive:
            return "exclamationmark.arrow.triangle.2.circlepath"
        case .automatic where activeAgentCount > 0:
            return "bolt.circle.fill"
        case .automatic where isHoldingAutoGrace:
            return "hourglass"
        case .automatic:
            return "eye.fill"
        }
    }

    var menuBarAccessibilityLabel: String {
        if state != .loading,
           state != .unavailable,
           !policyMatchesSystemState {
            return "WakeBar \(policyMode.title.lowercased()) selected, but the system sleep lock has not been applied"
        }

        switch policyMode {
        case .off where activeAgentCount == 1:
            return "WakeBar off, 1 active agent is unprotected and macOS may sleep"
        case .off where activeAgentCount > 1:
            return "WakeBar off, \(activeAgentCount) active agents are unprotected and macOS may sleep"
        case .off:
            return "WakeBar off, automatic system sleep enabled"
        case .on:
            return "WakeBar on, system sleep blocked"
        case .automatic where !agentDetectorAvailable || !agentScanConclusive:
            return "WakeBar automatic, activity scan interrupted, preserving the last safe state"
        case .automatic where activeAgentCount > 0:
            return "WakeBar automatic, \(activeAgentCount) active agents, system sleep blocked"
        case .automatic where isHoldingAutoGrace:
            return "WakeBar automatic, finishing a safety window before restoring system sleep"
        case .automatic:
            return "WakeBar automatic, watching for active agents"
        }
    }

    func refresh() async {
        guard !isChanging else { return }
        let revision = operationRevision

        let instantControlConfigured = await service.instantControlConfigured()
        guard !isChanging, operationRevision == revision else { return }
        instantControlState = instantControlConfigured ? .ready : .setupRequired

        let refreshedPower = (try? await service.currentPowerSnapshot()) ?? .unknown
        guard !isChanging, operationRevision == revision else { return }
        powerSnapshot = refreshedPower
        await loadState(
            showLoading: state == .unavailable,
            expectedOperationRevision: revision
        )
        guard !isChanging, operationRevision == revision else { return }

        if policyMode != .automatic {
            await reconcilePolicyWithoutPrompt()
        }
    }

    func pollAgentActivity(now: Date = Date()) async {
        guard !isChanging else { return }

        let snapshot = await agentDetector.scan(now: now)
        await verifyPhysicalStateIfNeeded(now: now)
        guard !isChanging else { return }

        lastAgentScanAt = snapshot.scannedAt
        agentDetectorAvailable = snapshot.processScanSucceeded
        agentScanConclusive = snapshot.scanWasConclusive

        guard snapshot.processScanSucceeded else {
            if policyMode != .automatic || desiredSleepPrevention {
                await reconcilePolicyWithoutPrompt()
            }
            return
        }

        if !snapshot.scanWasConclusive, snapshot.activities.isEmpty {
            if policyMode != .automatic || desiredSleepPrevention {
                await reconcilePolicyWithoutPrompt()
            }
            return
        }

        if !snapshot.activities.isEmpty {
            agentActivities = snapshot.activities
            lastActiveAt = now
            isHoldingAutoGrace = false
        } else if let lastActiveAt,
                  now.timeIntervalSince(lastActiveAt) < releaseGracePeriod {
            agentActivities = []
            isHoldingAutoGrace = true
        } else {
            agentActivities = []
            isHoldingAutoGrace = false
            lastActiveAt = nil
        }

        await reconcilePolicyWithoutPrompt()
    }

    func pollLidAngle() async {
        let angle = await lidAngleSensor.currentAngle()
        guard !Task.isCancelled else { return }
        await observeLidAngle(angle)
    }

    func requestPolicyMode(_ mode: WakePolicyMode) {
        guard !isChanging else { return }

        if mode == policyMode {
            let physicalStateMatches = state != .loading
                && state != .unavailable
                && desiredSleepPrevention == isEnabled
            let automaticSetupMissing = mode == .automatic
                && instantControlState != .ready
            guard !physicalStateMatches || automaticSetupMissing else { return }
        }

        policyMode = mode
        preferences.set(mode.rawValue, forKey: Self.policyPreferenceKey)
        updateLidMonitoringForPolicy()
        startOperation { model in
            await model.performApplyPolicyMode(mode)
        }
    }

    func requestInstantControlSetup() {
        guard !isChanging else { return }

        startOperation { model in
            await model.performConfigureInstantControl()
        }
    }

    func requestInstantControlRemoval() {
        guard !isChanging else { return }

        policyMode = .off
        preferences.set(WakePolicyMode.off.rawValue, forKey: Self.policyPreferenceKey)
        updateLidMonitoringForPolicy()
        startOperation { model in
            await model.performRemoveInstantControl()
        }
    }

    func retry() {
        guard case .failure = notice else { return }

        if state == .unavailable {
            Task { [weak self] in
                await self?.refresh()
                await self?.pollAgentActivity()
            }
        } else if instantControlState == .setupRequired {
            requestInstantControlSetup()
        } else {
            Task { [weak self] in
                await self?.refresh()
                await self?.pollAgentActivity()
            }
        }
    }

    func dismissNotice() {
        notice = nil
    }

    func applyPolicyMode(_ mode: WakePolicyMode) async {
        guard !isChanging else { return }

        operationRevision &+= 1
        isChanging = true
        await performApplyPolicyMode(mode)
        isChanging = false
    }

    private func performApplyPolicyMode(_ mode: WakePolicyMode) async {
        policyMode = mode
        preferences.set(mode.rawValue, forKey: Self.policyPreferenceKey)
        updateLidMonitoringForPolicy()
        notice = nil

        do {
            if mode == .automatic, instantControlState != .ready {
                instantControlState = .installing
                try await service.installInstantControl()
                instantControlState = .ready
            }

            try await applySystemStateIfNeeded(
                enabled: desiredSleepPrevention,
                allowSetupPrompt: true
            )
        } catch {
            await recoverState(after: error)
        }
    }

    private func reconcilePolicyWithoutPrompt() async {
        guard !isChanging else { return }
        let desired = desiredSleepPrevention

        if state == .enabled, desired { return }
        if state == .disabled, !desired { return }

        guard instantControlState == .ready else {
            return
        }

        operationRevision &+= 1
        isChanging = true
        do {
            try await applySystemStateIfNeeded(
                enabled: desired,
                allowSetupPrompt: false
            )
        } catch {
            await recoverState(after: error)
        }
        isChanging = false
    }

    private func applySystemStateIfNeeded(
        enabled: Bool,
        allowSetupPrompt: Bool
    ) async throws {
        // Read immediately before deciding to write so an external pmset change
        // cannot be mistaken for a new WakeBar protection session.
        let currentValue = try await service.currentSleepPreventionState()
        state = currentValue ? .enabled : .disabled

        guard enabled != currentValue else { return }

        do {
            try await service.setSleepPrevention(enabled: enabled)
            instantControlState = .ready
        } catch PMSetError.instantAuthorizationRequired where allowSetupPrompt {
            instantControlState = .installing
            try await service.installInstantControl()
            instantControlState = .ready
            try await service.setSleepPrevention(enabled: enabled)
        }

        let verifiedValue = try await service.currentSleepPreventionState()
        guard verifiedValue == enabled else {
            throw PMSetError.verificationFailed
        }

        state = enabled ? .enabled : .disabled
        powerSnapshot = (try? await service.currentPowerSnapshot()) ?? powerSnapshot
        notice = nil
    }

    private func performConfigureInstantControl() async {
        instantControlState = .installing
        notice = nil

        do {
            try await service.installInstantControl()
            instantControlState = .ready
            try await applySystemStateIfNeeded(
                enabled: desiredSleepPrevention,
                allowSetupPrompt: false
            )
        } catch {
            instantControlState = .setupRequired
            setNotice(for: error)
        }
    }

    private func performRemoveInstantControl() async {
        instantControlState = .installing
        notice = nil

        do {
            try await service.removeInstantControl()
            instantControlState = .setupRequired

            let verifiedValue = try await service.currentSleepPreventionState()
            guard !verifiedValue else {
                throw PMSetError.verificationFailed
            }

            state = .disabled
        } catch {
            instantControlState = await service.instantControlConfigured()
                ? .ready
                : .setupRequired
            await recoverState(after: error)
        }
    }

    private func startOperation(
        _ operation: @escaping @MainActor (SleepControlModel) async -> Void
    ) {
        guard !isChanging else { return }
        operationRevision &+= 1
        isChanging = true
        operationTask = Task { [weak self] in
            guard let self else { return }
            await operation(self)
            self.isChanging = false
            self.operationTask = nil
        }
    }

    private func loadState(
        showLoading: Bool,
        expectedOperationRevision: UInt64
    ) async {
        if showLoading {
            state = .loading
        }

        do {
            let enabled = try await service.currentSleepPreventionState()
            guard !isChanging,
                  operationRevision == expectedOperationRevision else { return }
            state = enabled ? .enabled : .disabled
        } catch {
            guard !isChanging,
                  operationRevision == expectedOperationRevision else { return }
            state = .unavailable
            notice = .failure(Self.userFacingMessage(for: error))
        }
    }

    private func verifyPhysicalStateIfNeeded(now: Date) async {
        if let lastSystemVerificationAt,
           now.timeIntervalSince(lastSystemVerificationAt) >= 0,
           now.timeIntervalSince(lastSystemVerificationAt) < systemVerificationInterval {
                return
        }

        let revision = operationRevision
        do {
            let enabled = try await service.currentSleepPreventionState()
            guard !isChanging, operationRevision == revision else { return }
            state = enabled ? .enabled : .disabled
            lastSystemVerificationAt = now
        } catch {
            guard !isChanging, operationRevision == revision else { return }
            state = .unavailable
            lastSystemVerificationAt = now
            notice = .failure(Self.userFacingMessage(for: error))
        }
    }

    private func recoverState(after error: Error) async {
        if let currentValue = try? await service.currentSleepPreventionState() {
            state = currentValue ? .enabled : .disabled
        } else {
            state = .unavailable
        }

        if case PMSetError.instantAuthorizationRequired = error {
            instantControlState = .setupRequired
        } else if case PMSetError.instantAuthorizationUnavailable = error {
            instantControlState = .setupRequired
        } else if case PMSetError.authorizationCancelled = error {
            instantControlState = .setupRequired
        } else if case PMSetError.authorizationFailed = error {
            instantControlState = .setupRequired
        } else if case PMSetError.unsafeAuthorizationReceipt = error {
            instantControlState = .setupRequired
        }

        setNotice(for: error)
    }

    private func updateLidMonitoringForPolicy() {
        if policyMode == .automatic {
            startLidMonitoringIfNeeded()
        } else {
            stopLidMonitoring()
        }
    }

    private func startLidMonitoringIfNeeded() {
        guard backgroundMonitoringEnabled,
              policyMode == .automatic,
              lidMonitorTask == nil else { return }

        let sensor = lidAngleSensor
        let interval = lidMonitorInterval
        lidMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let angle = await sensor.currentAngle()
                guard !Task.isCancelled else { break }
                await self?.observeLidAngle(angle)

                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
            }
            await sensor.stop()
        }
    }

    private func stopLidMonitoring() {
        lidMonitorTask?.cancel()
        lidMonitorTask = nil
        lidClosureDetector.reset()
        isLidClosed = false
    }

    private func observeLidAngle(_ angle: Double?) async {
        guard policyMode == .automatic else {
            isLidClosed = false
            return
        }

        let didClose = lidClosureDetector.observe(angle: angle)
        isLidClosed = lidClosureDetector.isClosed

        guard didClose,
              activeAgentCount > 0,
              !isChanging,
              lifetimeWakeSessionCount < Int.max else { return }

        let revision = operationRevision
        guard let physicallyEnabled = try? await service.currentSleepPreventionState()
        else { return }
        guard !isChanging, operationRevision == revision else { return }

        state = physicallyEnabled ? .enabled : .disabled
        guard physicallyEnabled,
              policyMode == .automatic,
              activeAgentCount > 0,
              policyMatchesSystemState,
              lifetimeWakeSessionCount < Int.max else { return }

        lifetimeWakeSessionCount += 1
        preferences.set(
            lifetimeWakeSessionCount,
            forKey: Self.lifetimeWakeSessionPreferenceKey
        )
    }

    private func setNotice(for error: Error) {
        if case PMSetError.authorizationCancelled = error {
            notice = .cancelled
        } else {
            notice = .failure(Self.userFacingMessage(for: error))
        }
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }

        return "WakeBar couldn’t read the system sleep setting."
    }
}
