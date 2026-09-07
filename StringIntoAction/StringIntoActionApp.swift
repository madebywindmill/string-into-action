import SwiftUI

@main
struct StringIntoActionApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") { model.chooseProject() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                Button("Refresh Strings") { model.refresh() }
                    .keyboardShortcut("r")
                    .disabled(model.projectURL == nil || model.isScanning)
            }
            CommandGroup(after: .pasteboard) {
                Button("Edit String") { model.focusStringEditor() }
                    .keyboardShortcut("e")
                    .disabled(!model.canEditSelectedString)
            }
            CommandGroup(after: .sidebar) {
                Button(model.showsProjectsSidebar ? "Hide Projects in Sidebar" : "Show Projects in Sidebar") {
                    model.toggleProjectsSidebar()
                }
            }
            CommandMenu("Review") {
                Button("Approve All…") { model.requestApproveAllQueuedStrings() }
                    .disabled(!model.canApproveAllQueuedStrings)

                Divider()

                Button("Not User-Facing") { model.ignoreSelectedString() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(!model.canIgnoreSelectedString)
            }
        }
    }
}
