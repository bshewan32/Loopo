import SwiftUI

@main
struct LoopoApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var locationService = LocationService.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .onAppear {
                    locationService.requestPermission()
                }
        }
    }
}
