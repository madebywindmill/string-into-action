import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: projectsColumnVisibility) {
            ProjectsSidebarView()
                .navigationSplitViewColumnWidth(min: 92, ideal: 108, max: 128)
                .toolbar(removing: .sidebarToggle)
        } content: {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 390)
        } detail: {
            Group {
                if let occurrence = model.selectedOccurrence {
                    StringDetailView(occurrence: occurrence)
                        .id(occurrence.fileURL.path + ":" + occurrence.id)
                } else if model.projectURL == nil {
                    WelcomeView()
                } else if model.isScanning {
                    LoadingView()
                } else if model.occurrences.isEmpty {
                    EmptyProjectView()
                } else {
                    CompletedView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(model.isScanning)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: model.chooseProject) {
                    Label("Open Project", systemImage: "folder")
                }
                .help("Open Project (⌘O)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(action: model.refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.projectURL == nil || model.isScanning)
                .help("Refresh Strings (⌘R)")
            }
        }
        .alert("String Into Action", isPresented: Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.presentedError = nil } }
        )) {
            Button("OK", role: .cancel) { model.presentedError = nil }
        } message: {
            Text(model.presentedError ?? "")
        }
        .alert("Approve All Strings?", isPresented: $model.isApproveAllConfirmationPresented) {
            Button("Cancel", role: .cancel) { model.cancelApproveAllQueuedStrings() }
            Button("Approve All") { model.confirmApproveAllQueuedStrings() }
        } message: {
            Text(model.approveAllConfirmationMessage)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.projectURL != nil, !model.isScanning {
                model.refresh()
            }
        }
    }

    private var projectsColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.showsProjectsSidebar ? .all : .doubleColumn },
            set: { visibility in
                if visibility == .all {
                    model.setProjectsSidebarVisible(true)
                } else if visibility == .doubleColumn || visibility == .detailOnly {
                    model.setProjectsSidebarVisible(false)
                }
            }
        )
    }
}
