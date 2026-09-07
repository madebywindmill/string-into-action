import AppKit
import SwiftUI

struct StringDetailView: View {
    @Environment(AppModel.self) private var model
    let occurrence: StringOccurrence
    @State private var draft: String
    @State private var draftOccurrence: StringOccurrence
    @StateObject private var optionKey = OptionKeyMonitor()
    @FocusState private var isEditorFocused: Bool

    init(occurrence: StringOccurrence) {
        self.occurrence = occurrence
        _draft = State(initialValue: occurrence.value)
        _draftOccurrence = State(initialValue: occurrence)
    }

    private var state: ReviewState { model.reviewState(for: occurrence) }
    private var hasChanges: Bool { draft != occurrence.value }
    private var primaryShortcutModifiers: EventModifiers {
        isEditorFocused ? .command : []
    }
    private var approveShortcutModifiers: EventModifiers {
        optionKey.isPressed ? primaryShortcutModifiers.union(.option) : primaryShortcutModifiers
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                editor
                context
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 30)
            .padding(.bottom, 42)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: occurrence) { old, updated in
            // Keep an unsaved draft and its original fingerprint across refreshes.
            if draft == old.value {
                draft = updated.value
                draftOccurrence = updated
            }
        }
        .onChange(of: model.stringEditorFocusRequest) { _, _ in
            guard occurrence.isEditable, state != .ignored else { return }
            isEditorFocused = true
        }
        .onAppear { optionKey.start() }
        .onDisappear { optionKey.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            optionKey.refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatusPill(state: state)
                Spacer()
                Menu {
                    Button("Open in Default Editor", systemImage: "arrow.up.forward.app") {
                        model.openInDefaultEditor(occurrence)
                    }
                    Button("Reveal in Finder", systemImage: "folder") {
                        model.revealInFinder(occurrence)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Text(occurrence.fileName)
                .font(.system(size: 30, weight: .bold))
                .lineLimit(1)

            HStack(spacing: 7) {
                Label(occurrence.language.rawValue, systemImage: occurrence.language.symbol)
                Text("—")
                Text(occurrence.locationDescription)
                    .textSelection(.enabled)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Label(occurrence.detectionReason, systemImage: "scope")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("User-facing string")
                    .font(.headline)
                Spacer()
                if hasChanges {
                    Text("Edited")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }

            TextEditor(text: $draft)
                .focused($isEditorFocused)
                .font(.system(size: 17, weight: .regular, design: .rounded))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 118)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.separator.opacity(0.75), lineWidth: 1)
                }
                .disabled(!occurrence.isEditable || state == .ignored)

            if !occurrence.isEditable {
                Label(editRestrictionMessage, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                if state == .ignored {
                    Button("Restore to Review", systemImage: "arrow.uturn.backward") {
                        model.restoreIgnored(occurrence)
                    }
                } else {
                    Button("Not User-Facing", systemImage: "eye.slash") {
                        model.ignore(occurrence)
                    }
                    if state == .approved && !hasChanges {
                        Button("Mark for Review", systemImage: "arrow.uturn.backward") {
                            model.markForReview(occurrence)
                        }
                    } else if hasChanges {
                        Button("Revert") {
                            draft = occurrence.value
                            draftOccurrence = occurrence
                        }
                    }
                }

                Spacer()

                if hasChanges {
                    Button("Save & Approve", systemImage: "checkmark") {
                        model.saveAndApprove(draft, for: draftOccurrence)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!occurrence.isEditable || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: primaryShortcutModifiers)
                } else if state != .approved && state != .ignored {
                    Button {
                        if optionKey.isPressed {
                            model.approveAllQueuedInFile(containing: occurrence)
                        } else {
                            model.approve(occurrence)
                        }
                    } label: {
                        Label(
                            optionKey.isPressed ? "Approve All in File" : "Approve",
                            systemImage: optionKey.isPressed ? "checkmark.circle" : "checkmark"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: approveShortcutModifiers)
                } else {
                    Label(state == .ignored ? "Ignored" : "Approved", systemImage: state.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(state == .ignored ? Color.secondary : .green)
                }
            }
        }
    }

    private var editRestrictionMessage: String {
        if occurrence.language == .stringCatalog {
            return "String Catalog entries can be reviewed here, but should be edited in Xcode."
        }
        return "This literal uses syntax that cannot safely be edited here. It can be reviewed here, but should be edited in source."
    }

    private var context: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Source context")
                    .font(.headline)
                Spacer()
                Text("Line \(occurrence.line)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(occurrence.contextLines) { line in
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(line.number)")
                            .foregroundStyle(line.isSelected ? Color.accentColor : .secondary.opacity(0.65))
                            .frame(width: 35, alignment: .trailing)
                            .textSelection(.disabled)
                        Text(SourceSyntaxHighlighter.highlight(
                            line.text.isEmpty ? " " : line.text,
                            as: occurrence.language
                        ))
                            .opacity(line.isSelected ? 1 : 0.72)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 5)
                    .background(line.isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
                }
            }
            .padding(.vertical, 8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.separator.opacity(0.7), lineWidth: 1)
            }
        }
    }
}

@MainActor
private final class OptionKeyMonitor: ObservableObject {
    @Published private(set) var isPressed = false
    private var eventMonitor: Any?

    func start() {
        guard eventMonitor == nil else { return }
        refresh()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.isPressed = event.modifierFlags.contains(.option)
            }
            return event
        }
    }

    func stop() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        isPressed = false
    }

    func refresh() {
        isPressed = NSEvent.modifierFlags.contains(.option)
    }
}

private struct StatusPill: View {
    let state: ReviewState

    private var tint: Color {
        switch state {
        case .changed: .orange
        case .needsReview: .secondary
        case .approved: .green
        case .ignored: .secondary
        }
    }

    var body: some View {
        Label(state.label.uppercased(), systemImage: state.symbol)
            .font(.caption2.weight(.bold))
            .tracking(0.45)
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.11), in: Capsule())
    }
}
