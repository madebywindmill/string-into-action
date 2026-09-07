import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 104, height: 104)
                    .shadow(color: .accentColor.opacity(0.22), radius: 18, y: 9)
                Image(systemName: "quote.opening")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white, .green)
                            .offset(x: 17, y: 12)
                    }
            }

            VStack(spacing: 7) {
                Text("Review every word your app UI")
                    .font(.system(size: 30, weight: .bold))
                Text("Find user-facing strings, see them in context,\nand approve or tweak them as needed.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            Button("Open a Project…", systemImage: "folder") {
                model.chooseProject()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("o")
        }
        .padding(50)
    }
}

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Looking for user-facing strings…")
                .font(.headline)
            Text("Build products and dependencies are skipped automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct EmptyProjectView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("No Strings Found", systemImage: "text.magnifyingglass")
        } description: {
            Text("This project doesn’t contain supported user-facing strings yet.")
        } actions: {
            Button("Scan Again") { model.refresh() }
        }
    }
}

struct CompletedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            switch model.filter {
            case .needsReview:
                ContentUnavailableView {
                    Label("Review Queue Clear", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } description: {
                    Text("You’re all caught up. New or changed text will appear here for review.")
                } actions: {
                    Button("Show All Strings") { model.filter = .all }
                }
            case .approved:
                empty(title: "No Approved Strings", symbol: "checkmark.circle", detail: "Approved strings will appear here.")
            case .ignored:
                empty(title: "No Ignored Strings", symbol: "eye.slash", detail: "Strings marked as non-user-facing will appear here.")
            case .all:
                empty(title: "No Strings", symbol: "text.magnifyingglass", detail: "No reviewable strings were discovered in this project.")
            }
        }
    }

    private func empty(title: String, symbol: String, detail: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
    }

}
