import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            PlanRouteView()
                .tabItem {
                    Label("Plan", systemImage: "arrow.triangle.2.circlepath")
                }
                .tag(0)
            
            RideHistoryView()
                .tabItem {
                    Label("Rides", systemImage: "list.bullet.clipboard")
                }
                .tag(1)
        }
        .accentColor(Color("LoopGreen"))
        .onAppear {
            setupTabBarAppearance()
        }
    }
    
    private func setupTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}
