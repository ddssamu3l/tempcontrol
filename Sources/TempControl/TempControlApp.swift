import SwiftUI
import Shared

@main
struct TempControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = MetricsStore()

    var body: some Scene {
        MenuBarExtra {
            DashboardView()
                .environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar shows a thermometer plus the live hottest die temp; switches to a
/// flame while the fan boost is actively engaged.
struct MenuBarLabel: View {
    @ObservedObject var store: MetricsStore

    var body: some View {
        let boosting = store.snap.control?.engaged == true
        HStack(spacing: 2) {
            Image(systemName: boosting ? "flame.fill" : "thermometer.medium")
            if let t = store.snap.hottest {
                Text("\(Int(t))°")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — no Dock icon (also covered by LSUIElement in the bundle).
        NSApp.setActivationPolicy(.accessory)
    }
}
