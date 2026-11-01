import SwiftUI

#if canImport(MWDATCore)
import MWDATCore
#endif

@main
struct EANShopperApp: App {
    @StateObject private var glasses = GlassesManager()

    init() {
        // Arranque liviano: el SDK de lentes se configura en segundo plano
        // tras el primer frame (ver ContentView.task).
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(glasses)
        }
    }
}
