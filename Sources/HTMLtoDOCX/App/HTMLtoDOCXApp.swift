import SwiftUI

@main
struct HTMLtoDOCXApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup("HTML to DOCX") {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 560, minHeight: 360)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
