import AppKit
import Foundation
import SwiftUI

private actor PreviewPMSetService: PMSetServicing {
    let enabled: Bool
    let configured: Bool

    init(enabled: Bool, configured: Bool) {
        self.enabled = enabled
        self.configured = configured
    }

    func currentSleepPreventionState() async throws -> Bool {
        enabled
    }

    func currentPowerSnapshot() async throws -> PowerSnapshot {
        PowerSnapshot(source: .powerAdapter, batteryPercentage: 86)
    }

    func instantControlConfigured() async -> Bool {
        configured
    }

    func installInstantControl() async throws {}

    func removeInstantControl() async throws {}

    func setSleepPrevention(enabled: Bool) async throws {}
}

private struct PreviewAgentDetector: AgentActivityDetecting {
    let activities: [AgentActivity]

    func scan(now: Date) async -> AgentActivitySnapshot {
        AgentActivitySnapshot(
            activities: activities,
            scannedAt: now,
            processScanSucceeded: true
        )
    }
}

private struct PreviewLidAngleSensor: LidAngleSensing {
    let angle: Double

    func currentAngle() async -> Double? {
        angle
    }
}

@main
@MainActor
struct WakeBarPreviewRenderer {
    static func main() async throws {
        guard (2...6).contains(CommandLine.arguments.count) else {
            fputs("usage: render-preview <output.png> [--off|--on] [--active] [--setup] [--closed]\n", stderr)
            exit(64)
        }

        _ = NSApplication.shared

        let options = Set(CommandLine.arguments.dropFirst(2))
        let mode: WakePolicyMode
        if options.contains("--off") {
            mode = .off
        } else if options.contains("--on") {
            mode = .on
        } else {
            mode = .automatic
        }
        let isActive = options.contains("--active")
        let isSetupRequired = options.contains("--setup")
        let isClosed = options.contains("--closed")
        let isEnabled = mode == .on || (mode == .automatic && isActive && !isSetupRequired)
        let activities: [AgentActivity] = isActive ? [
            AgentActivity(
                id: "codex:preview",
                runtime: .codex,
                projectName: "WakeBar",
                processID: 101,
                evidence: .lifecycle,
                lastActivityAt: Date()
            ),
            AgentActivity(
                id: "claude:preview",
                runtime: .claude,
                projectName: "agent-tools",
                processID: 102,
                evidence: .liveProcess,
                lastActivityAt: Date()
            )
        ] : []
        let suite = "WakeBarPreview.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(mode.rawValue, forKey: SleepControlModel.policyPreferenceKey)
        preferences.set(
            128,
            forKey: SleepControlModel.lifetimeWakeSessionPreferenceKey
        )
        defer { preferences.removePersistentDomain(forName: suite) }

        let model = SleepControlModel(
            service: PreviewPMSetService(
                enabled: isEnabled,
                configured: !isSetupRequired
            ),
            agentDetector: PreviewAgentDetector(activities: activities),
            lidAngleSensor: PreviewLidAngleSensor(angle: isClosed ? 0 : 120),
            preferences: preferences,
            refreshOnInit: false,
            startMonitoring: false
        )
        await model.refresh()
        await model.pollAgentActivity()
        if isClosed {
            await model.pollLidAngle()
            await model.pollLidAngle()
        }

        let rootView = WakeBarPopoverView(model: model)
            .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: rootView)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: 360, height: fittingSize.height)
        )

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hostingView
        window.orderFrontRegardless()

        try await Task.sleep(for: .milliseconds(120))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds
        ) else {
            throw NSError(domain: "WakeBarPreview", code: 1)
        }

        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "WakeBarPreview", code: 2)
        }

        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        window.orderOut(nil)
    }
}
