import SwiftUI

@main
struct ScreechApp: App {
    @StateObject private var model = ScreechModel()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
        }
    }
}
