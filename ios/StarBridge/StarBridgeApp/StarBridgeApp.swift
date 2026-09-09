import SwiftUI

@main
struct StarBridgeApp: App {
    @StateObject private var model = ChatModel()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
        }
    }
}
