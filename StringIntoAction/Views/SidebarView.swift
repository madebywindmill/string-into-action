import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            if let projectURL = model.projectURL {
                ProjectSummaryView(projectURL: projectURL)
                    .padding(.horizontal, 15)
                    .padding(.top, 15)
                    .padding(.bottom, 14)

                Divider()

                if model.filteredOccurrences.isEmpty, !model.isScanning {
                    ContentUnavailableView(
                        model.searchText.isEmpty ? "Nothing Here" : "No Results",
                        systemImage: model.filter == .approved ? "checkmark.circle" : "text.magnifyingglass",
                        description: Text(emptyDescription)
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    List(selection: $model.selectedID) {
                        if model.searchText.isEmpty {
                            OutlineGroup(model.sidebarNodes, children: \.children) { node in
                                SidebarNodeRow(node: node)
                            }
                        } else {
                            ForEach(model.filteredOccurrences) { occurrence in
                                StringRow(
                                    occurrence: occurrence,
                                    state: model.reviewState(for: occurrence),
                                    showsPath: true
                                )
                                .tag(occurrence.id)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            } else {
                Spacer()
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No Project Open")
                    .font(.headline)
                    .padding(.top, 10)
                Text("Choose a source folder to begin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Spacer()
            }
        }
        .background(.regularMaterial)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search strings")
        .onChange(of: model.filter) { _, _ in model.ensureSelectionIsVisible() }
        .onChange(of: model.searchText) { _, _ in model.ensureSelectionIsVisible() }
    }

    private var emptyDescription: String {
        if !model.searchText.isEmpty { return "Try different text from a flagged string." }
        switch model.filter {
        case .needsReview: return "The review queue is empty!"
        case .all: return "No user-facing strings were discovered."
        case .approved: return "Approved strings will appear here."
        case .ignored: return "Strings marked as non-user-facing will appear here."
        }
    }
}

private struct ProjectSummaryView: View {
    @Environment(AppModel.self) private var model
    let projectURL: URL

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Text("STRING REVIEW")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Picker("Filter", selection: $model.filter) {
                    ForEach(ReviewFilter.allCases) { filter in
                        Label(filter.rawValue, systemImage: filter.symbol).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }

            Text(projectURL.lastPathComponent)
                .font(.title2.weight(.semibold))
                .lineLimit(1)

            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Review progress")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.approvedCount) of \(model.occurrences.count - model.ignoredCount)")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: model.progress)
                    .tint(
                        model.reviewCount == 0 && !model.occurrences.isEmpty
                            ? .green : .accentColor
                    )
            }

            HStack(spacing: 8) {
                Label("\(model.reviewCount) to review", systemImage: "circle.dotted")

                Spacer(minLength: 8)

                Label("\(model.filesScanned) files", systemImage: "doc.on.doc")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct StringRow: View {
    let occurrence: StringOccurrence
    let state: ReviewState
    var showsPath = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: state.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(occurrence.summary)
                    .font(.body)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    if showsPath {
                        Image(systemName: occurrence.language.symbol)
                        Text(occurrence.relativePath)
                            .lineLimit(1)
                        Text("—")
                    }
                    Text("Line \(occurrence.line)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(occurrence.summary), \(state.label), \(occurrence.locationDescription)")
    }

    private var statusColor: Color {
        switch state {
        case .approved: .green
        case .changed: .orange
        case .ignored: .gray
        case .needsReview: .secondary
        }
    }
}

private struct SidebarNodeRow: View {
    @Environment(AppModel.self) private var model
    let node: SidebarNode

    var body: some View {
        switch node.kind {
        case .folder:
            ContainerRow(
                title: node.title,
                symbol: "folder",
                count: node.stringCount,
                isFolder: true
            )
        case .file:
            ContainerRow(
                title: node.title,
                symbol: node.language?.symbol ?? "doc.text",
                count: node.stringCount,
                isFolder: false
            )
        case .string:
            if let occurrence = node.occurrence {
                StringRow(
                    occurrence: occurrence,
                    state: model.reviewState(for: occurrence)
                )
                .tag(occurrence.id)
            }
        }
    }
}

private struct ContainerRow: View {
    let title: String
    let symbol: String
    let count: Int
    let isFolder: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isFolder ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(title)
                .font(isFolder ? .callout.weight(.medium) : .callout)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityLabel("\(title), \(count) strings")
    }
}
