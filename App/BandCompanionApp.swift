import SwiftUI

@main
struct BandCompanionApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: model.sceneBecameActive()
                    case .background: model.sceneLeftForeground()
                    default: break
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var started = false

    var body: some View {
        Group {
            if model.paired == nil || (model.isDemo && ["pairing", "address"].contains(DemoData.requestedScreen ?? "")) {
                PairingView()
            } else {
                MainTabs()
            }
        }
        .task {
            guard !started else { return }
            started = true
            await model.start()
        }
    }
}

struct MainTabs: View {
    private enum Screen {
        case today, trends, device
    }

    @State private var selection: Screen = {
        switch DemoData.requestedScreen {
        case "trends": return .trends
        case "device", "diagnostics": return .device
        default: return .today
        }
    }()

    var body: some View {
        TabView(selection: $selection) {
            TodayView()
                .tabItem { Label("Today", systemImage: "figure.walk") }
                .tag(Screen.today)
            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.bar.fill") }
                .tag(Screen.trends)
            DeviceView()
                .tabItem { Label("Band", systemImage: "applewatch.side.right") }
                .tag(Screen.device)
        }
    }
}
