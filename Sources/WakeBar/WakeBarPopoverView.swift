import AppKit
import Combine
import SwiftUI

struct WakeBarPopoverView: View {
    @ObservedObject var model: SleepControlModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var modeSelection
    @State private var showsQuitWarning = false
    @State private var quitsAfterDisabling = false

    var body: some View {
        VStack(spacing: 0) {
            header
            modeSelector
            hero

            if shouldShowAgentActivityCard {
                agentActivityCard
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if showsInstantSetupCard {
                instantSetupCard
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let notice = model.notice {
                noticeView(notice)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            details
            footer
        }
        .frame(width: 360)
        .background(background)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: model.policyMode
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: model.agentActivities
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: model.instantControlState
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: model.notice
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: model.isLidClosed
        )
        .task {
            await model.refresh()
            await model.pollAgentActivity()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didWakeNotification
            )
        ) { _ in
            Task {
                await model.refresh()
                await model.pollAgentActivity()
            }
        }
        .onReceive(model.$isChanging.removeDuplicates().dropFirst()) { isChanging in
            guard !isChanging, quitsAfterDisabling else { return }
            quitsAfterDisabling = false

            if model.state == .disabled {
                NSApplication.shared.terminate(nil)
            }
        }
        .alert("The sleep lock stays active", isPresented: $showsQuitWarning) {
            Button("Quit & Keep Awake") {
                NSApplication.shared.terminate(nil)
            }
            Button("Turn Off & Quit") {
                quitsAfterDisabling = true
                model.requestPolicyMode(.off)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Quitting WakeBar does not clear the system-wide sleep setting. Turn it off first if you want macOS sleep restored.")
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.92), Color.blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            .shadow(color: Color.blue.opacity(0.2), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text("WakeBar")
                    .font(.system(size: 14, weight: .semibold))

                Text("A quiet guard for long-running agents")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                statusPill

                if model.isLidClosed {
                    lidClosedPill
                        .transition(
                            .opacity.combined(
                                with: .scale(scale: 0.92, anchor: .topTrailing)
                            )
                        )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 12)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(model.menuBarText)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.45)
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(statusColor.opacity(colorScheme == .dark ? 0.16 : 0.1))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.menuBarAccessibilityLabel)
    }

    private var lidClosedPill: some View {
        Label("LID CLOSED", systemImage: "laptopcomputer")
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .tracking(0.45)
            .foregroundStyle(Color.purple)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.purple.opacity(colorScheme == .dark ? 0.17 : 0.1))
            .clipShape(Capsule())
            .accessibilityLabel("MacBook lid closed")
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("MODE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(systemLockLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 3) {
                ForEach(WakePolicyMode.allCases, id: \.self) { mode in
                    modeButton(mode)
                }
            }
            .padding(3)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.085 : 0.055))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 11)
    }

    private func modeButton(_ mode: WakePolicyMode) -> some View {
        let selected = model.policyMode == mode

        return Button {
            model.requestPolicyMode(mode)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: modeSymbol(mode))
                    .font(.system(size: 10, weight: .semibold))
                Text(mode.title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.55)
            }
            .foregroundStyle(selected ? modeTint(mode) : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(cardBackground)
                        .shadow(color: Color.black.opacity(0.09), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "mode-selection", in: modeSelection)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canSelectMode)
        .accessibilityLabel(modeAccessibilityLabel(mode))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var hero: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(colorScheme == .dark ? 0.17 : 0.11))

                if model.state == .loading || model.isChanging {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: heroSymbol)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(statusColor)
                }
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(heroTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)

                Text(heroSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(cardBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(statusColor.opacity(0.16), lineWidth: 1)
                }
        )
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }

    private var agentActivityCard: some View {
        VStack(spacing: 0) {
            if model.hasAgentsWhileOff {
                HStack(spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)

                    Text(offOverrideMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 4)

                    Button("Use AUTO") {
                        model.requestPolicyMode(.automatic)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
                    .disabled(!model.canSelectMode)
                    .accessibilityHint("Switch to automatic mode to protect active agents")
                }
                .padding(11)
            }

            if showsAutomaticScanWarning {
                HStack(spacing: 9) {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)

                    Text("Agent detection is retrying. AUTO is preserving the last safe state.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(11)
            }

            if !model.agentActivities.isEmpty,
               (model.hasAgentsWhileOff || showsAutomaticScanWarning) {
                Divider().padding(.leading, 35)
            }

            ForEach(Array(model.agentActivities.prefix(4))) { activity in
                activityRow(activity)

                if activity.id != model.agentActivities.prefix(4).last?.id {
                    Divider().padding(.leading, 35)
                }
            }

            if model.agentActivities.count > 4 {
                Text(model.hasAgentsWhileOff
                    ? "+ \(model.agentActivities.count - 4) more unprotected"
                    : "+ \(model.agentActivities.count - 4) more active")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 35)
                    .padding(.vertical, 7)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    (model.hasAgentsWhileOff ? Color.orange : Color.cyan)
                        .opacity(colorScheme == .dark ? 0.075 : 0.05)
                )
        )
        .padding(.horizontal, 12)
        .padding(.top, 9)
    }

    private func activityRow(_ activity: AgentActivity) -> some View {
        let isUnprotected = model.hasAgentsWhileOff
        let activityTint = isUnprotected ? Color.orange : Color.green

        return HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill((isUnprotected ? Color.orange : Color.cyan).opacity(0.13))
                Image(systemName: runtimeSymbol(activity.runtime))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isUnprotected ? Color.orange : Color.cyan)
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(activity.runtime.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)

                Text(activityProjectLabel(activity))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            HStack(spacing: 4) {
                Circle()
                    .fill(activityTint)
                    .frame(width: 5, height: 5)
                Text(isUnprotected ? "UNPROTECTED" : "ACTIVE")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.4)
            }
            .foregroundStyle(activityTint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var instantSetupCard: some View {
        HStack(alignment: .top, spacing: 10) {
            if model.instantControlState == .installing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)
                    .frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(model.instantControlState == .installing
                    ? "Completing one-time setup…"
                    : "Approve once, then AUTO is hands-off")
                    .font(.system(size: 11, weight: .semibold))

                Text("Permission is limited to WakeBar’s two exact sleep commands. No account or agent login is needed.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            if model.instantControlState == .setupRequired {
                Button("Set Up") {
                    model.requestInstantControlSetup()
                }
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.blue.opacity(colorScheme == .dark ? 0.1 : 0.07))
        )
        .padding(.horizontal, 12)
        .padding(.top, 9)
    }

    private func noticeView(_ notice: InlineNotice) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: notice.isFailure ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(notice.isFailure ? Color.red : Color.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.system(size: 11, weight: .semibold))
                Text(notice.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            if notice.isFailure {
                Button("Try Again") {
                    model.retry()
                }
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(.borderless)
            }

            Button {
                model.dismissNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .padding(4)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((notice.isFailure ? Color.red : Color.orange).opacity(0.08))
        )
        .padding(.horizontal, 12)
        .padding(.top, 9)
    }

    private var details: some View {
        VStack(spacing: 8) {
            detailRow(
                symbol: sleepLockSymbol,
                title: "System sleep lock",
                detail: sleepLockDetail,
                tint: model.isEnabled ? .cyan : .secondary
            )

            detailRow(
                symbol: "clock.arrow.circlepath",
                title: "Wake sessions",
                detail: "\(model.lifetimeWakeSessionCount.formatted()) lifetime",
                tint: .purple
            )

            detailRow(
                symbol: localAgentWatchHealthy ? "eye.fill" : "eye.slash.fill",
                title: "Local agent watch",
                detail: localAgentWatchHealthy ? "On-device · no login" : "Protected · retrying",
                tint: localAgentWatchHealthy ? .green : .orange
            )
            .help("Detects local Codex, Claude Code, Cursor, OpenCode, Copilot, Gemini, and other agent runtimes.")

            powerDetailRow

            detailRow(
                symbol: model.instantControlState == .ready
                    ? "checkmark.shield.fill"
                    : "lock.fill",
                title: "Instant switching",
                detail: instantControlDetail,
                tint: model.instantControlState == .ready ? .green : .secondary
            )

            if model.isEnabled {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)

                    Text(safetyMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 3)
            }
        }
        .padding(.horizontal, 17)
        .padding(.top, 13)
        .padding(.bottom, 12)
    }

    private var powerDetailRow: some View {
        let symbol: String
        let detail: String
        let tint: Color

        switch model.powerSnapshot.source {
        case .powerAdapter:
            symbol = "powerplug.fill"
            detail = "Connected"
            tint = .green
        case .battery:
            symbol = "battery.50percent"
            if let percentage = model.powerSnapshot.batteryPercentage {
                detail = "Battery · \(percentage)%"
            } else {
                detail = "On battery"
            }
            tint = .orange
        case .unknown:
            symbol = "bolt.horizontal.circle"
            detail = "Unknown"
            tint = .secondary
        }

        return detailRow(
            symbol: symbol,
            title: "Power",
            detail: detail,
            tint: tint
        )
    }

    private func detailRow(
        symbol: String,
        title: String,
        detail: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 14)

            Text(title)
                .font(.system(size: 11))

            Spacer()

            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                Task {
                    await model.refresh()
                    await model.pollAgentActivity()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isChanging)

            Menu {
                Button("Repair Instant Switching…") {
                    model.requestInstantControlSetup()
                }

                Button("Remove Instant Switching…", role: .destructive) {
                    model.requestInstantControlRemoval()
                }
                .disabled(model.instantControlState != .ready)
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("WakeBar security settings")

            Spacer()

            Button("Quit WakeBar") {
                if model.isEnabled {
                    showsQuitWarning = true
                } else {
                    NSApplication.shared.terminate(nil)
                }
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .font(.system(size: 11))
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.03))
        .overlay(alignment: .top) {
            Divider().opacity(0.55)
        }
    }

    private var background: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)

            LinearGradient(
                colors: [
                    statusColor.opacity(model.desiredSleepPrevention ? 0.085 : 0.025),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }

    private var showsInstantSetupCard: Bool {
        model.instantControlState == .setupRequired
            || model.instantControlState == .installing
    }

    private var cardBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.white.opacity(0.76)
    }

    private var localAgentWatchHealthy: Bool {
        model.agentDetectorAvailable && model.agentScanConclusive
    }

    private var showsAutomaticScanWarning: Bool {
        model.policyMode == .automatic && !localAgentWatchHealthy
    }

    private var shouldShowAgentActivityCard: Bool {
        model.hasAgentsWhileOff
            || (model.policyMode == .automatic
                && (!model.agentActivities.isEmpty || !localAgentWatchHealthy))
    }

    private var offOverrideMessage: String {
        if model.activeAgentCount == 1 {
            return "OFF is a manual override. macOS may sleep while this agent runs."
        }
        return "OFF is a manual override. macOS may sleep while these agents run."
    }

    private var policyNeedsSetup: Bool {
        model.instantControlState == .setupRequired
            && !model.policyMatchesSystemState
    }

    private var statusColor: Color {
        if model.state == .unavailable
            || showsAutomaticScanWarning
            || (!model.policyMatchesSystemState && model.state != .loading) {
            return .orange
        }

        if model.hasAgentsWhileOff {
            return .orange
        }

        switch model.policyMode {
        case .off:
            return .secondary
        case .on:
            return .cyan
        case .automatic:
            return model.effectiveAgentActivity ? .cyan : .blue
        }
    }

    private var heroSymbol: String {
        if model.state == .unavailable {
            return "exclamationmark.triangle.fill"
        }
        if policyNeedsSetup {
            return "exclamationmark.shield.fill"
        }

        switch model.policyMode {
        case .off where model.hasAgentsWhileOff:
            return "exclamationmark.triangle.fill"
        case .off:
            return "moon.zzz.fill"
        case .on:
            return "bolt.shield.fill"
        case .automatic where !localAgentWatchHealthy:
            return "eye.slash.fill"
        case .automatic where model.activeAgentCount > 0:
            return "bolt.circle.fill"
        case .automatic where model.isHoldingAutoGrace:
            return "hourglass"
        case .automatic:
            return "eye.fill"
        }
    }

    private var heroTitle: String {
        if model.instantControlState == .installing {
            return "Setting up instant control…"
        }
        if model.state == .loading {
            return "Reading the system sleep lock…"
        }
        if model.state == .unavailable {
            return "Sleep state unavailable"
        }
        if policyNeedsSetup {
            switch model.policyMode {
            case .off:
                return "Setup needed to restore sleep"
            case .automatic where model.activeAgentCount == 1:
                return "1 agent needs protection"
            case .automatic where model.isHoldingAutoGrace:
                return "Setup needed for the safety window"
            case .automatic:
                return "\(model.activeAgentCount) agents need protection"
            case .on:
                return "One-time setup needed"
            }
        }

        switch model.policyMode {
        case .off where model.activeAgentCount == 1:
            return "1 agent is unprotected"
        case .off where model.activeAgentCount > 1:
            return "\(model.activeAgentCount) agents are unprotected"
        case .off:
            return "Sleep follows macOS"
        case .on:
            return "Always awake"
        case .automatic where !localAgentWatchHealthy:
            return "Holding the last safe state"
        case .automatic where model.activeAgentCount == 1:
            return "Keeping 1 agent awake"
        case .automatic where model.activeAgentCount > 1:
            return "Keeping \(model.activeAgentCount) agents awake"
        case .automatic where model.isHoldingAutoGrace:
            return "Wrapping up safely"
        case .automatic:
            return "Watching for agents"
        }
    }

    private var heroSubtitle: String {
        if model.instantControlState == .installing {
            return "Approve once; future mode changes happen without prompts."
        }
        if model.state == .loading {
            return "Checking the system-wide setting and local activity."
        }
        if model.state == .unavailable {
            return "WakeBar could not verify the current macOS sleep setting."
        }
        if policyNeedsSetup {
            switch model.policyMode {
            case .off:
                return "Finish setup to turn off the current system sleep lock."
            case .automatic:
                return "Finish setup so AUTO can block sleep for this local work."
            case .on:
                return "Finish setup to block system sleep without future prompts."
            }
        }

        switch model.policyMode {
        case .off where model.hasAgentsWhileOff:
            return "OFF is a manual override. macOS may sleep while this work is running."
        case .off:
            return "WakeBar will not hold the Mac awake."
        case .on:
            return "System sleep stays blocked until you choose OFF or AUTO."
        case .automatic where !localAgentWatchHealthy:
            return "Detection will retry locally; WakeBar will not release on an uncertain scan."
        case .automatic where model.activeAgentCount > 0:
            return "AUTO detected local work and blocked system sleep."
        case .automatic where model.isHoldingAutoGrace:
            return "The last agent stopped. Sleep returns after a short safety window."
        case .automatic:
            return "Sleep stays normal until local agent work begins."
        }
    }

    private var sleepLockSymbol: String {
        switch model.state {
        case .loading:
            return "ellipsis.circle"
        case .enabled:
            return "lock.fill"
        case .disabled:
            return "lock.open.fill"
        case .unavailable:
            return "questionmark.circle.fill"
        }
    }

    private var sleepLockDetail: String {
        switch model.state {
        case .loading:
            return "Checking"
        case .enabled:
            return "Enabled"
        case .disabled:
            return "Off"
        case .unavailable:
            return "Unknown"
        }
    }

    private var systemLockLabel: String {
        switch model.state {
        case .enabled:
            return "SLEEP LOCK ON"
        case .disabled:
            return "SLEEP LOCK OFF"
        case .loading:
            return "CHECKING LOCK"
        case .unavailable:
            return "LOCK UNKNOWN"
        }
    }

    private var instantControlDetail: String {
        switch model.instantControlState {
        case .checking:
            return "Checking"
        case .setupRequired:
            return "Setup once"
        case .installing:
            return "Installing"
        case .ready:
            return "No prompts"
        }
    }

    private var safetyMessage: String {
        if model.powerSnapshot.source == .battery {
            return "On battery. Connect power before closing the lid; shutdown will stop your agents."
        }

        return "Keep the closed Mac uncovered on a hard, ventilated surface—never in a bag or sleeve."
    }

    private func modeSymbol(_ mode: WakePolicyMode) -> String {
        switch mode {
        case .off: return "moon.fill"
        case .automatic: return "wand.and.stars"
        case .on: return "bolt.fill"
        }
    }

    private func modeTint(_ mode: WakePolicyMode) -> Color {
        switch mode {
        case .off: return .secondary
        case .automatic: return .blue
        case .on: return .cyan
        }
    }

    private func modeAccessibilityLabel(_ mode: WakePolicyMode) -> String {
        switch mode {
        case .off:
            return "Off, restore normal macOS sleep"
        case .automatic:
            return "Automatic, stay awake only while local agents are active"
        case .on:
            return "On, always block system sleep"
        }
    }

    private func runtimeSymbol(_ runtime: AgentRuntime) -> String {
        switch runtime {
        case .codex, .openCode, .copilot, .gemini, .aider, .goose, .amp,
             .factory, .codebuff, .crush, .deepSeek, .minimax, .groq:
            return "terminal.fill"
        case .claude:
            return "sparkles"
        case .cursor, .cline, .kilo:
            return "cursorarrow.rays"
        case .antigravity:
            return "paperplane.fill"
        case .kiro, .qoder:
            return "hammer.fill"
        }
    }

    private func activityProjectLabel(_ activity: AgentActivity) -> String {
        if let project = activity.projectName, !project.isEmpty {
            return project
        }

        switch activity.evidence {
        case .lifecycle:
            return "Thread running"
        case .liveProcess:
            return "Agent process running"
        case .recentTranscript:
            return "Recent local activity"
        case .processActivity:
            return "Local work in progress"
        }
    }
}
