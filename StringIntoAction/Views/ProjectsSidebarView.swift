import AppKit
import SwiftUI

struct ProjectsSidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var isProjectDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PROJECTS")
                    .font(.caption2.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(action: model.chooseProject) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .help("Add Project…")
            }
            .padding(.leading, 13)
            .padding(.trailing, 11)
            .padding(.top, 16)
            .padding(.bottom, 11)

            Divider()

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(model.rememberedProjects, id: \.path) { projectURL in
                        ProjectRailItem(
                            projectURL: projectURL,
                            isSelected: model.projectURL == projectURL
                        )
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 8)
            }
        }
        .background(.regularMaterial)
        .dropDestination(for: URL.self) { urls, _ in
            model.addDroppedProjects(urls)
        } isTargeted: { isTargeted in
            isProjectDropTarget = isTargeted
        }
        .overlay {
            if isProjectDropTarget {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct ProjectRailItem: View {
    @Environment(AppModel.self) private var model
    let projectURL: URL
    let isSelected: Bool
    @State private var isDropTarget = false

    var body: some View {
        Button {
            guard !isSelected else { return }
            Task { await model.openProject(projectURL) }
        } label: {
            VStack(spacing: 5) {
                ProjectAppIcon(projectURL: projectURL)
                    .frame(width: 38, height: 38)
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected, model.isScanning {
                            ProgressView()
                                .controlSize(.mini)
                                .padding(3)
                                .background(.regularMaterial, in: Circle())
                                .offset(x: 3, y: 3)
                        }
                    }

                Text(projectURL.lastPathComponent)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.095) : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .draggable(projectURL.path) {
            ProjectAppIcon(projectURL: projectURL)
                .frame(width: 38, height: 38)
        }
        .dropDestination(for: String.self) { paths, location in
            guard let sourcePath = paths.first,
                  model.rememberedProjects.contains(where: { $0.path == sourcePath }) else { return false }
            model.moveProject(
                at: sourcePath,
                relativeTo: projectURL,
                placingAfter: location.y > 34
            )
            return true
        } isTargeted: { isTargeted in
            isDropTarget = isTargeted
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(1)
                    .allowsHitTesting(false)
            }
        }
        .help(projectURL.path)
        .contextMenu {
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([projectURL])
            }
            Divider()
            Button("Remove from Projects", systemImage: "minus.circle", role: .destructive) {
                model.forgetProject(projectURL)
            }
        }
        .accessibilityLabel("\(projectURL.lastPathComponent) project")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ProjectAppIcon: View {
    let projectURL: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.11))
                    Image(systemName: "folder.fill")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Color.accentColor.opacity(0.8))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .task(id: projectURL.path) {
            let data = await Task.detached(priority: .utility) {
                guard let url = ProjectIconResolver().iconURL(for: projectURL) else { return nil as Data? }
                return try? Data(contentsOf: url)
            }.value
            guard !Task.isCancelled else { return }
            image = data.flatMap(NSImage.init(data:))
        }
    }
}
