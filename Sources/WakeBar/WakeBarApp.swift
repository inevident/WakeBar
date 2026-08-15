import SwiftUI

@main
@MainActor
struct WakeBarApp: App {
    @StateObject private var model = SleepControlModel()

    var body: some Scene {
        MenuBarExtra {
            WakeBarPopoverView(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel(model.menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)
    }
}
