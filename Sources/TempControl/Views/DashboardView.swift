import SwiftUI
import ServiceManagement
import Shared

/// Add a case + view here to grow the app with more sections later.
enum Panel: String, CaseIterable {
    case temp = "TEMP"
    case soc = "SOC"
    case storage = "STORAGE"
    case battery = "BATTERY"
}

struct DashboardView: View {
    @EnvironmentObject var store: MetricsStore
    @State private var panel: Panel = .temp

    var body: some View {
        VStack(spacing: 8) {
            header
            TUITabBar(tabs: Panel.allCases.map { ($0, $0.rawValue) }, selection: $panel)
                .padding(.horizontal, 12)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    if store.sysInfo.isAppleSilicon {
                        switch panel {
                        case .temp:
                            TempPanel()
                        case .soc:
                            SoCView()
                        case .storage:
                            StoragePanel()
                        case .battery:
                            BatteryPanel()
                        }
                    } else {
                        Text("TEMPCONTROL REQUIRES APPLE SILICON")
                            .font(TUI.mono(11)).foregroundStyle(TUI.red)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            footer
        }
        .frame(width: 470, height: 700)
        .background(TUI.bg)
        .onAppear { store.popoverOpen = true }
        .onDisappear { store.popoverOpen = false }
    }

    private var header: some View {
        HStack {
            Text("TEMPCONTROL")
                .font(TUI.mono(12, .bold)).foregroundStyle(TUI.fg)
            Text("v0.1").font(TUI.mono(9)).foregroundStyle(TUI.faint)
            Spacer()
            if let sys = store.snap.systemPowerW {
                Text(String(format: "SYS %.1fW", sys))
                    .font(TUI.mono(12, .bold))
                    .foregroundStyle(TUI.amber)
            }
            if let pressure = store.snap.pm?.thermalPressure {
                Text("THERMAL: \(pressure.uppercased())")
                    .font(TUI.mono(9, .bold))
                    .foregroundStyle(pressure == "Nominal" ? TUI.mem : TUI.red)
            }
            Circle()
                .fill(store.snap.helperAvailable ? TUI.mem : TUI.red)
                .frame(width: 6, height: 6)
            Text(store.snap.helperAvailable ? "HELPER" : "NO HELPER")
                .font(TUI.mono(9)).foregroundStyle(TUI.dim)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var footer: some View {
        HStack {
            LoginToggle()
            Spacer()
            TUIButton(label: "[ QUIT ]", activeColor: TUI.red) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

/// "Start at login" via SMAppService — only meaningful when running from the
/// installed .app bundle.
struct LoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        TUIButton(label: enabled ? "[ LAUNCH ON MAC START: ON ]" : "[ LAUNCH ON MAC START: OFF ]",
                  active: enabled,
                  activeColor: TUI.mem) {
            do {
                if enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
                enabled = SMAppService.mainApp.status == .enabled
            } catch {
                enabled = SMAppService.mainApp.status == .enabled
            }
        }
    }
}
