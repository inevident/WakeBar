import SwiftUI

@main
@MainActor
struct WakeBarApp: App {
    @StateObject private var model = SleepControlModel()

    var body: some Scene {
        MenuBarExtra {
            WakeBarPopoverView(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.menuBarSymbol)
                Text(model.menuBarText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
                .accessibilityLabel(model.menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)
    }
}
